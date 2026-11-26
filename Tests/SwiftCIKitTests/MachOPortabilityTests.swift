import Foundation
import SwiftCIKit
import Testing

/// The fixture is `otool -l` of a real macOS release executable (apple-docs), reduced to its dylib and rpath commands.
struct MachOPortabilityTests {
    private func plan(existing: Set<String>) throws -> MachOPortability.Plan {
        let otool = try String(contentsOf: fixtures("macho/apple-docs-otool-l.txt"), encoding: .utf8)
        return MachOPortability.plan(otoolLoadCommands: otool) { existing.contains($0) }
    }

    @Test func `back-deployment dylibs linked through rpath are bundled from the first rpath that has them`() throws {
        let xcode =
            "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-6.2/macosx"
        let plan = try plan(existing: ["\(xcode)/libswiftCompatibilitySpan.dylib"])
        #expect(plan.bundled == ["\(xcode)/libswiftCompatibilitySpan.dylib"])
        #expect(plan.unresolved.isEmpty)
    }

    @Test func `build-machine rpaths are removed and the loader path is kept`() throws {
        let plan = try plan(existing: [])
        #expect(
            plan.removedRpaths == [
                "/var/run/cryptex/Metal.xctoolchain/usr/lib/swift-6.2/macosx",
                "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-6.2/macosx"
            ]
        )
        #expect(!plan.addsLoaderPath)
        #expect(plan.unresolved == ["libswiftCompatibilitySpan.dylib"])
    }

    @Test func `a binary without a loader-path rpath gets one when it bundles a dylib`() {
        let otool = """
            Load command 1
                      cmd LC_LOAD_DYLIB
                  cmdsize 56
                     name @rpath/libswiftCompatibilitySpan.dylib (offset 24)
            Load command 2
                      cmd LC_RPATH
                  cmdsize 32
                     path /opt/toolchain/lib (offset 12)
            """
        let plan = MachOPortability.plan(otoolLoadCommands: otool) {
            $0 == "/opt/toolchain/lib/libswiftCompatibilitySpan.dylib"
        }
        #expect(plan.bundled == ["/opt/toolchain/lib/libswiftCompatibilitySpan.dylib"])
        #expect(plan.removedRpaths == ["/opt/toolchain/lib"])
        #expect(plan.addsLoaderPath)
    }

    @Test func `a portable binary needs nothing`() {
        let otool = """
            Load command 1
                      cmd LC_LOAD_DYLIB
                  cmdsize 56
                     name /usr/lib/swift/libswiftCore.dylib (offset 24)
            Load command 2
                      cmd LC_RPATH
                  cmdsize 32
                     path /usr/lib/swift (offset 12)
            """
        let plan = MachOPortability.plan(otoolLoadCommands: otool) { _ in true }
        #expect(plan == MachOPortability.Plan(bundled: [], unresolved: [], removedRpaths: [], addsLoaderPath: false))
    }
}
