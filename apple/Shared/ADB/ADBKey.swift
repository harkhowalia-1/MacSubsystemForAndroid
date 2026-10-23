// Mac Android Subsystem - the RSA key the Mac uses to authenticate to adbd.
//
// adbd sends a 20-byte token; the host signs it with RSA PKCS#1 v1.5 treating the
// token as a SHA-1 digest (Security's .rsaSignatureDigestPKCS1v15SHA1 does exactly
// that). If adbd doesn't know the key yet, the host sends its public key in
// Android's own format (struct RSAPublicKey from libcrypto_utils/android_pubkey.cpp):
//
//   uint32 modulus_size_words   (64 for RSA-2048)
//   uint32 n0inv                (-1 / n[0] mod 2^32)
//   uint8  modulus[256]         little-endian
//   uint8  rr[256]              R^2 mod n, R = 2^2048, little-endian
//   uint32 exponent
//
// base64-encoded and followed by " user@host\0".
//
// Licensed under the GNU General Public License v3 or later.

import Foundation
import Security

final class ADBKey: @unchecked Sendable {
    enum Failure: LocalizedError {
        case generate(String)
        case sign(String)
        case publicKey
        var errorDescription: String? {
            switch self {
            case .generate(let detail): return L10n.format("Couldn't create the ADB key: %@", detail)
            case .sign(let detail): return L10n.format("Couldn't sign the ADB token: %@", detail)
            case .publicKey: return L10n.text("Couldn't read the ADB public key.")
            }
        }
    }

    private let privateKey: SecKey
    /// adb's encoding of the public key, ready to send in AUTH(RSAPUBLICKEY).
    let androidPublicKey: Data

    /// Load the shared key, creating it on first use.
    static func shared() throws -> ADBKey {
        try ADBKey(file: SubsystemPaths.adbKey)
    }

    init(file: URL) throws {
        if let data = try? Data(contentsOf: file), let key = Self.importPrivate(data) {
            privateKey = key
        } else {
            let attributes: [CFString: Any] = [
                kSecAttrKeyType: kSecAttrKeyTypeRSA,
                kSecAttrKeySizeInBits: 2048,
                kSecAttrIsPermanent: false,
            ]
            var error: Unmanaged<CFError>?
            guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
                throw Failure.generate(error?.takeRetainedValue().localizedDescription ?? L10n.text("unknown error"))
            }
            guard let exported = SecKeyCopyExternalRepresentation(key, &error) as Data? else {
                throw Failure.generate(error?.takeRetainedValue().localizedDescription ?? L10n.text("export failed"))
            }
            FileManager.default.createFile(atPath: file.path, contents: exported, attributes: [.posixPermissions: 0o600])
            privateKey = key
        }
        guard let publicKey = SecKeyCopyPublicKey(privateKey),
              let der = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?,
              let (modulus, exponent) = Self.parseRSAPublicKey(der) else { throw Failure.publicKey }
        let encoded = Self.androidEncoding(modulus: modulus, exponent: exponent)
        let comment = " msa@\(ProcessInfo.processInfo.hostName)"
        androidPublicKey = Data((encoded.base64EncodedString() + comment).utf8) + Data([0])
    }

    /// Sign adbd's AUTH token.
    func sign(token: Data) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(privateKey, .rsaSignatureDigestPKCS1v15SHA1, token as CFData, &error) as Data? else {
            throw Failure.sign(error?.takeRetainedValue().localizedDescription ?? L10n.text("unknown error"))
        }
        return signature
    }

    private static func importPrivate(_ data: Data) -> SecKey? {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits: 2048,
        ]
        return SecKeyCreateWithData(data as CFData, attributes as CFDictionary, nil)
    }

    // MARK: DER (RSAPublicKey ::= SEQUENCE { modulus INTEGER, publicExponent INTEGER })

    static func parseRSAPublicKey(_ der: Data) -> (modulus: [UInt8], exponent: UInt32)? {
        let bytes = [UInt8](der)
        var i = 0
        func readLength() -> Int? {
            guard i < bytes.count else { return nil }
            let first = Int(bytes[i]); i += 1
            if first < 0x80 { return first }
            let count = first & 0x7F
            guard count <= 4, i + count <= bytes.count else { return nil }
            var length = 0
            for _ in 0..<count { length = (length << 8) | Int(bytes[i]); i += 1 }
            return length
        }
        func readInteger() -> [UInt8]? {
            guard i < bytes.count, bytes[i] == 0x02 else { return nil }
            i += 1
            guard let length = readLength(), i + length <= bytes.count else { return nil }
            var value = Array(bytes[i..<(i + length)])
            i += length
            while value.count > 1 && value[0] == 0 { value.removeFirst() }
            return value
        }
        guard bytes.first == 0x30 else { return nil }
        i = 1
        guard readLength() != nil, let modulus = readInteger(), let exponentBytes = readInteger(),
              exponentBytes.count <= 4 else { return nil }
        let exponent = exponentBytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return (modulus, exponent)
    }

    // MARK: Android encoding

    static func androidEncoding(modulus: [UInt8], exponent: UInt32) -> Data {
        let words = 64 // RSA-2048
        // Modulus as little-endian 32-bit words.
        var n = [UInt32](repeating: 0, count: words)
        let be = Array(modulus.suffix(words * 4))
        for (index, byte) in be.reversed().enumerated() {
            n[index / 4] |= UInt32(byte) << (8 * UInt32(index % 4))
        }

        // n0inv = -1 / n[0] mod 2^32 (Newton's iteration; n[0] is odd).
        var inverse = n[0]
        for _ in 0..<5 { inverse = inverse &* (2 &- n[0] &* inverse) }
        let n0inv = 0 &- inverse

        // rr = 2^(2 * 2048) mod n, by repeated doubling (one extra word for the carry).
        var r = [UInt32](repeating: 0, count: words + 1)
        r[0] = 1
        let nExtended = n + [0]
        for _ in 0..<(2 * words * 32) {
            var carry: UInt32 = 0
            for k in 0..<r.count {
                let next = r[k] >> 31
                r[k] = (r[k] << 1) | carry
                carry = next
            }
            if !lessThan(r, nExtended) { subtract(&r, nExtended) }
        }

        var out = Data()
        func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) } }
        append(UInt32(words))
        append(n0inv)
        for word in n { append(word) }
        for word in r.prefix(words) { append(word) }
        append(exponent)
        return out
    }

    private static func lessThan(_ a: [UInt32], _ b: [UInt32]) -> Bool {
        for k in stride(from: a.count - 1, through: 0, by: -1) where a[k] != b[k] {
            return a[k] < b[k]
        }
        return false
    }

    private static func subtract(_ a: inout [UInt32], _ b: [UInt32]) {
        var borrow: UInt64 = 0
        for k in 0..<a.count {
            let lhs = UInt64(a[k])
            let rhs = UInt64(b[k]) + borrow
            if lhs >= rhs {
                a[k] = UInt32(lhs - rhs)
                borrow = 0
            } else {
                a[k] = UInt32((lhs + (1 << 32)) - rhs)
                borrow = 1
            }
        }
    }
}
