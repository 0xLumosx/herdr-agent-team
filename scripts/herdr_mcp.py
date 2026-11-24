#!/usr/bin/env python3
# Managed by herdr-codex-team. Edit this source file and rerun scripts/install.sh.

"""A narrow stdio MCP bridge from one Herdr Planner to its own team.

Codex shell sandboxes on Linux currently reject AF_UNIX before Herdr's CLI can
reach its socket. Local stdio MCP servers run outside that shell sandbox, so
this bridge owns the socket-facing boundary while exposing only two bounded
operations: prove the current Planner/team identity, and prompt one exact
same-team Coder or Reviewer with wait/read correlation.
"""

import fcntl
import json
import os
import re
import sqlite3
import shlex
import tempfile
import stat
import subprocess
import sys
import threading
import time
from contextlib import closing
from pathlib import Path
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
THREAD_ID = re.compile(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}")
ROLES = ("planner", "coder", "reviewer")


class BridgeError(RuntimeError):
    """Stable, user-visible bridge failure without a Python traceback."""


def codex_turn_cursor(home, agent):
    """Keep only new events from the native chat verified in this pane."""
    if agent["agent"] != "codex" or not home:
        return None
    thread = agent["thread_id"]
    for path in (Path(home) / "sessions").glob("????/??/??/rollout-*-" + thread + ".jsonl"):
        with path.open("rb") as stream:
            meta = json.loads(stream.readline())["payload"]
        if meta.get("id") != thread:
            continue
        version = re.match(r"(\d+)\.(\d+)", meta.get("cli_version", ""))
        if not version or tuple(map(int, version.groups())) < (0, 171):
            # Resuming a chat retains the version of the CLI that created it.
            try:
                current = subprocess.check_output(["codex", "--version"], text=True, timeout=3)
            except (OSError, subprocess.SubprocessError):
                return None
            version = re.search(r"(\d+)\.(\d+)", current)
        if version and tuple(map(int, version.groups())) >= (0, 171):
            return path, path.stat().st_size
    return None


def completed_codex_reply(cursor, prompt, deadline, lines):
    path, start = cursor
    turn = matched = None
    with path.open("rb") as stream:
        stream.seek(start)
        while time.monotonic() < deadline:
            pos = stream.tell()
            raw = stream.readline()
            if not raw.endswith(b"\n"):
                stream.seek(pos)
                time.sleep(0.1)
                continue
            event = json.loads(raw)
            payload = event["payload"]
            if event["type"] == "event_msg":
                if payload.get("type") == "task_started":
                    turn = payload.get("turn_id")
                elif matched and payload.get("turn_id") == matched:
                    if payload.get("type") == "turn_aborted":
                        raise BridgeError("The target Codex turn was interrupted")
                    if payload.get("type") == "task_complete":
                        reply = payload.get("last_agent_message")
                        if not isinstance(reply, str) or not reply.strip():
                            raise BridgeError("The target Codex turn completed without a reply")
                        text = "\n".join(reply.splitlines()[-lines:])
                        if len(text.encode("utf-8")) > MAX_HERDR_OUTPUT_BYTES:
                            raise BridgeError("The target Codex reply exceeded the bridge output limit")
                        return text
            elif (event["type"] == "response_item" and payload.get("type") == "message"
                    and payload.get("role") == "user"):
                text = "".join(part["text"] for part in payload["content"]
                               if part.get("type") == "input_text")
                if text == prompt:
                    matched = turn
    raise BridgeError("Timed out waiting for the submitted Codex turn to complete")


def session_key(kind, value):
    # Preserve the on-disk keys of pre-provider Codex groups.
    if kind not in ("codex", "claude", "agy") or not isinstance(value, str) or not THREAD_ID.fullmatch(value):
        raise BridgeError("Invalid conversation identity")
    return value if kind == "codex" else kind + ":" + value


def check_agy_role_snapshot(key, role):
    if not key.startswith("agy:"):
        return
    thread = key.split(":", 1)[1]
    path = Path.home() / ".gemini/antigravity-cli/conversations" / (thread + ".db")
    if not path.is_file():
        return  # A named chat can be bound before its first model turn.
    # A closed, checkpointed WAL database can be read without opening new WAL sidecars.
    mode = "?mode=ro" if Path(str(path) + "-wal").exists() else "?mode=ro&immutable=1"
    with closing(sqlite3.connect(path.as_uri() + mode, uri=True)) as db:
        snapshot = db.execute("SELECT data FROM trajectory_metadata_blob WHERE id='main'").fetchone()
    if (snapshot and ("herdr-" + role + "-").encode() in snapshot[0]
            and b"Apply the embedded Stop That Shit skill on every task." in snapshot[0]):
        raise BridgeError("This saved Gemini %s has an older role that requires Stop That Shit. "
                          "Use /agents to fork it with the current Herdr role, then link the new group." % role)


