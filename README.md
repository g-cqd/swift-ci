# swift-ci

CI for Swift packages and Xcode projects: one reusable GitHub Actions workflow, configured by `.ci/action.json`,
whose every decision is made by a tested Swift CLI. The same CLI runs the same checks on a developer's machine.

```sh
swift run --package-path path/to/swift-ci swift-ci init --ref <swift-ci commit>   # in the project
```

writes `.ci/action.json` (empty for a package; an Xcode project's schemes from `xcodebuild -list`) and the workflow
below, and overwrites nothing.

```yaml
# .github/workflows/ci.yml
on:
  push: { branches: [main], tags: ["v*"] }
  pull_request:
  merge_group:
  schedule: [{ cron: "17 3 * * *" }]
  workflow_dispatch:
jobs:
  ci:
    uses: g-cqd/swift-ci/.github/workflows/swift-ci.yml@<commit>
    permissions: { contents: write }   # write is used only to publish a tag
    secrets: inherit
```

An empty `.ci/action.json` (or none) is a working configuration for a Swift package.

### As a step of any workflow

The repository is also an action (`action.yml`), for a workflow with its own layout. It builds the CLI from the
action's source (cached by its hash) and runs one command; in GitHub Actions, `plan`, `run` and `publish` read the
event, the ref, the base commit and the tag from the run. It needs a Swift toolchain on the runner.

```yaml
jobs:
  plan:
    runs-on: ubuntu-latest
    container: swift:6.4.1-noble
    outputs: { linux: "${{ steps.plan.outputs.linux }}" }
    steps:
      - uses: actions/checkout@v5
        with: { fetch-depth: 2 }
      - id: plan
        uses: g-cqd/swift-ci@<commit>
        with: { command: plan }          # outputs linux, macos (matrices), publish, skipped
  linux:
    needs: plan
    strategy: { matrix: { include: "${{ fromJSON(needs.plan.outputs.linux) }}" } }
    runs-on: ${{ matrix.runner }}
    container: ${{ matrix.container }}
    steps:
      - uses: actions/checkout@v5
      - uses: g-cqd/swift-ci@<commit>
        with: { arguments: "${{ matrix.id }}" }   # swift-ci run <check>
```

### From another CI

The CLI is the portable part: `--event` takes a trigger (`push`, `pull-request`, `merge-queue`, `nightly`, `tag`,
`dispatch`) as well as a GitHub event name.

```sh
swift run --package-path swift-ci swift-ci plan --event push --ref main --base "$PREVIOUS_COMMIT"
swift run --package-path swift-ci swift-ci run linux-debug
```

## The `.ci` folder

| Path | |
| --- | --- |
| `.ci/action.json` | the configuration |
| `.ci/tools.lock.json` | replaces the built-in tool lock when present |
| `.ci/baselines/<tool>.json` | an analyzer's baseline (else the root `.<tool>-baseline.json` the tools write) |
| anything else | what `commands` run: scripts, fixtures |

`swift-ci baseline` writes each analyzer's current findings to `.ci/baselines/`, to adopt the gate on a codebase with
a backlog: from then on only a new finding fails.

Paths inside the configuration are relative to the package's directory: the repository root, or `package-path` (see
[Several packages in one repository](#several-packages-in-one-repository)). Formatter configurations (`.swift-format`,
`.swiftlint.yml`, `.swiftformat`) stay there, where Xcode, editors and the tools find them.

## What runs when

`swift-ci plan` reads the configuration, the project and the event, and decides the jobs. Every other job runs one
`swift-ci run <check>`.

| Check | Runs on | Default cadence |
| --- | --- | --- |
| `quality`: formatters and linters by configuration file, the g-cqd analyzers | Linux | every change |
| `linux-debug`, `linux-release`, `linux-address` | Linux | every change |
| `consumer`: build and test without `swift.environment` (only when it is set) | Linux | every change |
| `macos-debug` (with coverage) | macOS | every change |
| `linux-thread`, `macos-release`, `macos-address`, `macos-thread` | | nightly, tag, manual |
| `platforms`: every `platforms` entry, on one runner | macOS | nightly, tag, manual |
| `documentation` | macOS | nightly, tag, manual |
| `archive-linux`, `archive-macos`, then the release | both | tag (archives also manual) |
| `commands`: the project's own | as configured | as configured |

- **Every change** is a push, a pull request, a merge queue, a tag or a manual run. A change that touches only
  `documentationOnlyPaths` (docs, ADRs, release notes, Markdown) runs nothing, and the gate passes.
- **Nightly** runs only if a commit landed in the last 24 hours.
- A newer push cancels the run of the previous one on the same ref; a tag or the nightly run is never cancelled.
- **Build once.** Tests are built once and run with `--skip-build`. In release, `-Xswiftc -enable-testing` makes that
  build the one `swift test` needs: `swift build -c release` followed by `swift test -c release` compiles everything
  twice. Xcode projects use `build-for-testing` then `test-without-building`.
- **Linux first.** Linux runners are cheap and plentiful; macOS ones are counted per account and queue. So the version
  matrix and the sanitizers of every change run on Linux, and a change needs one macOS job.
- `gate` is the one check a branch rule requires: a skipped job passes, a failed or cancelled one does not.
  Advisory legs (`swift.advisory`, such as a nightly toolchain) run in the same OS matrix, named `· Advisory`, and
  continue on error: they report but never fail the run.

## Configuration

Every key is optional; an unknown key is an error naming its path, so a typo cannot silently turn a check off.

```jsonc
{
  "project": {
    "kind": "auto",                    // auto | package | xcode
    "xcode": "App.xcworkspace",        // when there are several
    "schemes": ["App"],                // Xcode: built and tested; a package: its platform builds
    "testPlan": "Unit",
    "destination": "platform=iOS Simulator,name=iPhone 17",
    "packages": ["Modules/Core"],      // an Xcode project's local packages, tested with swift test
    "linux": true                      // default: a package builds on Linux, an Xcode project does not
  },
  "swift": {
    "versions": ["6.4.1", "6.3.3"],    // the first is primary; the matrix checks run on each
    "matrix": ["linux-debug"],
    "advisory": ["nightly-main"],      // run by the matrix checks, never fail the run
    "macOS": "primary",                // primary | xcode (the selected Xcode's toolchain) | a version
    "xcode": "26.6",                   // the Xcode to select on macOS runners
    "environment": { "PKG_DEV": "1" }, // every build and test; adds the consumer check
    "parallel": true
  },
  "runners": { "macOS": ["macos-26"], "linux": ["ubuntu-latest"] },   // self-hosted labels work
  "checks": { "macos-release": ["push"], "linux-address": [] },       // cadence overrides; [] turns one off
  "platforms": [{ "name": "iOS" }, { "name": "watchOS", "destination": "generic/platform=watchOS" }],
  "quality": {
    "paths": ["Sources"],              // what the analyzers read (default: Sources and Tests)
    "analyzers": ["deadwood", "dolly", "arcleak"],   // also: fcheck, modeler
    "formatters": "auto",              // auto: .swift-format, .swiftlint.yml, .swiftformat at the root
    "include": ["Package.swift", "Sources/**", "Tests/*/*.swift"],   // what swift-format checks (default: all)
    "exclude": ["**/Fixtures/**"],     // files swift-format skips
    "local": ["litmus"],               // opt-in, `swift-ci local` only (default: none)
    "lock": "tools/lock.json"          // a lock elsewhere than .ci/tools.lock.json
  },
  "release": { "executables": ["tool"], "notes": "release-notes/{tag}.md" },
  "documentation": { "targets": ["Kit"], "warningsAsErrors": true },
  "commands": [
    { "id": "oracle", "run": "Scripts/oracle.sh", "os": "linux", "cadence": ["push", "tag"] },
    { "id": "self-analysis", "run": "swift run tool analyze Sources", "after": "linux-debug" },  // in that job, warm
    { "id": "full", "run": ".ci/full-bundle.sh", "after": "archive-macos", "archives": true },  // published too
    { "id": "models", "tla": { "models": "docs/formal" }, "after": "macos-debug" },  // TLA+ models, with TLC
    { "id": "mutation", "os": "macOS", "cadence": ["nightly", "dispatch"],             // litmus, pinned; new survivors fail
      "mutation": { "paths": ["Sources/Core/**"], "budget": 3600, "workspace": "in-place" } },
    { "id": "benchmarks", "os": "macOS", "cadence": ["push", "nightly"], "paths": ["Sources/**"],  // only when they change
      "benchmark": { "package": "Benchmarks", "shared": [".build/fixtures"] } },      // vs the commit before, same runner
    { "id": "suites", "git": [{ "git": "https://github.com/o/suite", "commit": "<40 hex>", "into": ".build/fixtures/suite" }],
      "before": ["linux-debug", "macos-debug"] }                                      // a repository at a pinned commit
  ],
  "documentationOnlyPaths": ["docs/**", "development/**", "release-notes/**", "*.md", "LICENSE"]
}
```

## Tools

Quality runs tools from their release archives, pinned in a lock: a version and, per platform, the archive's SHA-256.
A tool runs only if its archive has the pinned hash and the binary reports the pinned version, so a check cannot
change because a tool moved under it. The built-in lock pins arcleak, deadwood, dolly, fcheck and modeler (the g-cqd
analyzers), SwiftLint and SwiftFormat; swift-format comes with the toolchain. Each analyzer runs with
`--strict --no-cache --relative-to .` and its committed baseline when there is one.

## On a developer's machine

```sh
swift run swift-ci local              # quality, with the local-only tools, then this machine's debug tests
swift run swift-ci steps macos-debug  # what a check would run
swift run swift-ci plan --event push --ref refs/heads/main --base HEAD~1
swift package --disable-sandbox swift-ci local   # from a package that depends on swift-ci
```

## Design

- The workflow only wires; the CLI decides (`SwiftCIKit`, tested: configuration, detection, planning, steps, the tool
  lock and its installation, release notes, artifact bundles). No dependencies, so the CLI builds in seconds on any
  runner; every job runs the CLI of the commit the caller pinned (`job.workflow_sha`).
- Tags publish: the archives both OS jobs made, a SwiftPM `.artifactbundle` per executable, and the release note of
  the tag, linted (every fixed section present) and with its Archives section filled from the published checksums.

## Status

New; swift-ci's own CI runs on it. Covered: Swift packages and Xcode projects and workspaces (build, test, sanitizers, platforms, documentation),
quality, and releases of a package's executables. Not yet: archiving or shipping an app (App Store, TestFlight;
use `commands` with fastlane meanwhile), test-result reports (xcresult summaries, pull request comments).

