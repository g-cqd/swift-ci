# Working in `swift-ci`

Reusable Swift GitHub Actions workflows, release-verification CLI, and family dependency repinner (`g-cqd/swift-ci`).

## Engineering principles

- **Verify claims with executable checks.** Add a failing test before fixing a bug; confirm rule precision and false-positive regressions on real fixtures.
- **Strictness.** Swift 6 language mode, strict memory safety, warnings as errors, zero force-unwraps on untrusted source inputs.
- **Safety boundaries.** Never execute user code during static analysis; bound file sizes, recursion depth, and memory; keep CLI flags, exit codes, and SARIF/Xcode outputs aligned with `analyzerkit`'s contract.
- **Factual documentation.** Keep `README.md`, `docs/`, and `Package.swift` aligned with the current codebase—no roadmaps or working diaries.

Keep `ToolLock.swift` checksums synchronized with released analyzer tarballs. Never log secrets or tokens in workflow or CLI output.

## Commands

```sh
swift test
swift build -c release --product swift-ci
swift format lint --strict --recursive Sources Tests Package.swift
```
