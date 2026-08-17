#!/usr/bin/env bash
set -euo pipefail

# Repair/harden the vendored gotgt source in an already-generated Grendel tree.
# Usage: ./scripts/repair-gotgt.sh /path/to/grendel-build
ROOT=${1:?usage: $0 /path/to/grendel-build}
FILE="$ROOT/third_party/gotgt/pkg/port/iscsit/iscsid.go"

[[ -f "$FILE" ]] || { echo "ERROR: gotgt source not found: $FILE" >&2; exit 1; }

python3 - "$FILE" <<'PY'
from pathlib import Path
import re, sys

p = Path(sys.argv[1])
s = p.read_text()

# Remove stale process-global state if present.
s = re.sub(r'var \(\s*EnableStats\s+bool\s*CurrentHostIP\s+string\s*IPMutex\s+sync\.Mutex\s*\)', 'var EnableStats bool', s, count=1, flags=re.S)
s = re.sub(r'^\s*CurrentHostIP\s+string\s*\n', '', s, flags=re.M)
s = re.sub(r'^\s*IPMutex\s+sync\.Mutex\s*\n', '', s, flags=re.M)

# Ensure per-driver state exists.
if 'currentHostIP' not in s:
    marker = '\tblockMultipleHostLogin bool'
    if marker not in s:
        raise SystemExit('ERROR: cannot find ISCSITargetDriver state marker')
    s = s.replace(marker, marker + '\n\tcurrentHostIP          string', 1)

# Replace every old login bookkeeping block, not just the first occurrence.
old_login = re.compile(r'\s*remoteIP := strings\.Split\(conn\.RemoteAddr\(\)\.String\(\), ":"\)\[0\]\s*\n\s*IPMutex\.Lock\(\)\s*\n\s*if CurrentHostIP == "" \{\s*\n\s*CurrentHostIP = remoteIP\s*\n\s*\}\s*\n\s*IPMutex\.Unlock\(\)\s*\n', re.M)
new_login = '''\n\t\tremoteIP, _, splitErr := net.SplitHostPort(conn.RemoteAddr().String())\n\t\tif splitErr != nil {\n\t\t\t_ = conn.Close()\n\t\t\tcontinue\n\t\t}\n\n\t\tif s.blockMultipleHostLogin && s.currentHostIP == "" {\n\t\t\ts.currentHostIP = remoteIP\n\t\t}\n'''
s, nlogin = old_login.subn(new_login, s)

# Replace any remaining direct global references.
s = s.replace('remoteIP != CurrentHostIP', 'remoteIP != s.currentHostIP')
s = s.replace('remoteIP, CurrentHostIP)', 'remoteIP, s.currentHostIP)')

# Replace all known old logout cleanup variants.
patterns = [
    re.compile(r'\s*IPMutex\.Lock\(\)\s*\n\s*defer IPMutex\.Unlock\(\)\s*\n\s*addr := conn\.conn\.RemoteAddr\(\)\s*\n\s*if addr == nil \{\s*\n\s*return\s*\n\s*\}\s*\n\s*remoteIP := strings\.Split\(addr\.String\(\), ":"\)\[0\]\s*\n\s*if CurrentHostIP == remoteIP \{\s*\n\s*CurrentHostIP = ""\s*\n\s*\}', re.M),
    re.compile(r'\s*IPMutex\.Lock\(\)\s*\n\s*addr := conn\.conn\.RemoteAddr\(\)\s*\n\s*if addr == nil \{\s*\n\s*return\s*\n\s*\}\s*\n\s*remoteIP := strings\.Split\(addr\.String\(\), ":"\)\[0\]\s*\n\s*if CurrentHostIP == remoteIP \{\s*\n\s*CurrentHostIP = ""\s*\n\s*\}\s*\n\s*IPMutex\.Unlock\(\)', re.M),
]
logout = '''\n\taddr := conn.conn.RemoteAddr()\n\tif addr == nil {\n\t\treturn\n\t}\n\tremoteIP, _, err := net.SplitHostPort(addr.String())\n\tif err != nil {\n\t\treturn\n\t}\n\tif s.currentHostIP == remoteIP {\n\t\ts.currentHostIP = ""\n\t}'''
for pat in patterns:
    s, _ = pat.subn(logout, s)

# Remove stale imports left by the replacements.
s = re.sub(r'^\s*"os"\s*\n', '', s, flags=re.M)
s = re.sub(r'^\s*"strings"\s*\n', '', s, flags=re.M)

# The old globals must not survive. Fail instead of silently producing a broken tree.
if re.search(r'\b(?:CurrentHostIP|IPMutex)\b', s):
    raise SystemExit('ERROR: stale CurrentHostIP/IPMutex references remain; gotgt source layout changed')
if 'currentHostIP' not in s:
    raise SystemExit('ERROR: currentHostIP state was not installed')

p.write_text(s)
PY

gofmt -w "$FILE"

if grep -nE '\b(CurrentHostIP|IPMutex)\b' "$FILE"; then
    echo 'ERROR: gotgt hardening validation failed' >&2
    exit 1
fi

echo "gotgt hardening applied successfully: $FILE"
