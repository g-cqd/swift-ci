# Family adoption and verification

Updated 2026-11-04. This ledger distinguishes completed CI from pending work.
Always filter Actions queries to `ci.yml`: AemiJSON also runs **Cache cleanup**,
whose success does not mean CI succeeded.

## Current state (2026-11-04)

Twenty-three repositories call the reusable workflow through a `Checks` job pinned by full SHA, each with a
validated `.ci/action.json` and the same `.ci/swift-ci` bootstrap: the eleven below, and the twelve migrated from
aemi's older reusable workflow, its `setup-swift` action or copies of `Scripts/analyzers.sh`. The family, ask,
TerminalKit, AemiMarkdown and Atelier pin `27f96f0` (arcleak 0.17.5 in the lock); AemiProtobuf and CSVCoder pin
`e33bcf9` (TLA+ models on the `tla` command; CSVCoder's platform builds are on the simulator SDKs again, with
aemi 3062470); HTTP pins `e950325`; AemiSwift, InternedStrings, Abysm, AemiSDR,
swift-search and URLBuilder pin `c930444`.

| Repository | Shape | Notes |
| --- | --- | --- |
| AemiSwift, InternedStrings | macOS, Swift 6.4.1 + 6.3.3 | `swift package update` before the debug tests |
| Abysm | macOS | ASan on every change; iOS Simulator job of its own |
| AemiSDR | macOS, 6.4.1 + 6.3.3 | Metal toolchain + Z3 before, iOS Simulator renderer after the debug tests |
| swift-search | Linux + macOS, serial | no-GCD gate, self-analysis after Linux debug; release archives |
| URLBuilder | Linux + macOS | library discipline; its API, platform, generator, downstream and sanitizer jobs after `Checks` |
| Atelier | three packages | one call per package (`package-path`), gated by a paths filter |
| AemiMarkdown | Linux + macOS | TLA+ models after the macOS tests; allocation ceilings only where counting works |
| TerminalKit | macOS | release tests and the signal-safety probe on every change; benchmark comparison after |
| ask | macOS, Swift 6.4.2 | dependency audit and script guards after the debug tests; budgets and mutation workflows of its own |
| HTTP | Linux + macOS, serial | graph gates and the 85 % coverage floor as commands; its scoped sanitizers, conformance and performance jobs after `Checks` |
| CSVCoder | macOS, 6.4.1 + 6.3.3 | platform builds; TLA+/Lean, documentation and the `.version` release flow after `Checks` |

Not migrated: MacFS has no hosted CI by decision (its `macfs-tool gates` runs locally with a copied analyzer lock).
GameHub is retired. aemi's old reusable workflows (`swift-quality.yml`, `swift-tool.yml`), its `setup-swift` and
`setup-private-dependency` actions and `Scripts/analyzers.sh` with its lock are removed (aemi 3062470): nothing
called them from main, and AemiUI pins `setup-swift` by commit, which stays reachable.

Added to swift-ci for these migrations, each tested on macOS and Linux:

- `package-path` (751891e): several packages per repository, with runs, caches, archives, concurrency and change
  detection scoped to the package; the bootstrap finds the pin from a package in a directory.
- `swift.testSkips` (f9ebcf2): skips in one build mode (`debug`, `release`, `address`, `thread`).
- Platform builds (c930444): the selected Xcode's toolchain, unsigned, without trust prompts, and
  `SWIFT_SUPPRESS_WARNINGS=NO` (Xcode's `-suppress-warnings` conflicts with a dependency's warnings-as-errors).
- The discipline's strict configuration is written to a temporary file, not into the checked tree (9661877).
- On Linux, swift-format runs without `BeginDocumentationCommentWithOneLineSummary`, whose verdict needs
  NaturalLanguage (e950325).
- The discipline counts only `NeverForceUnwrap` and `NeverUseForceTry` findings; a formatting problem was reported
  as a force unwrap, twice. A `.build` symbolic link to a missing directory gets the directory back before SwiftPM
  runs (31b9830).
- The release job finds the archives in its container: `github.workspace` is the host's path there (b0546eb; the
  first tag since `package-path`, arcleak v0.17.5, failed on it).
