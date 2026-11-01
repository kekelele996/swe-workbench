import Foundation

struct ServerInfo {
    let url: URL
    let root: String?
    let workRoot: String?
}

/// 负责托管 `swe-flow serve`：
/// - 若目标端口上已经有同一套工作台在跑，就直接接管（不重复启动、退出时也不去关它）；
/// - 否则用 App 内置的 swe-flow 起一个子进程，端口冲突时退回随机端口；
/// - App 退出时只关闭自己启动的进程。
final class ServerSupervisor {
    enum Mode {
        case owned      // 由本 App 启动，退出时负责关闭
        case external   // 复用已在运行的实例，退出时保持不动
    }

    enum State {
        case idle
        case starting
        case ready(URL)
        case failed(String)
    }

    static let defaultPort = 8765

    private let queue = DispatchQueue(label: "com.gaobo.swe-workbench.server", qos: .userInitiated)
    private let lock = NSLock()

    private(set) var root: URL
    private var process: Process?
    private var outputBuffer = ""
    private var stderrTail: [String] = []
    private var generation = 0
    private var cancelRequested = false
    private var lastError: String?
    /// 上次会话由本 App 启动、App 异常退出后遗留的服务进程。
    private var adoptedPID: Int32?

    /// 只在主线程读取。UI 依赖这两个值显示地址和工作目录。
    private(set) var mode: Mode = .owned
    private(set) var current: ServerInfo?

    /// 状态回调总在主线程触发。
    var onState: ((State) -> Void)?

    init(root: URL) {
        self.root = root
    }

    // MARK: - 生命周期

    func start(preferredPort: Int = ServerSupervisor.defaultPort) {
        queue.async {
            self.startLocked(preferredPort: preferredPort, forceOwned: false)
        }
    }

    func restart(root newRoot: URL? = nil,
                 preferredPort: Int = ServerSupervisor.defaultPort,
                 forceOwned: Bool = true) {
        requestCancel()
        queue.async {
            self.generation += 1
            self.teardownLocked()
            if let newRoot { self.root = newRoot }
            self.startLocked(preferredPort: preferredPort, forceOwned: forceOwned)
        }
    }

    /// 供退出流程使用：阻塞到子进程确实结束（子进程正常会立刻响应 SIGTERM）。
    /// 启动等待中的队列会被 cancel 标记在 ~100ms 内打断。
    func stopSynchronously(timeout: TimeInterval = 5) {
        requestCancel()
        let semaphore = DispatchSemaphore(value: 0)
        queue.async {
            self.generation += 1
            self.teardownLocked()
            Self.clearState()
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            Log.warn("关闭本地服务超时，继续退出")
        }
    }

    func stop(completion: (() -> Void)? = nil) {
        requestCancel()
        queue.async {
            self.generation += 1
            self.teardownLocked()
            Self.clearState()
            DispatchQueue.main.async { completion?() }
        }
    }

    // MARK: - 启动流程

    private func startLocked(preferredPort: Int, forceOwned: Bool) {
        generation += 1
        let gen = generation
        resetCancel()
        teardownLocked()
        lastError = nil
        publish(.starting)

        // 1. 上次退出没来得及收尾的自家服务：重新接管，退出时负责关闭。
        if !forceOwned, adoptOrphanLocked() { return }

        // 2. 端口上已经是同一套工作台（例如终端里手动起的）：直接连上，但不负责关闭。
        if !forceOwned, let info = Self.fetchInfo(base: Self.baseURL(port: preferredPort)) {
            Self.clearState()
            Log.info("复用已在运行的工作台 \(info.url.absoluteString) root=\(info.root ?? "-")")
            publish(.ready(info.url), info: info, mode: .external)
            return
        }

        // 3. 自己起服务；端口被占则交回系统挑一个空闲端口。
        Self.clearState()
        let port = Self.isPortFree(preferredPort) ? preferredPort : 0
        var ok = spawnLocked(port: port, gen: gen)
        if !ok, !isCancelled, gen == generation, port != 0 {
            Log.warn("端口 \(port) 启动失败，改用随机端口重试")
            ok = spawnLocked(port: 0, gen: gen)
        }
        if !ok, !isCancelled, gen == generation {
            publish(.failed(lastError ?? "本地服务没有启动。"))
        }
    }

