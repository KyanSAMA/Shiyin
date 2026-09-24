# LocalMusic

macOS 27 本地音乐播放器。需求见 `需求与技术路线.md`，分步计划与进度见 `实施计划.md`。

## 命令
- 构建 / 测试：`swift build`、`swift test`
- 打包：`Scripts/bundle.sh [debug|release]` → `build/LocalMusic.app`（ad-hoc 签名；日常使用打 release，debug 版响度分析慢约 10 倍）
- 自测：`Scripts/selftest.sh SelfTests/NN-*.json` → `.build/selftest/<name>/`（PNG、`*.state.json`、`report.json`、`app.log`）；退出码 0 通过 / 1 失败 / 2 超时或崩溃
- 全部自测：`Scripts/run-all-selftests.sh`（结束时用 `find -newer` 证明 `~/Music` 未被写入）；夹具由 `Scripts/make-fixtures.sh` 生成到 `.build/fixtures`（改动时递增 VERSION）
- 无障碍操作：`swift Scripts/ax-press.swift <文本>`（或先 `swiftc -O` 编译），对运行中 App 里标题/描述/值等于该文本的元素做 AX 选中行 / 按下
- 解析校验：`lmtool tags [--stats] [--sha] <路径>`、`lmtool lrc <文件>`、`lmtool scan <db> [<根目录>...]`、`lmtool decode-check <路径>`、`lmtool loudness [--album] <路径>`；`Scripts/validate-loudness.sh` 对照 ffmpeg ebur128（30 首真实曲目，积分响度 ±0.5 LU、无损采样峰值 ±0.1 dB、≥20× 实时）；`Scripts/validate-tags.sh` 用 metaflac / ffprobe 对照真实曲库（只读）

## 硬性约束
- 只有 Command Line Tools：SwiftUI 宏插件缺失，禁用 `@State` / `@Entry` / `#Preview` / Animatable 宏；状态放 `@Observable` 模型，经 `.environment` 注入，`body` 里用 `@Bindable` 或 `Binding(get:set:)`
- `swift test` 依赖 `Package.swift` 里测试目标的 `-plugin-path`（CLT 不会自动传 TestingMacros）
- 零第三方依赖；ffmpeg / ffprobe / metaflac 只用于测试夹具和对照
- 曲库只读：任何代码路径都不得写入曲库目录
- 设置存 SQLite `setting` 表，不用 UserDefaults
- 数据库迁移只追加，不修改已提交的迁移
- 交给 AVFAudio / MediaPlayer / FSEvents 的回调闭包在 `LocalMusicCore` 的非隔离代码或 `nonisolated static` 工厂里构造，只捕获 Sendable 值，再 `Task { @MainActor in … }` 切回
- App 目标默认 MainActor 隔离；纯逻辑放 `LocalMusicCore` 以便单测
- 布局：`scaledToFill` 的图片放 `.background` 并 `.clipped()`，作为 ZStack 子视图会按填充尺寸撑大父视图
- Table 单元格等深层视图不用 `@Environment(AppModel.self)`（排序重建行时会查不到而崩溃），由表格层取出后显式传参（如 `CoverView(store:)`、`PlayingMark(player:)`）
- UI 文案中文硬编码（SwiftPM 打包的 .app 不带资源 bundle）

## 自测
- 启动参数：`--selftest <script> --out <dir> --data-dir <dir> [--fixtures <dir>]`；数据目录隔离，不碰真实 Application Support；自测模式下曲库不自动启动
- 动作：`wait` `settle` `window` `appearance` `activate` `sidebar` `snapshot`（`window: main|settings`） `state` `assert` `waitUntil` `startLibrary`（`include`/`exclude`，缺省用已存/默认目录） `rescan` `fs`（`copy`/`remove`，只能写 `@out` 内） `openSettings` `play`（`title`/`format`/`minSampleRate`，`context: album|songs`） `togglePlayPause` `pause` `resume` `next` `previous` `seek` `setShuffle` `setRepeat` `measure`（输出 tap 电平/跳变/空白） `enableNowPlaying` `search` `sort`（`column`: title/artist/album/year/duration/added，`ascending`） `openAlbum` `openPerson`（`role`: artist/composer） `back` `scrollList`（`steps`、`interval`；`steps: 0` 回到顶部） `perfReset` `showNowPlaying` `showQueue`（`value`，缺省 true） `seekToLyric`（`index`） `playNext`（`title`）
- 状态键：`app` `ui` `windows`（含 `scrolls` 滚动偏移） `library` `player`（含 `queue`） `lyrics` `loudness`（analyzed/failed/total/pending） `measure` `nowPlayingInfo` `snapshots` `perf`
- 自测模式关闭全部动画（根视图 `.transaction`）：显示器睡眠时动画不推进，带动画的滚动 / 转场会停在第一帧
- 路径占位：`@out`、`@fixtures`
- 断言比较器：`equals` / `approx`+`tol` / `lt` / `gt` / `contains`；路径为状态 JSON 的点路径（如 `snapshots.shell-dark.isLikelyBlank`）

## Spike 结论（第 1 步）
- `cacheDisplay` 渲染不出侧栏的 Liquid Glass 材质（整块空白）→ `snapshot` 默认用 `screencapture -l <windowNumber>` 截真实窗口，无屏幕录制权限时才退回 `cacheDisplay`
- 窗口必须可见才能截真实画面，因此不做 `alphaValue = 0` 隐藏；显示器睡眠 / 锁屏时 `screencapture -l` 报 "could not create image from window"，快照自动退回 `render` 并在 selftest 输出中警告
- 自测 App 为 `.accessory`，用户在用其他 App 时不会成为前台：禁止合成鼠标点击（会点进别的 App），交互验证只用 AX 动作（`AXSelected` / `AXPress`）；已验证 AX 选中侧栏行、按下播放条按钮都能驱动 UI。AppleScript 的 `entire contents` 遇到 Table 极慢且会挂起，故改用 Swift AX API
- `activate` 是尽力而为：用户在用其他 App 时 macOS 拒绝激活（`app.isActive` 记录结果），截图通常是非活动窗口样式
- `@NSApplicationDelegateAdaptor` 可用

## 播放引擎要点（第 4 步）
- 播放器节点始终以输出采样率连接、自行变换文件采样率：采样率不同于输出的节点在新挂载时时间线错位，会静音约 1 秒；因此任何采样率之间都无缝，仅声道数变化时换新节点交接
- `playerTime(forNodeTime:)` 对无效的 `lastRenderTime` 会抛 ObjC 异常（无法捕获）：调用前必须检查 `isSampleTimeValid`
- 无 SEEKTABLE 的大 FLAC 首次定位需约 0.5 s（Core Audio 扫描建索引，按文件对象缓存）：同一曲目内定位复用 `AVAudioFile`
- macOS 27 起用 `connectNode(_:to:format:)`、`playAudio()`、`installAudioTap`（`AVReadOnlyAudioPCMBuffer`，Sendable）
