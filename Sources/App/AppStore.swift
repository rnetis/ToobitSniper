//  AppStore.swift
//  ToobitSniper — central state: market data pipeline → signal engine → alerts
//
//  Flow: REST bootstrap (klines 1m/5m/15m/1h + ticker + depth + trades + funding + OI)
//  → WS live updates → on closed candles, re-run the SignalEngine → dedup → risk verdict
//  → local notification (alerts only; no orders — user-selected).

import Foundation
import Combine
import UserNotifications

@MainActor
final class AppStore: ObservableObject {

    // MARK: - Published state

    @Published var symbols: [String] = ["BTC-SWAP-USDT", "ETH-SWAP-USDT", "SOL-SWAP-USDT", "XRP-SWAP-USDT"]
    @Published var market: [String: SymbolMarketData] = [:]
    @Published var signals: [Signal] = []
    @Published var engineConfig = EngineConfig()
    @Published var riskConfig = RiskConfig()
    @Published var connectionStatus: String = "offline"
    @Published var lastRefresh: Date?
    @Published var availableSymbols: [String] = []
    @Published var bootstrapped = false

    let governor = RiskGovernor()
    private lazy var diagnostics = Diagnostics.shared
    private var engine: SignalEngine
    private let socket = ToobitSocket()
    private let api = ToobitAPI.shared
    private var cooldowns: [String: Date] = [:]
    private var evalTimer: Timer?
    private var dayStamp: String = ""
    private var contractInfo: [String: ContractInfo] = [:]
    private var started = false

    init() {
        self.engine = SignalEngine(config: EngineConfig())
        rebuildEngine()
    }

    private func rebuildEngine() {
        // Recreate with current config (SignalEngine reads config at init).
        engine = SignalEngine(config: engineConfig)
    }

    // MARK: - Lifecycle

    func start() {
        // onAppear can fire more than once (scene re-creation); never bootstrap twice.
        guard !started else { return }
        started = true
        diagnostics.log("app", "pipeline start (\(symbols.count) symbols)")
        Task { await bootstrap() }
        startEvalTimer()
        beginDayIfNeeded()
    }

    func stop() {
        diagnostics.log("app", "pipeline stop")
        socket.disconnect()
        evalTimer?.invalidate()
        started = false
        diagnostics.noteCleanShutdown()
    }

    /// Engine settings (mode, strategy toggles, Renko ratio) only affect the evaluator —
    /// the socket subscriptions do not change, so don't tear the connection down for them.
    func applyConfig() {
        rebuildEngine()
    }

    func beginDayIfNeeded() {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let today = fmt.string(from: Date())
        if today != dayStamp {
            dayStamp = today
            governor.newDay()
        }
    }

    // MARK: - Bootstrap

    func bootstrap() async {
        do {
            let contracts = try await api.exchangeInfo()
            let trading = contracts.filter { $0.status == "TRADING" }
            availableSymbols = trading.map { $0.symbol }.sorted()
            // market[sym] does not exist yet on the first bootstrap, so the sizes are kept here
            // and applied in loadSymbol (also used by addSymbol).
            contractInfo = Dictionary(trading.map { ($0.symbol, $0) }, uniquingKeysWith: { first, _ in first })
        } catch {
            connectionStatus = "exchangeInfo failed: \(error.localizedDescription)"
        }
        for sym in symbols {
            if market[sym] == nil { market[sym] = SymbolMarketData(symbol: sym) }
            await loadSymbol(sym)
        }
        bootstrapped = true
        await restartSocket()
        connectionStatus = socketStatusText()
    }

    private func loadSymbol(_ sym: String) async {
        guard let data = market[sym] else { return }
        do {
            async let k1 = try api.klines(symbol: sym, interval: "1m", limit: 500)
            async let k5 = try api.klines(symbol: sym, interval: "5m", limit: 400)
            async let k15 = try api.klines(symbol: sym, interval: "15m", limit: 400)
            async let k1h = try api.klines(symbol: sym, interval: "1h", limit: 300)
            async let tick = try api.ticker24h(symbol: sym)
            async let book = try api.depth(symbol: sym, limit: 100)
            async let trades = try api.trades(symbol: sym, limit: 60)
            async let funding = try api.fundingRate(symbol: sym)
            async let oi = try api.openInterest(symbol: sym)
            let (r1, r5, r15, r1h, t, b, tr, f, o) = try await (k1, k5, k15, k1h, tick, book, trades, funding, oi)
            data.klines1m = r1
            data.klines5m = r5
            data.klines15m = r15
            data.klines1h = r1h
            var ticker = data.ticker
            ticker.lastPrice = t.lastPrice
            ticker.changePct = t.changePct
            ticker.fundingRate = f
            ticker.openInterest = o
            if let info = contractInfo[sym] {
                ticker.tickSize = info.tickSize
                ticker.stepSize = info.stepSize
            }
            if ticker.tickSize <= 0 { ticker.tickSize = 0.01 }
            data.ticker = ticker
            data.depth = b
            data.ticks = tr
            objectWillChange.send()
        } catch {
            connectionStatus = "bootstrap \(sym): \(error.localizedDescription)"
        }
    }

    // MARK: - WebSocket

    func restartSocket() async {
        socket.disconnect()
        socket.onEvents = { [weak self] events in
            // One main-actor hop per coalesced batch, not per websocket event.
            Task { @MainActor in self?.apply(events) }
        }
        socket.onDropped = { [weak self] count in
            Task { @MainActor in self?.diagnostics.noteDropped(count) }
        }
        socket.onStatus = { [weak self] status in
            Task { @MainActor in
                guard let self = self else { return }
                self.connectionStatus = status
                self.diagnostics.noteStatus(status)
            }
        }
        socket.connect(symbols: symbols)
    }

