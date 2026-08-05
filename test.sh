#!/bin/bash
#
# test.sh - behavioural tests for the ai-aligned-xcode shim.
#
# Runs against a throwaway state dir and a throwaway bin dir; never touches the
# user's real ~/.ai-aligned-xcode. Tests that need a real Xcode are skipped when
# it is absent, so this stays useful on a CI box without one.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHIM="$SCRIPT_DIR/executable_ai-aligned-xcode"

TMP="$(mktemp -d -t aax-test)"
trap 'rm -rf "$TMP"' EXIT

export AI_ALIGNED_XCODE_HOME="$TMP/state"
export PATH="$TMP/bin:$PATH"
# Force agent detection on: these tests exercise the managed path.
export CLAUDECODE=1

mkdir -p "$TMP/bin"
install -m 0755 "$SHIM" "$TMP/bin/ai-aligned-xcode"
for t in xcodebuild xcrun swift xcodegen; do ln -sf ai-aligned-xcode "$TMP/bin/$t"; done

DB="$AI_ALIGNED_XCODE_HOME/runs.db"
PASS=0; FAIL=0
GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[1;33m'; NC=$'\033[0m'

ok()   { printf '%s✓%s %s\n' "$GREEN" "$NC" "$1"; PASS=$((PASS+1)); }
no()   { printf '%s✗%s %s\n'   "$RED" "$NC" "$1"; printf '    %s\n' "${2:-}"; FAIL=$((FAIL+1)); }
skip() { printf '%s-%s %s (skipped: %s)\n' "$YELLOW" "$NC" "$1" "$2"; }

has_xcode() { [ -x /usr/bin/xcodebuild ] && /usr/bin/xcodebuild -version >/dev/null 2>&1; }
sql() { /usr/bin/sqlite3 -cmd ".timeout 5000" "$DB" "$1" 2>/dev/null; }

# --------------------------------------------------------------- environment

if [ "$(uname -s)" != "Darwin" ]; then
    skip "all behavioural tests" "not macOS"
    echo "0 passed, 0 failed"; exit 0
fi

python3 -c 'import fcntl' 2>/dev/null && ok "python3 + fcntl present" \
                                      || no "python3 + fcntl present" "required for leases"
[ -x /usr/bin/sqlite3 ] && ok "sqlite3 present"    || no "sqlite3 present"  "required for the predictor"

# --------------------------------------------------------------- lease is CHEAP
#
# THE regression test. macOS lockf(1) busy-waits — with or without -t — so the
# original lease implementation burned a full core per waiter and took a real
# machine to 0.18% idle with fourteen of them. The suite passed anyway, because
# every test asserted that waiting WORKED and none asserted what it COST.
# A blocking flock should use approximately no CPU while it waits.

LOCKF_SPINS=""
if [ -x /usr/bin/lockf ]; then
    rm -f "$TMP/spin.probe"
    ( exec 9>>"$TMP/spin.probe"; /usr/bin/lockf -s -t 0 9 && sleep 4; exec 9>&- ) &
    sp_holder=$!
    sleep 0.4
    ( exec 8>>"$TMP/spin.probe"; /usr/bin/lockf -s -t 3 8 ) & sp_waiter=$!
    sleep 2
    sp_cpu=$(ps -o time= -p "$(pgrep -x lockf | head -1)" 2>/dev/null | tr -d ' ')
    case "$sp_cpu" in 0:00.0*|"") LOCKF_SPINS=no ;; *) LOCKF_SPINS=yes ;; esac
    wait "$sp_waiter" "$sp_holder" 2>/dev/null
    rm -f "$TMP/spin.probe"
    [ "$LOCKF_SPINS" = "yes" ] \
        && ok "confirmed lockf(1) busy-waits on this OS (so we must not use it)" \
        || skip "lockf spin check" "lockf did not spin here; the flock test below still governs"
fi

# Our own lease: a waiter must block, not spin.
rm -f "$TMP/cheap.lock"
( exec 9>>"$TMP/cheap.lock"
  python3 -c 'import fcntl,sys; fcntl.flock(9, fcntl.LOCK_EX)' && sleep 5
  exec 9>&- ) &
