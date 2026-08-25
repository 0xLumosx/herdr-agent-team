#!/usr/bin/env bash

# Parse Herdr JSON with a real parser. jq is preferred; Python's standard
# library is the portable fallback. Critical identity checks must never infer
# an empty result from malformed JSON.

json_backend_name() {
  if command -v jq >/dev/null 2>&1; then
    printf '%s' jq
  elif command -v python3 >/dev/null 2>&1; then
    printf '%s' python3
  else
    return 1
  fi
}

json_agent_field() {
  local payload=$1
  local field=$2

  if command -v jq >/dev/null 2>&1; then
    printf '%s\n' "$payload" | jq -ser --arg field "$field" '
      if length != 1 then error("expected one JSON document") else .[0] end |
      .result.agent as $agent |
      if ($agent | type) != "object" then error("expected agent object")
      else
        $agent[$field] as $value |
        if $value == null then ""
        elif ($value | type) == "boolean" then ($value | tostring)
        elif ($value | type) == "string" then
          if ($value | test("[[:cntrl:]]")) then error("control character in agent field")
          else $value end
        elif ($value | type) == "number" then ($value | tostring)
        else error("unsupported agent field type")
        end
      end
    ' 2>/dev/null
    return
  fi

  command -v python3 >/dev/null 2>&1 || return 127
  printf '%s\n' "$payload" | python3 -c '
import json
import sys

try:
    data = json.load(sys.stdin)
    agent = data["result"]["agent"]
    if not isinstance(agent, dict):
        raise TypeError
    value = agent.get(sys.argv[1])
    if value is None:
        print("")
    elif isinstance(value, bool):
        print(str(value).lower())
    elif isinstance(value, str):
        if any(ord(char) < 32 or 127 <= ord(char) <= 159 for char in value):
            raise TypeError
        print(value)
    elif isinstance(value, (int, float)):
        print(value)
    else:
        raise TypeError
except (KeyError, TypeError, ValueError):
    sys.exit(2)
' "$field" 2>/dev/null
}

# Identity and path preflights must not coerce booleans or numbers into text.
# Required fields are non-empty strings; optional fields are strings or null.
json_agent_required_string() {
  local payload=$1
  local field=$2

  if command -v jq >/dev/null 2>&1; then
    printf '%s\n' "$payload" | jq -ser --arg field "$field" '
      if length != 1 then error("expected one JSON document") else .[0] end |
      .result.agent as $agent |
      if ($agent | type) != "object" then error("expected agent object")
      else
        $agent[$field] as $value |
        if (($value | type) == "string" and ($value | length) > 0 and
            (($value | test("[[:cntrl:]]")) | not)) then $value
        else error("expected non-empty string agent field")
        end
      end
    ' 2>/dev/null
    return
  fi

  command -v python3 >/dev/null 2>&1 || return 127
  printf '%s\n' "$payload" | python3 -c '
import json
import sys

try:
    agent = json.load(sys.stdin)["result"]["agent"]
    if not isinstance(agent, dict):
        raise TypeError
    value = agent.get(sys.argv[1])
    if (not isinstance(value, str) or not value or
            any(ord(char) < 32 or 127 <= ord(char) <= 159 for char in value)):
        raise TypeError
    print(value)
except (KeyError, TypeError, ValueError):
    sys.exit(2)
' "$field" 2>/dev/null
}

json_agent_optional_string() {
  local payload=$1
  local field=$2

  if command -v jq >/dev/null 2>&1; then
    printf '%s\n' "$payload" | jq -ser --arg field "$field" '
      if length != 1 then error("expected one JSON document") else .[0] end |
      .result.agent as $agent |
      if ($agent | type) != "object" then error("expected agent object")
      else
        $agent[$field] as $value |
        if $value == null then ""
        elif (($value | type) == "string" and
              (($value | test("[[:cntrl:]]")) | not)) then $value
        else error("expected string or null agent field")
        end
      end
    ' 2>/dev/null
    return
  fi

  command -v python3 >/dev/null 2>&1 || return 127
  printf '%s\n' "$payload" | python3 -c '
import json
import sys

try:
    agent = json.load(sys.stdin)["result"]["agent"]
    if not isinstance(agent, dict):
        raise TypeError
    value = agent.get(sys.argv[1])
    if value is None:
        print("")
    elif (isinstance(value, str) and
          not any(ord(char) < 32 or 127 <= ord(char) <= 159 for char in value)):
        print(value)
    else:
        raise TypeError
except (KeyError, TypeError, ValueError):
    sys.exit(2)
' "$field" 2>/dev/null
}

