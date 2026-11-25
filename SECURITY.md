# Security Policy

## Scope

`swift-ci` provides reusable GitHub Actions workflows and a Swift CLI for formatting, linting, static analysis, binary signing/checksum verification, release-note checking, and multi-repository family dependency repinning.

- Released analyzer binaries are verified against pinned SHA-256 checksums in `ToolLock.swift`.
- Workflows run with minimal explicit permissions.

## Reporting a Vulnerability

Report security issues privately via [GitHub Security Advisories](https://github.com/g-cqd/swift-ci/security/advisories/new).