cheap_holder=$!
sleep 0.4
( exec 8>>"$TMP/cheap.lock"
  python3 -c '
import fcntl, signal, sys, os, time
def expire(*_): sys.exit(1)
signal.signal(signal.SIGALRM, expire); signal.setitimer(signal.ITIMER_REAL, 20)
t0 = time.time()
fcntl.flock(8, fcntl.LOCK_EX)
cpu = time.process_time()
print(f"{time.time()-t0:.1f} {cpu:.3f}")
' ) > "$TMP/cheap.out" 2>/dev/null &
cheap_waiter=$!
wait "$cheap_waiter" "$cheap_holder" 2>/dev/null
read -r waited cpu < "$TMP/cheap.out" 2>/dev/null || { waited=0; cpu=99; }
# Waited seconds of wall clock; CPU must stay negligible.
if awk -v w="$waited" -v c="$cpu" 'BEGIN{exit !(w>3 && c<0.5)}' 2>/dev/null; then
    ok "a waiting lease blocks instead of spinning (${waited}s wall, ${cpu}s CPU)"
else
    no "a waiting lease blocks instead of spinning" "waited=${waited}s cpu=${cpu}s — a spin-wait would show cpu≈wall"
fi
rm -f "$TMP/cheap.lock" "$TMP/cheap.out"

# --------------------------------------------------------------- plumbing

out="$(ai-aligned-xcode version 2>&1)"
case "$out" in ai-aligned-xcode\ *) ok "version reports itself" ;;
               *) no "version reports itself" "$out" ;; esac

out="$(ai-aligned-xcode doctor 2>&1)"
case "$out" in *"python3       : ok"*) ok "doctor sees python3 + fcntl" ;;
               *) no "doctor sees python3 + fcntl" "$out" ;; esac

# The pragma-echo regression: any sqlite chatter would corrupt tool output.
if has_xcode; then
    out="$(xcodebuild -version 2>/dev/null)"
    case "$out" in
        *wal*|*5000*) no "informational output stays clean" "$out" ;;
        Xcode*)       ok "informational output stays clean" ;;
        *)            no "informational output stays clean" "$out" ;;
    esac

    # -version must not be rewritten or recorded.
    err="$(xcodebuild -version 2>&1 >/dev/null)"
    [ -z "$err" ] && ok "informational calls emit no notices" \
                  || no "informational calls emit no notices" "$err"
else
    skip "informational passthrough" "no Xcode"
fi

# --------------------------------------------------------------- passthrough

if has_xcode; then
    # Match the notice prefix at line start; the repo's own path contains the
    # string "ai-aligned-xcode" and would otherwise false-positive.
    notices() { grep -c '^ai-aligned-xcode: ' <<<"$1"; }

    err="$(AMI_PASSTHROUGH=true xcodebuild -list 2>&1 >/dev/null)"
    [ "$(notices "$err")" -eq 0 ] && ok "humans get a pass-through" \
                                  || no "humans get a pass-through" "$err"

    err="$(AI_ALIGNED_XCODE_DISABLE=true xcodebuild -list 2>&1 >/dev/null)"
    [ "$(notices "$err")" -eq 0 ] && ok "DISABLE bypasses the shim" \
                                  || no "DISABLE bypasses the shim" "$err"
else
    skip "pass-through tests" "no Xcode"
fi

# --------------------------------------------------------------- derived data

if has_xcode; then
    err="$(xcodebuild -project /nonexistent.xcodeproj -scheme X \
             -destination 'generic/platform=iOS Simulator' build 2>&1 >/dev/null)"
    case "$err" in *"per-worktree DerivedData"*) ok "injects a per-worktree -derivedDataPath" ;;
                   *) no "injects a per-worktree -derivedDataPath" "$err" ;; esac

    err="$(xcodebuild -project /nonexistent.xcodeproj -scheme X -derivedDataPath /tmp/mine \
             -destination 'generic/platform=iOS Simulator' build 2>&1 >/dev/null)"
    case "$err" in *"per-worktree DerivedData"*) no "respects an explicit -derivedDataPath" "$err" ;;
                   *) ok "respects an explicit -derivedDataPath" ;; esac