json_agent_required_boolean() {
  local payload=$1
  local field=$2

  if command -v jq >/dev/null 2>&1; then
    printf '%s\n' "$payload" | jq -ser --arg field "$field" '
      if length != 1 then error("expected one JSON document") else .[0] end |
      .result.agent as $agent |
      if ($agent | type) != "object" then error("expected agent object")
      else
        $agent[$field] as $value |
        if ($value | type) == "boolean" then ($value | tostring)
        else error("expected boolean agent field")
        end
      end
    ' 2>/dev/null
    return
  fi

  command -v python3 >/dev/null 2>&1 || return 127
  printf '%s\n' "$payload" | python3 -c '
import json
import sys

try:
    agent = json.load(sys.stdin)["result"]["agent"]
    if not isinstance(agent, dict):
        raise TypeError
    value = agent.get(sys.argv[1])
    if not isinstance(value, bool):
        raise TypeError
    print(str(value).lower())
except (KeyError, TypeError, ValueError):
    sys.exit(2)
' "$field" 2>/dev/null
}

json_object_string() {
  local payload=$1
  local object_name=$2
  local field_name=$3

  if command -v jq >/dev/null 2>&1; then
    printf '%s\n' "$payload" | jq -ser \
      --arg object "$object_name" --arg field "$field_name" '
        if length != 1 then error("expected one JSON document") else .[0] end |
        .result[$object][$field] |
        if (type == "string" and ((test("[[:cntrl:]]")) | not)) then .
        else error("expected safe string") end
      ' 2>/dev/null
    return
  fi

  command -v python3 >/dev/null 2>&1 || return 127
  printf '%s\n' "$payload" | python3 -c '
import json
import sys

try:
    value = json.load(sys.stdin)["result"][sys.argv[1]][sys.argv[2]]
    if (not isinstance(value, str) or
            any(ord(char) < 32 or 127 <= ord(char) <= 159 for char in value)):
        raise TypeError
    print(value)
except (KeyError, TypeError, ValueError):
    sys.exit(2)
' "$object_name" "$field_name" 2>/dev/null
}

json_agent_names() {
  local payload=$1

  if command -v jq >/dev/null 2>&1; then
    printf '%s\n' "$payload" | jq -sr '
      if length != 1 then error("expected one JSON document") else .[0] end |
      .result.agents |
      if type != "array" then error("expected agents array") else . end |
      .[] |
      if type != "object" then error("expected agent object")
      elif (.name == null) then empty
        elif ((.name | type) == "string" and
              ((.name | test("[[:cntrl:]]")) | not)) then .name
      else error("expected string agent name")
      end
    ' 2>/dev/null
    return
  fi

  command -v python3 >/dev/null 2>&1 || return 127
  printf '%s\n' "$payload" | python3 -c '
import json
import sys

try:
    agents = json.load(sys.stdin)["result"]["agents"]
    if not isinstance(agents, list):
        raise TypeError
    for agent in agents:
        if not isinstance(agent, dict):
            raise TypeError
        name = agent.get("name")
        if name is None:
            continue
        if (not isinstance(name, str) or
                any(ord(char) < 32 or 127 <= ord(char) <= 159 for char in name)):
            raise TypeError
        print(name)
except (KeyError, TypeError, ValueError):
    sys.exit(2)
' 2>/dev/null
}

