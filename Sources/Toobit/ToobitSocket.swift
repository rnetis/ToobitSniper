//  ToobitSocket.swift
//  ToobitSniper — public market-data WebSocket
//
//  wss://stream.toobit.com/quote/ws/v1
//  Subscribe: {"symbol":"BTC-SWAP-USDT","topic":"kline_1m","event":"sub","params":{"binary":"false"}}
//  Heartbeat: {"ping":<ms>} → {"pong":<ms>} every ≤4 min (disconnect after 5 min without it).
//  Topics used: kline_1m/5m/15m/1h, trade, depth, bookTicker, markPrice.
//  NOTE: first kline push carries only the live bar → REST bootstrap is mandatory.
//
//  Lifecycle rules (they keep the app alive over long sessions):
//  • exactly one live URLSessionWebSocketTask — the previous one is cancelled before opening,
//    otherwise every reconnect leaves a second socket streaming duplicate events;
//  • reconnect scheduling is idempotent (one pending retry at a time) and backs off until a
//    connection actually opens, so a flapping network cannot spawn sockets in a loop;
//  • connection/timer state is only mutated on the main thread — RunLoop timer creation and
//    invalidation from a URLSession delegate queue is undefined behaviour.

import Foundation

final class ToobitSocket: NSObject, URLSessionWebSocketDelegate {

    static let host = "wss://stream.toobit.com/quote/ws/v1"

    enum Event {
        case kline(symbol: String, interval: String, candle: Candle, isClosed: Bool)
        case trade(symbol: String, tick: TradeTick)
        case depth(symbol: String, snapshot: DepthSnapshot)
        case bookTicker(symbol: String, ticker: BookTicker)
    }

    private var task: URLSessionWebSocketTask?
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    private var pingTimer: Timer?
    private var symbols: [String] = []
    private var reconnectAttempt = 0
    private var reconnectPending = false
    private var stopped = true

    var onEvent: ((Event) -> Void)?
    var onStatus: ((String) -> Void)?

    deinit {
        pingTimer?.invalidate()
        task?.cancel(with: .goingAway, reason: nil)
    }

    // MARK: - Connection

    /// Main thread only (AppStore calls this from the main actor).
    func connect(symbols: [String]) {
        self.symbols = symbols
        stopped = false
        reconnectAttempt = 0
        open()
    }

    private func open() {
        guard !stopped else { return }
        // Never leave the previous socket running: it would keep streaming duplicate events.
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        guard let url = URL(string: Self.host) else { return }
        let newTask = session.webSocketTask(with: url)
        task = newTask
        newTask.resume()
        onStatus?(reconnectAttempt == 0 ? "connecting" : "reconnecting(#\(reconnectAttempt))")
        subscribeAll(on: newTask, afterDelay: 1.0)
        startPing()
        receiveLoop(on: newTask)
    }

