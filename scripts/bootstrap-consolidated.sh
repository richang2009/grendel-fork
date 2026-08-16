#!/usr/bin/env bash
set -euo pipefail

# Build a complete working tree from upstream Grendel and apply the embedded
# gotgt iSCSI integration. This is the local fallback for environments where
# GitHub Actions is disabled.

ROOT=${1:-grendel-worktree}
UPSTREAM=${UPSTREAM:-https://github.com/ubccr/grendel.git}
GOTGT=${GOTGT:-https://github.com/gostor/gotgt.git}
GOTGT_COMMIT=${GOTGT_COMMIT:-7f708d0cf94501c169846651ecf14812356eb96f}

rm -rf "$ROOT"
git clone "$UPSTREAM" "$ROOT"
cd "$ROOT"
mkdir -p third_party

git clone "$GOTGT" third_party/gotgt
git -C third_party/gotgt checkout "$GOTGT_COMMIT"

python3 - <<'PY'
from pathlib import Path
p = Path('third_party/gotgt/pkg/port/iscsit/iscsid.go')
s = p.read_text()
s = s.replace('''var (\n\tEnableStats   bool\n\tCurrentHostIP string\n\tIPMutex       sync.Mutex\n)''', '''var EnableStats bool''')
s = s.replace('''\tclusterIP              string\n\tblockMultipleHostLogin bool\n}''', '''\tclusterIP              string\n\tblockMultipleHostLogin bool\n\tcurrentHostIP          string\n}''')
s = s.replace('''\t\tlog.Error(err)\n\t\tos.Exit(1)''', '''\t\tlog.Error(err)\n\t\treturn fmt.Errorf("failed to listen on iSCSI port %d: %w", port, err)''')
s = s.replace('''\t\tremoteIP := strings.Split(conn.RemoteAddr().String(), ":")[0]\n\n\t\tIPMutex.Lock()\n\t\tif CurrentHostIP == "" {\n\t\t\tCurrentHostIP = remoteIP\n\t\t}\n\t\tIPMutex.Unlock()\n\n\t\tif s.blockMultipleHostLogin && remoteIP != CurrentHostIP {''', '''\t\tremoteIP, _, splitErr := net.SplitHostPort(conn.RemoteAddr().String())\n\t\tif splitErr != nil {\n\t\t\t_ = conn.Close()\n\t\t\tcontinue\n\t\t}\n\n\t\tif s.blockMultipleHostLogin && s.currentHostIP == "" {\n\t\t\ts.currentHostIP = remoteIP\n\t\t}\n\n\t\tif s.blockMultipleHostLogin && remoteIP != s.currentHostIP {''')
s = s.replace('remoteIP, CurrentHostIP)', 'remoteIP, s.currentHostIP)')
s = s.replace('''\tIPMutex.Lock()\n\tdefer IPMutex.Unlock()\n\taddr := conn.conn.RemoteAddr()\n\tif addr == nil {\n\t\treturn\n\t}\n\tremoteIP := strings.Split(addr.String(), ":")[0]\n\tif CurrentHostIP == remoteIP {\n\t\tCurrentHostIP = ""\n\t}''', '''\taddr := conn.conn.RemoteAddr()\n\tif addr == nil {\n\t\treturn\n\t}\n\tremoteIP, _, err := net.SplitHostPort(addr.String())\n\tif err != nil {\n\t\treturn\n\t}\n\tif s.currentHostIP == remoteIP {\n\t\ts.currentHostIP = ""\n\t}''')
p.write_text(s)
PY

cat >> go.mod <<'EOF'

replace github.com/gostor/gotgt => ./third_party/gotgt
EOF

mkdir -p internal/iscsi
cat > internal/iscsi/server.go <<'EOF'
// SPDX-License-Identifier: GPL-3.0-or-later
package iscsi

import (
    "context"
    "fmt"
    "net"
    "os"
    "path/filepath"
    "sync"

    "github.com/gostor/gotgt/pkg/config"
    _ "github.com/gostor/gotgt/pkg/port/iscsit"
    "github.com/gostor/gotgt/pkg/scsi"
)

type Config struct { ListenIP string; Port int; Target string; Image string }

type Server struct { cfg Config; driver scsi.SCSITargetDriver; closeOnce sync.Once }

func New(cfg Config) (*Server, error) {
    if net.ParseIP(cfg.ListenIP) == nil && cfg.ListenIP != "0.0.0.0" && cfg.ListenIP != "::" { return nil, fmt.Errorf("invalid iSCSI listen address %q", cfg.ListenIP) }
    if cfg.Port < 1 || cfg.Port > 65535 { return nil, fmt.Errorf("invalid iSCSI port %d", cfg.Port) }
    if cfg.Target == "" { return nil, fmt.Errorf("iSCSI target is required") }
    if cfg.Image == "" { return nil, fmt.Errorf("iSCSI backing image is required") }
    st, err := os.Stat(cfg.Image); if err != nil { return nil, fmt.Errorf("stat backing image: %w", err) }
    if !st.Mode().IsRegular() { return nil, fmt.Errorf("backing image is not a regular file") }
    gc := &config.Config{
        Storages: []config.BackendStorage{{DeviceID: 1000, Path: "file:" + filepath.Clean(cfg.Image), Online: true, BlockShift: 9}},
        ISCSIPortals: []config.ISCSIPortalInfo{{ID: 0, Portal: net.JoinHostPort(cfg.ListenIP, fmt.Sprint(cfg.Port))}},
        ISCSITargets: map[string]config.ISCSITarget{cfg.Target: {TPGTs: map[string][]uint64{"1": {0}}, LUNs: map[string]uint64{"0": 1000}}},
    }
    if err := scsi.InitSCSILUMap(gc); err != nil { return nil, fmt.Errorf("initialize gotgt LUN: %w", err) }
    svc := scsi.NewSCSITargetService()
    drv, err := scsi.NewTargetDriver("iscsi", svc); if err != nil { return nil, fmt.Errorf("create iSCSI driver: %w", err) }
    if err := drv.NewTarget(cfg.Target, gc); err != nil { return nil, fmt.Errorf("create iSCSI target: %w", err) }
    drv.SetClusterIP(cfg.ListenIP)
    return &Server{cfg: cfg, driver: drv}, nil
}

func (s *Server) Run(ctx context.Context) error {
    errc := make(chan error, 1); go func() { errc <- s.driver.Run(s.cfg.Port) }()
    select { case <-ctx.Done(): _ = s.Close(); return ctx.Err(); case err := <-errc: return err }
}
func (s *Server) Close() error { var err error; s.closeOnce.Do(func(){ err=s.driver.Close() }); return err }
EOF

cat > cmd/iscsi.go <<'EOF'
// SPDX-License-Identifier: GPL-3.0-or-later
package cmd

import (
    "context"
    "flag"
    "os"
    "os/signal"
    "syscall"
    "github.com/ubccr/grendel/internal/iscsi"
)

func ServeISCSI(args []string) error {
    fs := flag.NewFlagSet("serve-iscsi", flag.ContinueOnError)
    listen := fs.String("iscsi-listen", "0.0.0.0", "iSCSI listen address")
    port := fs.Int("iscsi-port", 3260, "iSCSI TCP port")
    target := fs.String("iscsi-target", "iqn.2026-08.grendel:node001", "iSCSI target IQN")
    image := fs.String("iscsi-image", "/var/lib/grendel-iscsi/node001.img", "iSCSI backing image")
    if err := fs.Parse(args); err != nil { return err }
    srv, err := iscsi.New(iscsi.Config{ListenIP:*listen, Port:*port, Target:*target, Image:*image}); if err != nil { return err }
    ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM); defer cancel()
    if err := srv.Run(ctx); err != nil && err != context.Canceled { return err }; return nil
}
EOF

python3 - <<'PY'
from pathlib import Path
p=Path('main.go'); s=p.read_text()
if '"os"' not in s: s=s.replace('import (', 'import (\n\t"os"')
old='func main() {\n\tcmd.Execute()\n}'
new='func main() {\n\tfor _, a := range os.Args[1:] {\n\t\tif a == "--serve-iscsi" {\n\t\t\tif err := cmd.ServeISCSI(os.Args[1:]); err != nil { cmd.Log.Fatal(err) }\n\t\t\treturn\n\t\t}\n\t}\n\tcmd.Execute()\n}'
if old not in s: raise SystemExit('unexpected main.go')
p.write_text(s.replace(old,new))
PY

gofmt -w cmd/iscsi.go internal/iscsi/server.go main.go third_party/gotgt/pkg/port/iscsit/iscsid.go
go mod tidy

echo "Prepared $ROOT"
echo "Build with: cd $ROOT && go test ./... && go build -o grendel ./"
