# ai-aligned-xcode

[![100% Vibe_Coded](https://img.shields.io/badge/100%25-Vibe_Coded-ff69b4?style=for-the-badge&logo=claude&logoColor=white)](https://github.com/ai-ecoverse/vibe-coded-badge-action)

![ai-aligned-xcode — one simulator at a time](https://raw.githubusercontent.com/ai-ecoverse/ai-aligned-xcode/main/hero-banner.jpg)

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
| Destinations that are a hardcoded UDID | 54 % |
| Sessions using one that never ran `simctl list` | 65 % |

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
5. **Owns devices per worktree.** Each simulator belongs to one worktree, tagged
   in its name; a device belonging to someone else is refused outright. Stops
   the collision forming rather than serialising it.
6. **Records every run** in SQLite, which is what makes (3), (4) and (5) work.

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

### Device ownership

Leases stop two agents using one simulator *at the same time*. Ownership stops
them wanting to in the first place.

Each simulator belongs to exactly one worktree, recorded as a suffix on the
device name — `iPhone 17 Pro [two-check-2]`. simctl has no metadata field, and
the name is the only channel that survives a reboot, shows in Simulator.app, and
is visible to agents that never call this tool. SQLite mirrors it; the name is
the source of truth. Renaming is metadata-only, so tagging a device mid-build
cannot disturb that build.

- **First use claims.** An untagged device becomes yours when you first touch it.
- **A foreign device is refused** — exit 78, naming the owner and the device you
  should use instead.
- **Supply**: a free stock device of the same type and runtime is assigned first;
  only once that pool is exhausted is a new one cloned. `reap` deletes clones,
  never devices it merely borrowed.

```
ai-aligned-xcode: refusing to use 719B8CBE-E6AC-4D6F-A9C9-B3B2A27D3ECD.

  device : iPhone 17 Pro
  owner  : worktree 'higher-upgrade'
  you    : worktree 'two-check-2'
  yours  : iPhone 17 Pro [two-check-2] = 4ADEDEA8-2E04-4392-B6D8-7EC5EA118BC4

Re-run against your own device:
  -destination 'platform=iOS Simulator,id=4ADEDEA8-2E04-4392-B6D8-7EC5EA118BC4'
```

This matters because **54% of observed destinations are a hardcoded UDID**, and
**65% of the sessions using one never ran `simctl list`** — the UDID arrived by
compaction summary, agent memory, or copy-paste. Filtering what `simctl list`
shows would miss all of them; checking ownership when the destination resolves
catches every one.

Because ownership lives in the name, `simctl list` already reads as an ownership
table. No output filtering is needed, and none is done — rewriting a read-only
command that agents parse is not worth the reach it would add.

Assignment renames devices you may also use by hand, so it is reversible:

```bash
ai-aligned-xcode devices          # who owns what
ai-aligned-xcode release --apply  # untag borrowed devices, restore stock names
ai-aligned-xcode reap --apply     # delete devices this tool created
ai-aligned-xcode reap --older-than 3d --apply   # ...or anything idle that long
```

Disable with `AI_ALIGNED_XCODE_NO_OWNERSHIP=true`.

### Reaping idle devices

Simulators are not cheap once they have been booted: on one real machine 17
active devices held 39.8 GB while 28 never-booted ones cost 0.5 GB between them.
Disk follows use, not existence.

```bash
ai-aligned-xcode reap --orphaned               # owning worktree is gone
ai-aligned-xcode reap --older-than 3d          # or: idle that long
ai-aligned-xcode reap --older-than 3d --apply  # delete them
```

**`--orphaned` is usually the one you want.** With agents this busy nothing
stays idle for long — on one machine after two days, 51.7 GB sat in the
"used 1–3 days ago" bucket and *nothing at all* was older than seven. Age
filters scrape a thin tail. Worktrees, meanwhile, come and go constantly, and
a device abandoned an hour ago by a deleted worktree is already dead weight.

The owning worktree's path is recorded when the device is claimed, because a
label alone cannot be resolved back to a directory — `icon-race` could be a
`.yolo` worktree, an intent workspace, or long gone. Devices claimed before
that was recorded fall back to searching the usual worktree locations.

Three things are never proposed, whatever the age:

- **Booted devices** — something is using them by definition.
- **Devices with a held lease** — a build is between phases.
- **Devices named by a running `xcodebuild`/`xctest`** — belt and braces for a
  run that has not taken a lease.

Never-used devices are also skipped by default. They cost ~20 MB each and are
the pool assignment draws from, so deleting them just forces a `simctl create`
for the next worktree. `--include-never-used` overrides that.

Without `--older-than`, `reap` falls back to devices this tool created itself.
It never deletes a device it merely borrowed — that is `release`'s job.

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
| `AI_ALIGNED_XCODE_NO_OWNERSHIP=true` | skip the device-ownership check |
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

Locking is `fcntl.flock` via `python3`. macOS ships no `flock(1)`, and its
`lockf(1)` — the obvious substitute — **busy-waits**, with or without `-t`,
despite the man page's "waits indefinitely to acquire the lock":

```
lockf -s -t 10 <fd>   ->  3.03s CPU for 3s of waiting
lockf -s     <fd>     ->  97.5% CPU
python3 fcntl.flock   ->  0.02s CPU for 9.5s of waiting
```

An early build used `lockf` and put fourteen waiters on one lease, taking a real
machine to 0.18 % idle at load average 318 — a lease system built to stop agents
spinning that was itself a distributed spin lock. Do not reach for `lockf` here.

The lock is held on a file descriptor by the shim process itself, so the helper
can exit while the `flock(2)` lives on the still-open file description. Child
processes get the descriptor closed (`8>&- 9>&-`) — otherwise the watchdog,
which outlives the build by a grace period, would pin the lease after the build
had finished.

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

macOS with Xcode. Everything else is in the base system:

| | used for | if missing |
| --- | --- | --- |
| `python3` + `fcntl` | leases, `flock(2)` without spinning | leases do not work |
| `sqlite3` | run history, the predictor, device records | no prediction or stats |
| `jq` | resolving `name=` destinations and device ownership | name-based destinations run unleased and unowned |

`ai-aligned-xcode doctor` reports all three.

## License

Apache-2.0
