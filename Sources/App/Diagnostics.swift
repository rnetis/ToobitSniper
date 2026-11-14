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

    // Engine evaluation timing (main-thread stall evidence).
    @Published private(set) var evalCount: Int = 0
    @Published private(set) var lastEvalMs: Double = 0
    @Published private(set) var maxEvalMs: Double = 0
    @Published private(set) var slowEvals: Int = 0

    // Previous-session outcome, resolved at launch from the heartbeat state file.
    @Published private(set) var previousSessionClean: Bool?
    @Published private(set) var previousHeartbeatAgo: TimeInterval?

    let startedAt = Date()

    private let capacity = 200
    private let fileLimitBytes = 200_000
    private let slowEvalThresholdMs: Double = 120
    private let fileURL: URL
    private let stateURL: URL
    private let writeQueue = DispatchQueue(label: "com.tradingdesk.toobitsniper.diagnostics")
    private var heartbeatTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var evalTotalMs: Double = 0

    init() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        fileURL = dir.appendingPathComponent("diagnostics.log")
        stateURL = dir.appendingPathComponent("diagnostics.session")
        loadTail()
        checkPreviousSession()
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

    /// Records how long one engine evaluation took. Slow ones are logged as main-thread stall evidence.
    func noteEvaluation(symbol: String, milliseconds: Double) {
        evalCount += 1
        evalTotalMs += milliseconds
        lastEvalMs = milliseconds
        maxEvalMs = max(maxEvalMs, milliseconds)
        if milliseconds >= slowEvalThresholdMs {
            slowEvals += 1
            log("engine", String(format: "slow evaluation %@ %.0f ms", symbol, milliseconds))
        }
    }

    var averageEvalMs: Double {
        evalCount > 0 ? evalTotalMs / Double(evalCount) : 0
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

    /// True when the previous session left a heartbeat without a clean-shutdown marker.
    var previousSessionEndedUnexpectedly: Bool {
        previousSessionClean == false
    }

    var previousSessionText: String {
        switch previousSessionClean {
        case .none:
            return "no previous session"
        case .some(true):
            return "ended cleanly"
        case .some(false):
            let gap = Int(max(0, previousHeartbeatAgo ?? 0))
            return "ENDED UNEXPECTEDLY (\(gap)s before launch)"
        }
    }

    func clear() {
        events.removeAll()
        let url = fileURL
        writeQueue.async { try? FileManager.default.removeItem(at: url) }
    }

    /// Written when the app gets a chance to terminate normally (and from AppStore.stop()).
    func noteCleanShutdown() {
        log("app", "clean shutdown")
        // Written synchronously: at termination the process may not live long enough for
        // a queued write to run, and a missing marker is what signals an unclean exit.
        writeStateNow(clean: true)
    }

    // MARK: - Lifecycle / memory sampling

    private func start() {
        sampleMemory()
        writeState(clean: false)

        // One minute heartbeat: proves the process was alive and bounds the "it died at" window.
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.heartbeat() }
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeatTimer = timer

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
        observers.append(center.addObserver(forName: UIApplication.willTerminateNotification,
                                           object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.noteCleanShutdown() }
        })
        #endif
    }

    private func heartbeat() {
        sampleMemory()
        log("diag", String(format: "heartbeat · uptime %@ · mem %.1f MB · evals %d (max %.0f ms)",
                           uptimeText, memoryMB, evalCount, maxEvalMs))
        writeState(clean: false)
    }

    // MARK: - Previous-session detection

    private func checkPreviousSession() {
        guard let text = try? String(contentsOf: stateURL, encoding: .utf8) else { return }
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let ms = Int64(parts[0]) else { return }
        let lastBeat = Date(timeIntervalSince1970: Double(ms) / 1000)
        previousHeartbeatAgo = Date().timeIntervalSince(lastBeat)
        previousSessionClean = parts[1] == "1"
        if previousSessionClean == true {
            log("app", "previous session shut down cleanly")
        } else {
            let gap = Int(max(0, previousHeartbeatAgo ?? 0))
            log("app", "previous session ended unexpectedly — last heartbeat \(gap)s before launch")
        }
    }

    private func writeState(clean: Bool) {
        let line = stateLine(clean: clean)
        let url = stateURL
        writeQueue.async { try? Data(line.utf8).write(to: url) }
    }

    private func writeStateNow(clean: Bool) {
        try? Data(stateLine(clean: clean).utf8).write(to: stateURL, options: .atomic)
    }

    private func stateLine(clean: Bool) -> String {
        Int64(Date().timeIntervalSince1970 * 1000).description + "|" + (clean ? "1" : "0")
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
