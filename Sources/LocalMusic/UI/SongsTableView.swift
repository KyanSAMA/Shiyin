import AppKit
import SwiftUI
import LocalMusicCore

enum SongColumn: String, CaseIterable {
    case number, title, liked, artist, album, year, duration, added

    var header: String {
        switch self {
        case .number: "#"
        case .title: "标题"
        case .liked: ""
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
        case .number, .liked: nil
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

extension NSPasteboard.PasteboardType {
    static let trackID = Self("com.localmusic.track-id")
}

/// The song list as a plain NSTableView: SwiftUI's Table hosts a SwiftUI view per cell and re-measures each one, so every
/// re-sort, search or filter rebuilt it for 130–230 ms. Double-click or Return plays the list from that row.
struct SongsTableView: NSViewRepresentable {
    let model: AppModel
    let rows: [TrackRow]
    /// For an album's track list: track numbers instead of covers, album order, artists only where they differ.
    var album: AlbumGroup?
    /// For a playlist: its order with positions, drag to reorder, ⌫ to remove.
    var playlist: Int64?

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = TrackTable()
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.rowHeight = 36
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        let columns: [SongColumn] = if album != nil { [.number, .title, .liked, .artist, .duration] }
            else if playlist != nil { [.number, .title, .liked, .artist, .album, .duration] }
            else { [.title, .liked, .artist, .album, .year, .duration, .added] }
        for column in columns {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.header
            if album == nil, playlist == nil, column.comparator(.forward) != nil {
                tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: true)
            }
            switch column {
            case .liked: tableColumn.resizingMask = []
            case .number, .year, .duration, .added: tableColumn.resizingMask = .userResizingMask   // extra width goes to text columns
            default: break
            }
            switch column {
            case .number: tableColumn.width = 36
            case .liked: tableColumn.width = 18
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
        table.onDelete = { [weak coordinator] in coordinator?.removeSelection() }
        // Only a playlist reorders by dragging vertically; elsewhere vertical drags keep extending the selection.
        table.verticalMotionCanBeginDrag = playlist != nil
        if playlist != nil { table.registerForDraggedTypes([.trackID]) }
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.setDraggingSourceOperationMask([], forLocal: false)   // ids mean nothing to other apps
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
        context.coordinator.update(rows: rows, album: album, playlist: playlist, selection: ui.songSelection,
                                   sort: album == nil && playlist == nil ? ui.songSort.first : nil, playing: model.player?.current?.id,
                                   liked: model.library?.liked ?? [:])
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        let model: AppModel
        weak var table: NSTableView?
        private var rows: [TrackRow] = []
        private var album: AlbumGroup?
        private var playlist: Int64?
        private var multiDisc = false
        private var playing: Int64?
        private var liked: [Int64: Date] = [:]
        /// Set while the model pushes state into the table, so the table's callbacks don't echo it back.
        private var applying = false

        init(model: AppModel) {
            self.model = model
        }

        func update(rows: [TrackRow], album: AlbumGroup?, playlist: Int64?, selection: Set<Int64>, sort: KeyPathComparator<TrackRow>?,
                    playing: Int64?, liked: [Int64: Date]) {
            guard let table else { return }
            applying = true
            defer { applying = false }
            // Whole rows, not ids: a rescan can change a title, path or cover under the same id.
            if rows != self.rows || album != self.album || playlist != self.playlist {
                self.rows = rows
                self.album = album
                self.playlist = playlist
                multiDisc = album != nil && Set(rows.map(LibraryIndex.disc)).count > 1
                self.playing = playing
                self.liked = liked
                table.reloadData()
            }
            if liked.keys != self.liked.keys {
                self.liked = liked
                let column = table.column(withIdentifier: NSUserInterfaceItemIdentifier(SongColumn.liked.rawValue))
                table.enumerateAvailableRowViews { view, row in
                    (view.view(atColumn: column) as? LikedCell)?.isLiked = liked[self.rows[row].id] != nil
                }
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
            if column == .liked {
                let cell = tableView.makeView(withIdentifier: id, owner: nil) as? LikedCell ?? LikedCell(identifier: id)
                cell.isLiked = liked[row.id] != nil
                return cell
            }
            if column == .title {
                let cell = tableView.makeView(withIdentifier: id, owner: nil) as? TitleCell ?? TitleCell(identifier: id, cover: album == nil)
                cell.show(row, artwork: model.artwork, playing: row.id == playing)
                return cell
            }
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? TextCell
                ?? TextCell(identifier: id, digits: column == .duration || column == .number,
                            secondary: column == .number || album != nil && column != .duration)
            cell.textField?.stringValue = switch column {
            case .number where playlist != nil: "\(index + 1)"
            case .number: row.trackNo.map { multiDisc ? "\(LibraryIndex.disc(of: row))-\($0)" : "\($0)" } ?? ""
            case .title, .liked: row.title
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

        // Dragging carries track ids: onto a sidebar playlist to add them, or within a playlist to reorder it when it shows
        // all its tracks (no search / filter).
        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            let item = NSPasteboardItem()
            item.setString(String(rows[row].id), forType: .trackID)
            item.setString(String(rows[row].id), forType: .string)   // what the SwiftUI sidebar's drop targets read
            return item
        }

        private var reorderable: Bool {
            playlist.flatMap { model.library?.playlist($0) }?.trackIDs == rows.map(\.id)
        }

        func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
                       proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            guard reorderable, info.draggingSource as? NSTableView === tableView else { return [] }
            tableView.setDropRow(row, dropOperation: .above)
            return .move
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
                       dropOperation: NSTableView.DropOperation) -> Bool {
            guard reorderable, let playlist else { return false }
            let ids = info.draggingPasteboard.pasteboardItems?.compactMap { $0.string(forType: .trackID).flatMap { Int64($0) } } ?? []
            model.library?.movePlaylistTracks(playlist, Set(ids), to: row)
            return true
        }

        func removeSelection() {
            guard let playlist, let table else { return }
            model.library?.removeFromPlaylist(playlist, Set(table.selectedRowIndexes.map { rows[$0].id }))
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
            func add(_ title: String, _ action: Selector, to menu: NSMenu = menu, tag: Int = 0) {
                let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
                item.target = self
                item.representedObject = picked
                item.tag = tag
            }
            add("播放下一首", #selector(playNext))
            add("添加到队列", #selector(addToQueue))
            let playlists = NSMenu()
            add("新建播放列表…", #selector(addToNewPlaylist), to: playlists)
            if let existing = model.library?.playlists, !existing.isEmpty {
                playlists.addItem(.separator())
                for playlist in existing { add(playlist.name, #selector(addToPlaylist), to: playlists, tag: Int(playlist.id)) }
            }
            menu.addItem(withTitle: "添加到播放列表", action: nil, keyEquivalent: "").submenu = playlists
            menu.addItem(.separator())
            if playlist != nil { add("从播放列表中移除", #selector(removeFromPlaylist)) }
            let allLiked = picked.allSatisfy { model.library?.liked[$0.id] != nil }
            add(allLiked ? "取消喜欢" : "喜欢", #selector(toggleLiked), tag: allLiked ? 0 : 1)   // tag: what it sets
            add("编辑信息…", #selector(editInfo))
            menu.addItem(.separator())
            add("在访达中显示", #selector(reveal))
        }

        @objc private func playNext(_ item: NSMenuItem) { model.player?.playNext(picked(item).map(\.id)) }
        @objc private func addToQueue(_ item: NSMenuItem) { model.player?.addToQueue(picked(item).map(\.id)) }
        @objc private func addToNewPlaylist(_ item: NSMenuItem) { model.promptNewPlaylist(picked(item).map(\.id)) }
        @objc private func addToPlaylist(_ item: NSMenuItem) { model.library?.addToPlaylist(Int64(item.tag), picked(item).map(\.id)) }
        @objc private func removeFromPlaylist(_ item: NSMenuItem) {
            guard let playlist else { return }
            model.library?.removeFromPlaylist(playlist, Set(picked(item).map(\.id)))
        }
        @objc private func reveal(_ item: NSMenuItem) { revealInFinder(picked(item)) }
        @objc private func editInfo(_ item: NSMenuItem) { Task { await model.editInfo(picked(item)) } }
        @objc private func toggleLiked(_ item: NSMenuItem) { model.library?.setLiked(picked(item).map(\.id), item.tag == 1) }
        private func picked(_ item: NSMenuItem) -> [TrackRow] { item.representedObject as? [TrackRow] ?? [] }
    }
}

/// Return plays the selection, as double-click does; ⌫ removes it from a playlist.
private final class TrackTable: NSTableView {
    var onReturn: (() -> Void)?
    var onDelete: (() -> Void)?
    private var fitted = false

    /// Column autoresizing only spreads later width changes: a table first shown narrower than its columns would
    /// otherwise scroll sideways.
    override func layout() {
        super.layout()
        guard !fitted, let width = enclosingScrollView?.contentView.bounds.width, width > 0 else { return }
        fitted = true
        sizeToFit()
    }

    override func keyDown(with event: NSEvent) {
        let action: (() -> Void)? = switch event.keyCode {
        case 36, 76: onReturn
        case 51, 117: onDelete
        default: nil
        }
        guard let action, event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .function, .numericPad]).isEmpty
        else { return super.keyDown(with: event) }
        if !event.isARepeat { action() }
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

/// A heart on liked songs.
private final class LikedCell: NSTableCellView {
    private let heart = NSImageView(image: NSImage(systemSymbolName: "heart.fill", accessibilityDescription: "喜欢")!)

    var isLiked = false {
        didSet { heart.isHidden = !isLiked }
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { heart.contentTintColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : .systemPink }
    }

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        heart.symbolConfiguration = .init(pointSize: 10, weight: .regular)
        heart.contentTintColor = .systemPink
        heart.translatesAutoresizingMaskIntoConstraints = false
        addSubview(heart)
        NSLayoutConstraint.activate([heart.centerXAnchor.constraint(equalTo: centerXAnchor), heart.centerYAnchor.constraint(equalTo: centerYAnchor)])
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// Cover thumbnail (song lists), a speaker glyph on the playing row, and the title.
private final class TitleCell: NSTableCellView {
    private let cover = NSView()
    private let note = NSImageView(image: NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)!)
    private let mark = NSImageView(image: NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "正在播放")!)
    private var loading: Task<Void, Never>?
    /// The file whose cover is shown; a new modification time means new art.
    private var shown: (path: String, mtime: Double)?

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
        guard !cover.isHidden, shown?.path != row.path || shown?.mtime != row.fileMtime else { return }
        shown = (row.path, row.fileMtime)
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
            guard !Task.isCancelled, let self, shown?.path == row.path else { return }
            setCover(image)
        }
    }

    private func setCover(_ image: CGImage?) {
        cover.layer?.contents = image
        note.isHidden = image != nil
    }
}