    @discardableResult
    private func spawnLocked(port: Int, gen: Int) -> Bool {
        guard let binary = Self.binaryURL() else {
            lastError = "找不到 swe-flow。请重新构建 App，或设置 SWE_WORKBENCH_BINARY 指向可执行文件。"
            return false
        }

        let proc = Process()
        proc.executableURL = binary
        proc.arguments = ["serve", "-root", root.path, "-port", String(port)]
        proc.currentDirectoryURL = root

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = Self.childPath()
        environment.removeValue(forKey: "SWE_WORKBENCH_SELFTEST")
        environment.removeValue(forKey: "SWE_WORKBENCH_ROOT")
        environment.removeValue(forKey: "SWE_WORKBENCH_PORT")
        if let tools = Self.bundledToolsURL() {
            environment["SWE_FLOW_TOOLS"] = tools.path
        }
        proc.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr
        proc.standardInput = FileHandle.nullDevice

        lock.lock()
        outputBuffer = ""
        stderrTail = []
        lock.unlock()

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let text = String(data: data, encoding: .utf8) else { return }
            guard let self else { return }
            self.lock.lock()
            self.outputBuffer += text
            if self.outputBuffer.count > 64 * 1024 {
                self.outputBuffer = String(self.outputBuffer.suffix(8 * 1024))
            }
            self.lock.unlock()
            Log.info("swe-flow: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let text = String(data: data, encoding: .utf8) else { return }
            guard let self else { return }
            self.lock.lock()
            self.stderrTail.append(text)
            if self.stderrTail.count > 40 { self.stderrTail.removeFirst(self.stderrTail.count - 40) }
            self.lock.unlock()
            Log.error("swe-flow stderr: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        do {
            try proc.run()
        } catch {
            lastError = "启动 swe-flow 失败：\(error.localizedDescription)"
            Log.error(lastError!)
            return false
        }

        process = proc
        Log.info("已启动 swe-flow pid=\(proc.processIdentifier) port=\(port == 0 ? "auto" : String(port)) root=\(root.path)")

        proc.terminationHandler = { [weak self] finished in
            guard let self else { return }
            self.queue.async {
                guard gen == self.generation, self.process === finished else { return }
                self.process = nil
                let tail = self.stderrText()
                let detail = tail.isEmpty ? "" : "\n\(tail)"
                self.publish(.failed("本地服务已退出（状态码 \(finished.terminationStatus)）。\(detail)"))
            }
        }

        // 等服务把自己的地址打到 stdout，再确认 HTTP 真的可用。
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if isCancelled {
                lastError = "启动被取消。"
                break
            }
            if let url = discoveredURL() {
                if Self.waitReady(base: url, timeout: 8) {
                    let info = ServerInfo(url: url, root: root.path, workRoot: nil)
                    adoptedPID = nil
                    Self.saveState(PersistedState(pid: proc.processIdentifier,
                                                  port: url.port ?? port,
                                                  root: root.path,
                                                  binary: binary.path))
                    Log.info("工作台就绪 \(url.absoluteString)")
                    publish(.ready(url), info: info, mode: .owned)
                    return true
                }
                lastError = "服务已启动但没有响应 HTTP 请求。"
                break
            }
            if !proc.isRunning { break }
            usleep(80_000)
        }

        let tail = stderrText()
        if lastError == nil {
            lastError = "本地服务启动超时（20 秒）。" + (tail.isEmpty ? "" : "\n\(tail)")
        } else if !tail.isEmpty {
            lastError! += "\n\(tail)"
        }
        Log.error("启动失败：\(lastError ?? "-")")
        if proc.isRunning { proc.terminate() }
        proc.terminationHandler = nil
        if process === proc { process = nil }
        return false
    }

