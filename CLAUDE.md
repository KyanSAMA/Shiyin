# LocalMusic

macOS 27 本地音乐播放器。需求见 `需求与技术路线.md`，分步计划与进度见 `实施计划.md`。

## 命令
- 构建 / 测试：`swift build`、`swift test`
- 打包：`Scripts/bundle.sh [debug|release]` → `build/LocalMusic.app`（ad-hoc 签名；图标由 `Scripts/make-icon.swift` 生成到 `.build/AppIcon.icns`；日常使用打 release，debug 版响度分析慢约 10 倍）
- 自测：`Scripts/selftest.sh SelfTests/NN-*.json` → `.build/selftest/<name>/`（PNG、`*.state.json`、`report.json`、`app.log`）；退出码 0 通过 / 1 失败 / 2 超时或崩溃
- 全部自测：`Scripts/run-all-selftests.sh`（结束时用 `find -newer` 证明 `~/Music` 未被写入）；夹具由 `Scripts/make-fixtures.sh` 生成到 `.build/fixtures`（改动时递增 VERSION）
- 无障碍操作：`swift Scripts/ax-press.swift <文本>`（或先 `swiftc -O` 编译），对运行中 App 里标题/描述/值等于该文本的元素做 AX 选中行 / 按下
- 解析校验：`lmtool tags [--stats] [--sha] <路径>`、`lmtool lrc <文件>`、`lmtool scan <db> [<根目录>...]`、`lmtool decode-check <路径>`、`lmtool loudness [--album] <路径>`、`lmtool online search|lyric <netease|qq|itunes|lrclib> <关键词>|song <网易云 id>|match <文件>`（真实请求在线来源，只在开发验证时少量使用）；`Scripts/validate-loudness.sh` 对照 ffmpeg ebur128（30 首真实曲目，积分响度 ±0.5 LU、无损采样峰值 ±0.1 dB、≥20× 实时）；`Scripts/validate-tags.sh` 用 metaflac / ffprobe 对照真实曲库（只读）

## 硬性约束
- 只有 Command Line Tools：SwiftUI 宏插件缺失，禁用 `@State` / `@Entry` / `#Preview` / Animatable 宏；状态放 `@Observable` 模型，经 `.environment` 注入，`body` 里用 `@Bindable` 或 `Binding(get:set:)`
- `swift test` 依赖 `Package.swift` 里测试目标的 `-plugin-path`（CLT 不会自动传 TestingMacros）
- 零第三方依赖；ffmpeg / ffprobe / metaflac 只用于测试夹具和对照
- 曲库只读：任何代码路径都不得写入曲库目录
- 设置存 SQLite `setting` 表，不用 UserDefaults
- 补全 / 手动编辑存 `enrichment` 表，按音频内容指纹（`AudioFingerprint`：FLAC 用 STREAMINFO MD5，其他格式用音频数据区开头的哈希）关联，不按路径或曲目 id；每个在线来源（`OnlineSource`：网易云 / QQ 音乐 / iTunes / LRCLIB）各存一层；显示值 = 手动编辑 > 文件标签 > 各在线来源（按设置 `onlineSources` 的顺序）> 本地推断，在 `LibraryStore.rows()` 里合并
- 数据库迁移只追加，不修改已提交的迁移
- 交给 AVFAudio / MediaPlayer / FSEvents 的回调闭包在 `LocalMusicCore` 的非隔离代码或 `nonisolated static` 工厂里构造，只捕获 Sendable 值，再 `Task { @MainActor in … }` 切回
- App 目标默认 MainActor 隔离；纯逻辑放 `LocalMusicCore` 以便单测
- 布局：`scaledToFill` 的图片放 `.background` 并 `.clipped()`，作为 ZStack 子视图会按填充尺寸撑大父视图
- Table 单元格等深层视图不用 `@Environment(AppModel.self)`（排序重建行时会查不到而崩溃），由表格层取出后显式传参（如 `CoverView(store:)`、`PlayingMark(player:)`）
- UI 文案中文硬编码（SwiftPM 打包的 .app 不带资源 bundle）
- 自建窗口（迷你播放器面板）里的 `NSHostingView` 不能直接当 `contentView`：即使 `sizingOptions = []`，它仍会在 `windowDidLayout` 里按内容理想尺寸（含标题栏安全区）改窗口大小；作为子视图加 autoresizing 即可
- 按键：无修饰键的空格（播放 / 暂停）、← / →（±5 s）在 `AppModel.handleKey`（本地按键监听，先于菜单快捷键；无修饰键的菜单快捷键会吞掉搜索框里的输入），编辑文本时全部放行。⌘ 方向键在搜索框里也是切歌 / 音量（用户决定；前台 App 里交给输入框的尝试都会被菜单快捷键抢先）
- 退出时 `.terminateLater` 期间主线程跑的是不执行 MainActor 任务的 run loop 模式，异步保存会卡死退出：`applicationWillTerminate` 里交给 store actor 并用信号量等待（≤2 s）
- SwiftUI 列表性能（`SelfTests/13-real-perf.json` 实测）：内容整体换掉的 `Table` / `List`（换排序、搜索、筛选、艺人↔作曲）用 `.id` 重建而不是 diff（diff 会逐行动画并重新量行高，排序 1.4 s）；隐藏的 inspector 仍保留内容，队列视图只在显示时构建（否则开播 322 首时排版全部队列行，~600 ms）；工具栏项放在不随导航推入 / 弹出变化的层级（每次增删工具栏项 ~100 ms）；SwiftUI `Table` 每个可见单元格一个托管视图、逐个量行高，新建一张就要 130–230 ms，所以歌曲表 / 专辑曲目表是 AppKit `NSTableView`（`SongsTableView`，固定行高、单元格复用、换数据只 `reloadData`）
- `Commands` 菜单只在打开时重读模型状态，且禁用的菜单项仍会吞掉自己的快捷键：带快捷键的菜单项不按动态状态禁用，由动作本身判断