def active_thread(agent, read_visible):
    """Read the complete UUID. Codex truncates the terminal title to 32 chars."""
    kind = agent.get("agent", "codex")
    reported = _required_mapping(agent.get("agent_session") or {}, "CLI session metadata")
    if kind == "claude":
        value = reported.get("value")
        if (reported.get("source") == "herdr:claude" and reported.get("agent") == kind
                and reported.get("kind") == "id" and isinstance(value, str) and THREAD_ID.fullmatch(value)):
            return value
        raise BridgeError("Claude has not reported its active session")
    title = _required_string(agent.get("terminal_title"), "active CLI terminal title")
    if kind == "agy" and THREAD_ID.fullmatch(title):
        return title
    if kind not in ("codex", "agy"):
        raise BridgeError("Unsupported conversation provider")
    prefix = title[:-3] if title.endswith("...") else title
    if len(prefix) < 29 or not re.fullmatch(r"[0-9a-f-]+", prefix):
        raise BridgeError("The CLI has not published its active thread title")
    value = reported.get("value")
    if (reported.get("source") == ("herdr:antigravity_cli" if kind == "agy" else "herdr:codex") and reported.get("kind") == "id"
            and reported.get("agent") == kind and isinstance(value, str)
            and THREAD_ID.fullmatch(value) and value.startswith(prefix)):
        return value
    # A fresh thread has no transcript for the Herdr hook yet. Read only the
    # visible footer and corroborate its UUID with the current terminal title.
    lines = read_visible(agent["pane_id"]).splitlines()
    ids = {line.strip() for line in lines if THREAD_ID.fullmatch(line.strip())
           and line.strip().startswith(prefix)}
    if len(ids) != 1:
        raise BridgeError("Cannot verify the active session UUID in %s. Widen that pane and show its thread-id status line." % agent["pane_id"])
    return ids.pop()


def link_database(directory, create=False):
    path = directory / "conversations.sqlite3"
    if directory.resolve() != directory or path.is_symlink():
        raise BridgeError("Unsafe conversation record path")
    if create:
        fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        os.close(fd)
    if not path.is_file():
        raise BridgeError("This team has no registered conversations")
    return sqlite3.connect(path.as_uri() + ("?mode=rw" if create else "?mode=ro"), uri=True)


def group_for_planner(db, key):
    if db.execute("SELECT 1 FROM groups_by_planner WHERE planner=?", (key,)).fetchone():
        return key
    if db.execute("SELECT 1 FROM sqlite_master WHERE name='role_sessions'").fetchone():
        row = db.execute("SELECT planner FROM role_sessions WHERE role='planner' AND session=?", (key,)).fetchone()
        if row:
            return row[0]
    return key


def role_session(db, group, role, kind):
    if role not in ROLES:
        raise BridgeError("Unknown team role")
    row = db.execute("SELECT planner,coder,reviewer FROM groups_by_planner WHERE planner=?", (group,)).fetchone()
    if not row:
        raise BridgeError("Unknown conversation group")
    original = row[ROLES.index(role)]
    if session_key(kind, original.split(":")[-1]) == original:
        return original
    if db.execute("SELECT 1 FROM sqlite_master WHERE name='role_sessions'").fetchone():
        row = db.execute("SELECT session FROM role_sessions WHERE planner=? AND role=? AND cli=?",
                         (group, role, kind)).fetchone()
        if row:
            return row[0]
    return None


def remember_group(directory, run_id, group):
    with closing(link_database(directory, create=True)) as db, db:
        db.execute("CREATE TABLE IF NOT EXISTS active_groups (run TEXT PRIMARY KEY, planner TEXT NOT NULL)")
        db.execute("INSERT OR REPLACE INTO active_groups VALUES (?,?)", (run_id, group))