else
    skip "DerivedData injection" "no Xcode"
fi

# --------------------------------------------------------------- recording

if has_xcode; then
    n="$(sql 'SELECT COUNT(*) FROM runs;')"
    [ "${n:-0}" -gt 0 ] && ok "runs are recorded ($n rows)" \
                        || no "runs are recorded" "table empty or missing"
else
    skip "run recording" "no Xcode"
fi

# --------------------------------------------------------------- the gate

UDID="00000000-1111-2222-3333-444444444444"
GK="$(basename "$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || echo x)")|nonexistent.xcodeproj|xcodebuild|test|Slow|sim"
/usr/bin/sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS runs (id INTEGER PRIMARY KEY, ts INTEGER, agent TEXT, repo TEXT, worktree TEXT, tool TEXT, action TEXT, scheme TEXT, dest_kind TEXT, udid TEXT, gkey TEXT, duration_ms INTEGER, lease_wait_ms INTEGER, exit_code INTEGER, outcome TEXT);" >/dev/null 2>&1
for ms in 400000 500000 600000; do
    sql "INSERT INTO runs(ts,agent,repo,worktree,tool,action,scheme,dest_kind,udid,gkey,duration_ms,lease_wait_ms,exit_code,outcome)
         VALUES ($(date +%s),'claude','x','x','xcodebuild','test','Slow','sim','','$GK',$ms,0,0,'ok');" >/dev/null
done

if has_xcode; then
    ( cd "$SCRIPT_DIR" && xcodebuild -project nonexistent.xcodeproj -scheme Slow \
        -destination "platform=iOS Simulator,id=$UDID" test ) >/dev/null 2>"$TMP/gate.err"
    rc=$?
    if [ "$rc" -eq 78 ] && grep -q "refusing to start an unbudgeted long run" "$TMP/gate.err"; then
        ok "gate refuses an unbudgeted long run (exit 78)"
    else
        no "gate refuses an unbudgeted long run" "rc=$rc $(head -1 "$TMP/gate.err")"
    fi
    # Seeded medians 400/500/600s -> median 500s -> suggested budget 2x = 1000s.
    grep -q "TIMEOUT=1000 xcodebuild -project nonexistent.xcodeproj" "$TMP/gate.err" \
        && ok "gate echoes back a paste-ready command" \
        || no "gate echoes back a paste-ready command" "$(grep TIMEOUT= "$TMP/gate.err" | head -1)"

    ( cd "$SCRIPT_DIR" && TIMEOUT=30 xcodebuild -project nonexistent.xcodeproj -scheme Slow \
        -destination "platform=iOS Simulator,id=$UDID" test ) >/dev/null 2>"$TMP/gate2.err"
    grep -q "refusing to start" "$TMP/gate2.err" \
        && no "TIMEOUT bypasses the gate" "still refused" \
        || ok "TIMEOUT bypasses the gate"
else
    skip "budget gate" "no Xcode"
fi

# --------------------------------------------------------------- leases

mkdir -p "$AI_ALIGNED_XCODE_HOME/leases"
LOCK="$AI_ALIGNED_XCODE_HOME/leases/$UDID.lock"
( exec 9>>"$LOCK"; /usr/bin/lockf -s -t 0 9 && sleep 4; exec 9>&- ) &
holder=$!
sleep 0.5

out="$(ai-aligned-xcode leases 2>&1)"
case "$out" in *"$UDID  HELD"*) ok "leases reports a held simulator" ;;
               *) no "leases reports a held simulator" "$out" ;; esac