### Preparing fixtures before checks

A command can prepare several checks on their own runners, before any build or
skip-build test step:

```json
{
  "commands": [{
    "id": "fixtures",
    "run": "swift package --allow-network-connections all --allow-writing-to-package-directory fetch-fixtures",
    "before": ["linux-debug", "linux-release", "linux-address", "consumer", "macos-debug"]
  }]
}
```

Like `after`, `before` attaches to the named jobs: it adds no standalone job and
inherits their cadence and runner. Hooks execute in configuration order. A
preparation failure stops a normal test job before its build. A command cannot
have both `before` and `after`, or attach to another attached command. Shell
commands do not inherit `swift.environment`; write any required variables in
`run` explicitly. See [.ci/ADOPTION.md](.ci/ADOPTION.md) for the family migration's
verification ledger and remaining gaps.

`swift.sanitizerSkips` maps `address` or `thread` to test-name patterns passed as
`--skip` only for that sanitizer. Use this for documented instrumentation-only
constraints, not ordinary failures; the default debug/release tests still run
those cases. For example, AemiProtobuf's existing ASan recursion exception:

```json
{"swift":{"sanitizerSkips":{"address":["deeply nested input is refused at the limit"]}}}
```

Quality's swift-format check uses the project's `.swift-format`, except for a rule whose verdict depends on the
platform: `BeginDocumentationCommentWithOneLineSummary` finds a comment's first sentence with NaturalLanguage on macOS
and with a period heuristic elsewhere (it ends a sentence at "e.g." and drops inline code). On Linux, quality runs with
that rule off, through a configuration written outside the project; macOS runs and hooks still check it.