json_process_uses_profile() {
  local payload=$1
  local role=$2

  if command -v jq >/dev/null 2>&1; then
    printf '%s\n' "$payload" | jq -se --arg role "$role" '
      def is_codex_executable:
        type == "string" and
        ((gsub("\\\\"; "/") | split("/")[-1] | ascii_downcase | sub("[.]exe$"; "")) == "codex");
      def option_args($args):
        ([range(0; ($args | length)) as $index |
          select($args[$index] == "--") | $index][0] // ($args | length)) as $stop |
        $args[0:$stop];
      def argv_profiles($args):
        option_args($args) as $options |
        [range(0; ($options | length) - 1) as $index |
          select($options[$index] == "--profile") |
          $options[$index + 1]];
      def cmdline_profiles($cmdline):
        if ($cmdline | test("(?:^|[[:space:]])--(?:[[:space:]]|$)")) then []
        else [$cmdline |
          scan("(?:^|[[:space:]])--profile[[:space:]]+([^[:space:]]+)")[0]]
        end;

      if length != 1 then error("expected one JSON document") else .[0] end |
      .result.process_info.foreground_processes as $processes |
      if ($processes | type) != "array" then error("expected process array")
      else
        [$processes[] |
          if type != "object" then error("expected process object")
          else
            .argv as $raw_args |
            .argv0 as $argv0 |
            .cmdline as $raw_cmdline |
            .name as $name |
            .pid as $pid |
            (if $raw_args == null then [] else $raw_args end) as $args |
            (if $raw_cmdline == null then "" else $raw_cmdline end) as $cmdline |
            if (($pid | type) != "number" or ($pid | floor) != $pid or
                $pid < 0 or $pid > 4294967295 or
                ($name | type) != "string" or
                ($argv0 != null and ($argv0 | type) != "string") or
                ($args | type) != "array" or
                any($args[]; type != "string") or
                ($cmdline | type) != "string")
            then error("invalid process fields")
            else
              (($name | is_codex_executable) or
               ($argv0 | is_codex_executable) or
               (($args[0] // null) | is_codex_executable)) as $is_codex |
              (if ($raw_args != null and ($raw_args | length) > 0)
               then argv_profiles($args) else cmdline_profiles($cmdline) end) as $profiles |
              {is_codex: $is_codex, profiles: $profiles}
            end
          end
        ] as $records |
        any($records[]; .is_codex and any(.profiles[]; . == $role)) and
        all($records[];
          (.is_codex | not) or
          ((.profiles | length) > 0 and all(.profiles[]; . == $role)))
      end
    ' >/dev/null 2>&1
    return
  fi

  command -v python3 >/dev/null 2>&1 || return 127
  printf '%s\n' "$payload" | python3 -c '
import json
import re
import sys

try:
    processes = json.load(sys.stdin)["result"]["process_info"]["foreground_processes"]
    if not isinstance(processes, list):
        raise TypeError
    role = sys.argv[1]
    profile_pattern = re.compile(r"(?:^|\s)--profile\s+([^\s]+)")
    expected_found = False

    def is_codex_executable(value):
        if not isinstance(value, str):
            return False
        basename = re.split(r"[/\\]", value)[-1].lower()
        if basename.endswith(".exe"):
            basename = basename[:-4]
        return basename == "codex"

    for process in processes:
        if not isinstance(process, dict):
            raise TypeError
        name = process.get("name")
        if not isinstance(name, str):
            raise TypeError
        pid = process.get("pid")
        if (isinstance(pid, bool) or not isinstance(pid, (int, float)) or
                int(pid) != pid or pid < 0 or pid > 4294967295):
            raise TypeError
        argv0 = process.get("argv0")
        if argv0 is not None and not isinstance(argv0, str):
            raise TypeError
        raw_argv = process.get("argv")
        argv = raw_argv if raw_argv is not None else []
        if not isinstance(argv, list) or not all(isinstance(item, str) for item in argv):
            raise TypeError
        cmdline = process.get("cmdline", "")
        if cmdline is None:
            cmdline = ""
        if not isinstance(cmdline, str):
            raise TypeError
        executable_names = [name, argv0, argv[0] if argv else None]
        if not any(is_codex_executable(value) for value in executable_names):
            continue
        options = argv[:argv.index("--")] if "--" in argv else argv
        if raw_argv is not None and argv:
            profiles = [
                options[index + 1]
                for index in range(len(options) - 1)
                if options[index] == "--profile"
            ]
        elif not re.search(r"(?:^|\s)--(?:\s|$)", cmdline):
            profiles = [match.group(1) for match in profile_pattern.finditer(cmdline)]
        else:
            profiles = []
        if not profiles:
            sys.exit(1)
        if any(profile != role for profile in profiles):
            sys.exit(1)
        if role in profiles:
            expected_found = True
    sys.exit(0 if expected_found else 1)
except (KeyError, TypeError, ValueError):
    sys.exit(2)
' "$role" >/dev/null 2>&1
}

# Print every structured Codex --add-dir value, one path per line. The
# structured argv is required: cmdline text cannot preserve shell quoting and
# must not be used to recover paths containing spaces. No output with status 0
# means that a Codex process was found and it declared no additional roots.
json_process_codex_add_dirs() {
  local payload=$1

  if command -v jq >/dev/null 2>&1; then
    printf '%s\n' "$payload" | jq -ser '
      def is_codex_executable:
        type == "string" and
        ((gsub("\\\\"; "/") | split("/")[-1] | ascii_downcase | sub("[.]exe$"; "")) == "codex");
      def option_args($args):
        ([range(0; ($args | length)) as $index |
          select($args[$index] == "--") | $index][0] // ($args | length)) as $stop |
        $args[0:$stop];
      def argv_add_dirs($args):
        option_args($args) as $options |
        [range(0; ($options | length)) as $index |
          $options[$index] as $arg |
          if $arg == "--add-dir" then
            if ($index + 1) >= ($options | length) then error("dangling --add-dir")
            elif (($options[$index + 1] | startswith("/") | not) or
                  ($options[$index + 1] | test("[[:cntrl:]]")))
              then error("invalid --add-dir value")
            else $options[$index + 1]
            end
          elif ($arg | startswith("--add-dir=")) then
            ($arg | sub("^--add-dir="; "")) as $value |
            if (($value | startswith("/") | not) or ($value | test("[[:cntrl:]]")))
              then error("invalid --add-dir value") else $value end
          else empty
          end];

      if length != 1 then error("expected one JSON document") else .[0] end |
      .result.process_info.foreground_processes as $processes |
      if ($processes | type) != "array" then error("expected process array")
      else
        [$processes[] |
          if type != "object" then error("expected process object")
          else
            .argv as $raw_args |
            .argv0 as $argv0 |
            .cmdline as $raw_cmdline |
            .name as $name |
            .pid as $pid |
            (if $raw_cmdline == null then "" else $raw_cmdline end) as $cmdline |
            if (($pid | type) != "number" or ($pid | floor) != $pid or
                $pid < 0 or $pid > 4294967295 or
                ($name | type) != "string" or
                ($argv0 != null and ($argv0 | type) != "string") or
                ($raw_args != null and ($raw_args | type) != "array") or
                ($raw_args != null and any($raw_args[]; type != "string")) or
                ($cmdline | type) != "string")
            then error("invalid process fields")
            else
              (($name | is_codex_executable) or
               ($argv0 | is_codex_executable) or
               (($raw_args[0] // null) | is_codex_executable)) as $is_codex |
              if $is_codex then
                if $raw_args == null then error("Codex argv unavailable")
                else {is_codex: true, dirs: argv_add_dirs($raw_args)}
                end
              else {is_codex: false, dirs: []}
              end
            end
          end
        ] as $records |
        if ([$records[] | select(.is_codex)] | length) == 1 then
          [$records[] | select(.is_codex) | .dirs[]] as $dirs |
          if ($dirs | length) == 0 then "" else $dirs[] end
        else error("expected exactly one Codex process")
        end
      end
    ' 2>/dev/null
    return
  fi

  command -v python3 >/dev/null 2>&1 || return 127
  printf '%s\n' "$payload" | python3 -c '
import json
import re
import sys

try:
    processes = json.load(sys.stdin)["result"]["process_info"]["foreground_processes"]
    if not isinstance(processes, list):
        raise TypeError

    def is_codex_executable(value):
        if not isinstance(value, str):
            return False
        basename = re.split(r"[/\\\\]", value)[-1].lower()
        if basename.endswith(".exe"):
            basename = basename[:-4]
        return basename == "codex"

    codex_count = 0
    results = []
    for process in processes:
        if not isinstance(process, dict):
            raise TypeError
        name = process.get("name")
        if not isinstance(name, str):
            raise TypeError
        pid = process.get("pid")
        if (isinstance(pid, bool) or not isinstance(pid, (int, float)) or
                int(pid) != pid or pid < 0 or pid > 4294967295):
            raise TypeError
        argv0 = process.get("argv0")
        if argv0 is not None and not isinstance(argv0, str):
            raise TypeError
        argv = process.get("argv")
        if argv is not None and (not isinstance(argv, list) or
                                 not all(isinstance(item, str) for item in argv)):
            raise TypeError
        cmdline = process.get("cmdline", "")
        if cmdline is None:
            cmdline = ""
        if not isinstance(cmdline, str):
            raise TypeError
        executable_names = [name, argv0, argv[0] if argv else None]
        if not any(is_codex_executable(value) for value in executable_names):
            continue
        codex_count += 1
        if argv is None:
            raise TypeError
        options = argv[:argv.index("--")] if "--" in argv else argv
        index = 0
        while index < len(options):
            arg = options[index]
            if arg == "--add-dir":
                if index + 1 >= len(options):
                    raise TypeError
                value = options[index + 1]
                if not value.startswith("/") or any(ord(char) < 32 or 127 <= ord(char) <= 159 for char in value):
                    raise TypeError
                results.append(value)
                index += 2
                continue
            if arg.startswith("--add-dir="):
                value = arg[len("--add-dir="):]
                if not value.startswith("/") or any(ord(char) < 32 or 127 <= ord(char) <= 159 for char in value):
                    raise TypeError
                results.append(value)
            index += 1
    if codex_count != 1:
        raise TypeError
    for value in results:
        print(value)
except (KeyError, TypeError, ValueError):
    sys.exit(2)
' 2>/dev/null
}

# Managed teams neutralize profile/base-config writable_roots before adding the
# run-specific roots. Require that exact structured argv marker so collision
# checks do not silently miss implicit writable roots.
json_process_has_managed_scope() {
  local payload=$1
  local expected_sandbox=$2
  local marker='sandbox_workspace_write.writable_roots=[]'

  if command -v jq >/dev/null 2>&1; then
    printf '%s\n' "$payload" | jq -se --arg marker "$marker" --arg sandbox "$expected_sandbox" '
      def is_codex_executable:
        type == "string" and
        ((gsub("\\\\"; "/") | split("/")[-1] | ascii_downcase | sub("[.]exe$"; "")) == "codex");
      def option_args($args):
        ([range(0; ($args | length)) as $index |
          select($args[$index] == "--") | $index][0] // ($args | length)) as $stop |
        $args[0:$stop];
      def config_values($args):
        ([range(0; ($args | length) - 1) as $index |
          select($args[$index] == "-c" or $args[$index] == "--config") |
          $args[$index + 1]] +
         [$args[] |
          select(startswith("-c=") or startswith("--config=")) |
          sub("^(?:-c|--config)="; "")]);
      def sandbox_values($args):
        ([range(0; ($args | length) - 1) as $index |
          select($args[$index] == "-s" or $args[$index] == "--sandbox") |
          $args[$index + 1]] +
         [$args[] |
          select(startswith("-s=") or startswith("--sandbox=")) |
          sub("^(?:-s|--sandbox)="; "")]);
      def has_dangling_value_option($args):
        (($args | length) > 0 and
         ($args[-1] == "-c" or $args[-1] == "--config" or
          $args[-1] == "-s" or $args[-1] == "--sandbox"));

      if length != 1 then error("expected one JSON document") else .[0] end |
      .result.process_info.foreground_processes as $processes |
      if ($processes | type) != "array" then error("expected process array")
      else
        [$processes[] |
          if type != "object" then error("expected process object")
          else
            .argv as $raw_args |
            .argv0 as $argv0 |
            .name as $name |
            .pid as $pid |
            (if $raw_args == null then [] else option_args($raw_args) end) as $args |
            if (($pid | type) != "number" or ($pid | floor) != $pid or
                $pid < 0 or $pid > 4294967295 or
                ($name | type) != "string" or
                ($argv0 != null and ($argv0 | type) != "string") or
                ($raw_args != null and ($raw_args | type) != "array") or
                any($args[]; type != "string") or
                has_dangling_value_option($args))
            then error("invalid managed-scope process fields")
            else
              (($name | is_codex_executable) or
               ($argv0 | is_codex_executable) or
               (($args[0] // null) | is_codex_executable)) as $is_codex |
              if ($is_codex and $raw_args == null) then error("Codex argv unavailable")
              else
              config_values($args) as $configs |
              sandbox_values($args) as $sandboxes |
              {is_codex: $is_codex,
               configs: $configs,
               sandboxes: $sandboxes,
               cd_override: any($args[];
                 startswith("-C") or . == "--cd" or startswith("--cd=")),
               remote_override: any($args[];
                 . == "--remote" or startswith("--remote=")),
               bypass: any($args[];
                 . == "--dangerously-bypass-approvals-and-sandbox" or
                 . == "--dangerously-bypass-hook-trust" or
                 . == "--yolo" or . == "--approve-for-me" or . == "--full-auto")}
              end
            end
          end
        ] as $records |
        any($records[]; .is_codex) and
        all($records[]; (.is_codex | not) or
          (.configs == [$marker] and
           .sandboxes == [$sandbox] and
           (.cd_override | not) and
           (.remote_override | not) and
           (.bypass | not)))
      end
    ' >/dev/null 2>&1
    return
  fi

  command -v python3 >/dev/null 2>&1 || return 127
  printf '%s\n' "$payload" | python3 -c '
import json
import re
import sys

try:
    processes = json.load(sys.stdin)["result"]["process_info"]["foreground_processes"]
    if not isinstance(processes, list):
        raise TypeError
    marker = sys.argv[1]
    expected_sandbox = sys.argv[2]
    codex_found = False

    def is_codex_executable(value):
        if not isinstance(value, str):
            return False
        basename = re.split(r"[/\\\\]", value)[-1].lower()
        if basename.endswith(".exe"):
            basename = basename[:-4]
        return basename == "codex"

    for process in processes:
        if not isinstance(process, dict):
            raise TypeError
        name = process.get("name")
        pid = process.get("pid")
        argv0 = process.get("argv0")
        argv = process.get("argv")
        if (not isinstance(name, str) or isinstance(pid, bool) or
                not isinstance(pid, (int, float)) or int(pid) != pid or
                pid < 0 or pid > 4294967295 or
                (argv0 is not None and not isinstance(argv0, str)) or
                (argv is not None and (not isinstance(argv, list) or
                                       not all(isinstance(item, str) for item in argv)))):
            raise TypeError
        raw_args = argv if argv is not None else []
        args = raw_args[:raw_args.index("--")] if "--" in raw_args else raw_args
        if not any(is_codex_executable(value)
                   for value in (name, argv0, raw_args[0] if raw_args else None)):
            continue
        codex_found = True
        if argv is None:
            raise TypeError
        configs = []
        sandboxes = []
        bypass = False
        cd_override = False
        remote_override = False
        index = 0
        while index < len(args):
            arg = args[index]
            if arg in ("-c", "--config"):
                if index + 1 >= len(args):
                    raise TypeError
                configs.append(args[index + 1])
                index += 2
                continue
            if arg.startswith("-c="):
                configs.append(arg[len("-c="):])
            elif arg.startswith("--config="):
                configs.append(arg[len("--config="):])
            if arg in ("-s", "--sandbox"):
                if index + 1 >= len(args):
                    raise TypeError
                sandboxes.append(args[index + 1])
                index += 2
                continue
            if arg.startswith("-s="):
                sandboxes.append(arg[len("-s="):])
            elif arg.startswith("--sandbox="):
                sandboxes.append(arg[len("--sandbox="):])
            if arg in ("--dangerously-bypass-approvals-and-sandbox",
                       "--dangerously-bypass-hook-trust", "--yolo",
                       "--approve-for-me", "--full-auto"):
                bypass = True
            if arg.startswith("-C") or arg == "--cd" or arg.startswith("--cd="):
                cd_override = True
            if arg == "--remote" or arg.startswith("--remote="):
                remote_override = True
            index += 1
        if (configs != [marker] or sandboxes != [expected_sandbox] or
                cd_override or remote_override or bypass):
            sys.exit(1)
    sys.exit(0 if codex_found else 1)
except (KeyError, TypeError, ValueError):
    sys.exit(2)
' "$marker" "$expected_sandbox" >/dev/null 2>&1
}
