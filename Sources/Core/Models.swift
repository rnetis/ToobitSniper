//  Models.swift
//  ToobitSniper — core data types
//
//  Derived from docs/STRATEGY_SPEC.md. All book-derived constants carry citations.

import Foundation

// MARK: - Basic enums

enum TradeDirection: String, Codable, CaseIterable {
    case long
    case short
    var opposite: TradeDirection { self == .long ? .short : .long }
    var symbol: String { self == .long ? "▲ LONG" : "▼ SHORT" }
}

enum ZoneKind: String, Codable {
    case supply
    case demand
}

enum StrategyFamily: String, Codable, CaseIterable {
    case wyckoff = "Wyckoff"
    case supplyDemand = "Supply/Demand"
    case orderFlow = "Order Flow"
    case priceAction = "Price Action"
    case momentum = "Momentum/MTF"
    case scalping = "Scalping"
    case renko = "Renko"
}

enum MomentumState: String, Codable {
    case bullish
    case bearish
    case bullOB      // overbought: no new longs (Miner four-state table)
    case bearOS      // oversold: no new shorts
    case neutral

    var allowsLong: Bool { self == .bullish || self == .bearOS }
    var allowsShort: Bool { self == .bearish || self == .bullOB }
}

// MARK: - Market data

/// OHLCV candle from Toobit klines (indices 0-10 of the kline array).
struct Candle: Identifiable, Equatable {
    let openTime: Int64
    let open: Double
    let high: Double
    let low: Double
    let close: Double
    let volume: Double
    let takerBuyVolume: Double // aggressive buy volume (base asset); sell = volume - takerBuy

    var id: Int64 { openTime }
    var isBull: Bool { close >= open }
    var body: Double { abs(close - open) }
    var range: Double { high - low }
    var upperWick: Double { high - max(open, close) }
    var lowerWick: Double { min(open, close) - low }
    /// Aggressor delta: buy − sell = takerBuy − (volume − takerBuy)
    var delta: Double { 2 * takerBuyVolume - volume }
}

/// One footprint cell (price level inside a 1m bucket) built from the trade stream.
struct FootprintCell {
    let time: Int64
    let price: Double
    var buyVolume: Double = 0   // aggressor buys (hit the ask)
    var sellVolume: Double = 0  // aggressor sells (hit the bid)
    var total: Double { buyVolume + sellVolume }
}

struct TradeTick: Identifiable {
    let id: Int64
    let time: Int64
    let price: Double
    let qty: Double
    let buyerIsMaker: Bool // Toobit "ibm": true = buyer maker = SELL aggressor (Binance-style)
    var aggressorBuy: Double { buyerIsMaker ? 0 : qty }
    var aggressorSell: Double { buyerIsMaker ? qty : 0 }
}

struct PriceLevel: Equatable {
    let price: Double
    let qty: Double
}

struct DepthSnapshot: Equatable {
    let time: Int64
    let bids: [PriceLevel]
    let asks: [PriceLevel]
}

struct BookTicker: Equatable {
    let time: Int64
    let bid: Double
    let bidQty: Double
    let ask: Double
    let askQty: Double
    var spread: Double { ask - bid }
    var mid: Double { (ask + bid) / 2 }
}

struct TickerSnapshot {
    var lastPrice: Double = 0
    var changePct: Double = 0
    var markPrice: Double = 0
    var fundingRate: Double = 0
    var nextFundingTime: Int64 = 0
    var openInterest: Double = 0
    var tickSize: Double = 0.01
    var stepSize: Double = 0.001
}

// MARK: - Structure & zones

struct SwingPoint: Equatable {
    let index: Int
    let time: Int64
    let price: Double
    let isHigh: Bool
}

struct TradingRange: Equatable {
    let top: Double
    let bottom: Double
    let highTime: Int64
    let lowTime: Int64
    let climaxVolume: Double
    let startIndex: Int
}

/// Lebin supply/demand zone [Lebin].
struct SDZone: Identifiable, Equatable {
    let id: UUID
    let kind: ZoneKind
    let pattern: String     // DBR / RBR / RBD / DBD
    let top: Double
    let bottom: Double
    let startTime: Int64
    let endTime: Int64
    let touches: Int        // freshness counter (0 = fresh)
    let baseCandles: Int
    let quality: Double     // 0..1 after Lebin base-quality gates
    var isFresh: Bool { touches == 0 }
}