    private func teardownLocked() {
        if let pid = adoptedPID {
            adoptedPID = nil
            stopAdopted(pid)
        }
        guard let proc = process else { return }
        process = nil
        proc.terminationHandler = nil
        if proc.isRunning {
            Log.info("关闭 swe-flow pid=\(proc.processIdentifier)")
            proc.terminate()
            let deadline = Date().addingTimeInterval(2.0)
            while proc.isRunning && Date() < deadline { usleep(50_000) }
            if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
        }
        (proc.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (proc.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
    }

    // MARK: - 上次会话遗留的服务

    private func adoptOrphanLocked() -> Bool {
        guard let saved = Self.loadState(),
              Self.fetchInfo(base: Self.baseURL(port: saved.port)) != nil,
              Self.isOurs(pid: saved.pid, root: saved.root) else { return false }
        adoptedPID = saved.pid
        let url = Self.baseURL(port: saved.port)
        let info = ServerInfo(url: url, root: saved.root, workRoot: nil)
        Log.info("接管上次遗留的服务 pid=\(saved.pid) port=\(saved.port)")
        publish(.ready(url), info: info, mode: .owned)
        return true
    }

    private func stopAdopted(_ pid: Int32) {
        guard Self.isOurs(pid: pid, root: root.path) else {
            Self.clearState()
            return
        }
        Log.info("关闭上次遗留的服务 pid=\(pid)")
        kill(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(2.0)
        while Self.processExists(pid) && Date() < deadline { usleep(50_000) }
        if Self.processExists(pid) { kill(pid, SIGKILL) }
    }

    private struct PersistedState: Codable {
        let pid: Int32
        let port: Int
        let root: String
        let binary: String
    }

    private static var stateFileURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent("SWE Workbench/server.json")
    }

    private static func saveState(_ state: PersistedState) {
        guard let url = stateFileURL,
              let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private static func loadState() -> PersistedState? {
        guard let url = stateFileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PersistedState.self, from: data)
    }

    private static func clearState() {
        guard let url = stateFileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func processExists(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0
    }

    /// 确认某 pid 仍是本工作目录的 swe-flow serve，避免 pid 复用时误杀。
    private static func isOurs(pid: Int32, root: String) -> Bool {
        guard processExists(pid) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", "command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let command = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty else { return false }
        return command.contains("swe-flow") && command.contains("serve") && command.contains(root)
    }

    // MARK: - 状态发布

    private func publish(_ state: State, info: ServerInfo? = nil, mode newMode: Mode? = nil) {
        DispatchQueue.main.async {
            if let newMode { self.mode = newMode }
            if let info { self.current = info }
            self.onState?(state)
        }
    }

    // MARK: - 取消标记（可从任意线程打断 20 秒的启动等待）

    private func requestCancel() {
        lock.lock()
        cancelRequested = true
        lock.unlock()
    }

    private func resetCancel() {
        lock.lock()
        cancelRequested = false
        lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelRequested
    }

    private func discoveredURL() -> URL? {
        lock.lock()
        defer { lock.unlock() }
        guard let range = outputBuffer.range(of: #"http://127\.0\.0\.1:[0-9]+/?"#,
                                             options: .regularExpression) else { return nil }
        return URL(string: String(outputBuffer[range]))
    }

    private func stderrText() -> String {
        lock.lock()
        defer { lock.unlock() }
        return stderrTail.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 路径与探测

    static func baseURL(port: Int) -> URL {
        URL(string: "http://127.0.0.1:\(port)/")!
    }

    static func binaryURL() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["SWE_WORKBENCH_BINARY"], !override.isEmpty,
           FileManager.default.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        if let resources = Bundle.main.resourceURL {
            let bundled = resources.appendingPathComponent("bin/swe-flow")
            if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        }
        // 没有随包携带时，退回技能安装目录（开发调试用）。
        let fallback = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/skills/swe-task/runtime/bin/swe-flow")
        return FileManager.default.isExecutableFile(atPath: fallback.path) ? fallback : nil
    }

    static func bundledToolsURL() -> URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let tools = resources.appendingPathComponent("tools", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: tools.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return tools
    }

    /// GUI 进程默认 PATH 很短；补上 Homebrew 和用户的 bin，保持与终端里一致的 python3 / git。
    static func childPath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var parts = ["\(home)/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        if let existing = ProcessInfo.processInfo.environment["PATH"], !existing.isEmpty {
            for part in existing.split(separator: ":") where !parts.contains(String(part)) {
                parts.append(String(part))
            }
        }
        return parts.joined(separator: ":")
    }

    static func isPortFree(_ port: Int) -> Bool {
        guard port > 0, port < 65536 else { return false }
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        // 和 Go 的 net.Listen 对齐：允许复用处于 TIME_WAIT 的端口，但不允许两个监听者。
        var reuse: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return result == 0
    }

    private static let probeSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1.5
        configuration.timeoutIntervalForResource = 2.5
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()

    static func fetchInfo(base: URL, timeout: TimeInterval = 1.5) -> ServerInfo? {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.path = "/api/bootstrap"
        components?.query = nil
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let semaphore = DispatchSemaphore(value: 0)
        var info: ServerInfo?
        probeSession.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            guard error == nil,
                  let data,
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["csrf"] != nil else { return }
            info = ServerInfo(url: base,
                              root: object["root"] as? String,
                              workRoot: object["work_root"] as? String)
        }.resume()
        _ = semaphore.wait(timeout: .now() + timeout + 0.5)
        return info
    }

    static func waitReady(base: URL, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if fetchInfo(base: base) != nil { return true }
            usleep(120_000)
        }
        return false
    }
}
