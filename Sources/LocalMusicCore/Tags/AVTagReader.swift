import AVFoundation

/// AVFoundation paths: audio properties for non-FLAC files and tags for WAV / M4A / ID3-less MP3.
enum AVTagReader {
    static func properties(url: URL, format: String) throws -> AudioProperties {
        let file = try AVAudioFile(forReading: url)
        let fileFormat = file.fileFormat
        let asbd = fileFormat.streamDescription.pointee
        let (codec, bitDepth): (String?, Int?) = switch asbd.mFormatID {
        case kAudioFormatLinearPCM: ("pcm", Int(asbd.mBitsPerChannel))
        case kAudioFormatAppleLossless: ("alac", [1: 16, 2: 20, 3: 24, 4: 32][Int(asbd.mFormatFlags)])
        case kAudioFormatFLAC: ("flac", nil)
        case kAudioFormatMPEGLayer3: ("mp3", nil)
        case kAudioFormatMPEG4AAC: ("aac", nil)
        default: (nil, nil)
        }
        let rate = fileFormat.sampleRate
        return AudioProperties(format: format, codec: codec, sampleRate: Int(rate), bitDepth: bitDepth,
                               channels: Int(fileFormat.channelCount), frameCount: file.length,
                               duration: rate > 0 ? Double(file.length) / rate : 0)
    }

    static func metadata(url: URL) async throws -> (RawTags, CoverRef?) {
        var tags = RawTags()
        var cover: CoverRef?
        for item in try await AVURLAsset(url: url).load(.metadata) {
            if item.identifier == .iTunesMetadataTrackNumber || item.identifier == .iTunesMetadataDiscNumber {
                if let pair = try await item.load(.dataValue).flatMap(numberPair) {
                    tags.add(item.identifier == .iTunesMetadataTrackNumber ? "TRACKNUMBER" : "DISCNUMBER", pair)
                }
            } else if item.identifier == .iTunesMetadataCoverArt || item.commonKey == .commonKeyArtwork {
                if cover == nil, let data = try await item.load(.dataValue) {
                    cover = CoverRef(offset: nil, length: data.count, mime: nil, pictureType: 3)
                }
            } else if let key = key(for: item), let value = try await item.load(.stringValue) {
                tags.add(key, value)
            }
        }
        return (tags, cover)
    }

    static func artwork(url: URL) async throws -> Data? {
        for item in try await AVURLAsset(url: url).load(.metadata)
        where item.identifier == .iTunesMetadataCoverArt || item.commonKey == .commonKeyArtwork {
            if let data = try await item.load(.dataValue) { return data }
        }
        return nil
    }

    private static func key(for item: AVMetadataItem) -> String? {
        switch item.identifier {
        case .iTunesMetadataSongName: "TITLE"
        case .iTunesMetadataArtist: "ARTIST"
        case .iTunesMetadataAlbum: "ALBUM"
        case .iTunesMetadataAlbumArtist: "ALBUMARTIST"
        case .iTunesMetadataComposer: "COMPOSER"
        case .iTunesMetadataLyrics: "LYRICS"
        case .iTunesMetadataReleaseDate: "DATE"
        case .iTunesMetadataUserGenre: "GENRE"
        default:
            switch item.commonKey {
            case .commonKeyTitle: "TITLE"
            case .commonKeyArtist: "ARTIST"
            case .commonKeyAlbumName: "ALBUM"
            case .commonKeyCreationDate: "DATE"
            default: nil
            }
        }
    }

    /// iTunes `trkn` / `disk` atoms: big-endian number at bytes 2–3, total at 4–5.
    private static func numberPair(_ data: Data) -> String? {
        let b = [UInt8](data)
        guard b.count >= 6 else { return nil }
        let number = Int(b[2]) << 8 | Int(b[3]), total = Int(b[4]) << 8 | Int(b[5])
        guard number > 0 else { return nil }
        return total > 0 ? "\(number)/\(total)" : "\(number)"
    }
}
