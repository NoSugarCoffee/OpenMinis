import XCTest
@testable import MinisRemote

final class HostKeyFingerprintTests: XCTestCase {
    func testFingerprintMatchesSshKeygen() throws {
        let line = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAII9R3mn5Qfb2fXXH6JKDCErM3bPgzG84bQs1zfarvOm6 minis@test"
        // Output of `ssh-keygen -lf` for the line above.
        XCTAssertEqual(try HostKeyFingerprint.sha256(openSSHPublicKey: line),
                       "SHA256:ARwr1B4g7MKE3SbI/qwA2d7wL9joFaXAfJwcxBVwCl4")
    }

    func testMalformedLineThrows() {
        XCTAssertThrowsError(try HostKeyFingerprint.sha256(openSSHPublicKey: "ssh-ed25519"))
        XCTAssertThrowsError(try HostKeyFingerprint.sha256(openSSHPublicKey: "ssh-ed25519 !!!notbase64"))
    }
}
