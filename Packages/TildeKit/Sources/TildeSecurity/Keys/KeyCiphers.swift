import CommonCrypto
import CryptoKit
import CTildeBcrypt
import Foundation
import TildeCore

/// Block-cipher modes used to protect private keys at rest (`openssh-key-v1`, legacy PEM, PKCS#8).
enum KeyCipherError: Error {
    case invalidParameters
    case cancelled
    case failed(Int32)
}

/// The ciphers an `openssh-key-v1` file can name. CTR and CBC, both with a 16-byte block.
enum OpenSSHCipher: String {
    case aes128ctr = "aes128-ctr"
    case aes192ctr = "aes192-ctr"
    case aes256ctr = "aes256-ctr"
    case aes128cbc = "aes128-cbc"
    case aes192cbc = "aes192-cbc"
    case aes256cbc = "aes256-cbc"

    var keyLength: Int {
        switch self {
        case .aes128ctr, .aes128cbc: 16
        case .aes192ctr, .aes192cbc: 24
        case .aes256ctr, .aes256cbc: 32
        }
    }

    var ivLength: Int { 16 }
    var blockSize: Int { 16 }

    var isCTR: Bool {
        switch self {
        case .aes128ctr, .aes192ctr, .aes256ctr: true
        default: false
        }
    }

    /// Encrypts or decrypts `data` (a multiple of the block size). CTR is symmetric.
    func crypt(encrypt: Bool, key: [UInt8], iv: [UInt8], data: [UInt8]) throws -> [UInt8] {
        guard key.count == keyLength, iv.count == ivLength, data.count % blockSize == 0 else {
            throw KeyCipherError.invalidParameters
        }
        if isCTR {
            return try AESCrypto.ctr(key: key, counter: iv, data: data)
        }
        return try AESCrypto.cbc(encrypt: encrypt, key: key, iv: iv, data: data)
    }
}

/// Calls `body` with the array's bytes (or `nil`), keeping the pointer inside the closure.
private func withOptionalBytes<R>(_ bytes: [UInt8]?, _ body: (UnsafeRawPointer?) -> R) -> R {
    guard let bytes else { return body(nil) }
    return bytes.withUnsafeBytes { body($0.baseAddress) }
}

enum AESCrypto {
    /// AES-CBC without padding (`data` must be block-aligned).
    static func cbc(encrypt: Bool, key: [UInt8], iv: [UInt8], data: [UInt8]) throws -> [UInt8] {
        try ccCrypt(encrypt: encrypt, algorithm: CCAlgorithm(kCCAlgorithmAES), options: 0, key: key, iv: iv, data: data, blockSize: kCCBlockSizeAES128)
    }

    /// AES in ECB mode, no padding. Only used to build the CTR key stream.
    private static func ecbEncrypt(key: [UInt8], data: [UInt8]) throws -> [UInt8] {
        try ccCrypt(encrypt: true, algorithm: CCAlgorithm(kCCAlgorithmAES), options: CCOptions(kCCOptionECBMode), key: key, iv: nil, data: data, blockSize: kCCBlockSizeAES128)
    }

    /// AES-CTR with a 128-bit big-endian counter, as SSH defines it (RFC 4344).
    static func ctr(key: [UInt8], counter: [UInt8], data: [UInt8]) throws -> [UInt8] {
        let blocks = data.count / 16
        guard blocks > 0 else { return [] }
        var counterBlock = counter
        var stream = [UInt8]()
        stream.reserveCapacity(data.count)
        for _ in 0..<blocks {
            stream.append(contentsOf: counterBlock)
            var index = 15
            while index >= 0 {
                counterBlock[index] &+= 1
                if counterBlock[index] != 0 { break }
                index -= 1
            }
        }
        var keyStream = try ecbEncrypt(key: key, data: stream)
        defer { wipe(&keyStream) }
        return zip(data, keyStream).map { $0 ^ $1 }
    }

    /// 3DES-EDE CBC without padding (legacy PEM only).
    static func tripleDESCBC(encrypt: Bool, key: [UInt8], iv: [UInt8], data: [UInt8]) throws -> [UInt8] {
        try ccCrypt(encrypt: encrypt, algorithm: CCAlgorithm(kCCAlgorithm3DES), options: 0, key: key, iv: iv, data: data, blockSize: kCCBlockSize3DES)
    }

