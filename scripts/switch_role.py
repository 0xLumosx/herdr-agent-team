"""Associate an explicitly selected replacement CLI with this pane's conversation group."""
from contextlib import closing
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

from herdr_mcp import (BridgeError, active_thread, check_agy_role_snapshot, group_for_planner,
                       link_database, role_session, save_fresh_chats, session_key,
                       start_selection_observer, warm_agy_tools)


def herdr(*args):
    return subprocess.check_output([os.environ["HERDR_BIN_PATH"], *args], text=True, stderr=subprocess.PIPE, timeout=8)


def live_agent(pane):
    return json.loads(herdr("agent", "get", pane))["result"]["agent"]


def thread(agent):
    return active_thread(agent, lambda pane: herdr("agent", "read", pane, "--source", "visible", "--lines", "12"))


def record_for_pane(path, role):
    record = json.loads(path.read_text())
    member = record["herdr"]["agents"][role]
    if (record["run_id"] != os.environ["HERDR_TEAM_RUN_ID"]
            or member["pane_id"] != os.environ["HERDR_PANE_ID"]
            or record["herdr"]["workspace_id"] != os.environ["HERDR_WORKSPACE_ID"]
            or record["status"] != "ready"):
        raise BridgeError("窗格与当前团队启动记录不匹配")
    return record


def selected_group(path, record, role, pending_group=None):
    with closing(link_database(path.parent)) as db:
        if role != "planner":
            owner = record["herdr"]["agents"]["planner"]
            try:
                planner = live_agent(owner["pane_id"])
            except subprocess.CalledProcessError:
                planner = {}  # The Planner may have returned to its shell.
            if planner.get("agent"):
                if planner.get("name") != owner["name"] or planner["workspace_id"] != record["herdr"]["workspace_id"]:
                    raise BridgeError("Planner 窗格已变化")
                key = session_key(planner["agent"], thread(planner))
                group = group_for_planner(db, key)
                scope = json.dumps([record["launch"]["primary_cwd"], record["launch"]["add_dirs"]])
                if not db.execute("SELECT 1 FROM groups_by_planner WHERE planner=? AND scope=?", (group, scope)).fetchone():
                    if pending_group:
                        return pending_group  # Another CLI may still be starting in the Planner pane.
                    raise BridgeError("请先在 Planner 中选择已登记的会话")
                return group
        row = db.execute("SELECT planner FROM active_groups WHERE run=?", (record["run_id"],)).fetchone()
        if not row:
            raise BridgeError("未找到该团队上次使用的会话组")
        return row[0]


def wait_for_cli(record, role, kind, expected=None):
    member = record["herdr"]["agents"][role]
    deadline = time.monotonic() + 180
    while time.monotonic() < deadline:
        try:
            agent = live_agent(member["pane_id"])
            if (agent.get("agent") == kind and agent.get("workspace_id") == record["herdr"]["workspace_id"]
                    and agent.get("interactive_ready") and agent.get("agent_status") in ("idle", "done")):
                if agent.get("name") != member["name"]:
                    raise BridgeError("该窗格与登记的角色名称不符")
                if kind == "codex" and "enter confirm · esc skip" in herdr(
                        "pane", "read", member["pane_id"], "--source", "visible", "--lines", "15"):
                    time.sleep(0.25)
                    continue
                try:
                    value = thread(live_agent(member["pane_id"]))
                except BridgeError:
                    value = None
                if value and (not expected or value == expected):
                    return value
        except subprocess.CalledProcessError:
            pass  # Herdr may still see the shell while the new CLI starts.
        time.sleep(0.25)
    raise BridgeError("CLI 未就绪，请检查登录、信任提示或会话恢复界面")


def finish(path, role, kind, group, caller, args):
    with (path.parent / "switch.lock").open("a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        record = record_for_pane(path, role)
        member = record["herdr"]["agents"][role]
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            try:
                os.kill(caller, 0)
            except ProcessLookupError:
                break
            time.sleep(0.05)
        cmd = [os.environ["HERDR_BIN_PATH"], "agent", "start", member["name"], "--kind", kind,
               "--pane", member["pane_id"], "--timeout", "30000", "--", *args]
        deadline = time.monotonic() + 5
        while True:
            launch = subprocess.run(cmd, capture_output=True, text=True, timeout=40)
            if not launch.returncode:
                break
            message = launch.stderr + launch.stdout
            if "agent_not_ready" in message:
                break  # The user can answer first-run prompts here.
            # Herdr can still report the exiting agent by name on the very same pane.
            own_name_releasing = ("agent_name_taken" in message and message.count("pane_id=") == 1
                                  and ("pane_id=" + member["pane_id"] + " ") in message)
            if time.monotonic() < deadline and ("available shell" in message or "pane_busy" in message
                                                or own_name_releasing):
                time.sleep(0.1)
                continue
            raise BridgeError(message.strip())
        value = wait_for_cli(record, role, kind)
        record = record_for_pane(path, role)
        if selected_group(path, record, role, pending_group=group) != group:
            raise BridgeError("切换期间 Planner 改变了会话")
        member = record["herdr"]["agents"][role]
        member["cli"] = kind
        with closing(link_database(path.parent, create=True)) as db, db:
            old = role_session(db, group, role, kind)
            if old:
                check_agy_role_snapshot(old, role)
                target = old.split(":")[-1]
                if value != target:
                    herdr("agent", "prompt", member["pane_id"], "/resume " + target)
                    wait_for_cli(record, role, kind, target)
            else:
                save_fresh_chats(record, [value], roles=[role])
                key = session_key(kind, value)
                check_agy_role_snapshot(key, role)
                db.execute("CREATE TABLE IF NOT EXISTS role_sessions (planner TEXT, role TEXT, cli TEXT, session TEXT, "
                           "PRIMARY KEY(planner,role,cli))")
                db.execute("CREATE UNIQUE INDEX IF NOT EXISTS planner_role_session ON role_sessions(session) WHERE role='planner'")
                db.execute("INSERT INTO role_sessions VALUES (?,?,?,?)", (group, role, kind, key))
        if kind == "agy":
            warm_agy_tools(record, [role])
        record_for_pane(path, role)
        with tempfile.NamedTemporaryFile("w", dir=path.parent, prefix=".switch-", delete=False) as staged:
            json.dump(record, staged, ensure_ascii=False, indent=2)
            staged.write("\n")
        os.replace(staged.name, path)
        if role == "planner":
            start_selection_observer(path)
    herdr("notification", "show", role + " 已切换", "--body", kind)


if __name__ == "__main__":
    path = Path(os.environ["HERDR_TEAM_STATE_FILE"])
    role = os.environ["HERDR_TEAM_ROLE"]
    try:
        if sys.argv[1] == "context":
            record = record_for_pane(path, role)
            print(selected_group(path, record, role), record["launch"]["primary_cwd"],
                  *record["launch"]["add_dirs"], sep="\n")
        elif sys.argv[1] == "launch":
            with (path.parent / (role + "-switch.log")).open("w") as log:
                subprocess.Popen([sys.executable, "-B", __file__, "finish", *sys.argv[2:]],
                                 start_new_session=True, stdin=subprocess.DEVNULL, stdout=log, stderr=log)
        else:
            finish(path, role, sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5:])
    except Exception as error:
        if sys.argv[1] == "finish":
            herdr("notification", "show", "角色切换未完成", "--body", str(error))
        sys.exit(str(error))
