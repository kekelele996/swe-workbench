import Cocoa
import WebKit

enum Theme {
    static let paper = NSColor(name: "paper") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.063, green: 0.075, blue: 0.091, alpha: 1)
            : NSColor(srgbRed: 0.969, green: 0.965, blue: 0.949, alpha: 1)
    }

    static let ink = NSColor(name: "ink") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.925, green: 0.914, blue: 0.894, alpha: 1)
            : NSColor(srgbRed: 0.102, green: 0.118, blue: 0.145, alpha: 1)
    }

    static let muted = NSColor.secondaryLabelColor
    static let signal = NSColor(srgbRed: 0.824, green: 0.271, blue: 0.082, alpha: 1)
}

/// 纯色底视图，跟随浅色/深色外观。
class PaperView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Theme.paper.setFill()
        dirtyRect.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// 按钮的闭包封装，避免为每个按钮维护 tag/选择器。
final class BlockButton: NSButton {
    var handler: (() -> Void)?

    @objc private func fire(_ sender: Any?) {
        handler?()
    }

    static func make(_ title: String, primary: Bool = false, handler: @escaping () -> Void) -> BlockButton {
        let button = BlockButton(title: title, target: nil, action: nil)
        button.handler = handler
        button.target = button
        button.action = #selector(BlockButton.fire(_:))
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.font = NSFont.systemFont(ofSize: 13, weight: primary ? .semibold : .regular)
        if primary { button.keyEquivalent = "\r" }
        return button
    }
}

/// 启动中 / 启动失败的覆盖层。
final class StatusOverlay: PaperView {
    var onRetry: (() -> Void)?
    var onChooseRoot: (() -> Void)?
    var onOpenLog: (() -> Void)?

    private let spinner = NSProgressIndicator()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let buttons = NSStackView()
    private let stack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isDisplayedWhenStopped = false

        titleLabel.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = Theme.ink
        titleLabel.alignment = .center

        detailLabel.font = NSFont.systemFont(ofSize: 12.5)
        detailLabel.textColor = Theme.muted
        detailLabel.alignment = .center
        detailLabel.maximumNumberOfLines = 12
        detailLabel.preferredMaxLayoutWidth = 520
        detailLabel.isSelectable = true

        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.alignment = .centerY

        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(spinner)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(detailLabel)
        stack.addArrangedSubview(buttons)
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 40),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -40),
            detailLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 520)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }

    func showLoading(_ message: String, detail: String = "") {
        clearButtons()
        spinner.startAnimation(nil)
        titleLabel.stringValue = message
        detailLabel.stringValue = detail
        detailLabel.isHidden = detail.isEmpty
    }

    func showError(_ message: String) {
        clearButtons()
        spinner.stopAnimation(nil)
        titleLabel.stringValue = "本地服务没有启动"
        detailLabel.stringValue = message
        detailLabel.isHidden = false

        buttons.addArrangedSubview(BlockButton.make("重试", primary: true) { [weak self] in self?.onRetry?() })
        buttons.addArrangedSubview(BlockButton.make("换个工作目录…") { [weak self] in self?.onChooseRoot?() })
        buttons.addArrangedSubview(BlockButton.make("查看日志") { [weak self] in self?.onOpenLog?() })
    }

    private func clearButtons() {
        for view in buttons.arrangedSubviews {
            buttons.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }
}

/// The page header doubles as the window header. This 28pt strip keeps the
/// standard titlebar drag and leaves the traffic lights clickable.
final class TitlebarDragStrip: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if point.x < 78 { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

/// 主窗口：承载 WKWebView、接管导航策略、下载与文件选择面板。
final class MainWindowController: NSWindowController {
    private let supervisor: ServerSupervisor
    private var webView: WKWebView!
    private var overlay: StatusOverlay!
    private var downloads: [WKDownload] = []
    private var didLoadOnce = false
    private var loadFailed = false

    private(set) var currentRoot: URL
    private(set) var serverURL: URL?

    var onFirstLoad: (() -> Void)?
    var onChooseRoot: (() -> Void)?
    var onRestart: (() -> Void)?

    init(supervisor: ServerSupervisor, root: URL) {
        self.supervisor = supervisor
        self.currentRoot = root

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 860),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered,
                              defer: false)
        super.init(window: window)

