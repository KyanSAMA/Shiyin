import Foundation
@testable import LocalMusicCore

func be(_ value: Int, _ width: Int) -> Data {
    Data((0..<width).reversed().map { UInt8(value >> ($0 * 8) & 0xFF) })
}

func le32(_ value: Int) -> Data { Data(be(value, 4).reversed()) }

enum FLACBuilder {
    static func streamInfo(rate: Int, channels: Int, bitDepth: Int, total: Int64) -> Data {
        var b = [UInt8](repeating: 0, count: 34)
        b[10] = UInt8(rate >> 12 & 0xFF)
        b[11] = UInt8(rate >> 4 & 0xFF)
        b[12] = UInt8((rate & 0x0F) << 4 | (channels - 1) << 1 | (bitDepth - 1) >> 4)
        b[13] = UInt8(((bitDepth - 1) & 0x0F) << 4) | UInt8(total >> 32 & 0x0F)
        for i in 0..<4 { b[14 + i] = UInt8(total >> (24 - 8 * i) & 0xFF) }
        return Data(b)
    }

    static func comments(_ entries: [String], vendor: String = "test") -> Data {
        var out = le32(vendor.utf8.count) + Data(vendor.utf8) + le32(entries.count)
        for entry in entries { out += le32(entry.utf8.count) + Data(entry.utf8) }
        return out
    }

    static func picture(type: Int = 3, mime: String = "image/png", description: String = "", image: Data) -> Data {
        be(type, 4) + be(mime.utf8.count, 4) + Data(mime.utf8) + be(description.utf8.count, 4) + Data(description.utf8)
            + Data(count: 16) + be(image.count, 4) + image
    }

    static func file(_ blocks: [(type: UInt8, body: Data)], prefix: Data = Data()) -> Data {
        var out = prefix + Data("fLaC".utf8)
        for (i, block) in blocks.enumerated() {
            out.append((i == blocks.count - 1 ? 0x80 : 0) | block.type)
            out += be(block.body.count, 3) + block.body
        }
        return out
    }
}

enum ID3Builder {
    static func encode(_ s: String, _ encoding: UInt8) -> Data {
        switch encoding {
        case 0: Data(s.unicodeScalars.map { UInt8($0.value) })
        case 1: Data([0xFF, 0xFE]) + Data(s.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
        case 2: Data(s.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] })
        default: Data(s.utf8)
        }
    }

    static func terminator(_ encoding: UInt8) -> Data { encoding == 1 || encoding == 2 ? Data([0, 0]) : Data([0]) }

    static func text(_ values: [String], encoding: UInt8 = 3) -> Data {
        Data([encoding]) + values.map { encode($0, encoding) }.joined(separator: terminator(encoding))
    }

    static func lyrics(_ text: String, encoding: UInt8 = 3) -> Data {
        Data([encoding]) + Data("eng".utf8) + terminator(encoding) + encode(text, encoding)
    }

    static func userText(_ description: String, _ value: String, encoding: UInt8 = 3) -> Data {
        Data([encoding]) + encode(description, encoding) + terminator(encoding) + encode(value, encoding)
    }

    static func picture(type: UInt8, image: Data, description: String = "cover", encoding: UInt8 = 1) -> Data {
        Data([encoding]) + Data("image/png".utf8) + Data([0, type]) + encode(description, encoding) + terminator(encoding) + image
    }

    static func syncsafe(_ v: Int) -> Data { Data([UInt8(v >> 21 & 0x7F), UInt8(v >> 14 & 0x7F), UInt8(v >> 7 & 0x7F), UInt8(v & 0x7F)]) }

    static func frame(_ id: String, _ body: Data, major: UInt8, formatFlags: UInt8 = 0, plainSize: Bool = false) -> Data {
        Data(id.utf8) + (major == 4 && !plainSize ? syncsafe(body.count) : be(body.count, 4)) + Data([0, formatFlags]) + body
    }

    static func tag(major: UInt8, _ frames: [Data], flags: UInt8 = 0, extendedHeader: Data = Data(), padding: Int = 32) -> Data {
        let body = extendedHeader + frames.joined() + Data(count: padding)
        return Data("ID3".utf8) + Data([major, 0, flags]) + syncsafe(body.count) + body
    }

    static func unsync(_ data: Data) -> Data {
        var out = Data()
        for byte in data {
            out.append(byte)
            if byte == 0xFF { out.append(0) }
        }
        return out
    }
}

enum FFmpeg {
    static let path = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) }

    /// Runs ffmpeg with `-y -v error` prepended; returns the exit status.
    @discardableResult
    static func run(_ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(filePath: path!)
        process.arguments = ["-y", "-v", "error"] + arguments
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
