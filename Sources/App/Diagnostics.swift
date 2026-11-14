//  Diagnostics.swift
//  ToobitSniper — lightweight on-device diagnostics
//
//  Why: the app was closing itself after a while and there was nothing to look at afterwards.
//  This keeps a small, bounded, on-disk event log (ring buffer in memory + append-only file)
//  covering socket lifecycle, app lifecycle and memory, so the tail from the session that died
//  is still visible after relaunch. Everything is shown in Settings → DIAGNOSTICS.
//
//  Cost: one line per event (socket status changes, batch summaries, memory samples every 60 s),
//  capped at 200 in memory and ~200 KB on disk. No network, no third-party code.

import Foundation
import Combine
#if canImport(UIKit)
import UIKit
#endif
#if canImport(Darwin)
import Darwin
#endif

struct DiagEvent: Identifiable, Equatable {
    let id = UUID()
    let time: Date
    let category: String
    let message: String

    var timeText: String { DiagEvent.formatter.string(from: time) }
    var line: String { "\(timeText) [\(category)] \(message)" }
    /// `<epochMillis>|<category>|<message>` — round-trips through the log file.
    var fileLine: String { "\(Int64(time.timeIntervalSince1970 * 1000))|\(category)|\(message)" }

    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

@MainActor
final class Diagnostics: ObservableObject {

    static let shared = Diagnostics()

    @Published private(set) var events: [DiagEvent] = []
    @Published private(set) var reconnects: Int = 0
    @Published private(set) var eventsProcessed: Int = 0
    @Published private(set) var eventsDropped: Int = 0
    @Published private(set) var memoryMB: Double = 0
    @Published private(set) var peakMemoryMB: Double = 0

    let startedAt = Date()

    private let capacity = 200
    private let fileLimitBytes = 200_000
    private let fileURL: URL
    private let writeQueue = DispatchQueue(label: "com.tradingdesk.toobitsniper.diagnostics")
    private var memoryTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    init() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        fileURL = dir.appendingPathComponent("diagnostics.log")
        loadTail()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        log("app", "launch v\(version) (\(build))")
        start()
    }

    // MARK: - Recording

    func log(_ category: String, _ message: String) {
        let event = DiagEvent(time: Date(), category: category, message: message)
        events.append(event)
        if events.count > capacity {
            events.removeFirst(events.count - capacity)
        }
        let url = fileURL
        let line = event.fileLine
        writeQueue.async { Diagnostics.append(line, to: url, limit: 200_000) }
    }

    /// Socket status changes; "reconnecting(#n)" is the only reconnect counter increment.
    func noteStatus(_ status: String) {
        if status.hasPrefix("reconnecting") {
            reconnects += 1
        }
        log("socket", status)
    }

    func noteBatch(processed: Int) {
        eventsProcessed += processed
    }

    func noteDropped(_ count: Int) {
        eventsDropped += count
        log("socket", "\(count) events dropped — batch buffer full")
    }

    func sampleMemory(reason: String? = nil) {
        let mb = Diagnostics.residentMemoryMB()
        guard mb > 0 else { return }
        memoryMB = mb
        peakMemoryMB = max(peakMemoryMB, mb)
        if let reason = reason {
            log("memory", String(format: "%.1f MB (%@)", mb, reason))
        }
    }

    // MARK: - Presentation helpers

    var fullLogText: String {
        events.map { $0.line }.joined(separator: "\n")
    }

    var uptimeText: String {
        let seconds = Int(Date().timeIntervalSince(startedAt))
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    func clear() {
        events.removeAll()
        let url = fileURL
        writeQueue.async { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: - Lifecycle / memory sampling

    private func start() {
        sampleMemory()

        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleMemory(reason: nil) }
        }
        RunLoop.main.add(timer, forMode: .common)
        memoryTimer = timer

        #if canImport(UIKit)
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                           object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.log("lifecycle", "entered background")
                self?.sampleMemory(reason: "background")
            }
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification,
                                           object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.log("lifecycle", "entered foreground")
                self?.sampleMemory(reason: "foreground")
            }
        })
        observers.append(center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                           object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.log("memory", "didReceiveMemoryWarning")
                self?.sampleMemory(reason: "memory warning")
            }
        })
        #endif
    }

    // MARK: - Storage

    private func loadTail() {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n").suffix(capacity)
        events = lines.compactMap { line -> DiagEvent? in
            let parts = line.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let ms = Int64(parts[0]) else { return nil }
            return DiagEvent(time: Date(timeIntervalSince1970: Double(ms) / 1000),
                             category: String(parts[1]),
                             message: String(parts[2]))
        }
    }

    /// Runs on `writeQueue` (nonisolated so it never touches main-actor state).
    nonisolated private static func append(_ line: String, to url: URL, limit: Int) {
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attrs?[.size] as? Int, size > limit else { return }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let tail = text.split(separator: "\n").suffix(400).joined(separator: "\n")
        try? (tail + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    nonisolated private static func residentMemoryMB() -> Double {
        #if canImport(Darwin)
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.resident_size) / 1_048_576
        #else
        return 0
        #endif
    }
}
