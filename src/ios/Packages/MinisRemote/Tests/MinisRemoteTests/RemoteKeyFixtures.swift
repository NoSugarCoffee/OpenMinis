// Throwaway keys generated only for these tests; never used with a real host.
enum Fixtures {
    static let publicLine = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHovDN71yyW/xy7XcCsafbX0O7ALu8WojqCOd63U2jeM minis@test"
    static let privatePEM = """
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
QyNTUxOQAAACB6Lwze9cslv8cu13ArGn219DuwC7vFqI6gjnet1No3jAAAAJBemcjWXpnI
1gAAAAtzc2gtZWQyNTUxOQAAACB6Lwze9cslv8cu13ArGn219DuwC7vFqI6gjnet1No3jA
AAAECgvCMLS7ZZyRSt0lJwOkDz5g9alR6k8lTtOIxQfAaBWHovDN71yyW/xy7XcCsafbX0
O7ALu8WojqCOd63U2jeMAAAACm1pbmlzQHRlc3QBAgM=
-----END OPENSSH PRIVATE KEY-----
"""
    // ssh-keygen -a 16 -N pw; Citadel rejects bcrypt rounds >= 18 (macOS ssh-keygen defaults to more).
    static let encryptedPublicLine = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINxhWFdEKTcEN+k18wDGO04Nvq01QEJELOkHD98LqqPB minis@test"
    static let encryptedPrivatePEM = """
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABC+/yNXa7
HFJWB82tZmJwGlAAAAEAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAINxhWFdEKTcEN+k1
8wDGO04Nvq01QEJELOkHD98LqqPBAAAAkCJdstFIlSCk+09nBAMjbJacSDzrbRk1UXBvv2
G+Etbk+xeprU1DZ+hMnokvcO8aTys/Ah9laWLlsv7S3EbodzYNPqDvejHC3ajRMzJOPxFM
AP/uO7UbP50FEPIrtKBWtn0oA7CrV48Fiyq8JO1VZItQ/EdeCwHkru7UHG6rU9R0Aq0avv
5aCAhU+X1PmeEt3Q==
-----END OPENSSH PRIVATE KEY-----
"""

    // ssh-keygen -N pw with default rounds (24 on current OpenSSH).
    static let defaultRoundsEncryptedPrivatePEM = """
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABBa/9JfuD
8MZRagPIycV9BrAAAAGAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAINc056BkTxrJrT02
l6RhGmlb1GLMq7WfhgdvNEZZk18IAAAAkA2bKZA0LNab+79Ya83TzvbfBbfu2TnPu0m8r6
EYM+OHeYBbn8skbquWm4jcJZA+Lrz5Rdua0QxBSNBwYovW/Bt0afp78/j/Rk4EOOVNP2l2
825DjHfOUe28QXYXqkfa3SY8KRmfWk7H6/air1hr2zP6yNmmEjwYx7RwsgOfSCvMfkOzCc
zOhsBD7kg6w+5dNg==
-----END OPENSSH PRIVATE KEY-----
"""
}
