# Privacy Policy

`swift-ci` is an open-source Reusable Swift GitHub Actions workflow and release verification CLI, licensed under the MIT License.

## Data Collection and Telemetry

- **No telemetry or analytics:** `swift-ci` does not collect, log, store, or transmit usage analytics, crash reports, or personal data to the maintainers or any third party.
- **No accounts or tracking:** `swift-ci` does not require accounts, registration, cookies, or tracking identifiers.
- **Network behavior:** `swift-ci` only contacts GitHub endpoints explicitly configured by the user or CI workflow (such as downloading pinned, SHA-256-verified tool archives from `ToolLock.swift` or publishing release assets when invoked in a release workflow).

## Data Processed Locally

When invoked locally or inside your CI runner, `swift-ci` processes repository paths, configuration files (`.ci/action.json`), and build/test output solely within the execution environment controlled by the user or organization.

## GDPR and Enterprise Compliance

Because `swift-ci` does not transmit personal data to external servers operated by the maintainers, no personal data leaves the user's or organization's own infrastructure when running `swift-ci`.

## Contact

For privacy or security inquiries, see [`SECURITY.md`](SECURITY.md).
