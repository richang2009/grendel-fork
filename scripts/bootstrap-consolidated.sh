#!/usr/bin/env bash
set -euo pipefail

# Build a complete working tree from upstream Grendel and apply the embedded
# gotgt iSCSI integration plus deterministic DNS tests. This is the local
# fallback for environments where GitHub Actions is disabled.

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

# Replace the upstream Internet-dependent DNS test with a deterministic local upstream.
cat > internal/dns/server_test.go <<'EOF'
package dns

import (
    "context"
    "errors"
    "net"
    "net/netip"
    "strings"
    "testing"
    "time"

    "github.com/miekg/dns"
    "github.com/spf13/viper"
    "github.com/stretchr/testify/assert"
    "github.com/ubccr/grendel/internal/store/sqlstore"
    "github.com/ubccr/grendel/pkg/model"
)

var (
    serverAddr = "127.0.0.1:8053"
    clientFQDN = "test-01.example.local"
    clientIP   = netip.MustParsePrefix("10.1.0.1/24")
)

func newDNS() (*Server, error) {
    store, err := sqlstore.New(":memory:")
    if err != nil { return nil, err }
    store.StoreHost(&model.Host{Name: "test-01", Interfaces: []*model.NetInterface{{FQDN: clientFQDN, IP: clientIP}}})
    return NewServer(store, serverAddr, 5)
}

func TestDns(t *testing.T) {
    assert := assert.New(t)
    s, err := newDNS()
    if err != nil { t.Fatal(err) }

    // The test must not depend on public DNS, corporate firewall rules, VPNs,
    // or Internet access. Start a local deterministic upstream resolver.
    upstreamConn, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.ParseIP("127.0.0.1"), Port: 0})
    if err != nil { t.Fatal(err) }
    defer upstreamConn.Close()

    upstream := &dns.Server{PacketConn: upstreamConn, Handler: dns.HandlerFunc(func(w dns.ResponseWriter, r *dns.Msg) {
        reply := new(dns.Msg)
        reply.SetReply(r)
        if len(r.Question) > 0 && strings.EqualFold(r.Question[0].Name, "grendel-demo.ccr.buffalo.edu.") && r.Question[0].Qtype == dns.TypeA {
            reply.Answer = append(reply.Answer, &dns.A{Hdr: dns.RR_Header{Name: "grendel-demo.ccr.buffalo.edu.", Rrtype: dns.TypeA, Class: dns.ClassINET, Ttl: 21600}, A: net.ParseIP("128.205.11.109")})
        }
        _ = w.WriteMsg(reply)
    })}
    go func() { _ = upstream.Serve() }()
    t.Cleanup(func() { _ = upstream.Shutdown() })

    viper.Set("dns.forward", upstreamConn.LocalAddr().String())
    t.Cleanup(func() { viper.Reset() })

    // Start Grendel DNS. Keep the existing port for compatibility with the
    // server implementation, but wait for readiness instead of sleeping.
    probeAddr, _ := net.ResolveUDPAddr("udp", serverAddr)
    probe, err := net.ListenUDP("udp", probeAddr)
    if err == nil {
        _ = probe.Close()
        go func() {
            err := s.Serve()
            assert.NoError(err)
        }()
    } else {
        t.Fatal(err)
    }
    t.Cleanup(func() { _ = s.Shutdown(context.Background()) })

    exchange := func(m *dns.Msg) *dns.Msg {
        t.Helper()
        var r *dns.Msg
        var err error
        for i := 0; i < 30; i++ {
            r, err = dns.Exchange(m, serverAddr)
            if err == nil { return r }
            time.Sleep(20 * time.Millisecond)
        }
        t.Fatalf("DNS server did not become ready: %v", err)
        return nil
    }

    m1 := new(dns.Msg)
    m1.SetQuestion(clientFQDN+".", dns.TypeA)
    r1 := exchange(m1)
    assert.True(r1.Response)
    if len(r1.Answer) == 0 { t.Fatal(errors.New("r1 response is empty")) }
    assert.Equal(clientFQDN+".\t5\tIN\tA\t10.1.0.1", r1.Answer[0].String())

    m2 := new(dns.Msg)
    m2.SetQuestion("1.0.1.10.in-addr.arpa.", dns.TypePTR)
    r2 := exchange(m2)
    assert.True(r2.Response)
    if len(r2.Answer) == 0 { t.Fatal(errors.New("r2 response is empty")) }
    assert.Equal("1.0.1.10.in-addr.arpa.\t5\tIN\tPTR\ttest-01.example.local.", r2.Answer[0].String())

    m3 := new(dns.Msg)
    m3.SetQuestion("miekl.nl.", dns.TypeMX)
    r3 := exchange(m3)
    assert.True(r3.Response)
    assert.Len(r3.Answer, 0)

    // Local records must still win when forwarding is configured.
    m4 := new(dns.Msg)
    m4.SetQuestion(clientFQDN+".", dns.TypeA)
    r4 := exchange(m4)
    assert.True(r4.Response)
    if len(r4.Answer) == 0 { t.Fatal(errors.New("r4 response is empty")) }
    assert.Equal(clientFQDN+".\t5\tIN\tA\t10.1.0.1", r4.Answer[0].String())

    // Forwarded lookup is answered by the local fake upstream, not the Internet.
    m5 := new(dns.Msg)
    m5.SetQuestion("grendel-demo.ccr.buffalo.edu.", dns.TypeA)
    r5 := exchange(m5)
    assert.True(r5.Response)
    if len(r5.Answer) == 0 { t.Fatal(errors.New("r5 response is empty")) }
    p5 := strings.Split(r5.Answer[0].String(), "\t")
    if len(p5) != 5 { t.Fatal(errors.New("p5 response length is incorrect")) }
    assert.Equal("grendel-demo.ccr.buffalo.edu.", p5[0])
    assert.Equal("IN", p5[2])
    assert.Equal("A", p5[3])
    assert.Equal("128.205.11.109", p5[4])
}
EOF

gofmt -w cmd/iscsi.go internal/iscsi/server.go internal/dns/server_test.go main.go third_party/gotgt/pkg/port/iscsit/iscsid.go
go mod tidy

echo "Prepared $ROOT"
echo "Build with: cd $ROOT && go test ./... && go build -o grendel ./"
