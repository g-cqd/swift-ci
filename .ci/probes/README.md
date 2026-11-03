# Linux Foundation empty-file read leak

Reproduced with `swift:6.4.1-noble` on ARM64 locally and x86_64 in Actions.
Compile `EmptyFileRead.swift` with `swiftc -sanitize=address -g` and run it
without LSAN_OPTIONS. Three reads leak 12,288 bytes in three allocations,
all rooted at `FoundationEssentials17readBytesFromFile`. A nonempty file does
not reproduce it. Both `Data(contentsOf:)` and `String(contentsOf:encoding:)`
reach this Foundation implementation.

The Linux address check suppresses allocations whose stack includes this
specific Foundation function. This necessarily excludes *all* leaks rooted
there, not only empty-file reads; it does not disable LeakSanitizer or suppress
project allocations generally. Remove this suppression when the supported
Swift runtime fixes the empty-read leak.
