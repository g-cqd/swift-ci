#!/bin/bash
# Run in a disposable Swift Linux container as root. Exercises the real CLI archive,
# then hides the installed runtime to prove the bundled libraries are discoverable.
set -euo pipefail
if [[ "$(uname -s)" != Linux || "${SWIFT_CI_DISPOSABLE_CONTAINER:-}" != 1 ]]; then
    echo 'Requires a disposable Linux container with SWIFT_CI_DISPOSABLE_CONTAINER=1' >&2
    exit 2
fi
root="$(cd "$(dirname "$0")/../.." && pwd)"
cli="$(swift build -c release --package-path "$root" --show-bin-path)/swift-ci"
work="$(mktemp -d)"
runtime=/usr/lib/swift/linux
restore() {
    if [[ -d "$runtime-hidden" ]]; then mv "$runtime-hidden" "$runtime"; fi
    rm -rf "$work"
}
trap restore EXIT
mkdir -p "$work/Sources/probe" "$work/.ci"
cat > "$work/Package.swift" <<'SWIFT'
// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "probe", products: [.executable(name: "probe", targets: ["probe"])], targets: [.executableTarget(name: "probe")])
SWIFT
printf 'import Foundation\nprint("1.0.0")\n' > "$work/Sources/probe/main.swift"
printf '{"release":{"executables":["probe"]}}\n' > "$work/.ci/action.json"
# Explicitly no Actions context or inferred tag: the smoke archive is never published.
(cd "$work" && env -u GITHUB_ACTIONS -u GITHUB_REF "$cli" run archive-linux)
archive="$work/.build/swift-ci/dist/probe-1.0.0-linux-$(uname -m).tar.gz"
(cd "$(dirname "$archive")" && sha256sum -c "$(basename "$archive").sha256")
mkdir "$work/unpacked"
tar -xzf "$archive" -C "$work/unpacked"
mv "$runtime" "$runtime-hidden"
actual="$(cd / && env -u LD_LIBRARY_PATH "$work/unpacked/probe-1.0.0-linux-$(uname -m)/probe")"
[[ "$actual" == 1.0.0 ]]
echo 'Linux archive checksum and relocated runtime smoke passed'
