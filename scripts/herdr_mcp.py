#!/usr/bin/env python3
# Managed by herdr-codex-team. Edit this source file and rerun scripts/install.sh.

"""A narrow stdio MCP bridge from one Herdr Planner to its own team.

Codex shell sandboxes on Linux currently reject AF_UNIX before Herdr's CLI can
reach its socket. Local stdio MCP servers run outside that shell sandbox, so
this bridge owns the socket-facing boundary while exposing only two bounded
operations: prove the current Planner/team identity, and prompt one exact
same-team Coder or Reviewer with wait/read correlation.
"""

import json
import os
import re
import stat
import subprocess
import sys
from typing import Any, Callable, Dict, Iterable, List, Mapping, Optional


SERVER_NAME = "herdr-codex-team"
SERVER_VERSION = "1"
DEFAULT_PROTOCOL_VERSION = "2025-06-18"
SUPPORTED_PROTOCOL_VERSIONS = {
    "2024-11-05",
    "2025-03-26",
    "2025-06-18",
    "2025-11-25",
}
MAX_MESSAGE_BYTES = 1024 * 1024
MAX_HERDR_OUTPUT_BYTES = 4 * 1024 * 1024
MAX_PROMPT_CHARS = 131072
AGENT_NAME_RE = re.compile(r"^[a-z][a-z0-9_-]{0,31}$")
TEAM_PREFIX_RE = re.compile(r"^[a-z][a-z0-9_-]{0,22}$")
PANE_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9:._-]{0,63}$")


class BridgeError(RuntimeError):
    """Stable, user-visible bridge failure without a Python traceback."""


def _has_unsafe_control(value: str, allow_newlines: bool = False) -> bool:
    for character in value:
        codepoint = ord(character)
        if allow_newlines and character in ("\n", "\t"):
            continue
        if codepoint < 32 or 127 <= codepoint <= 159:
            return True
    return False


def _required_mapping(value: Any, label: str) -> Dict[str, Any]:
    if not isinstance(value, dict):
        raise BridgeError("%s is not a JSON object" % label)
    return value


def _required_string(value: Any, label: str) -> str:
    if (
        not isinstance(value, str)
        or not value
        or _has_unsafe_control(value)
    ):
        raise BridgeError("%s is not a safe non-empty string" % label)
    return value


def _required_bool(value: Any, label: str) -> bool:
    if not isinstance(value, bool):
        raise BridgeError("%s is not a boolean" % label)
    return value