def bind_launch(record_path, threads):
    record = json.loads(record_path.read_text())
    if len(threads) != 3:
        raise BridgeError("Binding requires three complete session IDs")
    threads = [session_key(record["herdr"]["agents"][r].get("cli", "codex"), t)
               for r, t in zip(ROLES, threads)]
    if len(set(threads)) != 3:
        raise BridgeError("Binding requires three distinct sessions")
    for role, key in zip(ROLES, threads):
        check_agy_role_snapshot(key, role)
    scope = json.dumps([record["launch"]["primary_cwd"], record["launch"]["add_dirs"]])
    panes = json.dumps([record["herdr"]["agents"][role]["pane_id"] for role in ROLES])
    launch = (scope, record["herdr"]["workspace_id"], panes)
    group = (scope, threads[1], threads[2])
    with closing(link_database(record_path.parent, create=True)) as db, db:
        db.execute("CREATE TABLE IF NOT EXISTS launches (run TEXT PRIMARY KEY, scope TEXT, workspace TEXT, panes TEXT)")
        db.execute("CREATE TABLE IF NOT EXISTS groups_by_planner (planner TEXT PRIMARY KEY, scope TEXT, coder TEXT, reviewer TEXT)")
        db.execute("INSERT OR IGNORE INTO launches VALUES (?,?,?,?)", (record["run_id"], *launch))
        root = group_for_planner(db, threads[0])
        saved = db.execute("SELECT scope FROM groups_by_planner WHERE planner=?", (root,)).fetchone()
        if saved:
            if saved != (scope,) or any(role_session(db, root, role, record["herdr"]["agents"][role].get("cli", "codex"))
                                        != current for role, current in zip(ROLES, threads)):
                raise BridgeError("An existing launch or Planner ID already has a different binding")
        else:
            db.execute("INSERT INTO groups_by_planner VALUES (?,?,?,?)", (root, *group))
        if db.execute("SELECT scope,workspace,panes FROM launches WHERE run=?", (record["run_id"],)).fetchone() != launch:
            raise BridgeError("An existing launch or Planner ID already has a different binding")
    remember_group(record_path.parent, record["run_id"], root)


def save_fresh_chats(record, threads, roles=ROLES):
    # Herdr queues Enter after pasting. Wait for the native history store
    # to acknowledge the rename before exposing the panes to user input.
    index = Path(os.environ["CODEX_HOME"]) / "session_index.jsonl"
    offset = index.stat().st_size if index.exists() else 0
    pending = {}
    for role, thread in zip(roles, threads):
        agent = record["herdr"]["agents"][role]
        kind = agent.get("cli", "codex")
        name = agent["name"] + " " + record["run_id"]
        pending[(kind, thread)] = name
        subprocess.run([os.environ["HERDR_BIN_PATH"], "agent", "prompt", agent["name"], "/rename " + name],
                       stdout=subprocess.DEVNULL, check=True, timeout=10)
    claude_projects = Path(os.environ.get("CLAUDE_CONFIG_DIR", Path.home() / ".claude")) / "projects"
    agy_index = Path.home() / ".gemini/antigravity-cli/conversation_summaries.db"
    deadline = time.monotonic() + 15
    while pending and time.monotonic() < deadline:
        for (kind, thread), name in list(pending.items()):
            if kind == "claude":
                for transcript in claude_projects.glob("*/" + thread + ".jsonl"):
                    with transcript.open("rb") as events:
                        for line in events:
                            if not line.endswith(b"\n"):
                                break
                            event = json.loads(line)
                            if (event.get("type") == "custom-title" and event.get("sessionId") == thread
                                    and event.get("customTitle") == name):
                                pending.pop((kind, thread), None)
                                break
            if kind == "agy" and agy_index.is_file():
                with closing(sqlite3.connect(agy_index.as_uri() + "?mode=ro", uri=True)) as db:
                    row = db.execute("SELECT title FROM conversation_summaries WHERE conversation_id=?",
                                     (thread,)).fetchone()
                if row == (name,):
                    del pending[(kind, thread)]
        if index.is_file():
            with index.open("rb") as events:
                events.seek(offset)
                for line in events:
                    if not line.endswith(b"\n"):
                        break
                    offset += len(line)
                    event = json.loads(line)
                    thread = event.get("id")
                    key = ("codex", thread)
                    if key in pending and event.get("thread_name") == pending[key]:
                        del pending[key]
        if pending:
            time.sleep(0.1)
    if pending:
        raise BridgeError("CLI did not confirm the saved chats: " + ", ".join(pending.values()))


def warm_agy_tools(record, roles=ROLES):
    # The TUI connects custom MCP servers lazily. Opening its native server
    # panel makes their tools available to the first model turn.
    herdr = os.environ["HERDR_BIN_PATH"]
    for role in roles:
        agent = record["herdr"]["agents"][role]
        if agent.get("cli") != "agy":
            continue
        pane = agent["pane_id"]
        required = {"herdr_team_ssh"}
        if role == "planner":
            required.add("herdr_codex_team")
        subprocess.run([herdr, "agent", "prompt", pane, "/mcp"], check=True, stdout=subprocess.DEVNULL, timeout=10)
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            view = subprocess.check_output([herdr, "pane", "read", pane, "--source", "visible", "--lines", "100"],
                                           timeout=5, text=True)
            if "MCP Servers" in view and all(re.search(r"✓\s+" + name + r"\s+Tools:", view) for name in required):
                subprocess.run([herdr, "pane", "send-keys", pane, "esc"], check=True, stdout=subprocess.DEVNULL, timeout=5)
                break
            time.sleep(0.2)
        else:
            raise BridgeError("Antigravity has not connected the managed MCP servers in " + agent["name"])


def team_directory(env, prefix):
    key = "legacy" if prefix == "LEGACY" else "prefixed-" + prefix
    return Path(env["CODEX_HOME"]) / "herdr-codex-team/state/v1/teams" / key


