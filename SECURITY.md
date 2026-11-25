# Security Policy

## Scope

`swift-ci` provides reusable GitHub Actions workflows and a Swift CLI for formatting, linting, static analysis, binary signing/checksum verification, release-note checking, and multi-repository family dependency repinning.

- Released analyzer binaries are verified against pinned SHA-256 checksums in `ToolLock.swift`.
- Workflows run with minimal explicit permissions.

## Reporting a Vulnerability

Report security issues privately via [GitHub Security Advisories](https://github.com/g-cqd/swift-ci/security/advisories/new).

## Release Verification & Supply-Chain Integrity

All commits and release tags are signed with GPG key `9FE7C7E8522EE497` (fingerprint: `1BF1 901A 8C67 2E9B C12E 1B31 9FE7 C7E8 522E E497`).

Verify a downloaded release archive and tag before use:

```sh
# 1. Verify the signed Git tag
git tag -v <tag>

# 2. Verify the SHA-256 checksum
shasum -a 256 -c <archive>.sha256

# 3. Verify the GitHub SLSA build provenance attestation (requires gh CLI)
gh attestation verify <archive> --owner g-cqd
```