def _required_sequence(value: Any, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise BridgeError("%s is not a non-negative integer" % label)
    return value


def _result_object(payload: Mapping[str, Any], field: str) -> Dict[str, Any]:
    result = _required_mapping(payload.get("result"), "Herdr result")
    return _required_mapping(result.get(field), "Herdr result.%s" % field)


def _typed_result(payload: Mapping[str, Any], expected_type: str) -> Dict[str, Any]:
    result = _required_mapping(payload.get("result"), "Herdr result")
    result_type = _required_string(result.get("type"), "Herdr result.type")
    if result_type != expected_type:
        raise BridgeError(
            "Herdr result type is %s, expected %s" % (result_type, expected_type)
        )
    return result


def _default_socket_validator(path: str) -> None:
    if not os.path.isabs(path) or _has_unsafe_control(path):
        raise BridgeError("HERDR_SOCKET_PATH must be a safe absolute path")
    try:
        metadata = os.lstat(path)
    except OSError as error:
        raise BridgeError("HERDR_SOCKET_PATH is not inspectable: %s" % error) from error
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISSOCK(metadata.st_mode):
        raise BridgeError("HERDR_SOCKET_PATH is not a direct Unix socket")
    if hasattr(os, "getuid") and metadata.st_uid != os.getuid():
        raise BridgeError("HERDR_SOCKET_PATH is not owned by the current user")


class HerdrCommandRunner:
    """Invoke only the installed Herdr binary, without a shell."""

    _FORWARDED_ENV = {
        "HOME",
        "LANG",
        "LC_ALL",
        "LC_CTYPE",
        "LOGNAME",
        "PATH",
        "TERM",
        "TMPDIR",
        "USER",
        "XDG_CONFIG_HOME",
        "XDG_RUNTIME_DIR",
        "HERDR_BIN_PATH",
        "HERDR_ENV",
        "HERDR_SOCKET_PATH",
        "HERDR_SESSION",
        "HERDR_PANE_ID",
        "HERDR_TAB_ID",
        "HERDR_WORKSPACE_ID",
    }

    def __init__(self, env: Mapping[str, str]):
        self._env = dict(env)
        self._binary = self._resolve_binary()

    def _resolve_binary(self) -> str:
        candidate = self._env.get("HERDR_BIN_PATH", "")
        if (
            not isinstance(candidate, str)
            or not candidate
            or not os.path.isabs(candidate)
            or _has_unsafe_control(candidate)
        ):
            raise BridgeError("HERDR_BIN_PATH must be a safe absolute path")
        resolved = os.path.realpath(candidate)
        if not os.path.isfile(resolved) or not os.access(resolved, os.X_OK):
            raise BridgeError("HERDR_BIN_PATH does not resolve to a runnable regular file")
        return resolved

    def _run(self, args: Iterable[str], timeout_ms: int) -> subprocess.CompletedProcess:
        argv = [self._binary]
        for argument in args:
            if not isinstance(argument, str) or "\x00" in argument:
                raise BridgeError("Herdr argv contains an invalid value")
            argv.append(argument)
        child_env = {
            key: value
            for key, value in self._env.items()
            if key in self._FORWARDED_ENV and isinstance(value, str)
        }
        try:
            completed = subprocess.run(
                argv,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                encoding="utf-8",
                errors="replace",
                env=child_env,
                timeout=max(timeout_ms, 1000) / 1000.0,
                check=False,
            )
        except subprocess.TimeoutExpired as error:
            raise BridgeError("Herdr command timed out") from error
        except OSError as error:
            raise BridgeError("Herdr command could not start: %s" % error) from error

        stdout = completed.stdout
        stderr = completed.stderr.strip()
        if len(stdout.encode("utf-8")) > MAX_HERDR_OUTPUT_BYTES:
            raise BridgeError("Herdr command output exceeded the bridge limit")
        if completed.returncode != 0:
            detail = stderr or stdout.strip() or "no diagnostic"
            if len(detail) > 2000:
                detail = detail[:2000] + "..."
            raise BridgeError(
                "Herdr command failed with exit status %s: %s"
                % (completed.returncode, detail)
            )
        return completed

    def __call__(self, args: Iterable[str], timeout_ms: int) -> Dict[str, Any]:
        completed = self._run(args, timeout_ms)
        try:
            payload = json.loads(completed.stdout)
        except (TypeError, ValueError) as error:
            raise BridgeError("Herdr command returned malformed JSON") from error
        return _required_mapping(payload, "Herdr response")

    def read_text(self, args: Iterable[str], timeout_ms: int) -> str:
        """Run one Herdr read command whose public CLI intentionally emits text."""
        return self._run(args, timeout_ms).stdout


class HerdrBridge:
    """Planner-only, same-team Herdr orchestration boundary."""

    def __init__(
        self,
        env: Optional[Mapping[str, str]] = None,
        runner: Optional[Callable[[Iterable[str], int], Dict[str, Any]]] = None,
        text_runner: Optional[Callable[[Iterable[str], int], str]] = None,
        socket_validator: Optional[Callable[[str], None]] = None,
    ):
        self._env = dict(os.environ if env is None else env)
        if runner is None:
            command_runner = HerdrCommandRunner(self._env)
            self._runner = command_runner
            self._text_runner = text_runner or command_runner.read_text
        else:
            self._runner = runner
            self._text_runner = text_runner or getattr(runner, "read_text", None)
        self._socket_validator = socket_validator or _default_socket_validator

    def _validate_runtime(self) -> str:
        if self._env.get("HERDR_ENV") != "1":
            raise BridgeError("HERDR_ENV is not 1; this profile is not in a Herdr pane")
        pane_id = self._env.get("HERDR_PANE_ID", "")
        if not PANE_ID_RE.fullmatch(pane_id):
            raise BridgeError("HERDR_PANE_ID is missing or invalid")
        socket_path = self._env.get("HERDR_SOCKET_PATH", "")
        self._socket_validator(socket_path)
        return pane_id

    def _call(self, args: Iterable[str], timeout_ms: int = 10000) -> Dict[str, Any]:
        try:
            return self._runner(args, timeout_ms)
        except BridgeError:
            raise
        except Exception as error:
            raise BridgeError("Herdr bridge call failed: %s" % error) from error

    def _read_text(self, args: Iterable[str], timeout_ms: int = 10000) -> str:
        if not callable(self._text_runner):
            raise BridgeError("Herdr bridge text reader is unavailable")
        try:
            result = self._text_runner(args, timeout_ms)
        except BridgeError:
            raise
        except Exception as error:
            raise BridgeError("Herdr bridge text read failed: %s" % error) from error
        if not isinstance(result, str):
            raise BridgeError("Herdr bridge text read returned a non-string value")
        return result

    @staticmethod
    def _validate_agent(
        agent: Mapping[str, Any],
        expected_name: str,
        expected_workspace: str,
        require_ready: bool,
    ) -> Dict[str, Any]:
        name = _required_string(agent.get("name"), "%s name" % expected_name)
        if name != expected_name:
            raise BridgeError(
                "Herdr lookup for %s resolved to %s" % (expected_name, name)
            )
        if not AGENT_NAME_RE.fullmatch(name):
            raise BridgeError("Herdr agent name is invalid: %s" % name)
        pane_id = _required_string(agent.get("pane_id"), "%s pane_id" % name)
        if not PANE_ID_RE.fullmatch(pane_id):
            raise BridgeError("Herdr agent %s has an invalid pane_id" % name)
        workspace_id = _required_string(
            agent.get("workspace_id"), "%s workspace_id" % name
        )
        if workspace_id != expected_workspace:
            raise BridgeError(
                "Herdr agent %s is in workspace %s, expected %s"
                % (name, workspace_id, expected_workspace)
            )
        kind = _required_string(agent.get("agent"), "%s agent kind" % name)
        if kind != "codex":
            raise BridgeError("Herdr agent %s is not a Codex agent" % name)
        status_value = agent.get("agent_status")
        status_text = _required_string(status_value, "%s agent_status" % name)
        if status_text not in ("idle", "done", "working", "blocked", "unknown"):
            raise BridgeError("Herdr agent %s has an unsupported lifecycle state" % name)
        if "launch_pending" in agent and _required_bool(
            agent.get("launch_pending"), "%s launch_pending" % name
        ):
            raise BridgeError("Herdr agent %s launch is still pending" % name)
        interactive_ready = agent.get("interactive_ready")
        if require_ready or "interactive_ready" in agent:
            interactive_ready = _required_bool(
                interactive_ready, "%s interactive_ready" % name
            )
            if require_ready and not interactive_ready:
                raise BridgeError("Herdr agent %s is not interactively ready" % name)
        if require_ready and status_text not in ("idle", "done"):
            raise BridgeError(
                "Herdr agent %s is not settled and ready: %s" % (name, status_text)
            )
        state_change_seq = _required_sequence(
            agent.get("state_change_seq"), "%s state_change_seq" % name
        )
        return {
            "name": name,
            "pane_id": pane_id,
            "workspace_id": workspace_id,
            "agent": kind,
            "agent_status": status_text,
            "interactive_ready": interactive_ready,
            "launch_pending": agent.get("launch_pending"),
            "state_change_seq": state_change_seq,
        }

    @staticmethod
    def _derive_team(self_name: str) -> Dict[str, str]:
        if self_name == "planner":
            return {
                "team_prefix": "LEGACY",
                "coder": "coder",
                "reviewer": "reviewer",
            }
        if not self_name.endswith("-planner"):
            raise BridgeError("current Herdr agent is not a Planner")
        prefix = self_name[: -len("-planner")]
        if not TEAM_PREFIX_RE.fullmatch(prefix):
            raise BridgeError("current Herdr Planner has an invalid team prefix")
        coder = "%s-coder" % prefix
        reviewer = "%s-reviewer" % prefix
        if not AGENT_NAME_RE.fullmatch(coder) or not AGENT_NAME_RE.fullmatch(reviewer):
            raise BridgeError("derived same-team Herdr agent name is invalid")
        return {"team_prefix": prefix, "coder": coder, "reviewer": reviewer}

    def inspect_team(self) -> Dict[str, Any]:
        env_pane_id = self._validate_runtime()
        current_payload = self._call(("pane", "current", "--current"))
        current_pane = _result_object(current_payload, "pane")
        current_pane_id = _required_string(
            current_pane.get("pane_id"), "current Herdr pane_id"
        )
        if current_pane_id != env_pane_id:
            raise BridgeError(
                "current pane %s does not match HERDR_PANE_ID %s"
                % (current_pane_id, env_pane_id)
            )

        self_payload = self._call(("agent", "get", env_pane_id))
        self_agent_raw = _result_object(self_payload, "agent")
        self_name = _required_string(self_agent_raw.get("name"), "current agent name")
        if not AGENT_NAME_RE.fullmatch(self_name):
            raise BridgeError("current Herdr agent name is invalid")
        if self_name != "planner" and not self_name.endswith("-planner"):
            raise BridgeError("current Herdr agent is not the team Planner")
        self_workspace = _required_string(
            self_agent_raw.get("workspace_id"), "current Planner workspace_id"
        )
        self_agent = self._validate_agent(
            self_agent_raw,
            expected_name=self_name,
            expected_workspace=self_workspace,
            require_ready=False,
        )
        if self_agent["pane_id"] != env_pane_id:
            raise BridgeError("current Planner ownership does not match HERDR_PANE_ID")
        team = self._derive_team(self_name)

        list_payload = self._call(("agent", "list"))
        list_result = _required_mapping(list_payload.get("result"), "Herdr list result")
        agents = list_result.get("agents")
        if not isinstance(agents, list):
            raise BridgeError("Herdr agent list is not an array")
        listed_names: List[str] = []
        for index, item in enumerate(agents):
            listed = _required_mapping(item, "Herdr agent list item %s" % index)
            name = listed.get("name")
            if name is None:
                continue
            listed_names.append(_required_string(name, "Herdr listed agent name"))
        for role in ("coder", "reviewer"):
            expected = team[role]
            if listed_names.count(expected) != 1:
                raise BridgeError(
                    "expected same-team Herdr agent %s was not listed exactly once" % expected
                )

        peer_agents: Dict[str, Dict[str, Any]] = {}
        seen_panes = {self_agent["pane_id"]}
        for role in ("coder", "reviewer"):
            expected = team[role]
            peer_payload = self._call(("agent", "get", expected))
            peer = self._validate_agent(
                _result_object(peer_payload, "agent"),
                expected_name=expected,
                expected_workspace=self_workspace,
                require_ready=True,
            )
            if peer["pane_id"] in seen_panes:
                raise BridgeError("same-team Herdr agents do not occupy distinct panes")
            seen_panes.add(peer["pane_id"])
            peer_agents[role] = peer

        return {
            "self_agent": self_name,
            "self_pane_id": env_pane_id,
            "workspace_id": self_workspace,
            "team_prefix": team["team_prefix"],
            "coder_agent": peer_agents["coder"],
            "reviewer_agent": peer_agents["reviewer"],
        }

    def prompt_agent(
        self,
        target_role: str,
        prompt: str,
        timeout_ms: int = 120000,
        read_lines: int = 2000,
    ) -> Dict[str, Any]:
        if target_role not in ("coder", "reviewer"):
            raise BridgeError("target_role must be exactly coder or reviewer")
        if (
            not isinstance(prompt, str)
            or not prompt.strip()
            or len(prompt) > MAX_PROMPT_CHARS
            or _has_unsafe_control(prompt, allow_newlines=True)
        ):
            raise BridgeError("prompt must be safe, non-empty, and within the bridge limit")
        if (
            isinstance(timeout_ms, bool)
            or not isinstance(timeout_ms, int)
            or timeout_ms <= 3000
            or timeout_ms > 300000
        ):
            raise BridgeError("timeout_ms must be an integer from 3001 through 300000")
        if (
            isinstance(read_lines, bool)
            or not isinstance(read_lines, int)
            or read_lines < 20
            or read_lines > 4000
        ):
            raise BridgeError("read_lines must be an integer from 20 through 4000")

        before = self.inspect_team()
        before_target = before["%s_agent" % target_role]
        target_name = before_target["name"]
        prompt_result = self._call(
            (
                "agent",
                "prompt",
                before_target["pane_id"],
                prompt,
                "--wait",
                "--timeout",
                str(timeout_ms),
            ),
            timeout_ms=timeout_ms + 5000,
        )
        prompt_result_body = _typed_result(prompt_result, "agent_prompted")
        prompted_target = self._validate_agent(
            _required_mapping(prompt_result_body.get("agent"), "Herdr result.agent"),
            expected_name=target_name,
            expected_workspace=before["workspace_id"],
            require_ready=True,
        )
        if prompted_target["pane_id"] != before_target["pane_id"]:
            raise BridgeError("Herdr prompt result changed the target pane identity")
        after = self.inspect_team()
        after_target = after["%s_agent" % target_role]
        if (
            after["self_agent"] != before["self_agent"]
            or after["workspace_id"] != before["workspace_id"]
            or after_target["name"] != target_name
            or after_target["pane_id"] != before_target["pane_id"]
        ):
            raise BridgeError("same-team Herdr identity changed during the handoff")
        before_seq = before_target.get("state_change_seq")
        prompted_seq = prompted_target.get("state_change_seq")
        after_seq = after_target.get("state_change_seq")
        if prompted_seq <= before_seq:
            raise BridgeError("target lifecycle did not advance in the Herdr prompt result")
        if after_seq <= before_seq:
            raise BridgeError("target lifecycle did not advance during the Herdr prompt")
        if after_seq < prompted_seq:
            raise BridgeError("target lifecycle regressed after the Herdr prompt")
        transcript_text = self._read_text(
            (
                "agent",
                "read",
                before_target["pane_id"],
                "--source",
                "recent-unwrapped",
                "--lines",
                str(read_lines),
            )
        )
        final = self.inspect_team()
        final_target = final["%s_agent" % target_role]
        if (
            final["self_agent"] != before["self_agent"]
            or final["workspace_id"] != before["workspace_id"]
            or final_target["name"] != target_name
            or final_target["pane_id"] != before_target["pane_id"]
        ):
            raise BridgeError("same-team Herdr identity changed during transcript read")
        final_seq = final_target.get("state_change_seq")
        if final_seq < after_seq:
            raise BridgeError("target lifecycle regressed during transcript read")
        return {
            "self_agent": before["self_agent"],
            "team_prefix": before["team_prefix"],
            "target_role": target_role,
            "target_agent": target_name,
            "target_pane_id": after_target["pane_id"],
            "before_state_change_seq": before_seq,
            "prompted_state_change_seq": prompted_seq,
            "after_state_change_seq": after_seq,
            "prompt_result": prompt_result,
            "transcript": {
                "agent": target_name,
                "pane_id": final_target["pane_id"],
                "workspace_id": final["workspace_id"],
                "source": "recent-unwrapped",
                "text": transcript_text,
            },
        }


TOOLS = [
    {
        "name": "inspect_team",
        "description": (
            "Prove the calling Herdr pane is its live Planner, derive the exact "
            "same-team Coder and Reviewer, and require both peers to be ready."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {},
            "additionalProperties": False,
        },
        "annotations": {
            "readOnlyHint": True,
            "destructiveHint": False,
            "idempotentHint": True,
            "openWorldHint": False,
        },
    },
    {
        "name": "prompt_agent",
        "description": (
            "Re-prove Planner identity, prompt only the exact same-team Coder or "
            "Reviewer, wait for lifecycle completion, and return its bounded transcript."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "target_role": {
                    "type": "string",
                    "enum": ["coder", "reviewer"],
                },
                "prompt": {"type": "string", "minLength": 1, "maxLength": MAX_PROMPT_CHARS},
                "timeout_ms": {
                    "type": "integer",
                    "minimum": 3001,
                    "maximum": 300000,
                    "default": 120000,
                },
                "read_lines": {
                    "type": "integer",
                    "minimum": 20,
                    "maximum": 4000,
                    "default": 2000,
                },
            },
            "required": ["target_role", "prompt"],
            "additionalProperties": False,
        },
        "annotations": {
            "readOnlyHint": False,
            "destructiveHint": False,
            "idempotentHint": False,
            "openWorldHint": False,
        },
    },
]


