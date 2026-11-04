# Family adoption and verification

Updated 2026-11-03. This ledger distinguishes completed CI from pending work.
Always filter Actions queries to `ci.yml`: AemiJSON also runs **Cache cleanup**,
whose success does not mean CI succeeded.

## Migrated

All eleven callers use `.ci/action.json` and pin swift-ci `09fd96d` (full SHA in each
workflow). Each repository's `.ci/README.md`, where present, explains its special
checks and exceptions. The CLI uses the same configuration locally and in CI.

- dolly, deadwood, fcheck, modeler, arcleak: serial tests, warm-tree self-analysis,
  no-GCD gate and the existing removal/leak/LSP oracles. Archives are tag-only.
- analyzerkit: common library matrix. Cleanup now recognizes dead container
  zombies, and inspects zombie state only for supervised survivors. Its shutdown
  test accounts for both bounded grace phases rather than assuming one.
- AemiRegex: dev/consumer split, independent Go fixture oracle, all 10,000 seeded
  differential comparisons retained under ASan. A standalone Foundation-only
  reproduction lives in its `.ci/probes`. Only its known Foundation regex stack
  symbol is added to Linux leak suppressions; expected test payloads are now
  scoped to the test body, not retained by parameter discovery.
- AemiJSON: fixture preparation before test legs, flag-free consumer and core
  portability check. Preserves path-gated macOS ASan+UBSan/TSan, API compatibility,
  exact platform SDK/triples, fuzz crash artifacts, benchmark baseline controls
  and Pages. Builds DocC once with warnings as errors and deploys that same site.
  Platform/fuzz/benchmark runs are scheduled/manual. The fixture plugin uses its
  sandbox-granted work directory even when `.build` points outside the package.
- AemiProtobuf: common graph, coverage floors without rerunning the suite, warm
  NIO checks, conformance, Lean/TLC/modeler, allocation thresholds, mutation and
  docs. Heavy work stays weekly/manual with a matching 168-hour idle window.
  Preserves its existing ASan-only depth-test exception. Bundle resource lookup
  fixes the existing Linux doubled-Resources path bug.
- aemi: serial 6.4.1/6.3.3 macOS debug matrix; primary release scheduled/manual.
  Keeps the Linux product subset instead of invalid whole-package Linux tests.
  All kernel/Embedded/Unicode/script oracles remain, and result waits for all.
  Modern package paths are formatted; legacy unformatted trees and their test
  suites remain explicit exceptions. No new legacy analyzer backlog is imposed.
  The old reusable workflow remains for external callers, with `job.workflow_sha`
  corrected. The process-table fixture now signals readiness after `setpgrp`,
  eliminating a parent/child ordering race rather than sleeping around it.

- litmus: macOS-only package tests on Swift 6.4.2, Linux source-quality gate,
  standalone scheduled/tag/manual smoke, and macOS release archives. Both package
  tests and smoke explicitly select the swift.org toolchain for xcrun-driven
  subject builds. Smoke resolves its own executable path and builds it rather
  than depending on another job's tree. Its leftover-helper check now fails
  explicitly instead of relying on `! command` with errexit (which does not fail
  the shell).

## Consolidation audit (swift-ci `09fd96d`)

Checked from each repository's `origin/main`, not local trees:

- All eleven callers pin `09fd96d`, with the same triggers (push, pull request, merge queue, schedule, dispatch),
  a `Checks` caller job and validated `.ci/action.json`. Tools and litmus also run on `v*` tags; libraries do not
  publish. Schedules: 03:17 daily (Protobuf Mondays only, with a 168-hour idle window); swift-ci and litmus 03:41.
- Every repository carries the same executable `.ci/swift-ci` (byte-identical; `validate` and `plan` refuse a
  stale or edited one). It builds the pinned swift-ci once and runs it, so hooks, local runs and CI share one tool
  lock. Verified end to end: a cold cache fetched and built `09fd96d` from GitHub; all eleven validate through it.
- Retired duplicate gates: `Scripts/ci-local.sh` and `lint-format.sh` (five tools; `localChecks` replaces them,
  and the old script skipped the family analyzers), `Scripts/analyzers.sh` (JSON, Regex; a separate installer
  outside the tool lock), `.adbuildtools.json` (JSON, Regex) and Protobuf's own analyzer pins, which were older
  than CI's (deadwood 0.13.0, dolly 0.13.0, arcleak 0.15.0, fcheck 0.4.0, modeler 0.4.0 locally against 0.15.2,
  0.14.2, 0.17.2, 0.4.6, 0.4.5). Its modeler for the model checks is now 0.4.5 too (0 findings).
- Restored a gate the migration had dropped: JSON and Regex ran aemi's `swift package lint` in their old CI
  (force unwrap and `try!` in shipped targets, `strtod`, inline PRNGs, untyped `#expect(throws:)`, wall-clock
  assertions). It is now `quality.discipline`, in swift-ci, tested, and ran clean in both hosted quality jobs.
- Baselines all live in `.ci/baselines/` (JSON and Protobuf moved theirs from the root).
- aemi keeps `Scripts/analyzers.sh` and its old reusable workflows only for callers outside this family
  (`swift-search`, `Atelier` still use them).
