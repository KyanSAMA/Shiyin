import AppKit
import SwiftUI

@main
struct LocalMusicApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("本地音乐", id: "main") {
            RootView()
                .environment(AppModel.shared)
        }
        .defaultSize(width: 1200, height: 760)

        Settings {
            SettingsView()
                .environment(AppModel.shared)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        if LaunchOptions.current.isSelfTest {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard LaunchOptions.current.isSelfTest else { return }
        let runner = SelfTestRunner(model: .shared)
        Task { exit(await runner.run()) }
    }
}
