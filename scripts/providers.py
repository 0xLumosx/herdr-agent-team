"""Build native CLI role configurations and inspect the live process arguments."""
import hashlib
import json
import os
import shlex
import shutil
import sys
import subprocess
from pathlib import Path

ROLES = ("planner", "coder", "reviewer")
CLAUDE_READ = "Read,Glob,Grep,WebFetch,WebSearch"
AGY_READ = ["view_file", "list_dir", "grep_search", "find_by_name", "read_url_content"]


def managed_file(path, content, create):
    if not create:
        if path.is_symlink() or path.read_text() != content:
            raise ValueError("Unexpected managed file: " + str(path))
        return str(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    try:
        with path.open("x") as f:
            f.write(content)
    except FileExistsError:
        if path.is_symlink() or path.read_text() != content:
            raise ValueError("Conflicting managed file: " + str(path))
    return str(path)


def agy_servers(bridge, herdr):
    base = {"command": os.path.realpath(sys.executable), "env": {"HERDR_BIN_PATH": herdr}}
    return {name: dict(base, args=[str(bridge), "--agy-server", mode]) for name, mode in
            (("herdr_codex_team", "team"), ("herdr_team_ssh", "ssh"))}


def configure_agy(bridge, herdr):
    # Antigravity initializes its global registry before the first model turn.
    # These servers publish no tools outside their corresponding Herdr panes.
    config = Path.home() / ".gemini/config/mcp_config.json"
    raw = config.read_text().strip() if config.exists() else ""
    existing = json.loads(raw).get("mcpServers", {}) if raw else {}
    for name, server in agy_servers(bridge, herdr).items():
        previous = existing.get(name)
        if previous is not None:
            if all(previous.get(k) == v for k, v in server.items()):
                if previous.get("disabled"):
                    subprocess.run(["agy", "mcp", "enable", name], check=True)
                continue
            if (previous.get("command") != server["command"] or previous.get("args") != server["args"]
                    or set(previous.get("env", {})) != {"HERDR_BIN_PATH"}):
                raise ValueError("Existing Antigravity MCP configuration conflicts with " + name)
            # The team's Herdr executable moved. Update its own registration in place.
        subprocess.run(["agy", "mcp", "add", "--env", "HERDR_BIN_PATH=" + herdr, name,
                        server["command"], *server["args"]], check=True)


def unconfigure_agy(bridge):
    config = Path.home() / ".gemini/config/mcp_config.json"
    raw = config.read_text().strip() if config.is_file() else ""
    servers = json.loads(raw).get("mcpServers", {}) if raw else {}
    for name, mode in (("herdr_codex_team", "team"), ("herdr_team_ssh", "ssh")):
        if servers.get(name, {}).get("args") == [str(bridge), "--agy-server", mode]:
            subprocess.run(["agy", "mcp", "remove", name], check=True)


def native_args(kind, role, directory, bridge, herdr, create=True):
    source = Path(__file__).resolve().parents[1] / "prompts" / (role + ".md")
    prompt = source.read_text()
    prompt_file = managed_file(directory / source.name, prompt, create)
    python = os.path.realpath(sys.executable)
    server = {"command": python, "args": [str(bridge)], "env": {"HERDR_BIN_PATH": herdr}}
    servers = {"herdr_team_ssh": dict(server, args=[str(bridge), "--ssh", role])}
    ssh_names = ["remote_context", "ssh_read"]
    if role == "planner":
        servers["herdr_codex_team"] = server
        ssh_names += ["select_remote", "use_local"]
    elif role == "coder":
        ssh_names.append("ssh_run")
    grants = [("herdr_team_ssh", name) for name in ssh_names]
    if role == "planner":
        grants += [("herdr_codex_team", name) for name in ("inspect_team", "prompt_agent")]
    settings_file = directory / (role + "." + kind + ".settings.json")
    if not create and not settings_file.exists():
        settings_file = directory / (role + ".settings.json")
    if kind == "claude":
        tools = CLAUDE_READ
        # Keep the user's native auth configuration in its original file.
        user_settings = Path(os.environ.get("CLAUDE_CONFIG_DIR", Path.home() / ".claude")) / "settings.json"
        if role == "coder":
            tools += ",Edit,Write,Bash"
            settings = {"sandbox": {"enabled": True, "failIfUnavailable": True,
                                    "allowUnsandboxedCommands": False}}
            policy = ["--setting-sources", "user", "--settings", managed_file(settings_file, json.dumps(settings), create)]
        else:
            policy = ["--restricted", "--settings", str(user_settings)]
        # A user's ordinary Claude installation can already have the Codex team's skill installed.
        # Deny its native invocation just for this managed session, including invocations with arguments.
        policy += ["--disallowedTools", "Skill(stop-that-shit *),Skill(stop-that-shit:stop-that-shit *)",
                   "--allowedTools", ",".join("mcp__%s__%s" % item for item in grants)]
        return policy + ["--strict-mcp-config", "--mcp-config", json.dumps({"mcpServers": servers}),
                         "--tools", tools, "--append-system-prompt-file", prompt_file]
    if kind != "agy":
        raise ValueError("Unknown CLI: " + kind)
    tools = list(AGY_READ)
    if role == "coder":
        tools.extend(["write_to_file", "replace_file_content", "multi_replace_file_content", "run_command"])
    fields = {"description": "Managed Herdr " + role, "subagent": False, "mainAgent": True,
              "tools": tools, "inheritMcp": False, "commandExecutionPolicy": "sandbox"}
    registered = agy_servers(bridge, herdr)
    fields["mcpServers"] = [dict(name=name, **registered[name]) for name in servers]
    dispatch = ("Antigravity tool calls use call_mcp_tool. Pass ServerName, ToolName and Arguments. "
                "For SSH use ServerName herdr_team_ssh, for example ToolName ssh_read with "
                'Arguments {"operation":"pwd"}.')
    if role == "planner":
        dispatch += " For handoffs use ServerName herdr_codex_team with ToolName inspect_team or prompt_agent."
    prompt = dispatch + "\n\n" + prompt
    body = "".join(k + ": " + json.dumps(v) + "\n" for k, v in fields.items()) + "---\n" + prompt
    name = "herdr-" + role + "-" + hashlib.sha256(body.encode()).hexdigest()[:12]
    managed_file(Path.home() / ".gemini/config/agents" / (name + ".md"), "---\nname: " + name + "\n" + body, create)
    title = {"command": shlex.quote(python) + " " + shlex.quote(str(bridge)) + " --session-title"}
    settings = {"title": title, "statusLine": title}
    settings["permissions"] = {"allow": ["mcp(%s/%s)" % item for item in grants]}
    if role != "coder":
        settings["permissions"]["deny"] = ["command(*)", "write_file(*)"]
    return ["--agent", name, "--settings", managed_file(settings_file, json.dumps(settings), create),
            "--sandbox", "--mode", "accept-edits"]


def inspect(kind, role):
    processes = json.load(sys.stdin)["result"]["process_info"]["foreground_processes"]
    matches = [p["argv"] for p in processes if p.get("argv") and
               kind in {Path(p["argv"][0]).name, Path(p.get("name", "")).name}]
    if len(matches) != 1:
        raise ValueError("Expected one foreground " + kind + " process")
    args = matches[0][1:]
    role_flag = "--append-system-prompt-file" if kind == "claude" else "--settings"
    directory = Path(args[args.index(role_flag) + 1]).parent
    codex_home = Path(os.environ.get("CODEX_HOME", Path.home() / ".codex"))
    managed = codex_home / "herdr-codex-team"
    if directory.parent.parent != managed / "state/v1/teams" or directory.resolve() != directory:
        raise ValueError("Role configuration is outside the managed team state")
    herdr = os.path.realpath(shutil.which("herdr") or "")
    expected = native_args(kind, role, directory, managed / "herdr_mcp.py", herdr, create=False)
    if args[:len(expected)] != expected:
        raise ValueError("Unexpected " + kind + " role arguments")

    rest = args[len(expected):]
    while rest:
        flag, value, *rest = rest
        if flag == "--add-dir" and role != "reviewer":
            if not os.path.isabs(value) or any(ord(c) < 32 for c in value):
                raise ValueError("Invalid workspace root")
            print(value)
        elif flag != "--model" or rest:
            raise ValueError("Unexpected " + kind + " option: " + flag)


if __name__ == "__main__":
    try:
        if sys.argv[1:2] == ["unconfigure-agy"]:
            unconfigure_agy(Path(sys.argv[2]))
            sys.exit(0)
        if sys.argv[1:2] == ["configure-agy"]:
            configure_agy(Path(sys.argv[2]), sys.argv[3])
            sys.exit(0)
        action, kind, role, *rest = sys.argv[1:]
        if role not in ROLES:
            raise ValueError("Unknown role")
        if action == "prepare":
            folder, bridge, herdr = rest
            for arg in native_args(kind, role, Path(folder), Path(bridge), herdr):
                print(arg)
        elif action == "inspect":
            inspect(kind, role)
        else:
            raise ValueError("Unknown action")
    except (KeyError, ValueError, OSError, IndexError, TypeError, subprocess.SubprocessError) as error:
        sys.exit(str(error))