if has_xcode; then
    start=$(date +%s)
    ( cd "$SCRIPT_DIR" && TIMEOUT=60 xcodebuild -project nonexistent.xcodeproj -scheme Slow \
        -destination "platform=iOS Simulator,id=$UDID" test ) >/dev/null 2>"$TMP/lease.err"
    waited=$(( $(date +%s) - start ))
    grep -q "is leased by another run; waiting" "$TMP/lease.err" \
        && ok "waits in-process for a busy simulator" \
        || no "waits in-process for a busy simulator" "$(head -1 "$TMP/lease.err")"
    [ "$waited" -ge 3 ] && ok "blocked until the lease was released (${waited}s)" \
                        || no "blocked until the lease was released" "returned after ${waited}s"
else
    skip "lease contention" "no Xcode"
fi
wait "$holder" 2>/dev/null

out="$(ai-aligned-xcode leases 2>&1)"
case "$out" in *"$UDID  free"*) ok "lease is released on exit" ;;
               *) no "lease is released on exit" "$out" ;; esac

# --------------------------------------------------------------- derived-data lease

if has_xcode; then
    # Two builds sharing one DerivedData tree must serialise even with no
    # simulator involved: 38 such pairs were observed in one worktree.
    DDL="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel 2>/dev/null || echo "$SCRIPT_DIR")"
    DDPATH="$TMP/shared-dd"
    mkdir -p "$DDPATH"
    h=$(printf '%s' "$DDPATH" | tr -d ' ' | cksum | cut -d' ' -f1)
    DDLOCK="$AI_ALIGNED_XCODE_HOME/leases/dd-$h.lock"
    mkdir -p "$AI_ALIGNED_XCODE_HOME/leases"

    ( exec 8>>"$DDLOCK"; /usr/bin/lockf -s -t 0 8 && sleep 4; exec 8>&- ) &
    ddholder=$!
    sleep 0.5
    start=$(date +%s)
    ( cd "$DDL" && xcodebuild -project /nonexistent.xcodeproj -scheme X \
        -derivedDataPath "$DDPATH" -destination 'generic/platform=iOS Simulator' build \
      ) >/dev/null 2>"$TMP/dd.err"
    waited=$(( $(date +%s) - start ))
    wait "$ddholder" 2>/dev/null

    grep -q 'another build is writing' "$TMP/dd.err" \
        && ok "serialises builds sharing one DerivedData tree" \
        || no "serialises builds sharing one DerivedData tree" "$(head -1 "$TMP/dd.err")"
    [ "$waited" -ge 3 ] && ok "waited for the DerivedData lease (${waited}s)" \
                        || no "waited for the DerivedData lease" "returned after ${waited}s"

    # A build needing both locks must take DerivedData before the simulator.
    # Holding only the simulator must not stop it reaching the DD wait, and
    # vice versa — a cycle would hang past the lease timeout.
    ( exec 9>>"$AI_ALIGNED_XCODE_HOME/leases/$UDID.lock"; /usr/bin/lockf -s -t 0 9 && sleep 3; exec 9>&- ) &
    simholder=$!
    sleep 0.3
    start=$(date +%s)
    ( cd "$DDL" && AI_ALIGNED_XCODE_LEASE_WAIT=20 TIMEOUT=20 \
        xcodebuild -project /nonexistent.xcodeproj -scheme X -derivedDataPath "$DDPATH" \
        -destination "platform=iOS Simulator,id=$UDID" test ) >/dev/null 2>&1
    both=$(( $(date +%s) - start ))
    wait "$simholder" 2>/dev/null
    [ "$both" -lt 19 ] && ok "acquires both leases without deadlocking (${both}s)" \
                       || no "acquires both leases without deadlocking" "took ${both}s (lease timeout was 20s)"
else
    skip "DerivedData lease" "no Xcode"
fi

# --------------------------------------------------------------- retry / classes
#
# Driven through the `swift` shim with a fake tool on PATH: aax_real_tool skips
# only the shim's own directory, so a stand-in later on PATH is what it resolves.
# That exercises the real aax_attempt path without needing a project that can
# reproduce simulator infrastructure failures on demand.

