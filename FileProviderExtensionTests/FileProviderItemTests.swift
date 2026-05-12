import FileProvider
import Foundation
import Testing
@testable import ImageRelayKit

/// Pins the on-demand cloud-storage `contentPolicy` choices that ship with the
/// File Provider extension. The defaults on macOS 13+ already produce the
/// iCloud-style experience (root inherits `.downloadLazily`), but we set the
/// policy explicitly per item type so a future SDK default change does not
/// silently flip our behavior. If one of these expectations starts failing,
/// the policy is being changed -- make sure that is intentional.
@Suite("FileProviderItem content policy")
struct FileProviderItemTests {

    @Test("File items download lazily and refresh on remote update")
    func fileItemIsLazy() {
        let file = RemoteFile(
            id: 42,
            name: "logo.png",
            size: 1024,
            updatedOn: "2026-05-12T00:00:00Z",
            contentType: "image/png",
            fileTypeID: 1
        )
        let item = FileProviderItem(file: file, parentItemIdentifier: .rootContainer)
        #expect(item.contentPolicy == .downloadLazily)
    }

    @Test("Folder items inherit policy from parent")
    func folderItemInherits() {
        let folder = RemoteFolder(
            id: 7,
            name: "Brand",
            parentID: nil,
            path: "Brand",
            updatedOn: nil
        )
        let item = FileProviderItem(folder: folder, parentItemIdentifier: .rootContainer)
        #expect(item.contentPolicy == .inherited)
    }

    @Test("Synthetic root container inherits policy")
    func syntheticRootInherits() {
        let item = FileProviderItem(containerIdentifier: .rootContainer, filename: "Image Relay")
        #expect(item.contentPolicy == .inherited)
    }
}