        window.title = "SWE 工作台"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.minSize = NSSize(width: 960, height: 620)
        window.backgroundColor = Theme.paper
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("SWEMainWindow")
        if !window.setFrameUsingName("SWEMainWindow") {
            window.setContentSize(NSSize(width: 1280, height: 860))
            window.center()
        }
        buildContent()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }

    // MARK: - 视图

    private func buildContent() {
        guard let window else { return }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let userContent = WKUserContentController()
        userContent.addUserScript(WKUserScript(source: "document.documentElement.dataset.shell='mac';",
                                                injectionTime: .atDocumentStart,
                                                forMainFrameOnly: true))
        configuration.userContentController = userContent

        let web = WKWebView(frame: .zero, configuration: configuration)
        web.translatesAutoresizingMaskIntoConstraints = false
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = false
        web.allowsMagnification = false
        if #available(macOS 13.3, *) {
            web.isInspectable = ProcessInfo.processInfo.environment["SWE_WORKBENCH_DEBUG"] == "1"
        }
        webView = web

        let container = PaperView(frame: .zero)
        container.addSubview(web)
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            web.topAnchor.constraint(equalTo: container.topAnchor),
            web.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        let drag = TitlebarDragStrip(frame: .zero)
        drag.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(drag)
        NSLayoutConstraint.activate([
            drag.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            drag.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            drag.topAnchor.constraint(equalTo: container.topAnchor),
            drag.heightAnchor.constraint(equalToConstant: 28)
        ])

        let status = StatusOverlay(frame: .zero)
        status.translatesAutoresizingMaskIntoConstraints = false
        status.onRetry = { [weak self] in self?.onRestart?() }
        status.onChooseRoot = { [weak self] in self?.onChooseRoot?() }
        status.onOpenLog = { NSWorkspace.shared.open(Log.fileURL) }
        status.showLoading("正在启动本地服务…")
        container.addSubview(status)
        NSLayoutConstraint.activate([
            status.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            status.topAnchor.constraint(equalTo: container.topAnchor),
            status.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        overlay = status

        window.contentView = container
        window.makeFirstResponder(web)
    }

    // MARK: - 状态

    func apply(_ state: ServerSupervisor.State) {
        switch state {
        case .idle:
            overlay.showLoading("正在启动本地服务…")
        case .starting:
            overlay.showLoading("正在启动本地服务…", detail: "首次启动需要 1–2 秒。")
            webView.isHidden = !didLoadOnce
        case .ready(let url):
            serverURL = url
            loadFailed = false
            webView.isHidden = false
            overlay.isHidden = true
            updateSubtitle()
            if webView.url != url || !didLoadOnce {
                load(url)
            }
        case .failed(let message):
            loadFailed = true
            overlay.isHidden = false
            overlay.showError(message)
            updateSubtitle()
        }
    }

    func updateRoot(_ url: URL) {
        currentRoot = url
        updateSubtitle()
    }

    private func updateSubtitle() {
        // The page header is the window header; the native title is hidden and
        // the local port never appears in the chrome.
        window?.subtitle = ""
    }

    private func load(_ url: URL) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("SWE-Workbench/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        webView.load(request)
    }

    // MARK: - 菜单动作

    func focusSearch() {
        webView.evaluateJavaScript("document.getElementById('search')?.focus()")
    }

    func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        webView.evaluateJavaScript("location.hash='#/settings'")
    }

    func reloadPage() {
        if let serverURL {
            load(serverURL)
        } else {
            onRestart?()
        }
    }

    func hardReload() {
        guard let url = serverURL else { return }
        webView.reloadFromOrigin()
        Log.info("硬性重载 \(url.absoluteString)")
    }

    func openInBrowser() {
        guard let url = serverURL else { return }
        NSWorkspace.shared.open(url)
    }

    func copyAddress() {
        guard let url = serverURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    func zoom(_ delta: CGFloat) {
        let current = webView.pageZoom
        webView.pageZoom = min(max(current + delta, 0.6), 1.8)
    }

    func resetZoom() {
        webView.pageZoom = 1.0
    }

    func currentWorkspaceRoot() -> URL {
        if let path = supervisor.current?.root, !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return currentRoot
    }

    // MARK: - 自检（不依赖屏幕录制权限：用 WKWebView 自身快照）

    func captureSelfTest(to path: String) {
        guard let webView else {
            Log.error("SELFTEST FAIL 没有 webView")
            NSApp.terminate(nil)
            return
        }
        let script = """
        JSON.stringify({
          title: document.title,
          ready: document.readyState,
          href: location.href,
          nodes: document.querySelectorAll('*').length,
          tasks: document.querySelectorAll('#list .row').length,
          topbar: (document.querySelector('.brand strong') || {}).textContent || '',
          text: (document.body ? document.body.innerText : '').replace(/\\s+/g, ' ').slice(0, 160)
        })
        """
        webView.evaluateJavaScript(script) { [weak self] result, error in
            guard let self else { return }
            let js = (result as? String) ?? "error:\(error?.localizedDescription ?? "unknown")"
            let configuration = WKSnapshotConfiguration()
            configuration.rect = self.webView.bounds
            self.webView.takeSnapshot(with: configuration) { image, snapshotError in
                var written = false
                if let image, let data = image.pngData() {
                    written = (try? data.write(to: URL(fileURLWithPath: path))) != nil
                }
                let snapshotNote = snapshotError.map { "snapshotError=\($0.localizedDescription)" } ?? ""
                Log.info("SELFTEST \(written ? "OK" : "FAIL") png=\(path) written=\(written) "
                         + "url=\(self.webView.url?.absoluteString ?? "-") "
                         + "server=\(self.serverURL?.absoluteString ?? "-") "
                         + "didLoad=\(self.didLoadOnce) loadFailed=\(self.loadFailed) "
                         + "js=\(js) \(snapshotNote)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    NSApp.terminate(nil)
                }
            }
        }
    }
}