enum FibKind: String, Codable {
    case inRet   // internal retracement 38.2/50/61.8/78.6 [Miner ch.4]
    case app     // alternate price projection 61.8/100/162 [Miner ch.4]
    case exRet   // external retracement 127/162 [Miner ch.4]
}

struct FibLevel: Equatable {
    let ratio: Double
    let price: Double
    let kind: FibKind
}

/// Cluster of ≥2 fib levels within tolerance = high-probability reversal zone [Miner].
struct FibZone: Identifiable, Equatable {
    let id: UUID
    let kind: ZoneKind
    let top: Double
    let bottom: Double
    let levels: [FibLevel]
    var weight: Int { levels.count }
}

/// Volume-profile node: heavy-volume (HVN/cluster) or low-volume pocket [Dale].
struct VPNode: Identifiable, Equatable {
    let id: UUID
    let center: Double
    let top: Double
    let bottom: Double
    let volume: Double
    let isHVN: Bool
    let isPOC: Bool
}

enum OFKind: String, Codable {
    case buyImbalance        // stacked buying imbalances ≥300% [Dale]
    case sellImbalance
    case absorption          // two-sided volume explosion, price stalls [Dale]
    case bigLimit            // large passive print at level [Dale confirmation 1]
    case unfinishedBusiness  // 0-contract rule violation at candle extreme [Dale]
}

/// Order-flow level from the footprint approximation.
struct OFLevel: Identifiable, Equatable {
    let id: UUID
    let kind: OFKind
    let direction: TradeDirection   // zone defends this direction (buy imbalance → long)
    let top: Double
    let bottom: Double
    let time: Int64
    let strength: Double
    let stackedCount: Int
    var isStacked: Bool { stackedCount >= 3 } // Dale: ≥3 stacked imbalances
}

// MARK: - Renko

enum RenkoDirection: String, Codable {
    case up
    case down
    var tradeDirection: TradeDirection { self == .up ? .long : .short }
}

struct RenkoBrick: Identifiable, Equatable {
    let index: Int
    var id: Int { index }
    let direction: RenkoDirection
    let open: Double
    let close: Double
    let openTime: Int64
    let closeTime: Int64
    let volume: Double
}

// MARK: - Signals

struct StrategyDef: Identifiable, Hashable, Codable {
    let id: String          // "S1".."S19"
    let name: String
    let baseScore: Int
    let book: String
    let family: StrategyFamily
}

struct Confluence: Identifiable, Hashable {
    let code: String        // "C1".."C10" per STRATEGY_SPEC §2
    let name: String
    let points: Int
    let detail: String
    var id: String { code }
}

struct SignalCandidate {
    let def: StrategyDef
    let direction: TradeDirection
    let entry: Double
    let stop: Double
    let targets: [Double]
    let timeframe: String
    let note: String
    var triggerQuality: Bool = false  // C6: book-defined confirmation trigger present
    var freshLevel: Bool = false      // C8: zone never retested
}

struct Signal: Identifiable {
    let id: UUID
    let symbol: String
    let def: StrategyDef
    let direction: TradeDirection
    let score: Int
    let baseScore: Int
    let confluences: [Confluence]
    let entry: Double
    let stop: Double
    let targets: [Double]
    let rr: Double
    let timeframe: String
    let createdAt: Date
    let note: String
    var allowedByRisk: Bool
    var riskNote: String?

    var stopDistance: Double { abs(entry - stop) }
    var scoreTier: SignalTier {
        if score >= 85 { return .elite }
        if score >= 70 { return .strong }
        return .aggressive
    }
}

enum SignalTier: String {
    case aggressive = "AGGRESSIVE"
    case strong = "STRONG"
    case elite = "ELITE"
}

// MARK: - Per-symbol engine input

/// Everything the signal engine needs for one symbol. Mutated by AppStore as data arrives.
final class SymbolMarketData {
    let symbol: String
    var klines1m: [Candle] = []
    var klines5m: [Candle] = []
    var klines15m: [Candle] = []
    var klines1h: [Candle] = []
    var ticks: [TradeTick] = []          // rolling window of live trades
    var depth: DepthSnapshot?
    var bookTicker: BookTicker?
    var ticker = TickerSnapshot()
    var lastEvaluatedAt: Date?

    init(symbol: String) { self.symbol = symbol }

    func candles(for timeframe: String) -> [Candle] {
        switch timeframe {
        case "1m": return klines1m
        case "5m": return klines5m
        case "15m": return klines15m
        case "1h": return klines1h
        default: return klines5m
        }
    }
}
