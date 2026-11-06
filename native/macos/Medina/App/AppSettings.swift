import AppKit
import Foundation
import Observation
import OSLog
import SwiftUI

@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard
    private let logger = Logger(subsystem: "com.medina.native", category: "app")
    private static let fileQueue = DispatchQueue(label: "com.medina.native.persistent-logs", qos: .utility)

    var loggingEnabled: Bool {
        didSet { defaults.set(loggingEnabled, forKey: "loggingEnabled") }
    }
    var minimumLogLevel: AppLogLevel {
        didSet { defaults.set(minimumLogLevel.rawValue, forKey: "minimumLogLevel") }
    }
    var persistentLoggingEnabled: Bool {
        didSet { defaults.set(persistentLoggingEnabled, forKey: "persistentLoggingEnabled") }
    }

    var logFileURL: URL {
        logDirectoryURL.appendingPathComponent("medina.log", isDirectory: false)
    }
    var logDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Medina", isDirectory: true)
    }

    private init() {
        loggingEnabled = defaults.object(forKey: "loggingEnabled") as? Bool ?? true
        minimumLogLevel = AppLogLevel(rawValue: defaults.string(forKey: "minimumLogLevel") ?? "info") ?? .info
        persistentLoggingEnabled = defaults.bool(forKey: "persistentLoggingEnabled")
    }

    func logDebug(_ message: String, category: String = "app") {
        writeLog(.debug, message, category: category)
    }

    func logInfo(_ message: String, category: String = "app") {
        writeLog(.info, message, category: category)
    }

    func clearPersistentLogs() {
        let url = logFileURL
        Self.fileQueue.async { try? FileManager.default.removeItem(at: url) }
    }

    func openLogFolder() {
        try? FileManager.default.createDirectory(at: logDirectoryURL, withIntermediateDirectories: true)
        NSWorkspace.shared.open(logDirectoryURL)
    }

    private func writeLog(_ level: AppLogLevel, _ message: String, category: String) {
        guard loggingEnabled, level >= minimumLogLevel else { return }
        let line = "\(ISO8601DateFormatter().string(from: Date())) [\(level.rawValue.uppercased())] [\(category)] \(message)\n"
        if level == .debug {
            logger.debug("[\(category, privacy: .public)] \(message, privacy: .public)")
        } else {
            logger.info("[\(category, privacy: .public)] \(message, privacy: .public)")
        }
        guard persistentLoggingEnabled else { return }
        let url = logFileURL
        let directory = logDirectoryURL
        Self.fileQueue.async {
            let manager = FileManager.default
            do {
                try manager.createDirectory(at: directory, withIntermediateDirectories: true)
                if let attributes = try? manager.attributesOfItem(atPath: url.path),
                   ((attributes[.size] as? NSNumber)?.intValue ?? 0) > 5_000_000 {
                    let previous = directory.appendingPathComponent("medina.previous.log")
                    try? manager.removeItem(at: previous)
                    try manager.moveItem(at: url, to: previous)
                }
                let data = Data(line.utf8)
                if manager.fileExists(atPath: url.path) {
                    let handle = try FileHandle(forWritingTo: url)
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                    try handle.close()
                } else {
                    try data.write(to: url, options: .atomic)
                }
            } catch {
                // Logging failures must never interrupt playback or app startup.
            }
        }
    }
}

enum AppLogLevel: String, CaseIterable, Identifiable, Comparable {
    case debug
    case info
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs == .debug && rhs == .info }
}

struct AppSettingsView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section("Logging") {
                Toggle("Enable app logging", isOn: $settings.loggingEnabled)
                Picker("Minimum level", selection: $settings.minimumLogLevel) {
                    ForEach(AppLogLevel.allCases) { level in
                        Text(level.title).tag(level)
                    }
                }
                .disabled(!settings.loggingEnabled)
                Toggle("Write logs to a persistent file", isOn: $settings.persistentLoggingEnabled)
                    .disabled(!settings.loggingEnabled)
                Text(settings.logFileURL.path)
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                HStack {
                    Button("Open Logs Folder") { settings.openLogFolder() }
                    Button("Clear Logs") { settings.clearPersistentLogs() }
                        .disabled(!settings.persistentLoggingEnabled)
                }
                Text("Debug and info messages are also sent to macOS unified logging. Persistent logs are optional and may contain server addresses and course titles.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 500, height: 470)
    }
}
