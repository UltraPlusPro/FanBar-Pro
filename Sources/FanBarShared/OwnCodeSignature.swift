import CryptoKit
import Foundation
import Security

/// Reads the running process's own code signature.
public enum OwnCodeSignature {
    /// The signing team, or nil for unsigned and ad-hoc builds.
    public static func teamIdentifier() -> String? {
        signingInformation()?[kSecCodeInfoTeamIdentifier] as? String
    }

    /// The signing identifier codesign recorded, or nil when unsigned.
    public static func identifier() -> String? {
        signingInformation()?[kSecCodeInfoIdentifier] as? String
    }

    /// SHA-1 of the leaf signing certificate, formatted the way
    /// `codesign -d -r-` prints it (`certificate leaf = H"…"`), or nil for
    /// unsigned and ad-hoc builds.
    ///
    /// A locally issued certificate — this project's `Local QA Code Signing` —
    /// carries no team identifier, so a Team-based designated requirement
    /// cannot describe it. Pinning the leaf certificate instead still proves
    /// *who* signed the helper, which is what the root install script checks
    /// before launchd is allowed to run that code as root.
    public static func leafCertificateSHA1() -> String? {
        guard let certificates = signingInformation()?[kSecCodeInfoCertificates] as? [SecCertificate],
              let leaf = certificates.first
        else { return nil }
        let digest = Insecure.SHA1.hash(data: SecCertificateCopyData(leaf) as Data)
        return digest.map { String(format: "%02X", $0) }.joined()
    }

    private static func signingInformation() -> [CFString: Any]? {
        var ownCode: SecCode?
        guard SecCodeCopySelf([], &ownCode) == errSecSuccess,
              let ownCode
        else { return nil }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(ownCode, [], &staticCode) == errSecSuccess,
              let staticCode
        else { return nil }

        var signingInformation: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInformation
        ) == errSecSuccess,
            let information = signingInformation as? [CFString: Any]
        else { return nil }
        return information
    }
}
