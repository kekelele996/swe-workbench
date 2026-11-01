import Cocoa
import WebKit

// MARK: - 自检参数

/// 隐藏的自检模式：加载完成后给 WKWebView 拍一张快照并退出。
/// 由 SWE_WORKBENCH_SELFTEST=<png 路径> 或 --self-test [路径] 触发，用于无人值守验证。
struct SelfTestConfig {
    let outputPath: String
    let delay: TimeInterval

    static var current: SelfTestConfig? {
        let arguments = CommandLine.arguments
        let environment = ProcessInfo.processInfo.environment
        var raw: String?

        if let value = environment["SWE_WORKBENCH_SELFTEST"], !value.isEmpty {
            raw = value
        }
        if raw == nil, let index = arguments.firstIndex(of: "--self-test") {
            let next = index + 1 < arguments.count ? arguments[index + 1] : nil
            raw = (next?.hasPrefix("-") == false) ? next : "1"
        }
        guard let raw else { return nil }

        let path = raw == "1"
            ? NSTemporaryDirectory() + "swe-workbench-selftest.png"
            : NSString(string: raw).expandingTildeInPath
        let milliseconds = Double(environment["SWE_WORKBENCH_SELFTEST_DELAY_MS"] ?? "") ?? 2500
        return SelfTestConfig(outputPath: path, delay: max(milliseconds, 0) / 1000)
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController?
    private var supervisor: ServerSupervisor?
    private var preferredPort = ServerSupervisor.defaultPort
    private var selfTest: SelfTestConfig?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("==== 启动 \(Bundle.main.bundleIdentifier ?? "dev") pid=\(ProcessInfo.processInfo.processIdentifier) args=\(CommandLine.arguments)")

        // The UI is embedded in the local service. A rebuilt app must never show
        // a cached app.js/style.css from a previous launch.
        URLCache.shared = URLCache(memoryCapacity: 0, diskCapacity: 0, diskPath: nil)
        WKWebsiteDataStore.default().removeData(
            ofTypes: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache],
            modifiedSince: .distantPast
        ) { }

        selfTest = SelfTestConfig.current
        if selfTest == nil, activateExistingInstance() { return }

        buildMenu()

        let root = resolveRoot()
        preferredPort = resolvePort()
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let supervisor = ServerSupervisor(root: root)
        self.supervisor = supervisor

        let controller = MainWindowController(supervisor: supervisor, root: root)
        self.windowController = controller
        controller.onChooseRoot = { [weak self] in self?.chooseRoot(nil) }
        controller.onRestart = { [weak self] in self?.restartServer(nil) }
        if let selfTest {
            controller.onFirstLoad = { [weak self] in self?.runSelfTest(selfTest) }
            // 自检看门狗：服务起不来或页面一直不完成，也要留下结论并退出。
            DispatchQueue.main.asyncAfter(deadline: .now() + selfTest.delay + 25) { [weak self] in
                guard let self else { return }
                Log.error("SELFTEST TIMEOUT 页面在限定时间内没有完成加载")
                self.shutdownForSelfTest()
            }
        }