## 自测
- 启动参数：`--selftest <script> --out <dir> --data-dir <dir> [--fixtures <dir>] [--online-fixtures <dir>]`（`selftest.sh` 默认传 `SelfTests/online` 录制应答，`ONLINE_LIVE=1` 才连真实的在线来源）；数据目录隔离，不碰真实 Application Support；自测模式下曲库不自动启动
- 动作：`wait` `settle` `window` `appearance` `activate` `sidebar` `snapshot`（`window: main|settings|mini|sheet`，sheet 为主窗口当前弹出的表单） `state` `assert` `waitUntil` `startLibrary`（`include`/`exclude`，缺省用已存/默认目录） `rescan` `fs`（`copy`/`remove`/`move`，只能动 `@out` 内） `openSettings` `play`（`title`/`format`/`minSampleRate`，`context: album|songs`） `togglePlayPause` `pause` `resume` `next` `previous` `seek` `setShuffle` `setRepeat` `measure`（输出 tap 电平/K 加权响度/跳变/空白，增益后、音量前） `enableNowPlaying` `search` `sort`（`column`: title/artist/album/year/duration/added，`ascending`） `openAlbum` `openPerson`（`role`: artist/composer；切到对应侧栏并选中） `back` `scrollList`（`steps`、`interval`；`steps: 0` 回到顶部） `perfReset` `showNowPlaying` `showQueue`（`value`，缺省 true） `seekToLyric`（`index`） `playNext`（`title`） `setNormalization`（`value`: off/track/album） `filter`（`albumArtists`/`years`/`genres`/`formats` 数组、`hiRes`/`hasLyrics` 布尔，都缺省即清空） `miniPlayer`（`value`，缺省 true） `focusSearch` `clearFocus` `focusList`（侧栏右侧的 SwiftUI 列表，如人物列表，取得键盘） `pressKey`（`key`: space/return/f/l/m/left/right/up/down，`modifiers`: command/shift/option，`repeat`；按前台 App 的路径走 `handleKey` → 窗口快捷键 → 菜单快捷键 → 窗口，因为 AppKit 不给非活动 App 匹配快捷键） `closeMainWindow` `openMainWindow` `setVolume`（`value`） `like`（`title`，缺省当前曲目；`value` 缺省 true） `promptPlaylist`（`titles` 新建 / `rename` 列表名，弹出命名框） `commitPlaylistPrompt`（`name`；模拟按下创建 / 重命名） `addToPlaylist` / `removeFromPlaylist`（`name`、`titles`） `movePlaylistTracks`（`name`、`titles`、`to` 移动前的位置） `deletePlaylist`（`name`） `editInfo`（`titles`、`fields` 以 EnrichField 名为键、`keepOpen`；经编辑表单保存） `closeEditInfo` `revertInfo`（`titles`） `enrich`（`titles`，缺省为「全部补全」；等队列跑完） `enrichFilter`（`value`: missingCover/missingLyrics/missingInfo/pending/done） `inspect`（`title`，把合并后的字段写进 `inspected.<标题>`） `openCandidates` / `chooseCandidate` / `rejectMatch`（都要 `title`，`chooseCandidate` 另有 `index`；选择匹配表单的三个操作）；`sidebar` 取 `playlist` 时用 `name` 指定列表 `quit`（先写报告，再走真实退出路径，含保存播放状态）
- 状态键：`app` `ui`（含 `filterChips`、`searchFocused`、`nowPlaying`、`sort`、`selectionCount`、`person` 当前人物的名字/曲目数/专辑数、`playlistPrompt` 命名框标题、`playlist` 当前列表名） `windows`（含 `mini` 面板层级/空间/尺寸、`scrolls` 滚动偏移） `library`（含 `liked` 标题、`playlists` 名字和曲目标题） `player`（含 `queue`、`gainDb`、`skipNotice`） `lyrics` `loudness`（analyzed/failed/total/pending/mode） `measure` `nowPlayingInfo` `snapshots` `perf` `enrich`（`counts` 各分类数量、按匹配状态分组的标题） `inspected`
- 自测模式关闭全部动画（根视图 `.transaction`）：显示器睡眠时动画不推进，带动画的滚动 / 转场会停在第一帧
- 路径占位：`@out`、`@fixtures`
- 夹具里同长度同采样率的音频要用不同频率（`make-fixtures.sh` 的 `FREQ`）：补全按音频内容指纹关联，同一段音频会共享补全结果
- 重启：脚本顶层 `"relaunch": "<相对路径>"` 时，第一段通过后用同一数据目录再启动一次跑第二段（`@out` 为 `<out>/relaunch`）；第二段放 `SelfTests/relaunch/`，不被全量自测单独执行
- 断言比较器：`equals` / `approx`+`tol` / `lt` / `gt` / `contains`；路径为状态 JSON 的点路径（如 `snapshots.shell-dark.isLikelyBlank`）

