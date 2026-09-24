import AppKit
import SwiftUI
import LocalMusicCore

enum SongColumn: String, CaseIterable {
    case number, title, artist, album, year, duration, added

    var header: String {
        switch self {
        case .number: "#"
        case .title: "标题"
        case .artist: "艺人"
        case .album: "专辑"
        case .year: "年份"
        case .duration: "时长"
        case .added: "添加时间"
        }
    }

    /// nil: not sortable.
    func comparator(_ order: SortOrder) -> KeyPathComparator<TrackRow>? {
        switch self {
        case .number: nil
        case .title: KeyPathComparator(\.title, comparator: .localizedStandard, order: order)
        case .artist: KeyPathComparator(\.artistText, comparator: .localizedStandard, order: order)
        case .album: KeyPathComparator(\.albumTitle, comparator: .localizedStandard, order: order)
        case .year: KeyPathComparator(\.yearSortKey, order: order)
        case .duration: KeyPathComparator(\.duration, order: order)
        case .added: KeyPathComparator(\.addedAt, order: order)
        }
    }

    init?(_ comparator: KeyPathComparator<TrackRow>) {
        guard let column = Self.allCases.first(where: { $0.comparator(.forward)?.keyPath == comparator.keyPath }) else { return nil }
        self = column
    }
}

/// The song list as a plain NSTableView: SwiftUI's Table hosts a SwiftUI view per cell and re-measures each one, so every
/// re-sort, search or filter rebuilt it for 130–230 ms. Double-click or Return plays the list from that row.
struct SongsTableView: NSViewRepresentable {
    let model: AppModel
    let rows: [TrackRow]
    /// For an album's track list: track numbers instead of covers, album order, artists only where they differ.
    var album: AlbumGroup?

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = TrackTable()
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.rowHeight = 36
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        let columns: [SongColumn] = album == nil ? [.title, .artist, .album, .year, .duration, .added] : [.number, .title, .artist, .duration]
        for column in columns {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.header
            if album == nil, column.comparator(.forward) != nil {
                tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: true)
            }
            switch column {
            case .number, .year, .duration, .added: tableColumn.resizingMask = .userResizingMask   // extra width goes to text columns
            default: break
            }
            switch column {
            case .number: tableColumn.width = 36
            case .title: (tableColumn.minWidth, tableColumn.width) = (160, album == nil ? 320 : 420)
            case .artist, .album: (tableColumn.minWidth, tableColumn.width) = (80, 200)
            case .year: tableColumn.width = 44
            case .duration: tableColumn.width = 48
            case .added: tableColumn.width = 96
            }
            table.addTableColumn(tableColumn)
        }
        let coordinator = context.coordinator
        table.dataSource = coordinator
        table.delegate = coordinator
        table.target = coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        table.onReturn = { [weak coordinator] in coordinator?.playSelection() }
        table.menu = NSMenu()
        table.menu?.delegate = coordinator
        coordinator.table = table
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let ui = model.ui
        context.coordinator.update(rows: rows, album: album, selection: ui.songSelection, sort: album == nil ? ui.songSort.first : nil,
                                   playing: model.player?.current?.id)
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        let model: AppModel
        weak var table: NSTableView?
        private var rows: [TrackRow] = []
        private var album: AlbumGroup?
        private var multiDisc = false
        private var playing: Int64?
        /// Set while the model pushes state into the table, so the table's callbacks don't echo it back.
        private var applying = false

        init(model: AppModel) {
            self.model = model
        }

        func update(rows: [TrackRow], album: AlbumGroup?, selection: Set<Int64>, sort: KeyPathComparator<TrackRow>?, playing: Int64?) {
            guard let table else { return }
            applying = true
            defer { applying = false }
            // Whole rows, not ids: a rescan can change a title, path or cover under the same id.
            if rows != self.rows || album != self.album {
                self.rows = rows
                self.album = album
                multiDisc = album != nil && Set(rows.map(LibraryIndex.disc)).count > 1
                self.playing = playing
                table.reloadData()
            }
            let descriptors = sort.flatMap(SongColumn.init).map { [NSSortDescriptor(key: $0.rawValue, ascending: sort?.order == .forward)] } ?? []
            if table.sortDescriptors != descriptors { table.sortDescriptors = descriptors }
            let indexes = IndexSet(rows.indices.filter { selection.contains(rows[$0].id) })
            if table.selectedRowIndexes != indexes { table.selectRowIndexes(indexes, byExtendingSelection: false) }
            if playing != self.playing {
                self.playing = playing
                let column = table.column(withIdentifier: NSUserInterfaceItemIdentifier(SongColumn.title.rawValue))
                table.enumerateAvailableRowViews { view, row in
                    (view.view(atColumn: column) as? TitleCell)?.isPlaying = self.rows[row].id == playing
                }
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
            guard let id = tableColumn?.identifier, let column = SongColumn(rawValue: id.rawValue) else { return nil }
            let row = rows[index]
            if column == .title {
                let cell = tableView.makeView(withIdentifier: id, owner: nil) as? TitleCell ?? TitleCell(identifier: id, cover: album == nil)
                cell.show(row, artwork: model.artwork, playing: row.id == playing)
                return cell
            }
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? TextCell
                ?? TextCell(identifier: id, digits: column == .duration || column == .number, secondary: album != nil && column != .duration)
            cell.textField?.stringValue = switch column {
            case .number: row.trackNo.map { multiDisc ? "\(LibraryIndex.disc(of: row))-\($0)" : "\($0)" } ?? ""
            case .title: row.title
            case .artist: row.artistText == album?.artist ? "" : row.artistText
            case .album: row.albumTitle
            case .year: row.year.map(String.init) ?? ""
            case .duration: clock(row.duration)
            case .added: row.addedAt.formatted(.dateTime.year().month().day())
            }
            return cell
        }

        func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
            tableColumn?.identifier.rawValue == SongColumn.title.rawValue ? rows[row].title : nil
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !applying, let descriptor = tableView.sortDescriptors.first, let column = descriptor.key.flatMap(SongColumn.init) else { return }
            if let comparator = column.comparator(descriptor.ascending ? .forward : .reverse) { model.ui.songSort = [comparator] }
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !applying, let table else { return }
            model.ui.songSelection = Set(table.selectedRowIndexes.map { rows[$0].id })
        }

        @objc func doubleClicked(_ sender: NSTableView) { play(from: sender.clickedRow) }
        func playSelection() { play(from: table?.selectedRowIndexes.first ?? -1) }

        private func play(from index: Int) {
            guard rows.indices.contains(index) else { return }
            model.player?.play(rows.map(\.id), startAt: index)
        }

        /// The clicked row, or the whole selection when the click lands inside it; in list order.
        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table, rows.indices.contains(table.clickedRow) else { return }
            let indexes = table.selectedRowIndexes.contains(table.clickedRow) ? table.selectedRowIndexes : [table.clickedRow]
            let picked = indexes.map { rows[$0] }
            for (title, action) in [("播放下一首", #selector(playNext)), ("添加到队列", #selector(addToQueue)), ("在访达中显示", #selector(reveal))] {
                if action == #selector(reveal) { menu.addItem(.separator()) }
                let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
                item.target = self
                item.representedObject = picked
            }
        }

        @objc private func playNext(_ item: NSMenuItem) { model.player?.playNext(picked(item).map(\.id)) }
        @objc private func addToQueue(_ item: NSMenuItem) { model.player?.addToQueue(picked(item).map(\.id)) }
        @objc private func reveal(_ item: NSMenuItem) { revealInFinder(picked(item)) }
        private func picked(_ item: NSMenuItem) -> [TrackRow] { item.representedObject as? [TrackRow] ?? [] }
    }
}

