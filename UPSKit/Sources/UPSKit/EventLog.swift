import Foundation
import os

/// Registro de eventos y lecturas en un archivo de texto, una línea por evento.
/// Rota a `<nombre>.1.log` al superar 5 MB.
public final class EventLog: Sendable {
    public let url: URL
    private let queue = DispatchQueue(label: "UPSForza.log")
    private let logger = Logger(subsystem: "UPSForza", category: "events")
    private static let maxSize = 5 * 1024 * 1024

    public init(url: URL) {
        self.url = url
    }

    /// `~/Library/Logs/ups-forza.log` del usuario actual.
    public static var userLogURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/ups-forza.log")
    }

    /// Espera a que se escriban las líneas pendientes (antes de salir del proceso).
    public func flush() {
        queue.sync {}
    }

    /// Borra el registro y su copia rotada.
    public func clear() {
        let url = self.url
        queue.sync {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.deletingPathExtension().appendingPathExtension("1.log"))
        }
    }

    public func write(_ message: String) {
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

extension TimeInterval {
    /// "1 h 05 min", "4 min 12 s", "35 s".
    public var durationText: String {
        let s = Int(self.rounded())
        if s >= 3600 { return "\(s / 3600) h \(String(format: "%02d", s % 3600 / 60)) min" }
        if s >= 60 { return "\(s / 60) min \(s % 60) s" }
        return "\(s) s"
    }
}
