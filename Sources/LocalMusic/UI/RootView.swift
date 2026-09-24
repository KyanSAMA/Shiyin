import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                SidebarView()
            } detail: {
                let item = model.ui.sidebar
                ContentUnavailableView(item.title, systemImage: item.symbol, description: Text("曲库尚未扫描"))
            }
            Divider()
            PlayerBarView()
        }
        .frame(minWidth: 900, minHeight: 560)
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let ui = model.ui
        List(selection: Binding(get: { ui.sidebar }, set: { if let item = $0 { ui.sidebar = item } })) {
            Section("资料库") {
                ForEach(SidebarItem.allCases) { item in
                    Label(item.title, systemImage: item.symbol).tag(item)
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 210)
    }
}

struct PlayerBarView: View {
    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary)
                .frame(width: 44, height: 44)
                .overlay { Image(systemName: "music.note").foregroundStyle(.secondary) }
            Text("未在播放")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 64)
        .background(.bar)
    }
}
