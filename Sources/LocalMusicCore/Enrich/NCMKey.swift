import CommonCrypto
import Foundation

/// The "163 key(Don't modify):…" comment NetEase Cloud Music writes into its MP3s: base64 of AES-128-ECB over
/// `music:{json}`, whose `musicId` is the song's NetEase id.
public enum NCMKey {
    static let metaKey = Array("#14ljk_!\\]&0U<'(".utf8)
    /// Wraps the audio key inside an .ncm (`NCMFile`).
    static let coreKey = Array("hzHRAmso5kInbaxW".utf8)

    public static func songID(_ comment: String) -> Int64? {
        let base64 = comment.hasPrefix(ID3Reader.ncmKeyPrefix) ? String(comment.dropFirst(ID3Reader.ncmKeyPrefix.count)) : comment
        guard let encrypted = Data(base64Encoded: base64.trimmingCharacters(in: .whitespacesAndNewlines)),
              let plain = crypt(encrypted, key: metaKey, encrypt: false), plain.starts(with: Data("music:".utf8)),
              let json = try? JSONSerialization.jsonObject(with: plain.dropFirst(6)) as? [String: Any]
        else { return nil }
        return (json["musicId"] as? NSNumber)?.int64Value ?? (json["musicId"] as? String).flatMap { Int64($0) }
    }

    /// AES-128-ECB with PKCS7 padding.
    static func crypt(_ data: Data, key: [UInt8], encrypt: Bool) -> Data? {
        var out = Data(count: data.count + kCCBlockSizeAES128)
        var written = 0
        let status = out.withUnsafeMutableBytes { output in
            data.withUnsafeBytes { input in
                CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding),
                        key, key.count, nil, input.baseAddress, data.count, output.baseAddress, output.count, &written)
            }
        }
        return status == kCCSuccess ? out.prefix(written) : nil
    }
}