class McpServer:
    def __init__(self, bridge: HerdrBridge):
        self._bridge = bridge

    @staticmethod
    def _response(request_id: Any, result: Any) -> Dict[str, Any]:
        return {"jsonrpc": "2.0", "id": request_id, "result": result}

    @staticmethod
    def _error(request_id: Any, code: int, message: str) -> Dict[str, Any]:
        return {
            "jsonrpc": "2.0",
            "id": request_id,
            "error": {"code": code, "message": message},
        }

    @staticmethod
    def _tool_result(payload: Any, is_error: bool = False) -> Dict[str, Any]:
        return {
            "content": [
                {
                    "type": "text",
                    "text": json.dumps(
                        payload, ensure_ascii=False, separators=(",", ":"), sort_keys=True
                    ),
                }
            ],
            "isError": is_error,
        }

    def handle(self, request: Mapping[str, Any]) -> Optional[Dict[str, Any]]:
        if not isinstance(request, dict):
            return self._error(None, -32600, "request must be an object")
        request_id = request.get("id")
        method = request.get("method")
        if request.get("jsonrpc") != "2.0" or not isinstance(method, str):
            return self._error(request_id, -32600, "invalid JSON-RPC request")
        if request_id is None:
            return None

        params = request.get("params", {})
        if not isinstance(params, dict):
            return self._error(request_id, -32602, "params must be an object")
        if method == "initialize":
            requested = params.get("protocolVersion")
            protocol = (
                requested
                if isinstance(requested, str) and requested in SUPPORTED_PROTOCOL_VERSIONS
                else DEFAULT_PROTOCOL_VERSION
            )
            return self._response(
                request_id,
                {
                    "protocolVersion": protocol,
                    "capabilities": {"tools": {"listChanged": False}},
                    "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
                    "instructions": (
                        "Planner-only Herdr bridge. Call inspect_team before relying on "
                        "identity. Use prompt_agent only for the returned same-team Coder "
                        "or Reviewer role. Never use shell Herdr commands or another agent "
                        "system as fallback when this bridge fails."
                    ),
                },
            )
        if method == "ping":
            return self._response(request_id, {})
        if method == "tools/list":
            return self._response(request_id, {"tools": TOOLS})
        if method != "tools/call":
            return self._error(request_id, -32601, "method not found")

        name = params.get("name")
        arguments = params.get("arguments", {})
        if not isinstance(arguments, dict):
            return self._error(request_id, -32602, "tool arguments must be an object")
        try:
            if name == "inspect_team":
                if arguments:
                    raise BridgeError("inspect_team accepts no arguments")
                result = self._bridge.inspect_team()
            elif name == "prompt_agent":
                unknown = set(arguments) - {
                    "target_role",
                    "prompt",
                    "timeout_ms",
                    "read_lines",
                }
                if unknown:
                    raise BridgeError(
                        "prompt_agent received unknown arguments: %s"
                        % ", ".join(sorted(unknown))
                    )
                if "target_role" not in arguments or "prompt" not in arguments:
                    raise BridgeError("prompt_agent requires target_role and prompt")
                result = self._bridge.prompt_agent(
                    target_role=arguments["target_role"],
                    prompt=arguments["prompt"],
                    timeout_ms=arguments.get("timeout_ms", 120000),
                    read_lines=arguments.get("read_lines", 2000),
                )
            else:
                raise BridgeError("unknown Herdr bridge tool")
            return self._response(request_id, self._tool_result(result))
        except BridgeError as error:
            return self._response(
                request_id,
                self._tool_result({"error": str(error)}, is_error=True),
            )


