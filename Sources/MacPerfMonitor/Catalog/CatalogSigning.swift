import CryptoKit
import Foundation

/// Shared trust anchor for our signed, server-hosted data catalogs (the diagnostic
/// check catalog and the process glossary). Both are downloaded from our server and
/// verified here against a single bundled Ed25519 public key — the matching private
/// key (`catalog-signing.pem`) lives only on the build/publish machine, so a
/// compromised server or CDN cannot forge or alter either catalog.
enum CatalogSigning {
    /// Base64 of the 32-byte raw Ed25519 public key (NOT the Sparkle key).
    static let publicKeyBase64 = "eqvpGyHF+9DyHNJjYhexXhRS99/cWfQ7P+D6DK8VJbU="

    /// True iff `signatureBase64` is a valid Ed25519 signature over `data`.
    static func verify(_ data: Data, signatureBase64: String) -> Bool {
        let trimmed = signatureBase64.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let keyData = Data(base64Encoded: publicKeyBase64),
            let signature = Data(base64Encoded: trimmed),
            let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        else { return false }
        return key.isValidSignature(signature, for: data)
    }
}
