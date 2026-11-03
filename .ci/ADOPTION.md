# Family adoption status

Updated 2026-11-03. This is a verification ledger, not a claim that pending runs pass.

## Migrated

- dolly, deadwood, fcheck, modeler, arcleak: thin pinned callers, `.ci/action.json`,
  formatter/no-GCD/analyzer quality, serial tests, self-analysis on the warm Linux
  debug tree, existing removal/leak/LSP oracles. Archives are tag-only; the heavy
  sanitizer/release matrix also runs nightly.
- AemiRegex: same graph with dev flags plus a flag-free consumer check. The Go
  fixture generator and diff job is retained as an independent oracle. Local
  quality passes without a new baseline; first Actions run pending.

## Observed in Actions

- swift-ci at 70f5a41: green, including root action smoke test.
- All five tools: quality, Linux debug, Linux release, macOS debug pass at the
  first migration revisions. modeler at 75d61c6 is fully green.
- Linux ASan exposed two runner/runtime problems rather than justifying disabling
  sanitizers: a relative suppression path inherited by child processes (fixed),
  and a Foundation empty-file read leak (standalone reproduction in `probes/`).
  The latest pins include the latter workaround; results pending.
- arcleak's deliberately cyclic deinit canary now breaks the cycle *after* proving
  it survives, and verifies deallocation. Its three local canary tests pass.

## Accepted existing analyzer backlog

These are adoption baselines, not fixes or proof that findings are false:

| Repository | Analyzer | Fingerprints |
| --- | --- | ---: |
| dolly | deadwood | 8 |
| deadwood | dolly | 39 |
| fcheck | dolly | 12 |
| modeler | dolly | 25 |
| arcleak | dolly | 57 |

## Not migrated yet

- analyzerkit: local quality finds 48 dolly warnings and 102 notes. Review or
  explicitly accept the backlog before enabling the new gate.
- AemiJSON: preserve fixture preparation before each test/build leg, platform
  builds, docs publishing, fuzzing and benchmarks. A pre-check hook is needed;
  after-check hooks are too late for downloading test fixtures.
- AemiProtobuf: preserve conformance, NIO, proof/model checks and allocation
  benchmarks; diagnose the existing failing Linux workflow before replacement.
- aemi: preserve kernel/Embedded/Unicode checks and its Linux subset. A blanket
  `swift test` is not valid for its Apple-only legacy targets; old formatting
  exclusions also must be retained rather than reformatting unrelated code.

## Not verified

Tag publishing, dolly's model-inclusive archive, nightly/dispatch heavy matrices,
Apple platform builds and docs deployment have not been exercised by migration
pushes. No timing improvement is claimed before comparable completed runs exist.
