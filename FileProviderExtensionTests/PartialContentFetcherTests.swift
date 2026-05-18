import Foundation
import Testing
@testable import ImageRelayKit

@Suite("PartialContentFetcher")
struct PartialContentFetcherTests {

    // The test target compiles `FileProviderExtension/PartialContentFetching.swift`
    // directly (see Project.yml `FileProviderExtensionTests.sources`), so we can
    // reference the real `PartialContentFetcher.alignedRange` here without rebuilding it.

    @Test("alignedRange snaps lower bound down to the alignment boundary")
    func alignedRangeRoundsLowerDown() {
        let r = PartialContentFetcher.alignedRange(
            covering: NSRange(location: 17, length: 1),
            alignment: 16,
            totalSize: 1024
        )
        #expect(r.location == 16)
    }

    @Test("alignedRange rounds upper bound up to the alignment boundary")
    func alignedRangeRoundsUpperUp() {
        let r = PartialContentFetcher.alignedRange(
            covering: NSRange(location: 0, length: 17),
            alignment: 16,
            totalSize: 1024
        )
        // Aligned upper exclusive should be 32 — so length 32.
        #expect(r.location == 0)
        #expect(r.length == 32)
    }

    @Test("alignedRange clamps to total file size")
    func alignedRangeClampsToFileSize() {
        let r = PartialContentFetcher.alignedRange(
            covering: NSRange(location: 1000, length: 50),
            alignment: 16,
            totalSize: 1024
        )
        // Lower aligns to 992 (multiple of 16 ≤ 1000), upper would be ceil(1050/16)*16 = 1056,
        // clamped to 1024. Length = 1024 - 992 = 32.
        #expect(r.location == 992)
        #expect(r.length == 32)
    }

    @Test("alignedRange returns zero length when start is past EOF")
    func alignedRangeBeyondEOF() {
        let r = PartialContentFetcher.alignedRange(
            covering: NSRange(location: 2000, length: 4),
            alignment: 16,
            totalSize: 1024
        )
        #expect(r.length == 0)
    }

    @Test("alignedRange leaves already-aligned ranges untouched")
    func alignedRangeIdentity() {
        let r = PartialContentFetcher.alignedRange(
            covering: NSRange(location: 64, length: 64),
            alignment: 16,
            totalSize: 1024
        )
        #expect(r.location == 64)
        #expect(r.length == 64)
    }
}
