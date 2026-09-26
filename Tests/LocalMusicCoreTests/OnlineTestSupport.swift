import Foundation
@testable import LocalMusicCore

/// Recorded responses for tests. `OnlineFixtures` serves one directory per process and tests run in parallel, so every
/// test adds its files to the same directory (a name always has the same body).
enum OnlineTestFixtures {
    private static let directory = FileManager.default.temporaryDirectory.appending(path: "lm-online-\(UUID().uuidString)")

    static func client(_ files: [(String, Data)]) throws -> OnlineClient {
        for (file, body) in files {
            let url = directory.appending(path: file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try body.write(to: url, options: .atomic)
        }
        return OnlineClient(configuration: OnlineFixtures.configuration(directory: directory))
    }
}
