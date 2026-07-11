import Foundation

enum WindowSpaceMembership {
    static func isRemoteRecoveryCandidate(spaceIDs: [UInt64]?) -> Bool {
        guard let spaceIDs else { return true }
        return !spaceIDs.isEmpty
    }
}
