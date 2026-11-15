import AppKit
import RoostCore

struct SpaceInfo: Hashable {
    var id: CGSSpaceID
    var uuid: String
    var displayUUID: String
    /// Position among the regular desktops of its display (0-based).
    var indexOnDisplay: Int
    /// Mission Control's "Desktop N" number (1-based, counted across displays).
    var number: Int
    var isFullscreen: Bool

    var nameKey: String { SpaceIdentity.key(uuid: uuid, displayUUID: displayUUID, index: indexOnDisplay) }
    var defaultName: String { isFullscreen ? "Full Screen" : "Desktop \(number)" }
}

struct DisplaySpaces {
    var displayUUID: String
    var spaces: [SpaceInfo]
    var currentSpaceID: CGSSpaceID?

    var currentSpace: SpaceInfo? { spaces.first { $0.id == currentSpaceID } }
}

struct SpacesState {
    var displays: [DisplaySpaces]
    var activeSpaceID: CGSSpaceID?

    var all: [SpaceInfo] { displays.flatMap(\.spaces) }
    var activeSpace: SpaceInfo? { activeSpaceID.flatMap(space(id:)) }

    func space(id: CGSSpaceID) -> SpaceInfo? { all.first { $0.id == id } }

    func space(uuid: String) -> SpaceInfo? {
        uuid.isEmpty ? nil : all.first { $0.uuid == uuid }
    }

    func space(displayUUID: String, index: Int) -> SpaceInfo? {
        displays.first { $0.displayUUID == displayUUID }?.spaces.first { !$0.isFullscreen && $0.indexOnDisplay == index }
    }

    func currentSpace(displayUUID: String) -> SpaceInfo? {
        displays.first { $0.displayUUID == displayUUID }?.currentSpace
    }

    static func current() -> SpacesState {
        let mainUUID = Displays.mainDisplayUUID ?? "Main"
        var number = 0
        var displays: [DisplaySpaces] = []

        for entry in CGS.managedDisplaySpaces() {
            var displayUUID = (entry["Display Identifier"] as? String ?? "Main").uppercased()
            // "Main" means "Displays have separate Spaces" is off: one set of Spaces spans all displays.
            if displayUUID == "MAIN" { displayUUID = mainUUID }
            let current = ((entry["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? NSNumber)?.uint64Value

            var index = 0
            var spaces: [SpaceInfo] = []
            for raw in entry["Spaces"] as? [[String: Any]] ?? [] {
                guard let id = ((raw["ManagedSpaceID"] ?? raw["id64"]) as? NSNumber)?.uint64Value else { continue }
                let type = (raw["type"] as? NSNumber)?.intValue ?? 0
                let isFullscreen = type == 4 || raw["TileLayoutManager"] != nil
                if !isFullscreen { number += 1 }
                spaces.append(SpaceInfo(id: id, uuid: raw["uuid"] as? String ?? "", displayUUID: displayUUID,
                                        indexOnDisplay: isFullscreen ? -1 : index, number: isFullscreen ? 0 : number,
                                        isFullscreen: isFullscreen))
                if !isFullscreen { index += 1 }
            }
            displays.append(DisplaySpaces(displayUUID: displayUUID, spaces: spaces, currentSpaceID: current))
        }
        return SpacesState(displays: displays, activeSpaceID: CGS.activeSpaceID())
    }
}
