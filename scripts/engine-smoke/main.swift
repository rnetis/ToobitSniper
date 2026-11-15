//  scripts/engine-smoke/main.swift
//  ToobitSniper — synthetic smoke test for SignalEngine.evaluate
//
//  Why: evaluate() runs on the main actor on every closed candle, so any trap inside it
//  (index out of range, force unwrap, arithmetic) kills the app in the field. This harness
//  feeds deterministic synthetic datasets through the same entry point the app uses, so
//  such traps fail the build instead of the app.
//
//  Run via `scripts/run-engine-smoke.sh` (also runs in CI before the IPA is archived).
//  No network, no simulator, no Combine: it only needs Sources/Core.
//
//  A trap aborts the process with a non-zero status, which fails the script. The PRNG is
//  seeded, so the printed seed reproduces any failure exactly.

import Foundation

// MARK: - Deterministic PRNG (SplitMix64) so failures are reproducible.

struct Seed: RandomNumberGenerator {
    private var state: UInt64
    let value: UInt64

    init(_ value: UInt64) {
        self.value = value
        self.state = value
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

var rng = Seed(0xC0FFEE)

// MARK: - Synthetic market data

func makeCandles(count: Int, start: Double, intervalMs: Int64, flat: Bool) -> [Candle] {
    var price = start
    var time: Int64 = 1_700_000_000_000
    var out: [Candle] = []
    out.reserveCapacity(count)
    for _ in 0..<count {
        let open = price
        let drift = flat ? 0 : Double.random(in: -0.01...0.01, using: &rng)
        let close = max(0.0001, open * (1 + drift))
        let high = max(open, close) * (1 + (flat ? 0 : Double.random(in: 0...0.005, using: &rng)))
        let low = min(open, close) * (1 - (flat ? 0 : Double.random(in: 0...0.005, using: &rng)))
        let volume = flat ? 0 : Double.random(in: 1...5000, using: &rng)
        out.append(Candle(openTime: time, open: open, high: high, low: low, close: close,
                          volume: volume,
                          takerBuyVolume: volume * Double.random(in: 0.1...0.9, using: &rng)))
        price = close
        time += intervalMs
    }
    return out
}

func makeTicks(count: Int, price: Double, tickSize: Double) -> [TradeTick] {
    (0..<count).map { i in
        let offset = Double.random(in: -4...4, using: &rng) * tickSize
        return TradeTick(id: Int64(i),
                         time: 1_700_000_000_000 + Int64(i) * 100,
                         price: max(price + offset, tickSize),
                         qty: Double.random(in: 0.001...50, using: &rng),
                         buyerIsMaker: Bool.random(using: &rng))
    }
}

func makeDepth(price: Double, levels: Int) -> DepthSnapshot {
    let bids = (0..<levels).map { i in
        PriceLevel(price: price * (1 - Double(i + 1) * 0.0001),
                   qty: Double.random(in: 1...500, using: &rng))
    }
    let asks = (0..<levels).map { i in
        PriceLevel(price: price * (1 + Double(i + 1) * 0.0001),
                   qty: Double.random(in: 1...500, using: &rng))
    }
    return DepthSnapshot(time: 1_700_000_000_000, bids: bids, asks: asks)
}

// MARK: - Invariants

var checked = 0

func validate(_ signal: Signal, label: String) {
    let numbers = [signal.entry, signal.stop, signal.rr] + signal.targets
    guard numbers.allSatisfy({ $0.isFinite }) else {
        fatalError("non-finite level from \(signal.def.id) in \(label)")
    }
    guard (0...100).contains(signal.score) else {
        fatalError("score \(signal.score) out of range from \(signal.def.id) in \(label)")
    }
    checked += 1
}

// MARK: - One evaluation

@discardableResult
func runCase(_ label: String,
             candles1m: Int, candles5m: Int, candles15m: Int, candles1h: Int,
             ticks: Int = 0, flat: Bool = false,
             depth: Bool = true, bookTicker: Bool = true) -> Int {
    let base = Double.random(in: 0.5...90_000, using: &rng)
    let data = SymbolMarketData(symbol: "SMOKE-SWAP-USDT")
    data.klines1m = makeCandles(count: candles1m, start: base, intervalMs: 60_000, flat: flat)
    data.klines5m = makeCandles(count: candles5m, start: base, intervalMs: 300_000, flat: flat)
    data.klines15m = makeCandles(count: candles15m, start: base, intervalMs: 900_000, flat: flat)
    data.klines1h = makeCandles(count: candles1h, start: base, intervalMs: 3_600_000, flat: flat)

    let price = data.klines1m.last?.close ?? base
    let tickSize = price >= 100 ? 0.1 : 0.0001
    data.ticker.lastPrice = price
    data.ticker.tickSize = tickSize
    data.ticker.fundingRate = 0.0001
    data.ticks = makeTicks(count: ticks, price: price, tickSize: tickSize)
    if depth { data.depth = makeDepth(price: price, levels: 100) }
    if bookTicker {
        data.bookTicker = BookTicker(time: 1_700_000_000_000,
                                     bid: price * 0.9999, bidQty: 5,
                                     ask: price * 1.0001, askQty: 5)
    }

    let signals = SignalEngine(config: EngineConfig()).evaluate(data)
    signals.forEach { validate($0, label: label) }
    return signals.count
}

// MARK: - Scenarios

print("engine smoke: seed 0xC0FFEE")

// Guards must return early instead of trapping.
precondition(runCase("below-thresholds", candles1m: 30, candles5m: 30,
                     candles15m: 30, candles1h: 10) == 0,
             "insufficient history must produce no signals")
precondition(runCase("empty", candles1m: 0, candles5m: 0, candles15m: 0, candles1h: 0) == 0,
             "empty market data must produce no signals")
precondition(runCase("no-ticker-price", candles1m: 80, candles5m: 80, candles15m: 80, candles1h: 40) >= 0,
             "evaluation must not trap without a price")

// Exact minimum sizes the engine accepts, with and without order-flow data.
_ = runCase("minimum", candles1m: 61, candles5m: 61, candles15m: 61, candles1h: 31)
_ = runCase("minimum+ticks", candles1m: 61, candles5m: 61, candles15m: 61, candles1h: 31, ticks: 10)
_ = runCase("minimum-no-orderflow", candles1m: 61, candles5m: 61, candles15m: 61, candles1h: 31,
            depth: false, bookTicker: false)

// Degenerate market: zero volume, identical prices (ATR 0), zero spread book.
_ = runCase("flat", candles1m: 120, candles5m: 120, candles15m: 120, candles1h: 60,
            ticks: 100, flat: true)

// Every symbol watchlist shapes the app loads at bootstrap, with a full tick window.
_ = runCase("realistic-500", candles1m: 500, candles5m: 400, candles15m: 400, candles1h: 300, ticks: 4000)
_ = runCase("long-history", candles1m: 600, candles5m: 600, candles15m: 600, candles1h: 400, ticks: 4000)

// Randomised matrix: varied history lengths, tick counts, and degenerate flags.
let cases = 200
for i in 0..<cases {
    let flat = i % 17 == 0
    _ = runCase("random\(i)",
                candles1m: Int.random(in: 61...600, using: &rng),
                candles5m: Int.random(in: 61...600, using: &rng),
                candles15m: Int.random(in: 61...600, using: &rng),
                candles1h: Int.random(in: 31...400, using: &rng),
                ticks: Int.random(in: 0...2000, using: &rng),
                flat: flat,
                depth: i % 11 != 0,
                bookTicker: i % 13 != 0)
}
_ = runCase("realistic-500", candles1m: 500, candles5m: 400, candles15m: 400, candles1h: 300, ticks: 4000)

print("engine smoke: OK — \(cases + 9) evaluations, \(checked) signals validated")