    private func subscribeAll(on socketTask: URLSessionWebSocketTask, afterDelay delay: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, !self.stopped, self.task === socketTask else { return }
            for sym in self.symbols {
                for tf in ["1m", "5m", "15m", "1h"] {
                    self.send(["symbol": sym, "topic": "kline_\(tf)", "event": "sub", "params": ["binary": "false"]], on: socketTask)
                }
                self.send(["symbol": sym, "topic": "trade", "event": "sub", "params": ["binary": "false"]], on: socketTask)
                self.send(["symbol": sym, "topic": "depth", "event": "sub", "params": ["binary": "false"]], on: socketTask)
                self.send(["symbol": sym, "topic": "bookTicker", "event": "sub"], on: socketTask)
            }
            self.onStatus?("streaming \(self.symbols.count) symbols")
        }
    }

    private func send(_ payload: [String: Any], on socketTask: URLSessionWebSocketTask) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        socketTask.send(.string(text)) { [weak self] error in
            guard error != nil else { return }
            DispatchQueue.main.async {
                guard let self = self, self.task === socketTask else { return }
                self.scheduleReconnect()
            }
        }
    }

    private func receiveLoop(on socketTask: URLSessionWebSocketTask) {
        socketTask.receive { [weak self, weak socketTask] result in
            guard let self = self, let t = socketTask else { return }
            switch result {
            case .success(let message):
                if case .string(let text) = message {
                    self.handle(text: text)
                }
                DispatchQueue.main.async {
                    guard !self.stopped, self.task === t else { return }
                    self.receiveLoop(on: t)
                }
            case .failure:
                DispatchQueue.main.async {
                    guard !self.stopped, self.task === t else { return }
                    self.onStatus?("disconnected")
                    self.scheduleReconnect()
                }
            }
        }
    }

    // MARK: - Heartbeat & reconnect

    private func startPing() {
        pingTimer?.invalidate()
        let timer = Timer(timeInterval: 240, repeats: true) { [weak self] _ in
            guard let self = self, let t = self.task else { return }
            let ms = Int64(Date().timeIntervalSince1970 * 1000)
            self.send(["ping": ms], on: t)
        }
        RunLoop.main.add(timer, forMode: .common)
        pingTimer = timer
    }

    /// One pending retry at a time; backoff only resets once a socket actually opens.
    private func scheduleReconnect() {
        guard !stopped, !reconnectPending else { return }
        reconnectPending = true
        reconnectAttempt += 1
        let delay = min(30.0, pow(2.0, Double(reconnectAttempt)))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            self.reconnectPending = false
            self.open()
        }
    }

    func disconnect() {
        stopped = true
        reconnectPending = false
        pingTimer?.invalidate()
        pingTimer = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    // MARK: URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        DispatchQueue.main.async {
            guard self.task === webSocketTask else { return }
            self.reconnectAttempt = 0
            self.onStatus?("socket open")
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        DispatchQueue.main.async {
            guard !self.stopped, self.task === webSocketTask else { return }
            self.onStatus?("socket closed")
            self.scheduleReconnect()
        }
    }

    // MARK: - Message parsing (read-only with respect to socket state)

    private func handle(text: String) {
        guard let data = text.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        if obj["pong"] != nil { return }
        guard let topic = obj["topic"] as? String else { return }
        let dataItems = (obj["data"] as? [[String: Any]]) ?? []
        switch topic {
        case "kline":
            for item in dataItems {
                guard let sym = item["s"] as? String,
                      let t = (item["t"] as? NSNumber)?.int64Value,
                      let o = (item["o"] as? String).flatMap(Double.init) ?? (item["o"] as? NSNumber)?.doubleValue,
                      let h = (item["h"] as? String).flatMap(Double.init) ?? (item["h"] as? NSNumber)?.doubleValue,
                      let l = (item["l"] as? String).flatMap(Double.init) ?? (item["l"] as? NSNumber)?.doubleValue,
                      let c = (item["c"] as? String).flatMap(Double.init) ?? (item["c"] as? NSNumber)?.doubleValue,
                      let v = (item["v"] as? String).flatMap(Double.init) ?? (item["v"] as? NSNumber)?.doubleValue
                else { continue }
                // Interval is in params.klineType
                let params = obj["params"] as? [String: Any]
                let interval = params?["klineType"] as? String ?? "1m"
                // WS kline has no taker-buy split — keep delta neutral by treating takerBuy = v/2.
                let candle = Candle(openTime: t, open: o, high: h, low: l, close: c, volume: v, takerBuyVolume: v / 2)
                let now = Int64(Date().timeIntervalSince1970 * 1000)
                let isClosed = t + intervalMillis(interval) <= now
                onEvent?(.kline(symbol: sym, interval: interval, candle: candle, isClosed: isClosed))
            }
        case "trade":
            for item in dataItems {
                guard let sym = obj["symbol"] as? String,
                      let p = (item["p"] as? String).flatMap(Double.init) ?? (item["p"] as? NSNumber)?.doubleValue,
                      let q = (item["q"] as? String).flatMap(Double.init) ?? (item["q"] as? NSNumber)?.doubleValue,
                      let t = (item["t"] as? NSNumber)?.int64Value else { continue }
                let m = (item["m"] as? NSNumber)?.boolValue ?? (item["m"] as? Bool) ?? false
                let id = (item["v"] as? String).flatMap(Int64.init) ?? (item["v"] as? NSNumber)?.int64Value ?? t
                onEvent?(.trade(symbol: sym, tick: TradeTick(id: id, time: t, price: p, qty: q, buyerIsMaker: m)))
            }
        case "depth":
            for item in dataItems {
                guard let sym = item["s"] as? String ?? obj["symbol"] as? String,
                      let bids = item["b"] as? [[Any]], let asks = item["a"] as? [[Any]],
                      let bidLevels = parseLevels(bids), let askLevels = parseLevels(asks)
                else { continue }
                let t = (item["t"] as? NSNumber)?.int64Value ?? Int64(Date().timeIntervalSince1970 * 1000)
                onEvent?(.depth(symbol: sym, snapshot: DepthSnapshot(time: t, bids: bidLevels, asks: askLevels)))
            }
        case "bookTicker":
            let items = dataItems.isEmpty ? [obj["data"] as? [String: Any] ?? [:]] : dataItems
            for item in items {
                guard let sym = item["s"] as? String,
                      let b = (item["b"] as? String).flatMap(Double.init) ?? (item["b"] as? NSNumber)?.doubleValue,
                      let a = (item["a"] as? String).flatMap(Double.init) ?? (item["a"] as? NSNumber)?.doubleValue,
                      let bq = (item["bq"] as? String).flatMap(Double.init) ?? (item["bq"] as? NSNumber)?.doubleValue,
                      let aq = (item["aq"] as? String).flatMap(Double.init) ?? (item["aq"] as? NSNumber)?.doubleValue
                else { continue }
                let t = (item["t"] as? NSNumber)?.int64Value ?? Int64(Date().timeIntervalSince1970 * 1000)
                onEvent?(.bookTicker(symbol: sym, ticker: BookTicker(time: t, bid: b, bidQty: bq, ask: a, askQty: aq)))
            }
        default:
            break
        }
    }

    private func parseLevels(_ raw: [[Any]]) -> [PriceLevel]? {
        var out: [PriceLevel] = []
        for pair in raw {
            guard pair.count >= 2 else { continue }
            let p: Double?
            let q: Double?
            if let ps = pair[0] as? String { p = Double(ps) } else if let pn = pair[0] as? NSNumber { p = pn.doubleValue } else { p = nil }
            if let qs = pair[1] as? String { q = Double(qs) } else if let qn = pair[1] as? NSNumber { q = qn.doubleValue } else { q = nil }
            guard let pv = p, let qv = q else { return nil }
            out.append(PriceLevel(price: pv, qty: qv))
        }
        return out.isEmpty ? nil : out
    }

    private func intervalMillis(_ interval: String) -> Int64 {
        switch interval {
        case "1m": return 60_000
        case "5m": return 300_000
        case "15m": return 900_000
        case "30m": return 1_800_000
        case "1h": return 3_600_000
        case "4h": return 14_400_000
        case "1d": return 86_400_000
        default: return 60_000
        }
    }
}
