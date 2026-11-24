#!/usr/bin/env python3

import importlib.util
import json
from itertools import product
import os
from pathlib import Path
import socket
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
from uuid import uuid4


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
            elif target not in self.agents:
                target = self._resolve_target(target)
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
        if len(args) == 4 and args[:2] == ("agent", "prompt") and args[3].startswith("/resume "):
            agent = self.agents[self._resolve_target(args[2])]
            thread = args[3].split()[1]
            agent["terminal_title"] = thread[:29] + "..."
            agent["agent_session"]["value"] = thread
            return {"result": {"type": "agent_prompted", "agent": dict(agent)}}
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
        home = tempfile.TemporaryDirectory(prefix="herdr-disposable-bridge-")
        self.addCleanup(home.cleanup)
        env.update(CODEX_HOME=os.path.realpath(home.name), HERDR_TEAM_RUN_ID="test-run")
        directory = self.module.team_directory(env, "dex-vut")
        directory.mkdir(parents=True)
        record = directory / "current.json"
        roles = self.module.ROLES
        record.write_text(json.dumps({
            "run_id": "test-run", "launch": {"primary_cwd": "/project", "add_dirs": []},
            "herdr": {"workspace_id": "w2", "agents": {
                role: {"pane_id": "w2:p%d" % i} for i, role in enumerate(roles, 1)
            }}
        }))
        threads = [str(uuid4()) for _ in roles]
        for role, thread in zip(roles, threads):
            agent = runner.agents.get("dex-vut-" + role)
            if agent is not None:
                agent.update(terminal_title=thread, agent_session={
                    "kind": "id", "agent": "codex", "source": "herdr:codex", "value": thread})
        self.module.bind_launch(record, threads)
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

    def test_each_provider_can_lead_or_follow_a_linked_switch(self):
        for kinds in product(("codex", "claude", "agy"), repeat=3):
            with self.subTest(kinds=kinds):
                bridge, runner = self.make_bridge()
                role_map = {}
                before = [str(uuid4()) for _ in kinds]
                older = [str(uuid4()) for _ in kinds]
                for role, kind, thread in zip(self.module.ROLES, kinds, before):
                    agent = runner.agents["dex-vut-" + role]
                    agent.update(agent=kind, terminal_title=thread)
                    source = "herdr:antigravity_cli" if kind == "agy" else "herdr:" + kind
                    agent["agent_session"] = dict(kind="id", agent=kind, source=source, value=thread)
                    role_map[role] = dict(pane_id=agent["pane_id"], cli=kind)
                with tempfile.TemporaryDirectory(prefix="herdr-disposable-providers-") as home:
                    bridge._env.update(CODEX_HOME=os.path.realpath(home), HERDR_TEAM_RUN_ID="run")
                    directory = self.module.team_directory(bridge._env, "dex-vut")
                    directory.mkdir(parents=True)
                    record = directory / "current.json"
                    record.write_text(json.dumps({"run_id": "run",
                        "launch": {"primary_cwd": "/project", "add_dirs": []},
                        "herdr": {"workspace_id": "w2", "agents": role_map}}))
                    for group in (older, before):
                        self.module.bind_launch(record, group)
                    for group in (older, before):
                        planner = runner.agents["dex-vut-planner"]
                        planner["terminal_title"] = group[0]
                        planner["agent_session"]["value"] = group[0]
                        self.assertFalse(bridge._follow_selection(group[0], set()))
                        team = bridge.inspect_team()
                        self.assertEqual([team[r + "_agent"]["thread_id"] for r in ("coder","reviewer")], group[1:])

    def test_fresh_mixed_chats_are_saved_by_their_native_clients(self):
        roles = self.module.ROLES
        kinds = ("claude", "codex", "agy")
        ids = [str(uuid4()) for _ in roles]
        agents = {r: dict(cli=k, name="team-" + r) for r, k in zip(roles, kinds)}
        with tempfile.TemporaryDirectory(prefix="herdr-disposable-native-history-") as temp:
            home = Path(temp).resolve()
            codex = home / ".codex"
            codex.mkdir()
            claude = home / ".claude"
            transcript_dir = claude / "projects/project"
            transcript_dir.mkdir(parents=True)
            index = home / ".gemini/antigravity-cli/conversation_summaries.db"
            index.parent.mkdir(parents=True)
            with sqlite3.connect(index) as db:
                db.execute("CREATE TABLE conversation_summaries(conversation_id TEXT, title TEXT)")

            def rename(argv, **kwargs):
                role = argv[3][len("team-"):]
                thread = ids[roles.index(role)]
                title = "team-" + role + " run"
                self.assertEqual(argv[4], "/rename " + title)
                if role == "planner":
                    event = {"sessionId": thread, "type": "custom-title", "customTitle": title}
                    (transcript_dir / (thread + ".jsonl")).write_text(json.dumps(event) + "\n")
                elif role == "coder":
                    event = {"id": thread, "thread_name": title}
                    (codex / "session_index.jsonl").write_text(json.dumps(event) + "\n")
                else:
                    with sqlite3.connect(index) as db:
                        db.execute("INSERT INTO conversation_summaries VALUES (?,?)", (thread, title))

            with mock.patch.dict(os.environ, HOME=str(home), CODEX_HOME=str(codex),
                                 CLAUDE_CONFIG_DIR=str(claude), HERDR_BIN_PATH="/herdr"):
                with mock.patch.object(self.module.subprocess, "run", side_effect=rename) as send:
                    self.module.save_fresh_chats({"herdr": {"agents": agents}, "run_id": "run"}, ids)
                    self.assertEqual(send.call_count, 3)

    def test_gemini_resume_checks_saved_role_instructions(self):
        with tempfile.TemporaryDirectory(prefix="herdr-disposable-gemini-snapshot-") as temp:
            thread = str(uuid4())
            path = Path(temp) / ".gemini/antigravity-cli/conversations" / (thread + ".db")
            path.parent.mkdir(parents=True)
            with sqlite3.connect(path) as db:
                db.execute("CREATE TABLE trajectory_metadata_blob(id TEXT PRIMARY KEY, data BLOB)")
                db.execute("INSERT INTO trajectory_metadata_blob VALUES ('main', ?)", (
                    b"herdr-reviewer-123456789abc Apply the embedded Stop That Shit skill on every task.",))
            with mock.patch.dict(os.environ, HOME=temp):
                with self.assertRaisesRegex(self.module.BridgeError, "older role"):
                    self.module.check_agy_role_snapshot("agy:" + thread, "reviewer")
                self.module.check_agy_role_snapshot(thread, "reviewer")
                with sqlite3.connect(path) as db:
                    db.execute("UPDATE trajectory_metadata_blob SET data=?", (b"herdr-reviewer-123456789abc",))
                self.module.check_agy_role_snapshot("agy:" + thread, "reviewer")

    def test_native_role_argv_round_trip(self):
        script = str(PROJECT_ROOT / "scripts/providers.py")
        with tempfile.TemporaryDirectory(prefix="herdr-disposable-role-argv-") as temp:
            home = Path(temp).resolve()
            codex = home / ".codex"
            bridge = codex / "herdr-codex-team/herdr_mcp.py"
            env = dict(os.environ, HOME=str(home), CODEX_HOME=str(codex))
            binary = home / "bin/herdr"
            binary.parent.mkdir()
            binary.touch(mode=0o700)
            env["PATH"] = str(binary.parent) + os.pathsep + env["PATH"]
            for kind, role in product(("claude", "agy"), self.module.ROLES):
                with self.subTest(kind=kind, role=role):
                    folder = bridge.parent / "state/v1/teams/legacy" / (kind + "-run")
                    folder.mkdir(parents=True, exist_ok=True)
                    args = subprocess.check_output([sys.executable, script, "prepare", kind, role,
                        str(folder), str(bridge), str(binary)], env=env, text=True).splitlines()
                    if kind == "claude":
                        instructions = Path(args[args.index("--append-system-prompt-file") + 1]).read_text()
                        self.assertIn("Skill(stop-that-shit:stop-that-shit *)",
                                      args[args.index("--disallowedTools") + 1])
                    else:
                        name = args[args.index("--agent") + 1]
                        instructions = (home / ".gemini/config/agents" / (name + ".md")).read_text()
                    self.assertIn((PROJECT_ROOT / "prompts" / (role + ".md")).read_text(), instructions)
                    self.assertNotIn("stop that shit", instructions.lower())
                    self.assertNotIn("stop-that-shit", instructions.lower())
                    if role != "reviewer":
                        args += ["--add-dir", "/project with spaces"]
                    command = [sys.executable, script, "inspect", kind, role]
                    def inspect(argv):
                        data = {"result": {"process_info": {"foreground_processes": [
                            {"argv": [kind] + argv, "name": kind}]}}}
                        return subprocess.run(command, env=env, input=json.dumps(data), text=True, capture_output=True)
                    result = inspect(args)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout.strip(), "" if role == "reviewer" else "/project with spaces")
                    self.assertNotEqual(inspect(args + ["--dangerously-skip-permissions"]).returncode, 0)

    def test_ssh_context_follows_group_and_reviewer_has_only_reads(self):
        bridge, runner = self.make_bridge()
        directory = self.module.team_directory(bridge._env, "dex-vut")
        record = directory / "current.json"
        data = json.loads(record.read_text())
        for role in self.module.ROLES:
            data["herdr"]["agents"][role]["name"] = "dex-vut-" + role
        record.write_text(json.dumps(data))
        first = [runner.agents["dex-vut-" + r]["agent_session"]["value"] for r in self.module.ROLES]
        older = [str(uuid4()) for _ in first]
        self.module.bind_launch(record, older)

        def call(role, tool, **args):
            runner.current_pane = runner.agents["dex-vut-" + role]["pane_id"]
            bridge._env["HERDR_PANE_ID"] = runner.current_pane
            return self.module.ssh_tool_call(bridge, role, tool, args)

        def show(group):
            for r, thread in zip(self.module.ROLES, group):
                a = runner.agents["dex-vut-" + r]
                a["terminal_title"] = thread
                a["agent_session"]["value"] = thread

        with mock.patch.object(self.module, "ssh_command", return_value={
                "exit_code": 0, "output": "/srv/project\n", "truncated": False}) as ssh:
            selected = call("planner", "select_remote", host="test-host")
            for role in self.module.ROLES:
                self.assertEqual(call(role, "remote_context"), selected)
                call(role, "ssh_read", operation="status")
                self.assertEqual(ssh.call_args.args[0], selected)
            with self.assertRaises(self.module.BridgeError):
                call("reviewer", "ssh_run", command="touch test")
            with self.assertRaises(self.module.BridgeError):
                call("coder", "select_remote", host="other")
            with self.assertRaises(self.module.BridgeError):
                call("reviewer", "ssh_read", operation="read", path="../outside")
            call("coder", "ssh_run", command="pwd")
            show(older)
            with self.assertRaisesRegex(self.module.BridgeError, "not selected"):
                call("reviewer", "remote_context")
            show(first)
            self.assertEqual(call("reviewer", "remote_context"), selected)
            call("planner", "use_local")
            with self.assertRaisesRegex(self.module.BridgeError, "not selected"):
                call("coder", "remote_context")

    def test_switched_planner_and_worker_keep_the_groups_ssh_destination(self):
        bridge, runner = self.make_bridge()
        directory = self.module.team_directory(bridge._env, "dex-vut")
        path = directory / "current.json"
        record = json.loads(path.read_text())
        agents = record["herdr"]["agents"]
        for role, agent in agents.items():
            agent["name"] = "dex-vut-" + role
        path.write_text(json.dumps(record))
        root = runner.agents["dex-vut-planner"]["agent_session"]["value"]
        with mock.patch.object(self.module, "ssh_command", return_value={
                "exit_code": 0, "output": "/srv/project\n", "truncated": False}):
            destination = self.module.ssh_tool_call(bridge, "planner", "select_remote", {"host": "test-host"})

        with self.module.link_database(directory, create=True) as db:
            db.execute("CREATE TABLE role_sessions (planner TEXT, role TEXT, cli TEXT, session TEXT)")
            for role in ("planner", "coder"):
                thread = str(uuid4())
                db.execute("INSERT INTO role_sessions VALUES (?,?,?,?)", (root, role, "claude", "claude:" + thread))
                runner.agents[agents[role]["name"]].update(agent="claude", terminal_title=thread,
                    agent_session=dict(kind="id", agent="claude", source="herdr:claude", value=thread))
                agents[role]["cli"] = "claude"
        db.close()
        path.write_text(json.dumps(record))
        current = [runner.agents[agents[r]["name"]]["agent_session"]["value"] for r in self.module.ROLES]
        self.module.bind_launch(path, current)
        for role in self.module.ROLES:
            pane = agents[role]["pane_id"]
            runner.current_pane = bridge._env["HERDR_PANE_ID"] = pane
            self.assertEqual(self.module.ssh_tool_call(bridge, role, "remote_context", {}), destination)

    def test_provider_mismatch_rejects_equal_uuid(self):
        bridge, runner = self.make_bridge()
        runner.agents["dex-vut-coder"].update(agent="agy", terminal_title=runner.agents["dex-vut-coder"]["agent_session"]["value"])
        with self.assertRaisesRegex(self.module.BridgeError, "different CLI"):
            bridge.inspect_team()

    def test_linked_resume_then_return_and_unknown_planner(self):
        bridge, runner = self.make_bridge()
        first = [str(uuid4()) for _ in self.module.ROLES]
        second = [str(uuid4()) for _ in self.module.ROLES]

        def show(role, thread):
            agent = runner.agents["dex-vut-" + role]
            agent["terminal_title"] = thread[:29] + "..."
            agent["agent_session"] = {"kind": "id", "source": "herdr:codex", "agent": "codex", "value": thread}

        with tempfile.TemporaryDirectory(prefix="herdr-disposable-conversation-test-") as home:
            bridge._env.update(CODEX_HOME=os.path.realpath(home), HERDR_TEAM_RUN_ID="test-run")
            directory = self.module.team_directory(bridge._env, "dex-vut")
            directory.mkdir(parents=True)
            record = directory / "current.json"
            record.write_text(json.dumps({
                "run_id": "test-run", "launch": {"primary_cwd": "/project", "add_dirs": []},
                "herdr": {"workspace_id": "w2", "agents": {
                    role: {"pane_id": runner.agents["dex-vut-" + role]["pane_id"]} for role in self.module.ROLES
                }}
            }))
            for group in (first, second):
                self.module.bind_launch(record, group)
            with self.assertRaisesRegex(self.module.BridgeError, "different binding"):
                self.module.bind_launch(record, [first[0], *second[1:]])
            for role, thread in zip(self.module.ROLES, first):
                show(role, thread)
            for group in (second, first):
                show("planner", group[0])
                with self.assertRaisesRegex(self.module.BridgeError, "switch incomplete"):
                    bridge.prompt_agent("coder", "Do not deliver during a switch")
                runner.agents["dex-vut-reviewer"]["agent_status"] = "working"
                with self.assertRaisesRegex(self.module.BridgeError, "not settled"):
                    bridge._follow_selection(group[0], set())
                runner.agents["dex-vut-reviewer"]["agent_status"] = "idle"
                self.assertFalse(bridge._follow_selection(group[0], set()))
                self.assertTrue(bridge._follow_selection(group[0], set()))
                result = bridge.inspect_team()
                self.assertEqual([result[r + "_agent"]["thread_id"] for r in ("coder", "reviewer")], group[1:])
            unknown = str(uuid4())
            show("planner", unknown)
            with self.assertRaisesRegex(self.module.BridgeError, "No conversation link"):
                bridge._follow_selection(unknown, set())
            submitted = [args[3] for args, _ in runner.calls if args[:2] == ("agent", "prompt")]
            self.assertEqual(submitted, ["/resume " + item for item in second[1:] + first[1:]])

    def test_thread_before_first_turn_and_delayed_hook_after_resume(self):
        current, old = str(uuid4()), str(uuid4())
        agent = {"pane_id": "w2:p1", "terminal_title": current[:29] + "..."}
        footer = lambda _pane: "  " + current + "\n  ? for shortcuts"
        self.assertEqual(self.module.active_thread(agent, footer), current)
        agent["agent_session"] = {"kind": "id", "agent": "codex", "source": "herdr:codex", "value": old}
        self.assertEqual(self.module.active_thread(agent, footer), current)
        with self.assertRaisesRegex(self.module.BridgeError, "Cannot verify"):
            self.module.active_thread(agent, lambda _pane: old)

    def test_matching_names_do_not_authorize_a_different_scope_or_launch(self):
        bridge, _ = self.make_bridge()
        directory = self.module.team_directory(bridge._env, "dex-vut")
        record = directory / "current.json"
        state = json.loads(record.read_text())
        state["run_id"] = "another-launch"
        state["launch"]["add_dirs"] = ["/other"]
        record.write_text(json.dumps(state))
        self.module.bind_launch(record, [str(uuid4()) for _ in self.module.ROLES])
        bridge._env["HERDR_TEAM_RUN_ID"] = state["run_id"]
        with self.assertRaisesRegex(self.module.BridgeError, "No conversation link"):
            bridge.prompt_agent("coder", "Wrong scope")
        del bridge._env["HERDR_TEAM_RUN_ID"]
        with self.assertRaisesRegex(self.module.BridgeError, "No managed conversation launch"):
            bridge.prompt_agent("coder", "Unknown launch")

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

    def test_codex_handoff_waits_for_the_exact_submitted_turn(self):
        class EarlyIdleRunner(FakeHerdrRunner):
            def __call__(self, args, timeout_ms):
                if tuple(args)[:2] == ("agent", "wait"):
                    return {"result": {"agent": self.agents[self._resolve_target(args[2])]}}
                response = super().__call__(args, timeout_ms)
                if tuple(args)[:2] == ("agent", "prompt"):
                    with rollout.open("a") as stream:
                        pane_report = "Reviewer report\n" + "pane only\n" * 25 + "End of report"
                        for turn, prompt, reply in (("other", "unrelated", "stale"),
                                                    ("wanted", args[3], "PASS\n" + pane_report)):
                            events = [
                                ("event_msg", {"type": "task_started", "turn_id": turn}),
                                ("response_item", {"type": "message", "role": "user",
                                                   "content": [{"type": "input_text", "text": prompt}]}),
                                ("event_msg", {"type": "task_complete", "turn_id": turn, "last_agent_message": reply}),
                            ]
                            for kind, payload in events:
                                stream.write(json.dumps({"type": kind, "payload": payload}) + "\n")
                    response["result"]["agent"]["agent_status"] = "working"
                return response

        bridge, runner = self.make_bridge(runner=EarlyIdleRunner())
        thread = runner.agents["dex-vut-reviewer"]["terminal_title"]
        rollout = Path(bridge._env["CODEX_HOME"]) / "sessions/2026/11/23" / ("rollout-test-" + thread + ".jsonl")
        rollout.parent.mkdir(parents=True)
        rollout.write_text(json.dumps({"type": "session_meta", "payload": {"id": thread, "cli_version": "0.160.1"}}) + "\n")
        with mock.patch.object(subprocess, "check_output", return_value="codex-cli 0.171.0"):
            result = bridge.prompt_agent("reviewer", "Check this change", read_lines=20)
        self.assertEqual(result["transcript"]["source"], "codex-turn")
        self.assertEqual(result["transcript"]["text"], "PASS")

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

    def test_terminal_review_returns_fix_and_question_without_report_history(self):
        bridge, _runner = self.make_bridge()
        handoff = "CHANGES_REQUIRED\nTASK_ID: link\nROUND: 1\nHANDOFF_ID: rev\nFix the link target."
        question = "ASK_USER\nTASK_ID: link\nROUND: 1\nHANDOFF_ID: next\nWhich directory?"
        history = "truncated old report\nEnd of report\nReviewer report\nold format without a footer\n"
        history += "› Review the link\n" + handoff
        history += "\n  ● **Reviewer report**\n" + "pane only\n" * 25 + "> quoted inside the report\n  End of report\n" + question
        with mock.patch.object(bridge, "_text_runner", return_value=history):
            result = bridge.prompt_agent("reviewer", "Review the link", read_lines=20)
        self.assertEqual(result["transcript"]["text"], "› Review the link\n" + handoff + "\n" + question)

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