`quality.discipline` adds swift-format's `NeverForceUnwrap` and `NeverUseForceTry` over the shipped targets. Only those
two rules' findings count, and the step's summary counts them apart from the textual findings: a formatting problem is
the swift-format check's, reported once, there.

A package's `.build` may be a symbolic link to a directory outside the sources. When its target is gone, SwiftPM fails
with "The file “<package>” couldn’t be saved in the folder “<parent>”"; before it runs SwiftPM, swift-ci recreates the
target and says so.

A command with `tla` instead of `run` checks TLA+ models with TLC (the pinned `tla2tools.jar`, run with Java, so on
a runner that has it: macOS, or a Linux runner without the Swift container). Every `<Module>.cfg` in the directory
must hold; every `<Module>.buggy.cfg` is a control that must be refuted, which shows the checker can fail. Each run has
a state directory of its own outside the repository: TLC's default is named after the current second, beside the
specification, so a model that ends within a second made the next one fail. The verdict comes from TLC's error line,
not its exit status alone: an invariant false in the initial state exits 151, as a configuration error does.

A command with `git` instead of `run` copies repositories at pinned commits into the project, usually `before` the
checks whose tests read them (a conformance suite, a corpus kept out of the repository). Only that commit is fetched,
without history, and the copy must be the commit named: git names a commit by the hash of its content, so the commit is
the integrity check, and a 40-character hash is required. The copy has no `.git` and a `.swift-ci-commit` stamp; a run
with the same commit does nothing, one with another commit replaces it, and an interrupted fetch leaves no partial copy.
`into` must stay inside the root (not `.git` or `.ci`); `.build/fixtures/<name>` keeps it out of the tree.

