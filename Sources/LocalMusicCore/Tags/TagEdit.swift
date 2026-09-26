import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What a write sets in a file's tags; nil leaves a field as it is.
public struct TagEdit: Sendable, Equatable {
    public struct Cover: Sendable, Equatable {
        public let data: Data
        public let mime: String
        public let width: Int
        public let height: Int

        /// JPEG and PNG as they are; other images become JPEG. Refuses what isn't an image or exceeds a FLAC block.
        public init(_ data: Data) throws {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  let type = CGImageSourceGetType(source) as String? else { throw TagWriteError.unsupported("封面不是图片") }
            var bytes = data, mime = type == UTType.png.identifier ? "image/png" : "image/jpeg"
            if type != UTType.png.identifier, type != UTType.jpeg.identifier {
                let out = NSMutableData()
                guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                      let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
                    throw TagWriteError.unsupported("封面无法转换为 JPEG")
                }
                CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
                guard CGImageDestinationFinalize(destination) else { throw TagWriteError.unsupported("封面无法转换为 JPEG") }
                (bytes, mime) = (out as Data, "image/jpeg")
            }
            guard bytes.count < 16 << 20 else { throw TagWriteError.unsupported("封面超过 16 MB") }
            (self.data, self.mime, self.width, self.height) = (bytes, mime, width, height)
        }
    }

    public var title: String?
    public var artists: [String]?
    public var album: String?
    public var albumArtist: String?
    public var trackNo: Int?
    public var discNo: Int?
    public var year: Int?
    public var genre: String?
    public var composers: [String]?
    public var lyrics: String?
    public var cover: Cover?
    /// NetEase's "163 key(Don't modify):…" (an MP3 comment, FLAC DESCRIPTION): the song's NetEase id for later lookups.
    public var ncmKey: String?
    /// Drop the file's own tags, comments, lyrics and pictures first (the audio inside an .ncm carries junk ones).
    public var replaceAll = false

    public init() {}

    public var isEmpty: Bool { self == TagEdit() }
}

public enum TagWriteError: Error, Equatable, CustomStringConvertible {
    case unsupported(String)
    /// The file changed while it was being written.
    case changed
    case verification(String)

    public var description: String {
        switch self {
        case .unsupported(let reason): reason
        case .changed: "文件在写入过程中被改动，已放弃"
        case .verification(let reason): "写入后校验失败，原文件未改动：\(reason)"
        }
    }
}
