import Foundation
import Crypto

/// AES-GCM encryption for the consolidation API key at rest. The symmetric key is derived from
/// the server's bearer token via HKDF, so the key never lives in the DB — copying the sqlite file
/// cannot reveal the API key without the bearer token.
public struct ConfigCrypto {
    private let key: SymmetricKey

    public init(bearerToken: String) {
        let ikm = SymmetricKey(data: Data(bearerToken.utf8))
        self.key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm,
            salt: Data("model-config-key".utf8),
            info: Data("apiKey".utf8),
            outputByteCount: 32)
    }

    /// Returns the AES-GCM `combined` blob (nonce + ciphertext + tag).
    public func seal(_ plaintext: String) throws -> Data {
        let sealed = try AES.GCM.seal(Data(plaintext.utf8), using: key)
        guard let combined = sealed.combined else { throw CryptoError.sealFailed }
        return combined
    }

    public func open(_ blob: Data) throws -> String {
        let box = try AES.GCM.SealedBox(combined: blob)
        let data = try AES.GCM.open(box, using: key)
        return String(decoding: data, as: UTF8.self)
    }

    public enum CryptoError: Error { case sealFailed }
}
