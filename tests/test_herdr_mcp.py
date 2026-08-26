#!/usr/bin/env python3

import importlib.util
import json
import os
from pathlib import Path
import socket
import sys
import tempfile
import unittest


PROJECT_ROOT = Path(__file__).resolve().parents[1]
BRIDGE_PATH = PROJECT_ROOT / "scripts" / "herdr_mcp.py"
PLANNER_PROFILE_PATH = PROJECT_ROOT / "profiles" / "planner.config.toml"


def load_bridge_module():
    spec = importlib.util.spec_from_file_location("herdr_mcp", BRIDGE_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError("could not load Herdr MCP bridge module")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FakeHerdrRunner:
    def __init__(self, self_name="dex-vut-planner", current_pane="w2:p1"):
        self.self_name = self_name
        self.current_pane = current_pane
        self.calls = []
        self.agents = {
            "dex-vut-planner": self._agent("dex-vut-planner", "w2:p1", "idle"),
            "dex-vut-coder": self._agent("dex-vut-coder", "w2:p2", "idle"),
            "dex-vut-reviewer": self._agent("dex-vut-reviewer", "w2:p3", "done"),
            "other-coder": self._agent("other-coder", "w9:p2", "idle", "w9"),
            "other-reviewer": self._agent("other-reviewer", "w9:p3", "idle", "w9"),
        }

    @staticmethod
    def _agent(name, pane_id, status, workspace_id="w2"):
        return {
            "name": name,
            "pane_id": pane_id,
            "workspace_id": workspace_id,
            "agent": "codex",
            "agent_status": status,
            "interactive_ready": True,
            "launch_pending": False,
            "state_change_seq": 10,
        }

    def _resolve_target(self, target):
        if target in self.agents:
            return target
        matches = [
            name for name, agent in self.agents.items()
            if agent["pane_id"] == target
        ]
        if len(matches) != 1:
            raise RuntimeError("agent_not_found")
        return matches[0]

    def __call__(self, args, timeout_ms):
        args = tuple(args)
        self.calls.append((args, timeout_ms))
        if args == ("pane", "current", "--current"):
            return {"result": {"pane": {"pane_id": self.current_pane}}}
        if args == ("agent", "list"):
            return {"result": {"agents": list(self.agents.values())}}
        if len(args) == 3 and args[:2] == ("agent", "get"):
            target = args[2]
            if target == "w2:p1":
                target = self.self_name
            if target not in self.agents:
                raise RuntimeError("agent_not_found")
            return {"result": {"agent": dict(self.agents[target])}}
        if len(args) == 7 and args[:2] == ("agent", "prompt"):
            target = self._resolve_target(args[2])
            self.agents[target]["state_change_seq"] += 2
            return {
                "result": {
                    "type": "agent_prompted",
                    "agent": dict(self.agents[target]),
                }
            }
        raise AssertionError("unexpected Herdr argv: %r" % (args,))

    def read_text(self, args, timeout_ms):
        args = tuple(args)
        self.calls.append((args, timeout_ms))
        if len(args) == 7 and args[:2] == ("agent", "read"):
            self._resolve_target(args[2])
            return "HERDR_COMMUNICATION_OK"
        raise AssertionError("unexpected Herdr text argv: %r" % (args,))


class HerdrBridgeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = load_bridge_module()

    def make_bridge(self, runner=None, pane_id="w2:p1"):
        runner = runner or FakeHerdrRunner()
        env = {
            "HERDR_ENV": "1",
            "HERDR_PANE_ID": pane_id,
            "HERDR_SOCKET_PATH": "/tmp/herdr-test.sock",
        }
        return self.module.HerdrBridge(
            env=env,
            runner=runner,
            socket_validator=lambda _path: None,
        ), runner

    def test_planner_profile_uses_direct_install_time_path_placeholders(self):
        profile = PLANNER_PROFILE_PATH.read_text(encoding="utf-8")

        self.assertIn(
            'command = "__HERDR_CODEX_TEAM_PYTHON__"',
            profile,
        )
        self.assertIn(
            'args = ["__HERDR_CODEX_TEAM_BRIDGE__"]',
            profile,
        )
        self.assertIn('  "HERDR_BIN_PATH",', profile)
        self.assertNotIn('command = "/bin/sh"', profile)
        self.assertNotIn("exec python3", profile)

    def test_command_runner_uses_herdr_bin_path_and_ignores_path(self):
        with tempfile.TemporaryDirectory(prefix="herdr-mcp-path-") as directory:
            poisoned_herdr = Path(directory) / "herdr"
            poisoned_herdr.write_text("#!/bin/sh\nexit 99\n", encoding="utf-8")
            poisoned_herdr.chmod(0o700)

            runner = self.module.HerdrCommandRunner(
                {
                    "HERDR_BIN_PATH": sys.executable,
                    "PATH": directory,
                }
            )

            self.assertEqual(runner._binary, os.path.realpath(sys.executable))
            self.assertNotEqual(runner._binary, str(poisoned_herdr))
            self.assertIn("HERDR_BIN_PATH", runner._FORWARDED_ENV)

    def test_command_runner_has_no_path_fallback(self):
        with tempfile.TemporaryDirectory(prefix="herdr-mcp-no-fallback-") as directory:
            poisoned_herdr = Path(directory) / "herdr"
            poisoned_herdr.write_text("#!/bin/sh\nexit 99\n", encoding="utf-8")
            poisoned_herdr.chmod(0o700)

            with self.assertRaisesRegex(self.module.BridgeError, "HERDR_BIN_PATH"):
                self.module.HerdrCommandRunner({"PATH": directory})

            with self.assertRaisesRegex(self.module.BridgeError, "safe absolute path"):
                self.module.HerdrCommandRunner(
                    {"HERDR_BIN_PATH": "relative/herdr", "PATH": directory}
                )

    def test_command_runner_accepts_symlink_and_rejects_non_executable(self):
        with tempfile.TemporaryDirectory(prefix="herdr-mcp-bin-") as directory:
            symlink_path = Path(directory) / "herdr-link"
            symlink_path.symlink_to(sys.executable)

            runner = self.module.HerdrCommandRunner(
                {"HERDR_BIN_PATH": str(symlink_path)}
            )
            self.assertEqual(runner._binary, os.path.realpath(sys.executable))

            non_executable = Path(directory) / "not-executable"
            non_executable.write_text("not executable", encoding="utf-8")
            non_executable.chmod(0o600)
            with self.assertRaisesRegex(self.module.BridgeError, "runnable regular file"):
                self.module.HerdrCommandRunner(
                    {"HERDR_BIN_PATH": str(non_executable)}
                )

    def test_command_runner_reads_public_cli_text_without_json_parsing(self):
        runner = self.module.HerdrCommandRunner(
            {"HERDR_BIN_PATH": sys.executable}
        )

        transcript = runner.read_text(
            ("-c", "print('HERDR_TRANSCRIPT')"),
            timeout_ms=1000,
        )

        self.assertEqual(transcript, "HERDR_TRANSCRIPT\n")
        with self.assertRaisesRegex(self.module.BridgeError, "malformed JSON"):
            runner(
                ("-c", "print('HERDR_TRANSCRIPT')"),
                timeout_ms=1000,
            )

    def test_inspect_team_derives_only_exact_same_team_agents(self):
        bridge, _runner = self.make_bridge()

        result = bridge.inspect_team()

        self.assertEqual(result["self_agent"], "dex-vut-planner")
        self.assertEqual(result["team_prefix"], "dex-vut")
        self.assertEqual(result["coder_agent"]["name"], "dex-vut-coder")
        self.assertEqual(result["reviewer_agent"]["name"], "dex-vut-reviewer")

    def test_active_planner_need_not_be_interactively_idle(self):
        runner = FakeHerdrRunner()
        runner.agents["dex-vut-planner"]["agent_status"] = "working"
        runner.agents["dex-vut-planner"]["interactive_ready"] = False
        bridge, _runner = self.make_bridge(runner=runner)

        result = bridge.inspect_team()

        self.assertEqual(result["self_agent"], "dex-vut-planner")
        self.assertEqual(result["coder_agent"]["agent_status"], "idle")

    def test_settled_herdr_0_8_2_agents_may_omit_launch_pending(self):
        runner = FakeHerdrRunner()
        for name in ("dex-vut-planner", "dex-vut-coder", "dex-vut-reviewer"):
            del runner.agents[name]["launch_pending"]
        bridge, _runner = self.make_bridge(runner=runner)

        result = bridge.inspect_team()

        self.assertIsNone(result["coder_agent"]["launch_pending"])
        self.assertIsNone(result["reviewer_agent"]["launch_pending"])

    def test_peer_must_report_boolean_interactive_ready(self):
        runner = FakeHerdrRunner()
        del runner.agents["dex-vut-coder"]["interactive_ready"]
        bridge, _runner = self.make_bridge(runner=runner)

        with self.assertRaisesRegex(self.module.BridgeError, "interactive_ready"):
            bridge.inspect_team()

    def test_agent_lifecycle_sequence_is_required(self):
        runner = FakeHerdrRunner()
        del runner.agents["dex-vut-coder"]["state_change_seq"]
        bridge, _runner = self.make_bridge(runner=runner)

        with self.assertRaisesRegex(self.module.BridgeError, "state_change_seq"):
            bridge.inspect_team()

    def test_prompt_routes_by_role_and_never_accepts_an_agent_name(self):
        bridge, runner = self.make_bridge()

        result = bridge.prompt_agent(
            target_role="coder",
            prompt="no-write echo test",
            timeout_ms=120000,
            read_lines=120,
        )

        prompt_calls = [call for call in runner.calls if call[0][:2] == ("agent", "prompt")]
        self.assertEqual(len(prompt_calls), 1)
        self.assertEqual(prompt_calls[0][0][2], "w2:p2")
        self.assertEqual(result["target_agent"], "dex-vut-coder")
        self.assertEqual(result["prompted_state_change_seq"], 12)
        self.assertEqual(result["transcript"]["agent"], "dex-vut-coder")
        self.assertEqual(result["transcript"]["pane_id"], "w2:p2")
        self.assertEqual(result["transcript"]["text"], "HERDR_COMMUNICATION_OK")

        with self.assertRaisesRegex(self.module.BridgeError, "target_role"):
            bridge.prompt_agent(
                target_role="other-coder",
                prompt="forbidden",
                timeout_ms=120000,
                read_lines=120,
            )

    def test_prompt_result_identity_mismatch_fails_before_transcript_read(self):
        class MismatchedPromptRunner(FakeHerdrRunner):
            def __call__(self, args, timeout_ms):
                result = super().__call__(args, timeout_ms)
                if tuple(args)[:2] == ("agent", "prompt"):
                    result["result"]["agent"]["pane_id"] = "w9:p9"
                return result

        bridge, runner = self.make_bridge(runner=MismatchedPromptRunner())

        with self.assertRaisesRegex(self.module.BridgeError, "target pane identity"):
            bridge.prompt_agent(
                target_role="coder",
                prompt="identity check",
                timeout_ms=120000,
                read_lines=120,
            )

        self.assertFalse(any(call[0][:2] == ("agent", "read") for call in runner.calls))

    def test_prompt_result_type_mismatch_fails_before_transcript_read(self):
        class WrongResultTypeRunner(FakeHerdrRunner):
            def __call__(self, args, timeout_ms):
                result = super().__call__(args, timeout_ms)
                if tuple(args)[:2] == ("agent", "prompt"):
                    result["result"]["type"] = "agent_info"
                return result

        bridge, runner = self.make_bridge(runner=WrongResultTypeRunner())

        with self.assertRaisesRegex(self.module.BridgeError, "expected agent_prompted"):
            bridge.prompt_agent(
                target_role="coder",
                prompt="result type check",
                timeout_ms=120000,
                read_lines=120,
            )

        self.assertFalse(any(call[0][:2] == ("agent", "read") for call in runner.calls))

    def test_prompt_result_requires_lifecycle_sequence(self):
        class MissingPromptSequenceRunner(FakeHerdrRunner):
            def __call__(self, args, timeout_ms):
                result = super().__call__(args, timeout_ms)
                if tuple(args)[:2] == ("agent", "prompt"):
                    del result["result"]["agent"]["state_change_seq"]
                return result

        bridge, runner = self.make_bridge(runner=MissingPromptSequenceRunner())

        with self.assertRaisesRegex(self.module.BridgeError, "state_change_seq"):
            bridge.prompt_agent(
                target_role="coder",
                prompt="sequence check",
                timeout_ms=120000,
                read_lines=120,
            )

        self.assertFalse(any(call[0][:2] == ("agent", "read") for call in runner.calls))

    def test_prompt_uses_text_cli_for_transcript(self):
        bridge, runner = self.make_bridge()

        result = bridge.prompt_agent(
            target_role="reviewer",
            prompt="text read check",
            timeout_ms=120000,
            read_lines=120,
        )

        text_calls = [call for call in runner.calls if call[0][:2] == ("agent", "read")]
        self.assertEqual(len(text_calls), 1)
        self.assertEqual(text_calls[0][0][2], "w2:p3")
        self.assertEqual(result["transcript"]["source"], "recent-unwrapped")

    def test_identity_mismatch_fails_before_agent_discovery(self):
        bridge, runner = self.make_bridge(runner=FakeHerdrRunner(current_pane="w2:p9"))

        with self.assertRaisesRegex(self.module.BridgeError, "HERDR_PANE_ID"):
            bridge.inspect_team()

        self.assertFalse(any(call[0][:2] == ("agent", "list") for call in runner.calls))

    def test_non_planner_caller_cannot_use_the_bridge(self):
        runner = FakeHerdrRunner(self_name="dex-vut-coder")
        runner.agents["dex-vut-coder"]["pane_id"] = "w2:p1"
        bridge, _runner = self.make_bridge(runner=runner)

        with self.assertRaisesRegex(self.module.BridgeError, "Planner"):
            bridge.inspect_team()

    def test_missing_same_team_reviewer_fails_closed(self):
        runner = FakeHerdrRunner()
        del runner.agents["dex-vut-reviewer"]
        bridge, _runner = self.make_bridge(runner=runner)

        with self.assertRaisesRegex(self.module.BridgeError, "dex-vut-reviewer"):
            bridge.inspect_team()

    def test_mcp_server_advertises_only_the_bounded_tools(self):
        bridge, _runner = self.make_bridge()
        server = self.module.McpServer(bridge)

        initialized = server.handle(
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {"protocolVersion": "2025-06-18"},
            }
        )
        self.assertEqual(initialized["result"]["protocolVersion"], "2025-06-18")

        listed = server.handle(
            {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}}
        )
        tool_names = [tool["name"] for tool in listed["result"]["tools"]]
        self.assertEqual(tool_names, ["inspect_team", "prompt_agent"])
        prompt_schema = listed["result"]["tools"][1]["inputSchema"]
        self.assertEqual(prompt_schema["properties"]["target_role"]["enum"], ["coder", "reviewer"])

        called = server.handle(
            {
                "jsonrpc": "2.0",
                "id": 3,
                "method": "tools/call",
                "params": {"name": "inspect_team", "arguments": {}},
            }
        )
        payload = json.loads(called["result"]["content"][0]["text"])
        self.assertEqual(payload["self_agent"], "dex-vut-planner")
        self.assertFalse(called["result"]["isError"])

    def test_socket_validator_requires_a_direct_owned_unix_socket(self):
        with tempfile.TemporaryDirectory(prefix="herdr-mcp-socket-") as directory:
            socket_path = Path(directory) / "herdr.sock"
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server_socket:
                server_socket.bind(str(socket_path))
                self.module._default_socket_validator(str(socket_path))

                symlink_path = Path(directory) / "linked.sock"
                symlink_path.symlink_to(socket_path)
                with self.assertRaisesRegex(self.module.BridgeError, "direct Unix socket"):
                    self.module._default_socket_validator(str(symlink_path))

            regular_path = Path(directory) / "regular"
            regular_path.write_text("not a socket", encoding="utf-8")
            with self.assertRaisesRegex(self.module.BridgeError, "direct Unix socket"):
                self.module._default_socket_validator(str(regular_path))


if __name__ == "__main__":
    unittest.main()
