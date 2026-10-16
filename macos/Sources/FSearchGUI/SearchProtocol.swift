import Foundation

enum SearchMode: String, CaseIterable, Identifiable {
    case names = "File names"
    case content = "Contents"
    var id: Self { self }
}

struct SearchFilters: Equatable {
    enum Kind: String, CaseIterable, Identifiable {
        case all = "All kinds", files = "Files", folders = "Folders", images = "Images"
        case documents = "Documents", pdf = "PDF", code = "Source code", audio = "Audio"
        case video = "Video", archives = "Archives", applications = "Applications"
        var id: Self { self }
    }
    enum Modified: String, CaseIterable, Identifiable {
        case any = "Any time", day = "Last 24 hours", week = "Last 7 days", month = "Last 30 days"
        var id: Self { self }
        var value: String? {
            switch self {
            case .any: return nil
            case .day: return "<1d"
            case .week: return "<7d"
            case .month: return "<30d"
            }
        }
    }
    enum Size: String, CaseIterable, Identifiable {
        case any = "Any size", small = "Under 1 MB", medium = "1–100 MB", large = "Over 100 MB", huge = "Over 1 GB"
        var id: Self { self }
        var value: String? {
            switch self {
            case .any: return nil
            case .small: return "<1mb"
            case .medium: return "1mb..100mb"
            case .large: return ">100mb"
            case .huge: return ">1gb"
            }
        }
    }

    var kind = Kind.all
    var modified = Modified.any
    var size = Size.any
    var isActive: Bool { self != SearchFilters() }

    func apply(to request: inout SearchRequest) {
        switch kind {
        case .all: break
        case .files: request.kind = "file"
        case .folders: request.kind = "dir"
        case .images: request.fileType = "image"
        case .documents: request.fileType = "doc"
        case .pdf: request.ext = "pdf"
        case .code: request.fileType = "code"
        case .audio: request.fileType = "audio"
        case .video: request.fileType = "video"
        case .archives: request.fileType = "archive"
        case .applications: request.fileType = "app"
        }
        request.mtime = modified.value
        request.size = size.value
    }
}

struct SearchRequest: Encodable, Sendable {
    var op: String = "search"
    var q: String?
    var pattern: String?
    var scope: String?
    var limit: Int = 100
    var offset: Int?
    var cursor: Int?
    var mode: String?
    var path: String?
    var progress: Bool?
    var openedOnly: Bool?
    var kind: String?
    var fileType: String?
    var ext: String?
    var mtime: String?
    var size: String?

    enum CodingKeys: String, CodingKey {
        case op, q, pattern, limit, offset, cursor, mode, path, progress, kind, ext, mtime, size
        case scope = "in"
        case fileType = "type"
        case openedOnly = "opened_only"
    }

    static func search(query: String, mode: SearchMode, scope: String?, next: Int? = nil, filters: SearchFilters = SearchFilters()) -> Self {
        let empty = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if empty && !filters.isActive { return Self(op: "recent", scope: scope, openedOnly: true) }
        var request: Self
        if empty || mode == .names {
            request = Self(q: empty ? "" : query, scope: scope, offset: next ?? 0)
        } else {
            request = Self(op: "grep", pattern: query, scope: scope, cursor: next, mode: "literal")
        }
        filters.apply(to: &request)
        return request
    }
}

struct IndexStatus: Decodable, Sendable {
    let ready: Bool
    let replaying: Bool
    let contentReady: Bool
    let listed: UInt64
    let entries: UInt64
    let overlay: UInt64
    let removed: UInt64
    let indexBytes: UInt64
    let contentDocs: UInt64
    let contentBytes: UInt64
    let contentPending: UInt64
    let fullDiskAccess: Bool
    let owner: Bool

    enum CodingKeys: String, CodingKey {
        case ready, replaying, listed, entries, overlay, removed, owner
        case contentReady = "content_ready"
        case indexBytes = "index_bytes"
        case contentDocs = "content_docs"
        case contentBytes = "content_bytes"
        case contentPending = "content_pending"
        case fullDiskAccess = "full_disk_access"
    }

    var entryCount: UInt64 { (entries > removed ? entries - removed : 0) + overlay }
    var isBusy: Bool { !ready || replaying || !contentReady || contentPending > 0 }
    var summary: String {
        if !ready { return "Scanning file names…" }
        if replaying { return "Catching up on changes…" }
        if !owner { return "Following shared index" }
        if !contentReady || contentPending > 0 { return "Indexing file contents…" }
        return "Up to date"
    }
}

struct LineMatch: Decodable, Sendable, Hashable {
    let line: Int
    let text: String
}

struct SearchHit: Decodable, Identifiable, Sendable, Hashable {
    let path: String
    var kind: String?
    var size: UInt64?
    var mtime: Double?
    var matches: [LineMatch]?
    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.lastPathComponent }
    var parent: String { (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath }
}

struct SearchReply: Decodable, Sendable {
    let ok: Bool
    var error: String?
    var hits: [SearchHit]?
    var files: [SearchHit]?
    var next: Int?
    var took_us: Double?
    var indexing: Int?
    var complete: Bool?
    var results: [SearchHit] { hits ?? files ?? [] }
}

enum SearchFailure: LocalizedError {
    case missingExecutable, disconnected, timeout, invalidReply, backend(String)
    var errorDescription: String? {
        switch self {
        case .missingExecutable: return "The built-in search engine is missing. Reinstall FSearch or rebuild the complete app."
        case .disconnected: return "The built-in search engine stopped unexpectedly. Try again to restart it."
        case .timeout: return "The search took too long. The index may still be building; try again shortly."
        case .invalidReply: return "The built-in search engine returned an invalid response."
        case .backend(let message): return message
        }
    }
}
