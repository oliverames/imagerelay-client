import Foundation

enum ImageRelayAPIPath {
    static func deleteFolder(_ folderID: Int) -> String {
        "/folder/\(folderID)"
    }
}
