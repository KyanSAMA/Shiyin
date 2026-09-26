import AVFAudio
import Foundation

/// WAV to FLAC with the system encoder: sample for sample for integer PCM up to 24 bits (16-bit stays 16-bit); 32-bit
/// and float sources become 24-bit.
public enum FLACConvert {
    public static func convert(_ source: URL, to out: URL) throws {
        let format = try AVAudioFile(forReading: source).fileFormat.settings
        let sixteen = (format[AVLinearPCMBitDepthKey] as? Int ?? 32) <= 16 && format[AVLinearPCMIsFloatKey] as? Bool != true
        // A 16-bit processing format makes the encoder write 16-bit FLAC; a 32-bit one, 24-bit.
        let common: AVAudioCommonFormat = sixteen ? .pcmFormatInt16 : .pcmFormatInt32
        let input = try AVAudioFile(forReading: source, commonFormat: common, interleaved: false)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: input.fileFormat.sampleRate,
                                       AVNumberOfChannelsKey: input.fileFormat.channelCount]
        do {
            let output = try AVAudioFile(forWriting: out, settings: settings, commonFormat: common, interleaved: false)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 1 << 16) else {
                throw TagWriteError.unsupported("无法分配音频缓冲")
            }
            while input.framePosition < input.length {
                try input.read(into: buffer)
                try output.write(from: buffer)
            }
            output.close()
            guard try AVAudioFile(forReading: out).length == input.length else { throw TagWriteError.unsupported("转换出的 FLAC 长度与 WAV 不一致") }
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
    }
}
