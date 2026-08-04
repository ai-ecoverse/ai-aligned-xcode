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

[ -x /usr/bin/lockf ]   && ok "lockf(1) present"   || no "lockf(1) present" "required for leases"
[ -x /usr/bin/sqlite3 ] && ok "sqlite3 present"    || no "sqlite3 present"  "required for the predictor"

# --------------------------------------------------------------- plumbing

out="$(ai-aligned-xcode version 2>&1)"
case "$out" in ai-aligned-xcode\ *) ok "version reports itself" ;;
               *) no "version reports itself" "$out" ;; esac

out="$(ai-aligned-xcode doctor 2>&1)"
case "$out" in *"lockf         : ok"*) ok "doctor sees lockf" ;;
               *) no "doctor sees lockf" "$out" ;; esac

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

out="$(ai-aligned-xcode failures 2>&1)"
case "$out" in *test_failure*your\ code*) ok "failures separates infrastructure from your code" ;;
               *) no "failures separates infrastructure from your code" "$out" ;; esac

# --------------------------------------------------------------- summary

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