    private static func ccCrypt(
        encrypt: Bool, algorithm: CCAlgorithm, options: CCOptions,
        key: [UInt8], iv: [UInt8]?, data: [UInt8], blockSize: Int
    ) throws -> [UInt8] {
        guard data.count % blockSize == 0 else { throw KeyCipherError.invalidParameters }
        if data.isEmpty { return [] }
        var output = [UInt8](repeating: 0, count: data.count + blockSize)
        var produced = 0
        let status = withOptionalBytes(iv) { ivPointer in
            key.withUnsafeBytes { keyBytes in
                data.withUnsafeBytes { dataBytes in
                    output.withUnsafeMutableBytes { outBytes in
                        CCCrypt(
                            CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), algorithm, options,
                            keyBytes.baseAddress, key.count,
                            ivPointer,
                            dataBytes.baseAddress, data.count,
                            outBytes.baseAddress, outBytes.count, &produced
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw KeyCipherError.failed(status) }
        return Array(output[0..<produced])
    }
}

/// Lets the caller abandon a slow passphrase check (bcrypt-pbkdf with many rounds) from another task.
///
/// `CancellableKeyParsing.parse` installs one for the duration of a parse; `BcryptPBKDF` polls it between rounds.
final class KeyParseCancellation: @unchecked Sendable {
    /// The token for the parse running on the current task, if any.
    @TaskLocal static var current: KeyParseCancellation?

    fileprivate let flag: OpaquePointer

    init() {
        guard let flag = tilde_cancel_create() else { fatalError("Out of memory") }
        self.flag = flag
    }

    deinit { tilde_cancel_destroy(flag) }

    func cancel() { tilde_cancel_request(flag) }
}

/// Parsing that can be cancelled while it is deriving a key. Cancelling the surrounding task makes the parse throw
/// `CancellationError` within one bcrypt round instead of running to the end.
public enum CancellableKeyParsing {
    /// Runs `service.parse(privateKey:passphrase:)` off the caller's actor, honouring task cancellation.
    public static func parse(
        service: any KeyService, privateKey: Data, passphrase: String?
    ) async throws -> (PublicKeyInfo, PrivateKeyMaterial) {
        let token = KeyParseCancellation()
        return try await withTaskCancellationHandler {
            try await run(service: service, privateKey: privateKey, passphrase: passphrase, token: token)
        } onCancel: {
            token.cancel()
        }
    }

    @concurrent
    private static func run(
        service: any KeyService, privateKey: Data, passphrase: String?, token: KeyParseCancellation
    ) async throws -> (PublicKeyInfo, PrivateKeyMaterial) {
        try KeyParseCancellation.$current.withValue(token) {
            try service.parse(privateKey: privateKey, passphrase: passphrase)
        }
    }
}

/// OpenBSD `bcrypt_pbkdf` (the KDF behind `openssh-key-v1` passphrases), backed by the vendored C implementation.
enum BcryptPBKDF {
    /// Registers CryptoKit's SHA-512 with the C code exactly once.
    private static let isInitialised: Bool = {
        tilde_set_crypto_hash_sha512 { output, input, length in
            guard let output, let input else { return }
            let digest = SHA512.hash(data: UnsafeRawBufferPointer(start: input, count: Int(length)))
            digest.withUnsafeBytes { _ = memcpy(output, $0.baseAddress!, 64) }
        }
        return true
    }()

    static func derive(passphrase: [UInt8], salt: [UInt8], rounds: UInt32, outputLength: Int) throws -> [UInt8] {
        guard isInitialised, !passphrase.isEmpty, !salt.isEmpty, rounds > 0, outputLength > 0 else {
            throw KeyCipherError.invalidParameters
        }
        let cancel = KeyParseCancellation.current?.flag
        var output = [UInt8](repeating: 0, count: outputLength)
        let result = passphrase.withUnsafeBufferPointer { pass in
            salt.withUnsafeBufferPointer { saltBytes in
                output.withUnsafeMutableBufferPointer { out in
                    tilde_bcrypt_pbkdf_cancellable(pass.baseAddress, pass.count, saltBytes.baseAddress, saltBytes.count,
                                                   out.baseAddress, out.count, rounds, cancel)
                }
            }
        }
        if result == -2 { throw KeyCipherError.cancelled }
        guard result == 0 else { throw KeyCipherError.invalidParameters }
        return output
    }
}

/// Key derivation used by the legacy PEM and PKCS#8 encryption schemes.
enum LegacyKDF {
    /// OpenSSL's `EVP_BytesToKey` with MD5 and one iteration (legacy `DEK-Info` PEM encryption).
    static func evpBytesToKeyMD5(passphrase: [UInt8], salt: [UInt8], keyLength: Int) -> [UInt8] {
        var derived: [UInt8] = []
        var previous: [UInt8] = []
        while derived.count < keyLength {
            var hasher = Insecure.MD5()
            hasher.update(data: previous)
            hasher.update(data: passphrase)
            hasher.update(data: salt)
            previous = Array(hasher.finalize())
            derived.append(contentsOf: previous)
        }
        return Array(derived.prefix(keyLength))
    }

    /// PBKDF2 (RFC 8018) with the given HMAC `prf` (`kCCPRFHmacAlg*`).
    static func pbkdf2(passphrase: [UInt8], salt: [UInt8], iterations: Int, prf: CCPseudoRandomAlgorithm, keyLength: Int) throws -> [UInt8] {
        var derived = [UInt8](repeating: 0, count: keyLength)
        let status = passphrase.withUnsafeBytes { pass in
            salt.withUnsafeBytes { saltBytes in
                derived.withUnsafeMutableBytes { out in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pass.baseAddress?.assumingMemoryBound(to: Int8.self), passphrase.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                        prf, UInt32(iterations),
                        out.baseAddress?.assumingMemoryBound(to: UInt8.self), keyLength
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw KeyCipherError.failed(status) }
        return derived
    }

    /// Removes PKCS#7 padding; `nil` when the padding is invalid (usually: wrong passphrase).
    static func removePKCS7Padding(_ data: [UInt8], blockSize: Int) -> [UInt8]? {
        guard let last = data.last, last >= 1, Int(last) <= blockSize, Int(last) <= data.count else { return nil }
        guard data.suffix(Int(last)).allSatisfy({ $0 == last }) else { return nil }
        return Array(data.dropLast(Int(last)))
    }
}
