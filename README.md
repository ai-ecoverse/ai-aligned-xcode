# ai-aligned-xcode

A transparent Xcode toolchain shim for coding agents. It shadows `xcodebuild`,
`xcrun`, `swift` and `xcodegen` on `PATH` and fixes the things that go wrong
when several agents share one Mac — **without asking you to teach the agent
anything**. No `CLAUDE.md` section, no `AGENTS.md` rule, no `SKILL.md`, no MCP
server. The agent runs the command it was always going to run.

Humans get an untouched pass-through. Only detected agents are managed.

## Why

Across ~2,800 real iOS tool invocations from four coding agents (Claude Code,
Factory Droid, Auggie, Intent) on one machine:

| observation | count |
| --- | --- |
| Concurrent invocations naming the **same simulator UDID** | 46 |
| Longest same-UDID collision (two `xcodebuild test` runs) | 825 s |
| Distinct sessions sharing one UDID, from 13 working directories | 55 |
| `xcodebuild` calls with **no** `-derivedDataPath` (so sharing the default) | 894 / 1153 |
| Uses of `flock` or any real mutex | **0** |
| `pgrep` polls for a rival `xcodebuild` | 170 |
| Spin-wait `sleep`s | 141 |
| `pkill` commands that killed *another agent's* build | 15 |
| `xcodebuild test` error rate | 31.9 % |

Agents already know they are colliding. Lacking a lease, they hand-roll mutexes
out of `pgrep`, `sleep` and — when patience runs out — `pkill`. Every poll is a
whole agent turn, so the workaround also burns context and cache.

## What it does

1. **Leases the simulator.** An exclusive `flock(2)` per destination UDID, held
   for the duration of the run. Contending runs *block inside the shim*, so the
   agent's single tool call absorbs the wait. Returning "busy, try later" is
   what produced the poll loops in the first place.
2. **Isolates DerivedData, and leases it too.** Injects a per-worktree
   `-derivedDataPath` when the caller did not set one, so parallel checkouts
   stop corrupting each other — and serialises builds that share one tree,
   because 38 pairs of concurrent builds in a single worktree were observed.
   `xcodegen` takes the same lease, since regenerating the project invalidates
   the tree a build is reading.
3. **Refuses runs nobody budgeted for.** Predicts the runtime from recorded
   history; if the median exceeds the budget (default 300 s) it fails with
   `EX_CONFIG` and a paste-ready command, rather than letting the agent start
   something its harness will kill halfway through.
4. **Retries infrastructure failures, once.** Separates "the simulator broke
   before your code ran" from "your code is wrong", and re-runs only the
   former. A genuine test or compile failure returns on the first attempt with
   its exit status intact.
5. **Records every run** in SQLite, which is what makes (3) and (4) work.

Only simulator-bound work takes a lease. `generic/platform=…`, macOS and
`-showBuildSettings` runs stay fully parallel, and read-only queries
(`-version`, `-list`, `-showsdks`, `-showdestinations`, …) pass through
untouched.

## Install

```bash
git clone https://github.com/ai-ecoverse/ai-aligned-xcode
cd ai-aligned-xcode
./install.sh
```

`~/.local/bin` must precede `/usr/bin` on `PATH`; the installer checks and tells
you if it does not. Agents often spawn non-login shells, so on zsh put the
`PATH` export in `~/.zshenv` rather than `~/.zshrc`.

Verify with:

```bash
ai-aligned-xcode doctor
```

## Usage

There is no usage. That is the point — run `xcodebuild` as you always did.

When a run is refused you get:

```
ai-aligned-xcode: refusing to start an unbudgeted long run.

  command   : xcodebuild test -scheme SliccFollower
  predicted : ~480s (median of recent runs for this scheme/action/destination)
  budget    : 300s

This run will most likely outlive your harness's command timeout, and you will
lose the output rather than the work. Re-run with an explicit budget so you know
what you are signing up for:

  TIMEOUT=960 xcodebuild -project SliccFollower.xcodeproj -scheme SliccFollower …
```

`TIMEOUT` is in seconds and bypasses the gate. The run is killed if it exceeds
the budget, and you get partial output plus a clear timeout status instead of a
silent truncation.

### Failure classes

`xcodebuild test` failed 31.9 % of the time in the observed corpus, and a
meaningful share of those never reached an assertion. Runs are classified so the
two are not confused:

