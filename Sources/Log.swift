import AppKit
import Foundation

/// 轻量文件日志：写到 ~/Library/Logs/SWE Workbench/app.log，同时镜像到 stderr，
/// 方便从终端直接启动 .app 内的可执行文件排查问题。
enum Log {
    private static let queue = DispatchQueue(label: "com.gaobo.swe-workbench.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static let fileURL: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent("Library/Logs/SWE Workbench", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("app.log")

        // 超过 2 MiB 就滚动一次，只保留一份旧日志。
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = (attrs[.size] as? NSNumber)?.intValue, size > 2 * 1024 * 1024 {
            let old = dir.appendingPathComponent("app.log.1")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: url, to: old)
        }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handles.append(handle)
        }
        return url
    }()

    private static var handles: [FileHandle] = []

    static func info(_ message: String) { write("INFO", message) }
    static func warn(_ message: String) { write("WARN", message) }
    static func error(_ message: String) { write("ERROR", message) }

    private static func write(_ level: String, _ message: String) {
        guard !message.isEmpty else { return }
        _ = fileURL   // 首次写入时建立日志文件与句柄
        queue.async {
            let stamp = formatter.string(from: Date())
            let line = "[\(stamp)] \(level) \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            for handle in handles {
                handle.write(data)
            }
            FileHandle.standardError.write(data)
        }
    }
}

extension NSImage {
    func pngData() -> Data? {
        guard let tiff = tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