        supervisor.onState = { [weak controller] state in
            controller?.apply(state)
        }

        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        Log.info("工作目录=\(root.path) 首选端口=\(preferredPort)")
        supervisor.start(preferredPort: preferredPort)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { windowController?.showWindow(nil) }
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let supervisor else { return .terminateNow }
        Log.info("退出中：\(supervisor.mode == .owned ? "关闭本 App 启动的服务" : "保留外部服务")")
        supervisor.stopSynchronously()
        Log.info("本地服务已收尾，退出")
        return .terminateNow
    }

    // MARK: - 自检

    private func runSelfTest(_ config: SelfTestConfig) {
        DispatchQueue.main.asyncAfter(deadline: .now() + config.delay) { [weak self] in
            self?.windowController?.captureSelfTest(to: config.outputPath)
        }
    }

    private func shutdownForSelfTest() {
        NSApp.terminate(nil)
    }

    // MARK: - 单实例

    private func activateExistingInstance() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty else { return false }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard let other = others.first else { return false }
        Log.info("已有实例 pid=\(other.processIdentifier)，激活它并退出本次启动")
        other.activate(options: [.activateAllWindows])
        NSApp.terminate(nil)
        return true
    }

    // MARK: - 配置

    private func resolveRoot() -> URL {
        let environment = ProcessInfo.processInfo.environment
        let arguments = CommandLine.arguments

        if let value = environment["SWE_WORKBENCH_ROOT"], !value.isEmpty {
            return URL(fileURLWithPath: NSString(string: value).expandingTildeInPath)
        }
        if let index = arguments.firstIndex(of: "--root"), index + 1 < arguments.count {
            return URL(fileURLWithPath: NSString(string: arguments[index + 1]).expandingTildeInPath)
        }
        if let saved = UserDefaults.standard.string(forKey: "workRoot"), !saved.isEmpty {
            return URL(fileURLWithPath: NSString(string: saved).expandingTildeInPath)
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let legacy = home.appendingPathComponent("Documents/ChatGPT/swe", isDirectory: true)
        if FileManager.default.fileExists(atPath: legacy.path) { return legacy }
        return home.appendingPathComponent("Documents/SWE-work", isDirectory: true)
    }

    private func resolvePort() -> Int {
        let environment = ProcessInfo.processInfo.environment
        if let value = environment["SWE_WORKBENCH_PORT"], let port = Int(value), port > 0, port < 65536 {
            return port
        }
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--port"), index + 1 < arguments.count,
           let port = Int(arguments[index + 1]), port > 0, port < 65536 {
            return port
        }
        return ServerSupervisor.defaultPort
    }

    // MARK: - 菜单动作

    @objc private func showAbout(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "SWE 工作台",
            .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.1.0",
            .version: "swe-flow 本地工作台",
            .credits: NSAttributedString(string: "面向 SWE 题目制作、验收与提交的本地工作台。",
                                         attributes: [.font: NSFont.systemFont(ofSize: 11)])
        ])
    }

    @objc private func openSettings(_ sender: Any?) { windowController?.openSettings() }

    @objc private func chooseRoot(_ sender: Any?) {
        guard let controller = windowController else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "使用此目录"
        panel.message = "选择 SWE 任务工作目录（包含 sources/ 与 workflow/ 的那一级）"
        panel.directoryURL = controller.currentWorkspaceRoot()
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.useRoot(url)
        }
    }

    private func useRoot(_ url: URL) {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            Log.error("创建工作目录失败：\(error.localizedDescription)")
        }
        UserDefaults.standard.set(url.path, forKey: "workRoot")
        windowController?.updateRoot(url)
        windowController?.apply(.starting)
        supervisor?.restart(root: url, preferredPort: preferredPort, forceOwned: true)
        Log.info("切换工作目录到 \(url.path)")
    }

    @objc private func restartServer(_ sender: Any?) {
        windowController?.apply(.starting)
        supervisor?.restart(root: nil, preferredPort: preferredPort, forceOwned: true)
        Log.info("手动重启本地服务")
    }

    @objc private func revealRoot(_ sender: Any?) {
        let root = windowController?.currentWorkspaceRoot() ?? FileManager.default.homeDirectoryForCurrentUser
        NSWorkspace.shared.activateFileViewerSelecting([root])
    }

    @objc private func openLog(_ sender: Any?) {
        NSWorkspace.shared.open(Log.fileURL)
    }

    @objc private func reloadPage(_ sender: Any?) { windowController?.reloadPage() }
    @objc private func hardReloadPage(_ sender: Any?) { windowController?.hardReload() }
    @objc private func focusSearch(_ sender: Any?) { windowController?.focusSearch() }
    @objc private func zoomIn(_ sender: Any?) { windowController?.zoom(0.1) }
    @objc private func zoomOut(_ sender: Any?) { windowController?.zoom(-0.1) }
    @objc private func zoomReset(_ sender: Any?) { windowController?.resetZoom() }

    // MARK: - 菜单

    private func item(_ title: String,
                      _ action: Selector?,
                      _ key: String = "",
                      _ modifiers: NSEvent.ModifierFlags = .command,
                      target: AnyObject? = nil) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menuItem.keyEquivalentModifierMask = modifiers
        menuItem.target = target ?? self
        return menuItem
    }

    // Standard editing actions must travel the responder chain. Giving them the
    // AppDelegate as target disables ⌘C/⌘V inside the WKWebView.
    private func systemItem(_ title: String,
                            _ action: Selector,
                            _ key: String = "",
                            _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menuItem.keyEquivalentModifierMask = modifiers
        menuItem.target = nil
        return menuItem
    }

    private func buildMenu() {
        let mainMenu = NSMenu()

        // 应用菜单
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "SWE 工作台")
        appMenu.addItem(item("关于 SWE 工作台", #selector(showAbout(_:))))
        appMenu.addItem(item("设置…", #selector(openSettings(_:)), ","))
        appMenu.addItem(.separator())
        appMenu.addItem(item("选择工作目录…", #selector(chooseRoot(_:)), "o", [.command, .shift]))
        appMenu.addItem(item("在 Finder 中显示工作目录", #selector(revealRoot(_:)), "f", [.command, .shift]))
        appMenu.addItem(item("打开日志", #selector(openLog(_:)), "l", [.command, .shift]))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 SWE 工作台", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = NSMenuItem(title: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(withTitle: "全部显示", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 SWE 工作台", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // 编辑菜单：WKWebView 的剪切/复制/粘贴依赖响应链，缺了菜单就按不了快捷键。
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(systemItem("撤销", Selector(("undo:")), "z"))
        editMenu.addItem(systemItem("重做", Selector(("redo:")), "z", [.command, .shift]))
        editMenu.addItem(.separator())
        editMenu.addItem(systemItem("剪切", #selector(NSText.cut(_:)), "x"))
        editMenu.addItem(systemItem("拷贝", #selector(NSText.copy(_:)), "c"))
        editMenu.addItem(systemItem("粘贴", #selector(NSText.paste(_:)), "v"))
        editMenu.addItem(systemItem("全选", #selector(NSText.selectAll(_:)), "a"))
        editMenu.addItem(.separator())
        editMenu.addItem(item("查找", #selector(focusSearch(_:)), "f"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // 显示菜单
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "显示")
        viewMenu.addItem(item("刷新", #selector(reloadPage(_:)), "r"))
        viewMenu.addItem(.separator())
        viewMenu.addItem(item("实际大小", #selector(zoomReset(_:)), "0"))
        viewMenu.addItem(item("放大", #selector(zoomIn(_:)), "+"))
        viewMenu.addItem(item("缩小", #selector(zoomOut(_:)), "-"))
        viewMenu.addItem(.separator())
        let fullScreen = NSMenuItem(title: "进入全屏", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.control, .command]
        viewMenu.addItem(fullScreen)
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // 工作台菜单：只保留应用自己的动作，不再暴露浏览器地址。
        let serverMenuItem = NSMenuItem()
        let serverMenu = NSMenu(title: "工作台")
        serverMenu.addItem(item("重启本地服务", #selector(restartServer(_:)), "r", [.command, .option]))
        serverMenu.addItem(item("打开日志", #selector(openLog(_:)), "l", [.command, .shift]))
        serverMenu.addItem(item("在 Finder 中显示工作目录", #selector(revealRoot(_:)), "f", [.command, .shift]))
        serverMenuItem.submenu = serverMenu
        mainMenu.addItem(serverMenuItem)

        // 窗口菜单
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "前置全部窗口", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        // 帮助菜单
        let helpMenuItem = NSMenuItem()
        let helpMenu = NSMenu(title: "帮助")
        helpMenu.addItem(item("打开日志", #selector(openLog(_:))))
        helpMenu.addItem(item("在 Finder 中显示工作目录", #selector(revealRoot(_:))))
        helpMenuItem.submenu = helpMenu
        mainMenu.addItem(helpMenuItem)
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = mainMenu
    }
}

// MARK: - 入口

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