// MARK: - 导航策略

extension MainWindowController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        // target="_blank" 或 window.open：交给系统浏览器。
        if navigationAction.targetFrame == nil {
            openExternally(url)
            decisionHandler(.cancel)
            return
        }

        switch url.scheme?.lowercased() {
        case "http", "https":
            if isLocal(url) {
                decisionHandler(.allow)
            } else {
                openExternally(url)
                decisionHandler(.cancel)
            }
        case "about", "blob", "data":
            decisionHandler(.allow)
        case "file":
            decisionHandler(.cancel)
        default:
            openExternally(url)
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if !navigationResponse.canShowMIMEType || isAttachment(navigationResponse.response) {
            decisionHandler(.download)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, navigationResponse response: WKNavigationResponse,
                 didBecome download: WKDownload) {
        download.delegate = self
        downloads.append(download)
    }

    func webView(_ webView: WKWebView, navigationAction action: WKNavigationAction,
                 didBecome download: WKDownload) {
        download.delegate = self
        downloads.append(download)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        Log.info("开始加载 \(webView.url?.absoluteString ?? "-")")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let first = !didLoadOnce
        didLoadOnce = true
        loadFailed = false
        overlay.isHidden = true
        webView.isHidden = false
        window?.makeFirstResponder(webView)
        Log.info("加载完成 title=\(webView.title ?? "-") url=\(webView.url?.absoluteString ?? "-")")
        if first {
            onFirstLoad?()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleLoadFailure(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        handleLoadFailure(error)
    }

    private func handleLoadFailure(_ error: Error) {
        guard !loadFailed else { return }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }
        loadFailed = true
        Log.error("加载失败：\(error.localizedDescription)")
        overlay.isHidden = false
        overlay.showError("页面加载失败：\(error.localizedDescription)\n\n服务地址：\(serverURL?.absoluteString ?? "未知")")
    }

    private func isLocal(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        guard host == "127.0.0.1" || host == "localhost" || host == "::1" else { return false }
        if let port = url.port, let expected = serverURL?.port, port != expected { return false }
        return true
    }

    private func openExternally(_ url: URL) {
        if url.scheme == nil || url.scheme == "file" { return }
        Log.info("打开外部链接 \(url.absoluteString)")
        NSWorkspace.shared.open(url)
    }

    private func isAttachment(_ response: URLResponse) -> Bool {
        if let http = response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition") {
            return disposition.lowercased().contains("attachment")
        }
        return false
    }
}

// MARK: - JS 面板、文件选择、弹窗

extension MainWindowController: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            openExternally(url)
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = "SWE 工作台"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        present(alert) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "确认"
        alert.informativeText = message
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        present(alert) { response in completionHandler(response == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = "输入"
        alert.informativeText = prompt
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        present(alert) { response in
            completionHandler(response == .alertFirstButtonReturn ? field.stringValue : nil)
        }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        panel.message = "选择工作台需要的文件"
        choose(with: panel) { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }

    private func present(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window, window.isVisible {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    private func choose(with panel: NSOpenPanel, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window, window.isVisible {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }
}

// MARK: - 下载

extension MainWindowController: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename
        panel.canCreateDirectories = true
        if let downloadsDirectory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            panel.directoryURL = downloadsDirectory
        }
        panel.begin { result in
            completionHandler(result == .OK ? panel.url : nil)
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        downloads.removeAll { $0 === download }
        Log.info("下载完成 \(download.originalRequest?.url?.absoluteString ?? "-")")
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloads.removeAll { $0 === download }
        Log.error("下载失败 \(error.localizedDescription)")
        let alert = NSAlert()
        alert.messageText = "下载失败"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "好")
        if let window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }
}