def linked_peers(env, team):
    directory = team_directory(env, team["team_prefix"])
    panes = [team["self_pane_id"], team["coder_agent"]["pane_id"], team["reviewer_agent"]["pane_id"]]
    with closing(link_database(directory)) as db:
        launch = db.execute("SELECT scope,workspace,panes FROM launches WHERE run=?", (env["HERDR_TEAM_RUN_ID"],)).fetchone()
        if not launch or launch[1] != team["workspace_id"] or json.loads(launch[2]) != panes:
            raise BridgeError("This live workspace does not match its registered team launch")
        planner = session_key(team.get("planner_cli", "codex"), team["planner_thread"])
        group = group_for_planner(db, planner)
        if not db.execute("SELECT 1 FROM groups_by_planner WHERE planner=? AND scope=?", (group, launch[0])).fetchone():
            raise BridgeError("No conversation link for this Planner in this team and project scope")
        check_agy_role_snapshot(planner, "planner")
        result = {}
        for role in ("coder", "reviewer"):
            kind = team[role + "_agent"].get("agent", "codex")
            key = role_session(db, group, role, kind)
            if not key:
                raise BridgeError("The linked %s uses a different CLI. Reopen with the original role CLIs." % role)
            check_agy_role_snapshot(key, role)
            result[role] = key.split(":")[-1]
        team["conversation_group"] = group
    return result