/// Return plays the selection, as double-click does.
private final class TrackTable: NSTableView {
    var onReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 36 || event.keyCode == 76, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty else {
            return super.keyDown(with: event)
        }
        if !event.isARepeat { onReturn?() }
    }
}

private final class TextCell: NSTableCellView {
    init(identifier: NSUserInterfaceItemIdentifier, digits: Bool, secondary: Bool) {
        super.init(frame: .zero)
        self.identifier = identifier
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        if secondary { label.textColor = .secondaryLabelColor }
        if digits { label.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular) }
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// Cover thumbnail (song lists), a speaker glyph on the playing row, and the title.
private final class TitleCell: NSTableCellView {
    private let cover = NSView()
    private let note = NSImageView(image: NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)!)
    private let mark = NSImageView(image: NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "正在播放")!)
    private var loading: Task<Void, Never>?
    /// The row whose cover is shown; a new file modification time means new art.
    private var shown: (id: Int64, mtime: Double)?

    var isPlaying = false {
        didSet { mark.isHidden = !isPlaying }
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { mark.contentTintColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : .controlAccentColor }
    }

    init(identifier: NSUserInterfaceItemIdentifier, cover showsCover: Bool) {
        super.init(frame: .zero)
        self.identifier = identifier
        cover.isHidden = !showsCover
        cover.wantsLayer = true
        cover.layer?.cornerRadius = 3
        cover.layer?.masksToBounds = true
        cover.layer?.contentsGravity = .resizeAspectFill
        note.symbolConfiguration = .init(pointSize: 9, weight: .regular)
        note.contentTintColor = .tertiaryLabelColor
        note.translatesAutoresizingMaskIntoConstraints = false
        cover.addSubview(note)
        mark.contentTintColor = .controlAccentColor
        mark.symbolConfiguration = .init(pointSize: 10, weight: .regular)
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField = label
        let stack = NSStackView(views: [cover, mark, label])
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            cover.widthAnchor.constraint(equalToConstant: 28), cover.heightAnchor.constraint(equalToConstant: 28),
            note.centerXAnchor.constraint(equalTo: cover.centerXAnchor), note.centerYAnchor.constraint(equalTo: cover.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    // Layer colors don't follow the appearance by themselves.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTile()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateTile()
    }

    private func updateTile() {
        effectiveAppearance.performAsCurrentDrawingAppearance { cover.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor }
    }

    func show(_ row: TrackRow, artwork: ArtworkStore, playing: Bool) {
        textField?.stringValue = row.title
        isPlaying = playing
        guard !cover.isHidden, shown?.id != row.id || shown?.mtime != row.fileMtime else { return }
        shown = (row.id, row.fileMtime)
        loading?.cancel()
        let pixels = CoverView.pixels(for: 28), box = artwork.box(row, pixels: pixels)
        setCover(box.image)
        guard box.image == nil else { return }
        loading = Task { [weak self] in
            // Another view may be loading the same box; then fetch directly rather than wait on it.
            let image: CGImage?
            if box.requested {
                image = await artwork.image(for: row, pixels: pixels)
            } else {
                await artwork.load(box, row, pixels: pixels)
                image = box.image
            }
            guard !Task.isCancelled, let self, shown?.id == row.id else { return }
            setCover(image)
        }
    }

    private func setCover(_ image: CGImage?) {
        cover.layer?.contents = image
        note.isHidden = image != nil
    }
}
