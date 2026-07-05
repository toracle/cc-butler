#!/usr/bin/env sh
# cc-butler-statusline.sh --- context-size reporter for the cc-butler cleaner
#
# Claude Code invokes a custom `statusLine` command with a JSON blob on stdin
# describing the session, including a `context_window` object.  This helper
# parses it and prints ONE line that is both human-readable AND machine-
# readable: a marker `CTX:<total_input_tokens>` that cc-butler's cleaner scrapes
# from the session terminal (see `cc-butler-cleanup-context-function'), followed
# by a short percentage / over-200k hint.
#
# It is intentionally generic and site-agnostic — it ships with the open-source
# core and hard-codes no policy (the 200k threshold lives in Emacs).  Wire it as
# your statusLine, e.g. in .claude/settings.json:
#
#   { "statusLine": { "type": "command",
#                     "command": "/abs/path/to/cc-butler-statusline.sh",
#                     "refreshInterval": 2 } }
#
# `cc-butler-cleanup-install-statusline' writes exactly this for a new worker.

input=$(cat)

if command -v python3 >/dev/null 2>&1; then
  printf '%s' "$input" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print("CTX:?"); sys.exit(0)
cw = d.get("context_window") or {}
tot = cw.get("total_input_tokens")
if tot is None:
    cu = cw.get("current_usage") or {}
    tot = sum(v for v in (cu.get("input_tokens"),
                          cu.get("cache_creation_input_tokens"),
                          cu.get("cache_read_input_tokens"))
              if isinstance(v, (int, float)))
pct = cw.get("used_percentage")
over = d.get("exceeds_200k_tokens")
mark = ("CTX:%d" % int(tot)) if isinstance(tot, (int, float)) else "CTX:?"
extra = ""
if isinstance(pct, (int, float)):
    extra += " %d%%" % int(pct)
if over:
    extra += " >200k"
print(mark + extra)
'
elif command -v jq >/dev/null 2>&1; then
  printf '%s' "$input" | jq -r '
    "CTX:\(.context_window.total_input_tokens // 0)"
    + (if .context_window.used_percentage
         then " \(.context_window.used_percentage | floor)%" else "" end)
    + (if .exceeds_200k_tokens then " >200k" else "" end)'
else
  printf 'CTX:?\n'
fi
