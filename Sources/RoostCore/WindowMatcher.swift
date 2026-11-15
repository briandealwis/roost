import Foundation

/// A window that exists right now and could be put back.
public struct WindowCandidate: Hashable {
    public var windowID: UInt32
    public var pid: Int32
    public var bundleID: String?
    public var title: String?
    public var ordinal: Int

    public init(windowID: UInt32, pid: Int32, bundleID: String?, title: String?, ordinal: Int) {
        self.windowID = windowID
        self.pid = pid
        self.bundleID = bundleID
        self.title = title
        self.ordinal = ordinal
    }
}

public struct WindowMatch: Hashable {
    public var record: WindowRecord
    public var candidate: WindowCandidate
}

public enum WindowMatcher {
    /// Pairs saved records with live windows, each used at most once:
    /// 1. same WindowServer id and process (survives sleep / display changes),
    /// 2. same app and same non-empty title (survives app relaunch),
    /// 3. same app and same front-to-back position (last resort).
    public static func match(records: [WindowRecord], candidates: [WindowCandidate]) -> [WindowMatch] {
        var matches: [WindowMatch] = []
        var remainingRecords = records
        var remainingCandidates = candidates

        func pass(_ isMatch: (WindowRecord, WindowCandidate) -> Bool) {
            var unmatched: [WindowRecord] = []
            for record in remainingRecords {
                if let i = remainingCandidates.firstIndex(where: { isMatch(record, $0) }) {
                    matches.append(WindowMatch(record: record, candidate: remainingCandidates.remove(at: i)))
                } else {
                    unmatched.append(record)
                }
            }
            remainingRecords = unmatched
        }

        pass { r, c in r.windowID == c.windowID && r.pid == c.pid }
        pass { r, c in
            guard let bundle = r.bundleID, bundle == c.bundleID,
                  let title = r.title, !title.isEmpty else { return false }
            return title == c.title
        }
        pass { r, c in r.bundleID != nil && r.bundleID == c.bundleID && r.ordinal == c.ordinal }
        return matches
    }
}
