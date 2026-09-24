# LocalMusic

macOS 27 本地音乐播放器。需求见 `需求与技术路线.md`，分步计划与进度见 `实施计划.md`。

## 命令
- 构建 / 测试：`swift build`、`swift test`
- 打包：`Scripts/bundle.sh [debug|release]` → `build/LocalMusic.app`（ad-hoc 签名）
- 自测：`Scripts/selftest.sh SelfTests/NN-*.json` → `.build/selftest/<name>/`（PNG、`*.state.json`、`report.json`、`app.log`）；退出码 0 通过 / 1 失败 / 2 超时或崩溃
- 无障碍操作：`Scripts/ax-click.sh <文本>`，对运行中窗口的元素做 AX 选中 / 按下

## 硬性约束
- 只有 Command Line Tools：SwiftUI 宏插件缺失，禁用 `@State` / `@Entry` / `#Preview` / Animatable 宏；状态放 `@Observable` 模型，经 `.environment` 注入，`body` 里用 `@Bindable` 或 `Binding(get:set:)`
- `swift test` 依赖 `Package.swift` 里测试目标的 `-plugin-path`（CLT 不会自动传 TestingMacros）
- 零第三方依赖；ffmpeg / ffprobe / metaflac 只用于测试夹具和对照
- 曲库只读：任何代码路径都不得写入曲库目录
- 设置存 SQLite `setting` 表，不用 UserDefaults
- 数据库迁移只追加，不修改已提交的迁移
- 交给 AVFAudio / MediaPlayer / FSEvents 的回调闭包在 `LocalMusicCore` 的非隔离代码或 `nonisolated static` 工厂里构造，只捕获 Sendable 值，再 `Task { @MainActor in … }` 切回
- App 目标默认 MainActor 隔离；纯逻辑放 `LocalMusicCore` 以便单测
- UI 文案中文硬编码（SwiftPM 打包的 .app 不带资源 bundle）

## 自测
- 启动参数：`--selftest <script> --out <dir> --data-dir <dir> [--fixtures <dir>]`；数据目录隔离，不碰真实 Application Support
- 动作：`wait` `settle` `window` `appearance` `activate` `sidebar` `snapshot` `state` `assert` `waitUntil`
- 断言比较器：`equals` / `approx`+`tol` / `lt` / `gt` / `contains`；路径为状态 JSON 的点路径（如 `snapshots.shell-dark.isLikelyBlank`）

## Spike 结论（第 1 步）
- `cacheDisplay` 渲染不出侧栏的 Liquid Glass 材质（整块空白）→ `snapshot` 默认用 `screencapture -l <windowNumber>` 截真实窗口，无屏幕录制权限时才退回 `cacheDisplay`
- 窗口必须可见才能截真实画面，因此不做 `alphaValue = 0` 隐藏
- 自测 App 为 `.accessory`，用户在用其他 App 时不会成为前台：禁止合成鼠标点击（会点进别的 App），交互验证只用 AX 动作（`AXSelected` / `AXPress`）；已验证 AX 选中侧栏行能驱动 SwiftUI 选择
- `activate` 是尽力而为：用户在用其他 App 时 macOS 拒绝激活（`app.isActive` 记录结果），截图通常是非活动窗口样式
- `@NSApplicationDelegateAdaptor` 可用