mkdir -p "$TMP/fakebin"
cat > "$TMP/fakebin/swift" <<'FAKE'
#!/bin/bash
c="$AAX_TEST_COUNTER"
n=$(cat "$c" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$c"
echo "stdout from attempt $n"
if [ "$n" -le "${FAIL_TIMES:-1}" ]; then printf '%s\n' "$SIGNATURE" >&2; exit 65; fi
echo "SUCCESS on attempt $n"; exit 0
FAKE
chmod +x "$TMP/fakebin/swift"
export PATH="$TMP/bin:$TMP/fakebin:$PATH"
export AAX_TEST_COUNTER="$TMP/attempts"

attempts() { cat "$AAX_TEST_COUNTER" 2>/dev/null || echo 0; }
reset_attempts() { rm -f "$AAX_TEST_COUNTER"; }

reset_attempts
SIGNATURE="Timed out while loading Accessibility" FAIL_TIMES=1 swift build >/dev/null 2>"$TMP/r1.err"
rc=$?
[ "$rc" -eq 0 ] && [ "$(attempts)" -eq 2 ] \
    && ok "retries once past a runner-bootstrap failure" \
    || no "retries once past a runner-bootstrap failure" "rc=$rc attempts=$(attempts)"
grep -q 'runner_bootstrap: the simulator environment failed' "$TMP/r1.err" \
    && ok "explains why it retried" \
    || no "explains why it retried" "$(head -1 "$TMP/r1.err")"

reset_attempts
SIGNATURE="** TEST FAILED **" FAIL_TIMES=9 swift build >/dev/null 2>&1
rc=$?
[ "$rc" -eq 65 ] && [ "$(attempts)" -eq 1 ] \
    && ok "does not retry a genuine test failure" \
    || no "does not retry a genuine test failure" "rc=$rc attempts=$(attempts)"

reset_attempts
AI_ALIGNED_XCODE_NO_RETRY=true SIGNATURE="Unable to boot the Simulator" FAIL_TIMES=1 \
    swift build >/dev/null 2>&1
[ "$(attempts)" -eq 1 ] && ok "NO_RETRY disables the retry" \
                        || no "NO_RETRY disables the retry" "attempts=$(attempts)"

# Teeing for classification must not merge the two streams.
reset_attempts
SIGNATURE="Unable to boot the Simulator" FAIL_TIMES=1 swift build 2>/dev/null >"$TMP/o.txt"
reset_attempts
SIGNATURE="Unable to boot the Simulator" FAIL_TIMES=1 swift build 2>"$TMP/e.txt" >/dev/null
if grep -q 'SUCCESS on attempt 2' "$TMP/o.txt" && ! grep -q 'Unable to boot' "$TMP/o.txt" \
   && grep -q 'Unable to boot' "$TMP/e.txt" && ! grep -q 'SUCCESS on attempt' "$TMP/e.txt"; then
    ok "stdout and stderr stay separated through the tee"
else
    no "stdout and stderr stay separated through the tee" \
       "out=$(tr '\n' '|' <"$TMP/o.txt") err=$(tr '\n' '|' <"$TMP/e.txt")"
fi

cls="$(sql "SELECT failure_class FROM runs WHERE outcome='ok' AND retried=1 LIMIT 1;")"
[ "$cls" = "runner_bootstrap" ] || [ "$cls" = "sim_boot" ] \
    && ok "records which class was recovered ($cls)" \
    || no "records which class was recovered" "got '$cls'"

# A lease_timeout must not record the epoch as a duration.
bad="$(sql "SELECT COUNT(*) FROM runs WHERE duration_ms > 86400000;")"
[ "${bad:-0}" -eq 0 ] && ok "no absurd durations recorded" \
                      || no "no absurd durations recorded" "$bad row(s) over 24h — unset start timestamp?"

out="$(ai-aligned-xcode failures 2>&1)"
case "$out" in *test_failure*your\ code*) ok "failures separates infrastructure from your code" ;;
               *) no "failures separates infrastructure from your code" "$out" ;; esac

# --------------------------------------------------------------- summary

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
