import SwiftCIKit
import Testing

/// `ldd` output of a release executable built with a swiftly toolchain (runtime outside /usr) and with a Docker one.
struct LinuxRuntimeBundlingTests {
    @Test func `swift runtime libraries are bundled wherever the toolchain lives, system libraries are not`() {
        let ldd = """
            \tlinux-vdso.so.1 (0x0000ffff8a1c0000)
            \tlibsqlite3.so.0 => /lib/aarch64-linux-gnu/libsqlite3.so.0 (0x0000ffff89f00000)
            \tlibswiftCore.so => /home/ci/.local/share/swiftly/toolchains/6.4.3/usr/lib/swift/linux/libswiftCore.so (0x1)
            \tlibFoundation.so => /usr/lib/swift/linux/libFoundation.so (0x2)
            \tlib_FoundationICU.so => /opt/swift/usr/lib/swift/linux/lib_FoundationICU.so (0x3)
            \tlibc.so.6 => /lib/aarch64-linux-gnu/libc.so.6 (0x4)
            \t/lib/ld-linux-aarch64.so.1 (0x5)
            """
        #expect(
            LinuxRuntime.librariesToBundle(lddOutput: ldd) == [
                "/home/ci/.local/share/swiftly/toolchains/6.4.3/usr/lib/swift/linux/libswiftCore.so",
                "/usr/lib/swift/linux/libFoundation.so",
                "/opt/swift/usr/lib/swift/linux/lib_FoundationICU.so"
            ]
        )
    }
}
