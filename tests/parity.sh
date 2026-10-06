#!/usr/bin/env bash
# Runs tests/scenarios.py against the Python server and the Dart server (both
# modes), then checks the two servers' CSV exports are identical apart from
# timestamps and random record ids.
#
#   PYTHON=python3 DART="dart" tests/parity.sh
#
# PYTHON must have the app's requirements installed; DART is the Flutter SDK's
# dart (run from flutter_app/).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PYTHON="${PYTHON:-python3}"
DART="${DART:-dart}"
PORT="${PORT:-8765}"
WORK="$(mktemp -d)"
fail=0

wait_up() {
  for _ in $(seq 240); do
    curl -s -o /dev/null "http://127.0.0.1:$PORT/" && return 0
    sleep 0.25
  done
  echo "server did not start"; return 1
}

# Single run per server+mode, keeping the exit code.
scenario() {   # scenario <label> <mode> <export dir> <server command...>
  local label=$1 mode=$2 dir=$3; shift 3
  "$@" > "$WORK/$label-$mode.log" 2>&1 &
  local pid=$!
  if ! wait_up; then fail=1; cat "$WORK/$label-$mode.log"; return; fi
  echo "== $label / $mode"
  if ! "$PYTHON" "$ROOT/tests/scenarios.py" --base "http://127.0.0.1:$PORT" --mode "$mode" \
      > "$WORK/$label-$mode.out"; then
    fail=1
  fi
  grep -E "^FAIL|^FAILURES" "$WORK/$label-$mode.out"
  kill -INT $pid 2>/dev/null; wait $pid 2>/dev/null
  sleep 0.5
}

scenario python password "$WORK/py" \
  "$PYTHON" "$ROOT/tests/serve_python.py" --port "$PORT" --export-dir "$WORK/py"
scenario python nopassword "$WORK/py-np" \
  "$PYTHON" "$ROOT/tests/serve_python.py" --port "$PORT" --no-password --export-dir "$WORK/py-np"
scenario dart password "$WORK/dart" \
  bash -c "cd '$ROOT/flutter_app' && exec '$DART' run bin/serve.dart --port $PORT --static-dir '$ROOT/static' --export-dir '$WORK/dart'"
scenario dart nopassword "$WORK/dart-np" \
  bash -c "cd '$ROOT/flutter_app' && exec '$DART' run bin/serve.dart --port $PORT --no-password --static-dir '$ROOT/static' --export-dir '$WORK/dart-np'"

echo "== CSV parity (Python vs Dart)"
if ! "$PYTHON" - "$WORK/py" "$WORK/dart" <<'EOF'
import csv, glob, sys
VOLATILE = {"Time", "Submitted_At", "Last_Updated", "Record"}
bad = 0
for kind in ("Raw", "Final", "Audited"):
    def load(d):
        files = sorted(glob.glob(f"{d}/*_{kind}.csv"))
        if not files:
            return None
        with open(files[-1], encoding="utf-8-sig", newline="") as f:
            rows = list(csv.DictReader(f))
        return [{k: v for k, v in r.items() if k not in VOLATILE} for r in rows]
    py, da = load(sys.argv[1]), load(sys.argv[2])
    if py is None or da is None:
        print(f"FAIL {kind}: missing export (python={py is not None}, dart={da is not None})"); bad += 1
    elif py != da:
        bad += 1
        print(f"FAIL {kind}: exports differ")
        for i, (a, b) in enumerate(zip(py, da)):
            if a != b:
                print("  row", i, {k: (a.get(k), b.get(k)) for k in a if a.get(k) != b.get(k)})
        if len(py) != len(da):
            print(f"  python {len(py)} rows, dart {len(da)} rows")
    else:
        print(f"OK   {kind}: {len(py)} rows identical")
sys.exit(1 if bad else 0)
EOF
then fail=1; fi

rm -rf "$WORK"
[ $fail -eq 0 ] && echo "PARITY OK" || echo "PARITY FAILED"
exit $fail