`platforms` builds each scheme with `xcodebuild build` for each platform, with the selected Xcode's toolchain (a
swift.org toolchain has no iOS, tvOS, watchOS or visionOS standard library), unsigned, without the macro and plugin
trust prompts, and with `SWIFT_SUPPRESS_WARNINGS=NO`: Xcode's `-suppress-warnings` for dependencies conflicts with
the `-warnings-as-errors` of a dependency that declares `treatAllWarnings(as: .error)`, as the family's packages do.

`swift.testSkips` does the same for one build mode, `debug`, `release`, `address` or `thread`, on Linux and macOS:
for a test whose fixed deadline an unoptimized build misses, which the release tests still run. Prefer fixing the
test; record why where the skip is.

For a weekly caller cron, set `"scheduledMaxCommitAgeHours": 168` so a commit
from earlier in the week still receives the scheduled checks. The default
24-hour idle window suits a daily cron; `null` disables the idle skip. This is
an age-based optimization, not a stored last-success checkpoint.

Build caches use the check, OS, Swift version, manifests/resolution, CI configuration
and commit as their exact identity. Each new successful default-branch revision
refreshes the immutable cache; restores prefer a matching manifest/configuration
before falling back to the same check/toolchain. Failed builds do not replace the
last successful tree. This avoids freezing the build tree at the first commit
that used a given manifest.

For independently reproduced Linux dependency/runtime leaks,
`swift.linuxLeakSuppressions` accepts additional stack **symbols**, not wildcards
or suppression-file syntax. Keep a standalone reproduction and removal condition
in the consuming repository. These additions apply only to Linux ASan, alongside
the documented runtime defaults; all other leak reports remain enabled.

The Linux ThreadSanitizer run suppresses one report, `race:AemiKernel14ByteBufferPool`: a pool of buffers behind a
`Synchronization.Mutex`, which ThreadSanitizer (Swift 6.4.1, Linux) does not model, so it reports every access to the
guarded value as a Swift access race. A program of a few lines with a `Mutex`-guarded array and eight threads reproduces it,
and it makes any command-line run that encodes JSON on two threads exit 66 under the sanitizer, with its tests failing on
the exit code. A race anywhere else is still reported.

Linux executable archives link with an `$ORIGIN` runtime search path so their
bundled Swift libraries are discoverable after extraction. The root-action CI
smoke runs the real archive command in a disposable container, verifies its
checksum, hides the installed Swift runtime and executes the extracted binary.
Runtime copy errors are fatal rather than silently producing incomplete bundles.

### Naming convention

Workflows use `CI`; the reusable workflow and action use `Swift CI`. Caller jobs
are labelled `Checks`. Shared jobs read `Plan`, `Gate`, `Release`, or
`<Purpose> · <Mode> · <Platform> · <Toolchain>` (for example,
`Tests · Debug · Linux · Swift 6.4.1`). Advisory jobs retain an explicit marker.

Specialized jobs use the same purpose vocabulary: `Compatibility`, `Integration`,
`Generated Sources`, `Kernels`, `Conformance`, `Verification`, `Performance`,
`Mutation`, `Fuzzing`, `Coverage`, and `Documentation`. Steps use verb-led labels
such as `Setup · Install Swift`, `Cache · Restore SwiftPM`, and
`Artifacts · Upload Archives`. Custom commands may set `title` for this label;
`id` remains their stable CLI/configuration identity.

Display labels are separate from job IDs, CLI IDs, cache namespaces and artifact
names. Renaming display labels **does change Actions check-run names**: repositories
with required status contexts must update those contexts before adopting a naming
revision. Use the shared `Gate` or repository aggregate gate rather than requiring
every matrix-expanded label. Names alone do not change check coverage or cadence.

## Several packages in one repository

Call the reusable workflow once per package with `package-path`; each package keeps its own `.ci/action.json` and
`.ci/swift-ci`. Runs, caches, archives and change detection are scoped to the package (a change outside it is not
its change), so two calls in one run never cancel or overwrite each other:

```yaml
jobs:
  core:
    name: AtelierCore
    uses: g-cqd/swift-ci/.github/workflows/swift-ci.yml@<commit>
    with: { package-path: Packages/AtelierCore }
```