def _write_response(response: Mapping[str, Any]) -> None:
    serialized = json.dumps(response, ensure_ascii=False, separators=(",", ":"))
    sys.stdout.write(serialized + "\n")
    sys.stdout.flush()


def serve() -> int:
    server = McpServer(HerdrBridge())
    while True:
        raw = sys.stdin.buffer.readline(MAX_MESSAGE_BYTES + 1)
        if not raw:
            return 0
        if len(raw) > MAX_MESSAGE_BYTES:
            _write_response(McpServer._error(None, -32700, "request exceeds size limit"))
            return 1
        if not raw.strip():
            continue
        try:
            request = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            _write_response(McpServer._error(None, -32700, "invalid JSON"))
            continue
        response = server.handle(request)
        if response is not None:
            _write_response(response)


def self_check() -> int:
    names = [tool.get("name") for tool in TOOLS]
    if names != ["inspect_team", "prompt_agent"] or len(names) != len(set(names)):
        raise BridgeError("invalid bounded MCP tool surface")
    print("herdr_mcp.py: ok")
    return 0


def main(argv: List[str]) -> int:
    if argv == ["--check"]:
        return self_check()
    if argv in (["--help"], ["-h"]):
        print("usage: herdr_mcp.py [--check]")
        return 0
    if argv:
        print("herdr_mcp.py: unexpected arguments", file=sys.stderr)
        return 2
    try:
        return serve()
    except BridgeError as error:
        print("herdr_mcp.py: %s" % error, file=sys.stderr)
        return 1
    except BrokenPipeError:
        return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
