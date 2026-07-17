import Darwin
import Foundation

@main
enum WindowSpaceMembershipTests {
    static func main() {
        expect(
            WindowSpaceMembership.isRemoteRecoveryCandidate(spaceIDs: nil),
            "an unavailable Space query should fail open"
        )
        expect(
            !WindowSpaceMembership.isRemoteRecoveryCandidate(spaceIDs: []),
            "a successful empty Space query should exclude the remote candidate"
        )
        expect(
            WindowSpaceMembership.isRemoteRecoveryCandidate(spaceIDs: [42]),
            "a user-Space assignment should keep the remote candidate"
        )
        print("WindowSpaceMembershipTests: passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }
}
