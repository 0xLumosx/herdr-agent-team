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
        elif (($value | type) == "string" or ($value | type) == "number") then ($value | tostring)
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
    elif isinstance(value, (str, int, float)):
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
        if (($value | type) == "string" and ($value | length) > 0) then $value
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
    if not isinstance(value, str) or not value:
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
        elif ($value | type) == "string" then $value
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
    elif isinstance(value, str):
        print(value)
    else:
        raise TypeError
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
        if type == "string" then . else error("expected string") end
      ' 2>/dev/null
    return
  fi

  command -v python3 >/dev/null 2>&1 || return 127
  printf '%s\n' "$payload" | python3 -c '
import json
import sys

try:
    value = json.load(sys.stdin)["result"][sys.argv[1]][sys.argv[2]]
    if not isinstance(value, str):
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
      elif (.name | type) == "string" then .name
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
        if not isinstance(name, str):
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
      def argv_profiles($args):
        [range(0; ($args | length) - 1) as $index |
          select($args[$index] == "--profile") |
          $args[$index + 1]];
      def cmdline_profiles($cmdline):
        [$cmdline |
          scan("(?:^|[[:space:]])--profile[[:space:]]+([^[:space:]]+)")[0]];

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
              (argv_profiles($args) + cmdline_profiles($cmdline)) as $profiles |
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
    pattern = re.compile(r"(^|\s)--profile\s+" + re.escape(role) + r"(\s|$)")
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
        argv = process.get("argv", [])
        if argv is None:
            argv = []
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
        profiles = [
            argv[index + 1]
            for index in range(len(argv) - 1)
            if argv[index] == "--profile"
        ]
        profiles.extend(match.group(1) for match in profile_pattern.finditer(cmdline))
        if not profiles:
            sys.exit(1)
        if any(profile != role for profile in profiles):
            sys.exit(1)
        if role in profiles or pattern.search(cmdline):
            expected_found = True
    sys.exit(0 if expected_found else 1)
except (KeyError, TypeError, ValueError):
    sys.exit(2)
' "$role" >/dev/null 2>&1
}
