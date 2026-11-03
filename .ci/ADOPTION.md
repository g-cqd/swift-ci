# Family adoption status

Updated 2026-11-03. This is a verification ledger, not a claim that pending runs pass.

## Migrated

- dolly, deadwood, fcheck, modeler, arcleak: thin pinned callers, `.ci/action.json`,
  formatter/no-GCD/analyzer quality, serial tests, self-analysis on the warm Linux
  debug tree, existing removal/leak/LSP oracles. Archives are tag-only; the heavy
  sanitizer/release matrix also runs nightly.
- AemiRegex: same graph with dev flags plus a flag-free consumer check. The Go
  fixture generator and diff job is retained as an independent oracle. Local
  quality passes without a new baseline. Its first run passed everything except
  Linux LeakSanitizer: Foundation regex allocations and static test-case data
  need investigation; no blanket suppression was added.

## Observed in Actions

- swift-ci at 70f5a41: green, including root action smoke test.
- All five tools: quality, Linux debug, Linux release, macOS debug pass at the
  first migration revisions. modeler at 75d61c6 is fully green.
- Linux ASan exposed two runner/runtime problems rather than justifying disabling
  sanitizers: a relative suppression path inherited by child processes (fixed),
  and a Foundation empty-file read leak (standalone reproduction in `probes/`).
  The latest pins include the latter workaround; all five tool runs are now
  fully green in Actions.
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

## Remaining libraries migrated (first Actions runs pending)

- analyzerkit `f4aff0a`: pinned caller, local tests/quality pass. The clone backlog
  is explicitly accepted at adoption: 150 dolly fingerprints (48 warnings,
  102 notes), committed under `.ci/baselines`, not silently disabled.
- AemiJSON `6873e79`: fixture preparation before test legs, dev/consumer split,
  Foundation-free core check on the consumer tree. Preserves risk-path ASan+UBSan
  and TSan, API checks, exact SDK/triple platform builds, fuzz crash artifacts,
  benchmark baseline controls and Pages. Builds DocC once with link validation
  and deploys that same site. Platform/fuzz/benchmark jobs are scheduled/manual.
- AemiProtobuf (initial `9322505`, cadence `e81fdff`): common graph plus coverage floors and NIO on the warm
  macOS debug tree; no second coverage test run. Retains conformance, model
  proofs, allocation thresholds and mutation on weekly schedule/dispatch. Preserves
  the existing ASan-only depth-test exception. Fixes Linux fixture lookup using
  Bundle resource lookup (resourceURL already includes Resources on Linux).
  Local tests/quality pass; a standalone Linux probe verifies the resource API.
- aemi `cd455e6`: cached Linux product subset, never blanket Linux tests; serial
  macOS debug matrix 6.4.1/6.3.3, primary release weekly/manual for Protobuf. All kernel,
  Embedded, Unicode and script oracles retained, and result now waits for every
  required oracle. Formats modern package paths, explicitly excludes the legacy
  unformatted trees, and does not impose a new legacy analyzer backlog gate.
  Fixes the old shared workflow's invalid SHA context for external consumers.

Each repository's `.ci/README.md` records its cadence and exceptions. All four
configurations validate, plan for push/nightly/dispatch, and pass local quality;
actionlint passes (with only its known unsupported workflow context suppressed).

## Not verified

Tag publishing, dolly's model-inclusive archive, nightly/dispatch heavy matrices,
Apple platform builds and docs deployment have not been exercised by migration
pushes. No timing improvement is claimed before comparable completed runs exist.
