import Foundation

public struct RemoteHostConfig: Codable, Hashable, Sendable {
    /// Unique, matches [A-Za-z0-9_-]{1,32}.
    public let name: String
    public let address: String
    public let port: Int
    public let user: String
    /// Secret-store account of the private key.
    public let keyRef: String
    /// OpenSSH public-key line; nil until the host is trusted.
    public let pinnedHostKey: String?
    /// `uname -s` from the host setup checks; nil until they run. Absent in files written before this field.
    public let os: String?

    public init(
        name: String, address: String, port: Int, user: String, keyRef: String, pinnedHostKey: String?, os: String?
    ) {
        self.name = name
        self.address = address
        self.port = port
        self.user = user
        self.keyRef = keyRef
        self.pinnedHostKey = pinnedHostKey
        self.os = os
    }
}