    private func apply(_ events: [ToobitSocket.Event]) {
        var toEvaluate: [String] = []
        for event in events {
            if let symbol = handleSocketEvent(event), !toEvaluate.contains(symbol) {
                toEvaluate.append(symbol)
            }
        }
        // SymbolMarketData is a class: publish once per batch instead of once per event.
        objectWillChange.send()
        // At most one evaluation per symbol per batch, even if several timeframes rolled.
        for symbol in toEvaluate { evaluate(symbol: symbol) }
        diagnostics.noteBatch(processed: events.count)
    }

    /// Applies one event; returns the symbol if a candle just closed and the engine should run.
    private func handleSocketEvent(_ event: ToobitSocket.Event) -> String? {
        switch event {
        case .kline(let symbol, let interval, let candle, let isClosed):
            guard let data = market[symbol], ["1m", "5m", "15m", "1h"].contains(interval) else { return nil }
            let previousOpen = data.candles(for: interval).last?.openTime
            data.append(candle: candle, interval: interval)
            // The stream only ever pushes the live bar, so `isClosed` (computed from the clock)
            // is never true for it. A bar is closed once the next one opens.
            let rolled = previousOpen.map { candle.openTime > $0 } ?? false
            if isClosed || rolled {
                data.ticker.lastPrice = candle.close
                return symbol
            }
        case .trade(let symbol, let tick):
            market[symbol]?.push(tick: tick)
        case .depth(let symbol, let snapshot):
            market[symbol]?.depth = snapshot
        case .bookTicker(let symbol, let ticker):
            guard let data = market[symbol] else { return nil }
            data.bookTicker = ticker
            data.ticker.lastPrice = (ticker.ask + ticker.bid) / 2
        }
        return nil
    }

    // MARK: - Evaluation loop

    private func startEvalTimer() {
        evalTimer?.invalidate()
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.beginDayIfNeeded()
                for sym in self.symbols { self.evaluate(symbol: sym) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        evalTimer = timer
    }

    func evaluate(symbol: String) {
        guard let data = market[symbol] else { return }
        let started = DispatchTime.now().uptimeNanoseconds
        let produced = engine.evaluate(data)
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        diagnostics.noteEvaluation(symbol: symbol, milliseconds: elapsedMs)
        data.lastEvaluatedAt = Date()
        lastRefresh = Date()
        for var signal in produced {
            let key = "\(signal.symbol)-\(signal.def.id)-\(signal.direction.rawValue)"
            if let last = cooldowns[key], Date().timeIntervalSince(last) < engineConfig.cooldownSeconds {
                continue
            }
            cooldowns[key] = Date()
            let verdict = governor.verdict(signal: signal)
            signal.allowedByRisk = verdict.allowed
            signal.riskNote = verdict.reason
            signals.insert(signal, at: 0)
            if signals.count > engineConfig.maxLiveSignals * 3 {
                signals = Array(signals.prefix(engineConfig.maxLiveSignals * 3))
            }
            if verdict.allowed {
                governor.recordAlert(symbol: symbol)
                notify(signal: signal)
            }
        }
    }

    // MARK: - Alerts

    private func notify(signal: Signal) {
        guard signal.score >= engineConfig.mode.threshold else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(signal.direction == .long ? "▲ LONG" : "▼ SHORT") \(signal.symbol) \(signal.score)/100 — \(signal.def.name)"
        let target = signal.targets.first ?? 0
        content.body = "TF \(signal.timeframe) · entry \(String(format: "%.4f", signal.entry)) · stop \(String(format: "%.4f", signal.stop)) · target \(String(format: "%.4f", target)) · \(String(format: "%.1f", signal.rr))R"
        content.sound = engineConfig.alertSound ? .default : nil
        content.interruptionLevel = signal.score >= 85 ? .timeSensitive : .active
        let request = UNNotificationRequest(identifier: signal.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    // MARK: - Watchlist management

    func addSymbol(_ sym: String) {
        guard !symbols.contains(sym) else { return }
        symbols.append(sym)
        Task {
            if market[sym] == nil { market[sym] = SymbolMarketData(symbol: sym) }
            await loadSymbol(sym)
            await restartSocket()
        }
    }

    func removeSymbol(_ sym: String) {
        guard symbols.count > 1 else { return }
        symbols.removeAll { $0 == sym }
        market.removeValue(forKey: sym)
        signals.removeAll { $0.symbol == sym }
        Task { await restartSocket() }
    }

    private func socketStatusText() -> String { connectionStatus }
}

// MARK: - SymbolMarketData helpers

extension SymbolMarketData {

    /// Append/replace a live candle into the correct kline series.
    func append(candle: Candle, interval: String) {
        func upsert(_ series: inout [Candle]) {
            if let last = series.last, last.openTime == candle.openTime {
                series[series.count - 1] = candle
            } else if let last = series.last, candle.openTime > last.openTime {
                series.append(candle)
                if series.count > 600 { series.removeFirst(series.count - 600) }
            }
        }
        switch interval {
        case "1m": upsert(&klines1m)
        case "5m": upsert(&klines5m)
        case "15m": upsert(&klines15m)
        case "1h": upsert(&klines1h)
        default: break
        }
    }

    /// Push a live trade into the rolling tick window (keep ~10 minutes).
    func push(tick: TradeTick) {
        ticks.append(tick)
        let cutoff = tick.time - 600_000
        if ticks.count > 4000 {
            ticks.removeFirst(ticks.count - 4000)
        }
        ticks.removeAll { $0.time < cutoff }
    }
}
