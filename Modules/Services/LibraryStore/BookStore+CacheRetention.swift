import Foundation

/// Automatic cache cleanup needs to know which books' chapters must be kept.
///
/// `BookStore` is the shelf's owner, but its `records` and load-completeness flag are
/// private. This conformance uses the store's public `books` list instead, which is the
/// same shelf the reader draws, and stays in its own file so the store's own logic
/// (membership, glass review panels, offline downloads) is untouched.
@MainActor
extension BookStore: CacheRetentionOwner {
    func cacheRetention() -> CacheRetention? {
        var kept = Set<UUID>()
        var lastOpened: [UUID: Date] = [:]
        for book in books {
            if let opened = book.lastOpenedDate { lastOpened[book.id] = opened }
            // A shelf book downloaded (or being downloaded) for offline reading must keep
            // its chapters: deleting them would break reading with no network.
            if book.isInBookshelf,
               book.offlineDownloadState != .none || book.offlineDownloadTask != nil {
                kept.insert(book.id)
            }
        }
        return CacheRetention(keptBooks: kept, lastOpened: lastOpened)
    }
}