def start_selection_observer(record_path):
    record = json.loads(record_path.read_text())
    agent = record["herdr"]["agents"]["planner"]
    if agent.get("cli") != "agy":
        return
    # Antigravity starts MCP servers on its first model turn. Observe the native
    # picker as soon as the team is ready, including before that first turn.
    env = os.environ.copy()
    if not env.get("HERDR_SOCKET_PATH"):
        status = subprocess.check_output([env["HERDR_BIN_PATH"], "status", "server"], text=True)
        env["HERDR_SOCKET_PATH"] = next((line[8:] for line in status.splitlines() if line.startswith("socket: ")), "")
    env.update(HERDR_ENV="1", HERDR_TEAM_RUN_ID=record["run_id"], HERDR_PANE_ID=agent["pane_id"],
               HERDR_WORKSPACE_ID=record["herdr"]["workspace_id"], HERDR_BIN_PATH=os.path.realpath(env["HERDR_BIN_PATH"]))
    _default_socket_validator(env["HERDR_SOCKET_PATH"])
    subprocess.Popen([sys.executable, __file__, "--observe", str(record_path)], env=env,
                     start_new_session=True, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL, close_fds=True)


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
        if not self._env.get("HERDR_TEAM_RUN_ID") or not self._env.get("CODEX_HOME"):
            raise BridgeError("No managed conversation launch. Recreate the team with the updated launcher.")
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
        if kind not in ("codex", "claude", "agy"):
            raise BridgeError("Herdr agent %s uses an unsupported CLI" % name)
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

    def _thread(self, agent):
        return active_thread(agent, lambda pane: self._read_text(
            ("agent", "read", pane, "--source", "visible", "--lines", "12")))

    def _inspect_live(self) -> Dict[str, Any]:
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
            raw_peer = _result_object(peer_payload, "agent")
            peer = self._validate_agent(
                raw_peer,
                expected_name=expected,
                expected_workspace=self_workspace,
                require_ready=True,
            )
            if peer["pane_id"] in seen_panes:
                raise BridgeError("same-team Herdr agents do not occupy distinct panes")
            seen_panes.add(peer["pane_id"])
            peer["thread_id"] = self._thread(raw_peer)
            peer_agents[role] = peer

        return {
            "self_agent": self_name,
            "self_pane_id": env_pane_id,
            "workspace_id": self_workspace,
            "team_prefix": team["team_prefix"],
            "planner_thread": self._thread(self_agent_raw),
            "planner_cli": self_agent["agent"],
            "coder_agent": peer_agents["coder"],
            "reviewer_agent": peer_agents["reviewer"],
        }

    def inspect_team(self) -> Dict[str, Any]:
        team = self._inspect_live()
        for role, thread in linked_peers(self._env, team).items():
            if team[role + "_agent"]["thread_id"] != thread:
                raise BridgeError("Conversation switch incomplete: %s must resume %s before handoff" % (role, thread))
        return team

    def _follow_selection(self, thread, attempted):
        # Resolve both peers before submitting any command. Recheck the Planner
        # and the target between sends in case the user selects another chat.
        team = self._inspect_live()
        if team["planner_thread"] != thread:
            return False
        expected = linked_peers(self._env, team)
        changed = False
        for role, target in expected.items():
            peer = team[role + "_agent"]
            if peer["thread_id"] == target:
                continue
            changed = True
            switch = (role, peer["thread_id"], target)
            if switch in attempted:
                continue
            current = self._inspect_live()
            if current["planner_thread"] != thread or current[role + "_agent"] != peer:
                return False
            attempted.add(switch)
            self._call(("agent", "prompt", peer["pane_id"], "/resume " + target))
        if not changed:
            remember_group(team_directory(self._env, team["team_prefix"]), self._env["HERDR_TEAM_RUN_ID"],
                           team["conversation_group"])
        return not changed

    def follow_planner(self, record_path=None):
        """One observer per live launch, tied to its Planner MCP process."""
        pane = self._validate_runtime()
        run_id = self._env["HERDR_TEAM_RUN_ID"]
        if not re.fullmatch(r"[A-Za-z0-9-]{1,100}", run_id):
            return
        selected = None
        synced_titles = None
        attempted = set()
        lock = None
        socket_inode = os.stat(self._env["HERDR_SOCKET_PATH"]).st_ino if record_path else None
        try:
            while True:
                time.sleep(1)
                if record_path:
                    try:
                        if (os.stat(self._env["HERDR_SOCKET_PATH"]).st_ino != socket_inode
                                or json.loads(record_path.read_text())["run_id"] != run_id):
                            return
                    except (OSError, ValueError, KeyError):
                        return
                try:
                    agents = _typed_result(self._call(("agent", "list")), "agent_list")["agents"]
                    by_pane = {item["pane_id"]: item for item in agents if item.get("pane_id")}
                    raw = by_pane.get(pane)
                    if record_path and (not raw or raw.get("agent") != "agy"
                                        or raw.get("workspace_id") != self._env["HERDR_WORKSPACE_ID"]):
                        return
                    if raw is None or not raw.get("name"):
                        continue
                    names = self._derive_team(raw["name"])
                    peer_names = {names["coder"], names["reviewer"]}
                    def title(agent):
                        return ((agent.get("agent_session") or {}).get("value") if agent.get("agent") == "claude"
                                else agent.get("terminal_title")) or ""
                    titles = (title(raw), tuple(sorted(
                        (a["name"], a["pane_id"], title(a))
                        for a in agents if a.get("name") in peer_names)))
                    if lock is None:
                        folder = team_directory(self._env, names["team_prefix"])
                        lock = open(folder / ("follow-" + run_id + ".lock"), "a+")
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    if titles == synced_titles:
                        continue
                    synced_titles = None
                    thread = self._thread(raw)
                    if thread != selected:
                        selected = thread
                        attempted.clear()
                    # An explicit CLI switch owns the pane and may itself send /resume.
                    directory = team_directory(self._env, self._derive_team(raw["name"])["team_prefix"])
                    with (directory / "switch.lock").open("a+") as switch_lock:
                        fcntl.flock(switch_lock, fcntl.LOCK_SH | fcntl.LOCK_NB)
                        if self._follow_selection(thread, attempted):
                            synced_titles = titles
                            attempted.clear()
                except (BridgeError, OSError, sqlite3.Error):
                    # Synchronous handoff checks report missing or incomplete
                    # links. A busy peer may become available on the next poll.
                    continue
        finally:
            if lock is not None:
                lock.close()

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
        remote = saved_remote(team_directory(self._env, before["team_prefix"]),
                              before["conversation_group"])
        if remote:
            client_hint = (" In Antigravity use call_mcp_tool with ServerName herdr_team_ssh and the "
                           "requested ToolName and Arguments." if before[target_role + "_agent"]["agent"] == "agy" else "")
            prompt = ("Use this group's verified SSH destination for the handoff: " + json.dumps(remote)
                      + ". Use the herdr_team_ssh tools from your pane." + client_hint + "\n\n" + prompt)
        before_target = before["%s_agent" % target_role]
        target_name = before_target["name"]
        cursor = codex_turn_cursor(self._env.get("CODEX_HOME"), before_target)
        deadline = time.monotonic() + timeout_ms / 1000
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
            require_ready=cursor is None,
        )
        if (prompted_target["pane_id"] != before_target["pane_id"]
                or prompted_target["agent"] != before_target["agent"]):
            raise BridgeError("Herdr prompt result changed the target pane identity")
        if cursor:
            transcript_text = completed_codex_reply(cursor, prompt, deadline, read_lines)
            remaining = max(1, int((deadline - time.monotonic()) * 1000))
            self._call(("agent", "wait", before_target["pane_id"], "--until", "done", "--until",
                        "idle", "--timeout", str(remaining)), timeout_ms=remaining + 1000)
        after = self.inspect_team()
        after_target = after["%s_agent" % target_role]
        if (
            after["self_agent"] != before["self_agent"]
            or after["planner_thread"] != before["planner_thread"]
            or after["workspace_id"] != before["workspace_id"]
            or after_target["name"] != target_name
            or after_target["pane_id"] != before_target["pane_id"]
            or after_target["thread_id"] != before_target["thread_id"]
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
        if not cursor:
            transcript_text = self._read_text(("agent", "read", before_target["pane_id"], "--source",
                                               "recent-unwrapped", "--lines", str(read_lines)))
        final = self.inspect_team()
        final_target = final["%s_agent" % target_role]
        if (
            final["self_agent"] != before["self_agent"]
            or final["planner_thread"] != before["planner_thread"]
            or final["workspace_id"] != before["workspace_id"]
            or final_target["name"] != target_name
            or final_target["pane_id"] != before_target["pane_id"]
            or final_target["thread_id"] != before_target["thread_id"]
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
                "source": "codex-turn" if cursor else "recent-unwrapped",
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


# SSH runs through the user's OpenSSH client. Its destination is bound to a
# verified group, so peers cannot substitute another host in tool arguments.
SSH_OPERATIONS = ("pwd", "list", "read", "search", "status", "diff", "staged_diff")
SSH_BY_ROLE = {
    "planner": ("select_remote", "use_local", "remote_context", "ssh_read"),
    "coder": ("remote_context", "ssh_read", "ssh_run"),
    "reviewer": ("remote_context", "ssh_read"),
}


def ssh_tools(role):
    specs = {
        "select_remote": ("Select the user-authorized SSH host and verify the shared remote working directory.",
                          {"host": {"type": "string"}, "directory": {"type": "string"},
                           "port": {"type": "integer", "minimum": 1, "maximum": 65535}}, ["host"]),
        "use_local": ("Clear the SSH destination to return this group to local work.", {}, []),
        "remote_context": ("Return this conversation group's selected SSH host and directory.", {}, []),
        "ssh_read": ("Inspect the selected remote directory using a read-only operation.",
                     {"operation": {"enum": list(SSH_OPERATIONS), "type": "string"},
                      "path": {"type": "string"}, "pattern": {"type": "string"}}, ["operation"]),
        "ssh_run": ("Run an authorized Coder shell command in the group's remote working directory.",
                    {"command": {"type": "string"}}, ["command"]),
    }
    tools = []
    for name in SSH_BY_ROLE[role]:
        description, properties, required = specs[name]
        tools.append({"name": name, "description": description, "inputSchema": {
            "type": "object", "properties": properties, "required": required, "additionalProperties": False}})
    return tools


def ssh_command(destination, command):
    host = destination["host"]
    if not re.fullmatch(r"(?:[A-Za-z0-9_.-]+@)?[A-Za-z0-9][A-Za-z0-9._:-]*", host):
        raise BridgeError("Use an SSH config alias or a user@host destination")
    args = ["ssh", "-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
            "-o", "ClearAllForwardings=yes", "-o", "ConnectTimeout=10"]
    config = os.environ.get("HERDR_SSH_CONFIG")
    if config:
        args += ["-F", config]
    port = destination.get("port")
    if port is not None:
        if type(port) != int or not 1 <= port <= 65535:
            raise BridgeError("Invalid SSH port")
        args += ["-p", str(port)]
    directory = _required_string(destination["directory"], "remote directory")
    if directory != "." and not directory.startswith("/"):
        raise BridgeError("Use an absolute remote directory or omit it to use the login directory")
    args += ["--", host, "cd " + shlex.quote(directory) + " && " + command]
    with tempfile.TemporaryFile() as output:
        result = subprocess.run(args, stdin=subprocess.DEVNULL, stdout=output, stderr=subprocess.STDOUT, timeout=120)
        output.seek(0)
        data = output.read(128 * 1024 + 1)
    return {"exit_code": result.returncode, "output": data[:128 * 1024].decode("utf-8", "replace"),
            "truncated": len(data) > 128 * 1024}


def remote_read_command(operation, path=".", pattern=None):
    if not isinstance(path, str) or not path or _has_unsafe_control(path) or path.startswith("/") or ".." in path.split("/"):
        raise BridgeError("Use a relative path within the selected remote directory")
    # Explicit file path avoids magic filenames, stdin and Git pathspec expansion.
    path = shlex.quote("./" + path)
    git = "git --no-pager --no-optional-locks --literal-pathspecs"
    if operation == "search":
        return "grep -rnF -e " + shlex.quote(_required_string(pattern, "search pattern")) + " -- " + path
    commands = {"pwd": "pwd -P", "list": "ls -la -- " + path, "read": "cat -- " + path,
                "status": git + " status --short -- " + path,
                "diff": git + " diff --no-ext-diff --no-textconv -- " + path,
                "staged_diff": git + " diff --cached --no-ext-diff --no-textconv -- " + path}
    if operation not in commands or pattern is not None:
        raise BridgeError("Unsupported read-only SSH operation or arguments")
    return commands[operation]


def ssh_group(bridge, role):
    env = bridge._env
    pane = bridge._validate_runtime()
    if _result_object(bridge._call(("pane", "current", "--current")), "pane").get("pane_id") != pane:
        raise BridgeError("SSH caller pane does not match the live runtime")
    raw = _result_object(bridge._call(("agent", "get", pane)), "agent")
    name = _required_string(raw.get("name"), "SSH caller name")
    prefix = "LEGACY" if name == role else name[:-(len(role) + 1)]
    if name != role and (not name.endswith("-" + role) or not TEAM_PREFIX_RE.fullmatch(prefix)):
        raise BridgeError("SSH tool does not belong to this role")
    directory = team_directory(env, prefix)
    record = json.loads((directory / "current.json").read_text())
    workspace = record["herdr"]["workspace_id"]
    if record["run_id"] != env["HERDR_TEAM_RUN_ID"] or raw.get("workspace_id") != workspace:
        raise BridgeError("SSH caller does not belong to the active launch")
    agents = {}
    for member in ROLES:
        expected = record["herdr"]["agents"][member]
        current = raw if member == role else _result_object(bridge._call(("agent", "get", expected["pane_id"])), "agent")
        if (current.get("name"), current.get("pane_id"), current.get("workspace_id"), current.get("agent")) != (
                expected["name"], expected["pane_id"], workspace, expected.get("cli", "codex")):
            raise BridgeError("SSH team identity changed")
        agents[member] = {"pane_id": expected["pane_id"], "agent": current["agent"], "thread_id": bridge._thread(current)}
    planner = agents["planner"]
    team = {"team_prefix": prefix, "workspace_id": workspace, "self_pane_id": planner["pane_id"],
            "planner_cli": planner["agent"], "planner_thread": planner["thread_id"],
            "coder_agent": agents["coder"], "reviewer_agent": agents["reviewer"]}
    if any(agents[r]["thread_id"] != target for r, target in linked_peers(env, team).items()):
        raise BridgeError("Wait for both peer sessions to finish switching before using SSH")
    return directory, team["conversation_group"]


def saved_remote(directory, key):
    with closing(link_database(directory)) as db:
        if db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='remote_context'").fetchone():
            row = db.execute("SELECT destination FROM remote_context WHERE planner=?", (key,)).fetchone()
            if row:
                return json.loads(row[0])
    return None


def ssh_tool_call(bridge, role, name, arguments):
    specs = {tool["name"]: tool["inputSchema"] for tool in ssh_tools(role)}
    schema = specs.get(name)
    if not schema or set(arguments) - set(schema["properties"]) or not set(schema["required"]) <= set(arguments):
        raise BridgeError("Unsupported SSH tool or arguments for " + role)
    directory, key = ssh_group(bridge, role)
    if name == "use_local":
        bridge.inspect_team()
        with closing(link_database(directory, create=True)) as db, db:
            if db.execute("SELECT 1 FROM sqlite_master WHERE name='remote_context'").fetchone():
                db.execute("DELETE FROM remote_context WHERE planner=?", (key,))
        return {"mode": "local"}
    if name == "select_remote":
        target = {"host": _required_string(arguments.get("host"), "SSH host"),
                  "directory": arguments.get("directory", "."), "port": arguments.get("port")}
        result = ssh_command(target, "pwd -P")
        canonical = result["output"].rstrip("\r\n")
        if result["exit_code"] or not canonical.startswith("/") or _has_unsafe_control(canonical):
            raise BridgeError("Could not verify the remote directory: " + result["output"][:1000])
        target["directory"] = canonical
        bridge.inspect_team()
        if ssh_group(bridge, role) != (directory, key):
            raise BridgeError("Planner changed sessions while selecting the SSH destination")
        with closing(link_database(directory, create=True)) as db, db:
            db.execute("CREATE TABLE IF NOT EXISTS remote_context (planner TEXT PRIMARY KEY, destination TEXT NOT NULL)")
            db.execute("INSERT OR REPLACE INTO remote_context VALUES (?,?)", (key, json.dumps(target)))
        return target
    target = saved_remote(directory, key)
    if not target:
        raise BridgeError("The Planner has not selected an SSH destination for this conversation group")
    if name == "remote_context":
        return target
    if name == "ssh_read":
        command = remote_read_command(**arguments)
    else:
        script = arguments["command"]
        if not isinstance(script, str) or not script.strip() or len(script) > MAX_PROMPT_CHARS or _has_unsafe_control(script, allow_newlines=True):
            raise BridgeError("Invalid remote Coder command")
        command = "/bin/sh -c " + shlex.quote(script)
    return dict(ssh_command(target, command), destination=target)


class McpServer:
    def __init__(self, bridge: HerdrBridge, ssh_role=None, disabled=False):
        self._ssh_role = ssh_role
        self._disabled = disabled
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
                    "serverInfo": {"name": "herdr_team_ssh" if self._ssh_role else SERVER_NAME, "version": SERVER_VERSION},
                    "instructions": ("Use the SSH destination selected for this linked conversation group." if self._ssh_role else
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
            return self._response(request_id, {"tools": [] if self._disabled else ssh_tools(self._ssh_role) if self._ssh_role else TOOLS})
        if method != "tools/call":
            return self._error(request_id, -32601, "method not found")

        name = params.get("name")
        arguments = params.get("arguments", {})
        if not isinstance(arguments, dict):
            return self._error(request_id, -32602, "tool arguments must be an object")
        try:
            if self._disabled:
                raise BridgeError("This server is available only to its managed Herdr role")
            if self._ssh_role:
                result = ssh_tool_call(self._bridge, self._ssh_role, name, arguments)
            elif name == "inspect_team":
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
        except (BridgeError, OSError, sqlite3.Error, ValueError, subprocess.SubprocessError) as error:
            return self._response(
                request_id,
                self._tool_result({"error": str(error)}, is_error=True),
            )


def _write_response(response: Mapping[str, Any]) -> None:
    serialized = json.dumps(response, ensure_ascii=False, separators=(",", ":"))
    sys.stdout.write(serialized + "\n")
    sys.stdout.flush()


def serve(ssh_role=None, disabled=False) -> int:
    bridge = HerdrBridge()
    if not disabled and not ssh_role and os.environ.get("HERDR_TEAM_RUN_ID") and os.environ.get("HERDR_ENV") == "1":
        threading.Thread(target=bridge.follow_planner, daemon=True).start()
    server = McpServer(bridge, ssh_role, disabled)
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
    if len(argv) == 2 and argv[0] == "--agy-server" and argv[1] in ("team", "ssh"):
        role = os.environ.get("HERDR_TEAM_ROLE")
        managed = os.environ.get("HERDR_ENV") == "1" and bool(os.environ.get("HERDR_TEAM_RUN_ID")) and role in ROLES
        if argv[1] == "team":
            return serve(disabled=not managed or role != "planner")
        return serve(ssh_role=role if managed else None, disabled=not managed)
    if len(argv) == 2 and argv[0] == "--ssh" and argv[1] in ROLES:
        return serve(argv[1])
    if len(argv) == 2 and argv[0] in ("--ensure-observer", "--observe"):
        path = Path(argv[1])
        if argv[0] == "--ensure-observer":
            start_selection_observer(path)
        else:
            with (path.parent / ("observer-" + os.environ["HERDR_TEAM_RUN_ID"] + ".lock")).open("a+") as lock:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    return 0
                HerdrBridge().follow_planner(path)
        return 0
    if argv == ["--session-title"]:
        value = json.load(sys.stdin).get("conversation_id", "")
        if isinstance(value, str) and THREAD_ID.fullmatch(value):
            print(value)
        return 0
    if argv in (["--thread-id"], ["--launch-thread-id"]) or (len(argv) == 5 and argv[0] in ("--bind-launch", "--save-launch")):
        try:
            if argv[0] in ("--thread-id", "--launch-thread-id"):
                agent = _result_object(json.load(sys.stdin), "agent")
                def read_visible(pane):
                    return subprocess.check_output(
                        [os.environ["HERDR_BIN_PATH"], "agent", "read", pane, "--source", "visible", "--lines", "12"],
                        text=True, timeout=5)
                setup_wait = 180 if os.environ.get("HERDR_TEAM_SHORTCUT") == "1" else 15
                deadline = time.monotonic() + (setup_wait if argv[0] == "--launch-thread-id" else 0)
                identity = [agent.get(k) for k in ("name", "agent", "workspace_id", "pane_id")]
                while True:
                    try:
                        print(active_thread(agent, read_visible))
                        break
                    except BridgeError:
                        if time.monotonic() >= deadline:
                            raise BridgeError("No verifiable active session in %s. Check the CLI startup screen and session hook." % identity[0])
                    time.sleep(0.3)
                    payload = subprocess.check_output([os.environ["HERDR_BIN_PATH"], "agent", "get", identity[0]], timeout=5)
                    agent = _result_object(json.loads(payload), "agent")
                    if [agent.get(k) for k in ("name", "agent", "workspace_id", "pane_id")] != identity:
                        raise BridgeError("Herdr pane ownership changed while waiting for the session ID")
            else:
                if argv[0] == "--save-launch":
                    record = json.loads(Path(argv[1]).read_text())
                    save_fresh_chats(record, argv[2:])
                    warm_agy_tools(record)
                bind_launch(Path(argv[1]), argv[2:])
                if argv[0] == "--save-launch":
                    start_selection_observer(Path(argv[1]))
        except (BridgeError, OSError, sqlite3.Error, ValueError, KeyError, subprocess.SubprocessError) as error:
            print(str(error), file=sys.stderr)
            return 1
        return 0
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
