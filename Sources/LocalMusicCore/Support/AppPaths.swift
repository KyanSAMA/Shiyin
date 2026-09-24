import Foundation

public struct AppPaths: Sendable {
    public let data: URL
    public let cache: URL

    public init(data: URL, cache: URL) {
        self.data = data
        self.cache = cache
    }

    /// Self-test isolation: everything lives under one throwaway directory.
    public init(isolatedRoot root: URL) {
        self.init(data: root, cache: root.appending(path: "Caches"))
    }

    public static func standard() -> AppPaths {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return AppPaths(data: support.appending(path: "LocalMusic"), cache: caches.appending(path: "LocalMusic"))
    }

    public var database: URL { data.appending(path: "library.sqlite") }
}