| class | retried | meaning |
| --- | --- | --- |
| `runner_bootstrap` | yes | UI-test runner died at init (accessibility load, preflight checks) |
| `sim_boot` | yes | simulator would not boot, or `launchd_sim` never answered |
| `runner_crash` | yes | lost the test manager, or the bundle failed to load |
| `coresim` | yes | CoreSimulatorService wedged |
| `build_db_lock` | yes | lost a race on the build database |
| `test_failure` | no | your tests failed |
| `build_failure` | no | your code did not compile |
| `signing` | no | certificate or provisioning problem |
| `destination` | no | no such device or destination |

A retried run records the class that provoked it, so a green build still tells
you the environment hiccuped. Disable with `AI_ALIGNED_XCODE_NO_RETRY=true`.

Deliberately *not* retried: the generic `Failed to install or launch the test
runner` wrapper, which also covers permanent failures like a bad bundle or a bad
signature. Retrying those just burns another full build.

For `sim_boot` and `coresim` the leased device is shut down before the retry —
never erased, which would destroy app state the caller may need.

### Inspection

```bash
ai-aligned-xcode stats     # runtime history per scheme/action/destination
ai-aligned-xcode failures  # failure classes, and which were infrastructure
ai-aligned-xcode leases    # which simulators are currently leased
ai-aligned-xcode doctor    # environment check
```

### Environment

| variable | effect |
| --- | --- |
| `TIMEOUT=<seconds>` | budget for this run; bypasses the gate |
| `AI_ALIGNED_XCODE_DISABLE=true` | pass everything through untouched |
| `AI_ALIGNED_XCODE_BUDGET=<seconds>` | gate threshold (default `300`) |
| `AI_ALIGNED_XCODE_LEASE_WAIT=<seconds>` | max lease wait (default `1800`) |
| `AI_ALIGNED_XCODE_MIN_SAMPLES=<n>` | samples before the predictor is trusted (default `3`) |
| `AI_ALIGNED_XCODE_NO_RETRY=true` | never retry infrastructure failures |
| `AI_ALIGNED_XCODE_HOME=<dir>` | state directory (default `~/.ai-aligned-xcode`) |
| `AI_ALIGNED_XCODE_DEBUG=true` | trace decisions to stderr |
| `AMI_PASSTHROUGH=true` | force "not an agent" |

## How it works

Agent detection comes from [am-i-ai](https://github.com/ai-ecoverse/am-i-ai),
memoised per session — its process-tree walk costs ~54 ms, which is 8× a real
`xcrun` call and far too much to pay per invocation.

A run can need two leases — the DerivedData tree it writes and the simulator it
drives — so there is one global ordering rule: **DerivedData (fd 8) before
simulator (fd 9)**. `xcodegen` takes only fd 8, `xcrun simctl` only fd 9, and
`xcodebuild` takes 8 then 9, so no cycle can form. A test asserts a run needing
both completes rather than hanging to the lease timeout.

Locking uses **`/usr/bin/lockf`**, since macOS ships no `flock(1)`. The lock is
held on a file descriptor by the shim process itself, so `lockf(1)` can exit
while the `flock(2)` lives on the still-open file description. Child processes
get the descriptor closed (`9>&-`) — otherwise the watchdog, which outlives the
build by a grace period, would pin the lease after the build had finished.

`timeout(1)` is also absent from base macOS, so the budget watchdog is
hand-rolled rather than depending on GNU coreutils being installed.

State lives in `~/.ai-aligned-xcode`: `runs.db` (SQLite, WAL), `leases/`,
`derived/`, `cache/`.

### Why not just serialize everything

Because most calls are fast. In the observed corpus `xcodebuild build` has a
3.7 s median against a 223 s p90 — a sixty-fold spread between incremental and
cold. A blanket mutex would be worse than the status quo, which is why the lease
is keyed on the **destination UDID** rather than on "an `xcodebuild` is running".

## Prior art

[XCSteward](https://xcsteward.com) reaches the same diagnosis — lease-backed
simulator locks, per-job DerivedData, readiness checks, a documented
`runner_bootstrap_failure` class — and is worth reading; its failure taxonomy
informed the classes above. It is opt-in: agents must call
`xcsteward submit --project <name>` against a TOML profile. This tool takes the
opposite integration bet: shadow the real commands so nothing needs teaching.
The two are complementary.

The retry signatures also come from slicc's `swift-coverage-runner-retry.sh`,
which converged on the same three runner-init strings independently — good
evidence they are the right ones.

Apple's Xcode 27 Agent Skills are instruction files and cover neither simulator
management nor build execution.

## Requirements

macOS with Xcode. `jq` is optional but needed to resolve `-destination
'…,name=iPhone 17 Pro'` to a concrete UDID; without it, name-based destinations
run unleased.

## License

Apache-2.0