- Benchmarks as a command, `{"benchmark": {"package", "filter", "metrics", "shared"}}`: an ordo-one package run at the
  commit before (a worktree of the project's name, `shared` paths linked in) and here, on the same runner. Only
  instructions and allocations are taken by default. The two baselines go into the job summary, and a regression past
  the tolerances the benchmarks declare fails the command; the plugin reports an improvement as an error too, so the
  verdict reads its message. The commit before builds with this run's toolchain (the project's `.swift-version` is copied
  into its tree; the first AemiHMMML run failed there, on a 6.4.0 the runner did not have). A command's `paths` limit a push or a pull request to changes that touch them. Verified on
  AemiHMMML: an unchanged tree is within its tolerances, and reverting a speed-up (+5 % instructions) fails it.
- Mutation testing as a scheduled command, `{"os": "macOS", "mutation": {"paths", "budget", "workspace"}}`: the pinned
  litmus over the given globs, then its verdict (only a new survivor fails with `.ci/baselines/litmus.json`, any
  without one). `in-place` mutates a CI runner's checkout, so the tests find fixtures fetched into `.build`.
  AemiHMMML runs it nightly over its format modules.
- Repositories at pinned commits as a command, `{"git": [{"git", "commit", "into"}]}`: one commit without history,
  checked by its hash, stamped, replaced only when the commit changes. AemiHMMML fetches toml-test and the YAML
  test suite with it.
- TLA+ models as a command, `{"tla": {"models": "docs/formal"}}`: the pinned TLC, a state directory per run
  outside the tree, `.buggy.cfg` controls that must be refuted (dd661c4).
- arcleak 0.17.5 in the built-in lock: a token made by `map`/`compactMap` goes where the call's result goes.
- TLC with the off-heap fingerprint set: with the default one, a model that holds failed about one run in four
  with "Division by zero" in TLC's collision-probability report (e33bcf9); a held model reports the final state
  count, not a progress line (84a0fe1).

Open:

- AemiProtobuf's and CSVCoder's TLA+ models run on the `tla` command (AemiProtobuf weekly on macOS, CSVCoder after
  the macOS release tests; its control is `BackpressureOld.buggy.cfg`); their own jobs keep the Lean proofs.
  AemiProtobuf's modeler check moved into quality (swift-ci's modeler 0.4.7, on every change).
- ask runs without the library discipline (it is an application; enabling it means clearing force unwraps in
  `Sources` and untyped `#expect(throws:)` and wall-clock assertions in `Tests`).
- HTTP: its Linux TSan job passes again (since swift-ci 5ef5e74's suppression); its benchmark job, which held
  until its 25-minute timeout, passes since HTTP 87d0a10 (the echo benchmarks' teardown) and 65d3221/414ebca (a
  cancelled receive returns after a kqueue or epoll transport has shut down).
- Not exercised yet: Atelier's `kittycode/v*` release on swift-actions/setup-swift, CSVCoder's next `.version`
  release, HTTP's manual h3spec and soak jobs.

## History

### The first eleven (2026-11-03)

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

### Consolidation audit (swift-ci `09fd96d`)

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

Resolved since: fcheck `v0.4.7` is published (its deep-nesting tests run on a large stack, as the product does), and
advisory toolchains run in the OS matrices with `continue-on-error`, so no skipped job shows an unrendered name.

### Latest completed verification

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

### Earlier verified steps

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

### Tooling refinements from adoption

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
| AemiSDR | deadwood, dolly | 3, 143 |
| Abysm | dolly | 7 |
| swift-search | dolly | 17 |
| URLBuilder | deadwood, dolly | 1, 100 |
| Atelier: AtelierCore | deadwood, dolly | 3, 1012 |
| Atelier: GitDiffViewer | deadwood, dolly | 3, 705 |
| Atelier: KittyCode | deadwood, dolly | 2, 565 |
| TerminalKit | dolly | 260 (49 warnings) |
| HTTP | deadwood, dolly | 4, 1330 (283 warnings) |
| CSVCoder | dolly | 281 |

## Not verified (the first eleven)

Tag publishing, dolly's model-inclusive archive, full scheduled/manual heavy
matrices and Apple platform builds have not been exercised by migration pushes.
JSON Pages deployment and its risk-surface sanitizer matrix have now passed. No timing improvement is claimed before comparable completed
runs exist. Local dependency-heavy Linux validation also hit a container/SwiftPM
filesystem failure; those jobs were stopped and their VMs cleaned up, not counted
as passing tests. Dependency-free swift-ci Linux tests completed successfully.
