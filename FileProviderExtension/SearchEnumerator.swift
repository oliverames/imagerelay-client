@preconcurrency import FileProvider
import ImageRelayKit
import os.log

#if compiler(>=6.2)
final class SearchEnumerator: NSObject, NSFileProviderSearchEnumerator, @unchecked Sendable {
    private let logger = Logger(subsystem: "com.oliverames.imagerelay-client.fileprovider", category: "SearchEnumerator")
    private let query: String
    private let desiredNumberOfResults: Int
    private let db: SyncDatabase
    private var invalidated = false

    init(request: NSFileProviderStringSearchRequest, db: SyncDatabase) {
        self.query = request.query
        self.desiredNumberOfResults = request.desiredNumberOfResults
        self.db = db
        super.init()
    }

    func invalidate() {
        invalidated = true
    }

    func enumerateSearchResults(
        for observer: NSFileProviderSearchEnumerationObserver,
        startingAt page: NSFileProviderPage?
    ) {
        guard !invalidated else {
            observer.finishEnumerating(upTo: nil)
            return
        }

        let observerLimit = max(observer.maximumNumberOfResultsPerPage, 1)
        let requestedLimit = desiredNumberOfResults > 0 ? desiredNumberOfResults : observerLimit
        let limit = min(observerLimit, requestedLimit)

        do {
            let results = try db.searchItems(matching: query, limit: limit)
                .map { FileProviderItem(trackedItem: $0) }
            logger.info("Enumerated \(results.count, privacy: .public) cached search results for query length \(self.query.count, privacy: .public)")
            observer.didEnumerate(results)
            observer.finishEnumerating(upTo: nil)
        } catch {
            logger.error("Cached File Provider search failed: \(error.localizedDescription, privacy: .public)")
            observer.finishEnumeratingWithError(error.asFileProviderError)
        }
    }
}
#endif