## Spike 结论（第 1 步）
- `cacheDisplay` 渲染不出侧栏的 Liquid Glass 材质（整块空白）→ `snapshot` 默认用 `screencapture -l <windowNumber>` 截真实窗口，无屏幕录制权限时才退回 `cacheDisplay`
- 窗口必须可见才能截真实画面，因此不做 `alphaValue = 0` 隐藏；显示器睡眠 / 锁屏时 `screencapture -l` 报 "could not create image from window"，快照自动退回 `render` 并在 selftest 输出中警告
- 自测 App 为 `.accessory`，用户在用其他 App 时不会成为前台：禁止合成鼠标点击（会点进别的 App），交互验证只用 AX 动作（`AXSelected` / `AXPress`）；已验证 AX 选中侧栏行、按下播放条按钮都能驱动 UI。AppleScript 的 `entire contents` 遇到 Table 极慢且会挂起，故改用 Swift AX API
- `activate` 是尽力而为：用户在用其他 App 时 macOS 拒绝激活（`app.isActive` 记录结果），截图通常是非活动窗口样式
- `@NSApplicationDelegateAdaptor` 可用
- 锁屏 / 显示器睡眠时 AX 树退化（窗口元素报成 AXApplication），`ax-press` 找不到面板里的元素：AX 走查要在屏幕解锁时做

## 播放引擎要点（第 4 步）
- 播放器节点始终以输出采样率连接、自行变换文件采样率：采样率不同于输出的节点在新挂载时时间线错位，会静音约 1 秒；因此任何采样率之间都无缝，仅声道数变化时换新节点交接
- `playerTime(forNodeTime:)` 对无效的 `lastRenderTime` 会抛 ObjC 异常（无法捕获）：调用前必须检查 `isSampleTimeValid`
- 无 SEEKTABLE 的大 FLAC 首次定位需约 0.5 s（Core Audio 扫描建索引，按文件对象缓存）：同一曲目内定位复用 `AVAudioFile`
- macOS 27 起用 `connectNode(_:to:format:)`、`playAudio()`、`installAudioTap`（`AVReadOnlyAudioPCMBuffer`，Sendable）、`withAUAudioUnit`
- 增益用进程内自注册的 `GainUnit`（AUAudioUnit 子类）：系统效果器（如 AUNBandEQ）的 `scheduleParameterBlock` 只按渲染周期生效（实测落在周期起点），且排好的事件无法撤销。无缝衔接处的增益切换按渲染采样时间精确到帧；暂停会改变播放器时间与渲染时间的映射，所以暂停时撤销（按渲染已到达的一侧取增益）、播放中每个 tick 重新校准
- 单声道经 channelMixer 上混到两侧各 −3 dB；引擎给单声道段补 +3.01 dB，按双单声道播放（与响度测量一致）
