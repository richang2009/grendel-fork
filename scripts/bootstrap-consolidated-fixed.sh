#!/usr/bin/env bash
set -euo pipefail

# Canonical reproducible bootstrap for the Grendel + embedded gotgt POC.
# It delegates to the existing consolidated bootstrap, then applies a second
# validation/repair pass so no stale gotgt global-IP state can survive.
ROOT=${1:-grendel-worktree}
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

"$SCRIPT_DIR/bootstrap-consolidated.sh" "$ROOT"
"$SCRIPT_DIR/repair-gotgt.sh" "$ROOT"

cd "$ROOT"
go mod tidy

echo
echo "Bootstrap complete: $ROOT"
echo "Verify:"
echo "  cd $ROOT/third_party/gotgt && go test ./..."
echo "  cd $ROOT && go test ./..."
echo "  cd $ROOT && go build -o grendel ."
