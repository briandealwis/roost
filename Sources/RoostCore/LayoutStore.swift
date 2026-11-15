import CoreGraphics
import Foundation

/// Persists one layout per display configuration.
public final class LayoutStore {
    private struct FileFormat: Codable {
        var version: Int
        var layouts: [SavedLayout]
    }

    public private(set) var layouts: [String: SavedLayout] = [:]
    private let fileURL: URL?

    public init(fileURL: URL?) {
        self.fileURL = fileURL
        load()
    }

    public var sortedLayouts: [SavedLayout] {
        layouts.values.sorted { $0.lastSeen > $1.lastSeen }
    }

    public func layout(for key: String) -> SavedLayout? {
        layouts[key]
    }

    /// Stores `snapshot` for `configuration`.
    /// An empty snapshot never replaces a non-empty one (e.g. right after login, before apps
    /// have opened their windows); it only refreshes `lastSeen`.
    public func save(_ snapshot: LayoutSnapshot, for configuration: DisplayConfiguration, at now: Date = Date()) {
        let key = configuration.key
        if snapshot.windows.isEmpty, var existing = layouts[key], !existing.snapshot.windows.isEmpty {
            existing.lastSeen = now
            layouts[key] = existing
        } else {
            layouts[key] = SavedLayout(configuration: configuration, snapshot: snapshot, lastSeen: now)
        }
        persist()
    }

    public func markSeen(_ key: String, at now: Date = Date()) {
        guard layouts[key] != nil else { return }
        layouts[key]?.lastSeen = now
        persist()
    }

    public func remove(key: String) {
        layouts[key] = nil
        persist()
    }

    /// Drops layouts whose display configuration hasn't been seen within `retention`.
    /// `nil` retention keeps everything. Returns the removed keys.
    @discardableResult
    public func prune(retention: TimeInterval?, now: Date = Date(), keeping currentKey: String? = nil) -> [String] {
        guard let retention else { return [] }
        let cutoff = now.addingTimeInterval(-retention)
        let stale = layouts.values
            .filter { $0.lastSeen < cutoff && $0.key != currentKey }
            .map(\.key)
        guard !stale.isEmpty else { return [] }
        stale.forEach { layouts[$0] = nil }
        persist()
        return stale
    }

    private func load() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(FileFormat.self, from: data) else { return }
        layouts = Dictionary(file.layouts.map { ($0.key, $0) }, uniquingKeysWith: { a, b in a.lastSeen > b.lastSeen ? a : b })
    }

    private func persist() {
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try encoder.encode(FileFormat(version: 1, layouts: sortedLayouts))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Non-fatal: we'll try again on the next save.
        }
    }
}
