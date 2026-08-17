#!/usr/bin/env bash
set -euo pipefail

# Repair/harden the vendored gotgt source in an already-generated Grendel tree.
# Usage: ./scripts/repair-gotgt.sh /path/to/grendel-build
ROOT=${1:?usage: $0 /path/to/grendel-build}
FILE="$ROOT/third_party/gotgt/pkg/port/iscsit/iscsid.go"

[[ -f "$FILE" ]] || { echo "ERROR: gotgt source not found: $FILE" >&2; exit 1; }

python3 - "$FILE" <<'PY'
from pathlib import Path
import re
import sys

p = Path(sys.argv[1])
s = p.read_text()

# 1. Remove the process-global host state. The exact upstream formatting has
# changed over time, so match the complete var block rather than individual lines.
s = re.sub(
    r'var\s*\(\s*EnableStats\s+bool\s+CurrentHostIP\s+string\s+IPMutex\s+sync\.Mutex\s*\)',
    'var EnableStats bool', s, count=1, flags=re.S)

# 2. Add per-driver host state.
if not re.search(r'\bcurrentHostIP\s+string\b', s):
    marker = '\tblockMultipleHostLogin bool'
    if marker not in s:
        raise SystemExit('ERROR: cannot find ISCSITargetDriver state marker')
    s = s.replace(marker, marker + '\n\tcurrentHostIP          string', 1)

# 3. Replace the entire Run method. This removes all legacy CurrentHostIP /
#    IPMutex bookkeeping and also removes the fatal os.Exit() behavior.
run_re = re.compile(
    r'func \(s \*ISCSITargetDriver\) Run\(port int\) error \{.*?\n\}\n\nfunc \(s \*ISCSITargetDriver\) setClientStatus',
    re.S)
run_new = '''func (s *ISCSITargetDriver) Run(port int) error {
\tl, err := net.Listen("tcp", ":"+strconv.Itoa(port))
\tif err != nil {
\t\tlog.Error(err)
\t\treturn fmt.Errorf("listen on iSCSI port %d: %w", port, err)
\t}

\ts.mu.Lock()
\ts.l = l
\ts.mu.Unlock()
\tlog.Infof("iSCSI service listening on: %v", s.l.Addr())

\ts.setState(STATE_RUNNING)
\tfor {
\t\tconn, err := l.Accept()
\t\tif err != nil {
\t\t\tif err, ok := err.(net.Error); ok && !err.Temporary() {
\t\t\t\tlog.Warning("Closing connection with initiator...")
\t\t\t\tbreak
\t\t\t}
\t\t\tlog.Error(err)
\t\t\tcontinue
\t\t}

\t\tremoteIP, _, splitErr := net.SplitHostPort(conn.RemoteAddr().String())
\t\tif splitErr != nil {
\t\t\t_ = conn.Close()
\t\t\tlog.Warningf("rejecting connection with invalid remote address %q: %v", conn.RemoteAddr(), splitErr)
\t\t\tcontinue
\t\t}

\t\tif s.blockMultipleHostLogin {
\t\t\ts.mu.Lock()
\t\t\tif s.currentHostIP == "" {
\t\t\t\ts.currentHostIP = remoteIP
\t\t\t}
\t\t\tallowedIP := s.currentHostIP
\t\t\ts.mu.Unlock()
\n\t\t\tif remoteIP != allowedIP {
\t\t\t\t_ = conn.Close()
\t\t\t\tlog.Infof("rejecting connection: %s target already connected at %s", remoteIP, allowedIP)
\t\t\t\tcontinue
\t\t\t}
\t\t}

\t\tlog.Info("connection establishing at: ", conn.LocalAddr().String())
\t\ts.setClientStatus(true)

\t\tiscsiConn := &iscsiConnection{conn: conn, loginParam: &iscsiLoginParam{}}
\t\tiscsiConn.init()
\t\tiscsiConn.rxIOState = IOSTATE_RX_BHS
\t\tlog.Infof("Target is connected to initiator: %s", conn.RemoteAddr().String())
\t\tgo s.handler(DATAIN, iscsiConn)
\t}
\treturn nil
}

func (s *ISCSITargetDriver) setClientStatus'''
if not run_re.search(s):
    raise SystemExit('ERROR: cannot locate ISCSITargetDriver.Run; gotgt source layout changed')
s = run_re.sub(run_new, s, count=1)

# 4. Replace the complete clearHostIP method. This catches both legacy logout
#    variants and avoids fragile line-oriented matching.
clear_re = re.compile(
    r'func \(s \*ISCSITargetDriver\) clearHostIP\(conn \*iscsiConnection\) \{.*?\n\}\n\nfunc \(s \*ISCSITargetDriver\) rxHandler',
    re.S)
clear_new = '''func (s *ISCSITargetDriver) clearHostIP(conn *iscsiConnection) {
\tif conn.conn == nil {
\t\treturn
\t}

\taddr := conn.conn.RemoteAddr()
\tif addr == nil {
\t\treturn
\t}
\tremoteIP, _, err := net.SplitHostPort(addr.String())
\tif err != nil {
\t\treturn
\t}

\ts.mu.Lock()
\tif s.currentHostIP == remoteIP {
\t\ts.currentHostIP = ""
\t}
\ts.mu.Unlock()
}

func (s *ISCSITargetDriver) rxHandler'''
if not clear_re.search(s):
    raise SystemExit('ERROR: cannot locate clearHostIP; gotgt source layout changed')
s = clear_re.sub(clear_new, s, count=1)

# 5. Remove imports that became unused after replacing the old paths.
s = re.sub(r'^\s*"os"\s*\n', '', s, flags=re.M)
s = re.sub(r'^\s*"strings"\s*\n', '', s, flags=re.M)

# 6. Hard validation: the old symbols must not survive.
if re.search(r'\b(?:CurrentHostIP|IPMutex)\b', s):
    raise SystemExit('ERROR: stale CurrentHostIP/IPMutex references remain after gotgt repair')
if not re.search(r'\bcurrentHostIP\s+string\b', s):
    raise SystemExit('ERROR: currentHostIP state was not installed')

p.write_text(s)
PY

gofmt -w "$FILE"

if grep -nE '\b(CurrentHostIP|IPMutex)\b' "$FILE"; then
    echo 'ERROR: gotgt hardening validation failed' >&2
    exit 1
fi

echo "gotgt hardening applied successfully: $FILE"
