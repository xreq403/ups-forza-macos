import Foundation
import os

/// Registro de eventos y lecturas en `~/Library/Logs/ups-forza.log`.
/// Rota a `ups-forza.1.log` al superar 5 MB.
final class EventLog: Sendable {
    static let shared = EventLog()

    let url = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Logs/ups-forza.log")
    private let queue = DispatchQueue(label: "UPSForza.log")
    private let logger = Logger(subsystem: "UPSForza", category: "events")
    private static let maxSize = 5 * 1024 * 1024

    func write(_ message: String) {
        logger.info("\(message, privacy: .public)")
        let date = Date()
        let url = self.url
        queue.async {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            let line = Data("\(f.string(from: date)) \(message)\n".utf8)
            let fm = FileManager.default
            if let size = try? fm.attributesOfItem(atPath: url.path)[.size] as? Int, size > Self.maxSize {
                let old = url.deletingPathExtension().appendingPathExtension("1.log")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: url, to: old)
            }
            if let h = try? FileHandle(forWritingTo: url) {
                defer { try? h.close() }
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: line)
            } else {
                try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? line.write(to: url)
            }
        }
    }
}
