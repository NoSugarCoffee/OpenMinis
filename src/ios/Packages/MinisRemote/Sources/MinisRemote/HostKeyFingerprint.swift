import Crypto
import Foundation

public enum HostKeyFingerprintError: Error, Equatable {
    case malformedPublicKey(String)
}

public enum HostKeyFingerprint {
    /// Matches `ssh-keygen -lf`: "SHA256:" + unpadded base64 of the SHA-256 of the decoded key blob.
    public static func sha256(openSSHPublicKey: String) throws -> String {
        let fields = openSSHPublicKey.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 2, let blob = Data(base64Encoded: String(fields[1])), !blob.isEmpty else {
            throw HostKeyFingerprintError.malformedPublicKey(
                "Expected an OpenSSH public-key line '<type> <base64> [comment]', got '\(openSSHPublicKey)'.")
        }
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + digest.replacingOccurrences(of: "=", with: "")
    }
}