- Local mutation testing works for the first time: litmus is pinned and checksum-verified, writes outside the
  project, and is opt-in; with `.ci/baselines/litmus.json` only a new survivor fails (verified: 218 mutants,
  74.31 %, 0 new, 56 accepted). `--help` on a subcommand no longer runs it.
- All twelve CI runs on these commits completed green.

Open: fcheck `v0.4.7` is unpublished — its first heavy (tag) run crashed the macOS release/ASan/TSan test
processes (the 600-level nesting test, consistent with stack exhaustion; not reproduced locally on Swift 6.4.2),
and the gate correctly withheld the release. A skipped advisory job still shows `${{ matrix.title }}` as its
name in repositories without an advisory toolchain (GitHub does not evaluate a skipped matrix job's name).

## Latest completed verification

- analyzerkit `80af3dd`: all push checks passed, including Linux debug/release/ASan
  and macOS debug.
- AemiJSON `86e3608`: all push checks passed, including consumer, Linux ASan,
  macOS address+undefined/thread sanitizers and Pages deployment.
- AemiRegex `b36639e`: all push checks passed, including Go oracle and Linux ASan.
- aemi `b1eae7b`: all push checks and independent oracles passed.
- All five tool repositories and AemiProtobuf completed green on the prior pin.
- Litmus's full local real-execution smoke passed: all verdicts and report formats,
  strict/new-survivor gates, stale-test detection, PR scope, budget/resume/cache,
  per-test reach, in-place and persistent workspaces, clean interruption and
  explicit absence of surviving helpers. Current hosted test run is pending.
- Linux archive smoke now runs the actual CLI archive command, verifies checksum,
  hides the installed runtime, and executes the extracted binary without
  LD_LIBRARY_PATH. Passed locally on ARM64 and in the hosted root-action job.
- All eleven callers have been updated to `cdc970c`; the new push runs are pending.

## Earlier verified steps

- swift-ci `1da0e40`: full Actions CI green; 72 tests in 20 suites passed locally
  on macOS and Swift 6.4.1 Linux. Quality and actionlint pass.
- All five tool migrations have completed fully green CI. On the refined pin,
  dolly, fcheck and modeler have completed green; deadwood/arcleak are pending
  remaining jobs, with Linux ASan already green.
- AemiProtobuf: full migration CI and the refined-pin CI completed green.
- AemiRegex `b36639e`: Linux ASan, debug, release, consumer, quality and Go golden
  fixture pass. macOS job still pending at this update.
- AemiJSON `86e3608`: Linux ASan, debug, consumer and quality pass. Remaining jobs
  still pending. The earlier 840-byte report was expected test payloads; their
  lifetime was corrected, not suppressed. A previous status report accidentally
  cited Cache cleanup rather than CI; this entry corrects that distinction.
- analyzerkit: zombie fix passes Linux debug/release/ASan in Actions. Latest
  follow-ups await CI. Local bounded-process suites pass (23 tests).
- aemi: initial migration completed green. A subsequent run found the fixture
  readiness race; its fix passes the local ProcessTable suite plus 15 repeated
  runs. Latest CI pending. Its independent kernel, Embedded, Unicode and script
  oracles passed before that fixture failure.
- Local library suites and all four new migration quality gates passed. Resource
  lookup was also independently checked against a Linux Foundation bundle.

## Tooling refinements from adoption

- Absolute LSAN paths work when a test runs its tool from another directory.
- Linux Foundation empty-file reads have a standalone reproduction and a narrow
  stack-function suppression, not a general Data suppression. An unrelated
  retain-cycle probe still triggers LeakSanitizer with the suppression enabled.
- Arcleak's deliberate-cycle canary breaks the cycle after proving it and then
  verifies deallocation.
- `commands.before`, `commands.after`, sanitizer-specific test exclusions and
  additional symbol-only Linux dependency leak suppressions are tested.
- macOS action failures always print their captured log under `bash -e`; a
  regression test executes the actual action script with a failing command.
- Cache identities include config/manifests and commit, restore the matching
  configuration first, and save only successful default-branch builds. New
  source revisions no longer leave the tree frozen at the first manifest key.
- Consumer checks keep the hosted-runner 250 ms compiler budget without enabling
  any dev flags. Local defaults remain unchanged.

## Accepted existing analyzer backlog

These baselines are recorded adoption boundaries, not fixes or claims of false
positives. Only new fingerprints fail; remove entries as the backlog is fixed.

| Repository | Analyzer | Fingerprints |
| --- | --- | ---: |
| dolly | deadwood | 8 |
| deadwood | dolly | 39 |
| fcheck | dolly | 12 |
| modeler | dolly | 25 |
| arcleak | dolly | 57 |
| analyzerkit | dolly | 150 (48 warnings, 102 notes) |

## Not verified

Tag publishing, dolly's model-inclusive archive, full scheduled/manual heavy
matrices and Apple platform builds have not been exercised by migration pushes.
JSON Pages deployment and its risk-surface sanitizer matrix have now passed. No timing improvement is claimed before comparable completed
runs exist. Local dependency-heavy Linux validation also hit a container/SwiftPM
filesystem failure; those jobs were stopped and their VMs cleaned up, not counted
as passing tests. Dependency-free swift-ci Linux tests completed successfully.
