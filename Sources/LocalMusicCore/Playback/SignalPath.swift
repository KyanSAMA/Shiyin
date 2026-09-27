import Foundation

/// What happens to the audio between the file and the output device, as far as the app is concerned.
public struct SignalPath: Equatable, Sendable {
    public var format: String
    public var lossy: Bool
    public var fileRate: Double
    public var bitDepth: Int?
    public var channels: Int
    public var device: String
    public var outputRate: Double
    public var switching: Bool
    public var gainDb: Float
    public var softwareVolume: Float
    /// Volume set on the device instead (原样输出).
    public var deviceVolume: Bool

    public init(format: String, lossy: Bool, fileRate: Double, bitDepth: Int?, channels: Int, device: String, outputRate: Double,
                switching: Bool, gainDb: Float, softwareVolume: Float, deviceVolume: Bool) {
        (self.format, self.lossy, self.fileRate, self.bitDepth, self.channels) = (format, lossy, fileRate, bitDepth, channels)
        (self.device, self.outputRate, self.switching) = (device, outputRate, switching)
        (self.gainDb, self.softwareVolume, self.deviceVolume) = (gainDb, softwareVolume, deviceVolume)
    }

    public var resampled: Bool { !switching && fileRate != outputRate }
    /// The samples reach the output as decoded (the float path carries 24 bits).
    public var untouched: Bool { !switching && !resampled && gainDb == 0 && softwareVolume == 1 && channels == 2 && (bitDepth ?? 0) <= 24 }

    public var lines: [String] {
        let depth = bitDepth.map { " · \($0) bit" } ?? ""
        let layout = channels == 1 ? "单声道" : channels == 2 ? "立体声" : "\(channels) 声道"
        var lines = ["文件：\(format.uppercased()) · \(Self.kHz(fileRate))\(lossy ? " · 有损压缩" : depth) · \(layout)",
                     "输出：\(device) · \(switching ? "正在切换采样率…" : Self.kHz(outputRate))"]
        if !switching { lines.append(resampled ? "重采样 \(Self.kHz(fileRate, unit: false)) → \(Self.kHz(outputRate))" : "采样率一致，未重采样") }
        lines.append(gainDb == 0 ? "响度均衡：未调整" : String(format: "响度均衡 %+.1f dB", gainDb))
        lines.append(deviceVolume ? "音量由设备控制" : "软件音量 \(Int((softwareVolume * 100).rounded()))%")
        if channels == 1 { lines.append("单声道复制到左右声道") } else if channels > 2 { lines.append("\(channels) 声道缩混为立体声") }
        lines.append(untouched ? "拾音没有改动音频数据（直通）" : "拾音对音频做了以上处理")
        return lines
    }

    public static func kHz(_ rate: Double, unit: Bool = true) -> String { String(format: unit ? "%g kHz" : "%g", rate / 1000) }
}
