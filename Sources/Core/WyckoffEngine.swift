//  WyckoffEngine.swift
//  ToobitSniper — Wyckoff structure detection [Wyckoff Methodology, Villahermosa]
//
//  Encoded events:
//    • Trading range (Phase A/B): SC/AR extremes, STs building the cause.
//    • Spring / UTAD (Phase C): break of range edge + rejection back inside.
//      Spring quality from volume behavior (Spring #3 = strongest: decreased volume, narrow ranges).
//    • SOS/SOW "significant bar" [WM-4]: wider range + higher volume + close in direction half
//      + close beyond the prior extreme.
//    • Test / No Demand / No Supply [WM-7]: volume LOWER than the TWO previous candles at a key level.
//    • Effort vs result harmony [Law 2] for scoring confluence C3.

import Foundation

enum WyckoffEngine {

    // MARK: - Trading range

    /// Range detection over the swing structure: last 2 highs + 2 lows inside a band.
    static func detectRange(candles: [Candle], swings: [SwingPoint], atrValue: Double) -> TradingRange? {
        guard swings.count >= 4, atrValue > 0 else { return nil }
        let recent = Array(swings.suffix(6))
        let highs = recent.filter { $0.isHigh }
        let lows = recent.filter { !$0.isHigh }
        guard highs.count >= 2, lows.count >= 2 else { return nil }
        let top = highs.suffix(2).map { $0.price }.max() ?? 0
        let bottom = lows.suffix(2).map { $0.price }.min() ?? 0
        guard top > bottom, (top - bottom) > atrValue * 1.5 else { return nil }
        // Range integrity: most recent candles should be inside (or just outside at a shake).
        guard let last = candles.last else { return nil }
        let span = top - bottom
        let inside = last.close <= top + atrValue * 0.5 && last.close >= bottom - atrValue * 0.5
        guard inside || abs(last.close - top) < span * 0.15 || abs(last.close - bottom) < span * 0.15 else { return nil }
        let climax = candles[max(0, recent.first!.index - 10)...recent.first!.index].map { $0.volume }.max() ?? 0
        return TradingRange(top: top, bottom: bottom,
                            highTime: highs.last?.time ?? 0, lowTime: lows.last?.time ?? 0,
                            climaxVolume: climax, startIndex: recent.first?.index ?? 0)
    }

    // MARK: - Spring / UTAD [WM-1, WM-2]

    /// Spring: close below range bottom with moderate/decreasing volume, then close back inside
    /// within ≤3 candles. Strongest (Spring #3): break volume low, narrow ranges.
    static func spring(candles: [Candle], range: TradingRange, atrValue: Double) -> SignalCandidate? {
        guard candles.count > 25, atrValue > 0 else { return nil }
        let avgVol = Indicators.avgVolume(candles, lookback: 20)
        let n = candles.count
        // Find the most recent close below the bottom within the last 6 candles.
        for i in max(0, n - 6)..<n {
            let c = candles[i]
            guard c.close < range.bottom else { continue }
            // Rejection back inside within 3 candles (this or later candle closes above bottom).
            for j in i...min(n - 1, i + 3) where candles[j].close > range.bottom {
                let breakVol = candles[i].volume
                let pen = range.bottom - c.low
                guard pen < atrValue * 1.2 else { return nil } // deep penetration = shakeout of supply, weaker
                let volRatio = avgVol > 0 ? breakVol / avgVol : 1
                // Spring #3 quality: lower volume at the break = strongest [WM-1 Spring types]
                let volOK = volRatio <= 1.25
                guard volOK else { return nil }
                let entry = range.bottom
                let stop = min(c.low, candles[i...j].map { $0.low }.min() ?? c.low) - atrValue * 0.15
                let target1 = range.top
                let target2 = entry + (range.top - range.bottom) // measured move of the range
                let dir = TradeDirection.long
                return SignalCandidate(
                    def: StrategyRegistry.springDef,
                    direction: dir,
                    entry: entry,
                    stop: stop,
                    targets: [target1, target2],
                    timeframe: "15m",
                    note: "Spring below range \(String(format: "%.4f", range.bottom)); break vol \(String(format: "%.2f", volRatio))× avg; reject back inside \(j - i + 1) candle(s). [WM Phase C]",
                    triggerQuality: candles[j].close > range.bottom,
                    freshLevel: true)
            }
            return nil // break not yet rejected back inside → wait for the test
        }
        return nil
    }

    /// UTAD: close above range top with rejection back inside (distribution mirror).
    static func utad(candles: [Candle], range: TradingRange, atrValue: Double) -> SignalCandidate? {
        guard candles.count > 25, atrValue > 0 else { return nil }
        let avgVol = Indicators.avgVolume(candles, lookback: 20)
        let n = candles.count
        for i in max(0, n - 6)..<n {
            let c = candles[i]
            guard c.close > range.top else { continue }
            for j in i...min(n - 1, i + 3) where candles[j].close < range.top {
                let breakVol = candles[i].volume
                let pen = c.high - range.top
                guard pen < atrValue * 1.2 else { return nil }
                let volRatio = avgVol > 0 ? breakVol / avgVol : 1
                guard volRatio <= 1.25 else { return nil }
                let entry = range.top
                let stop = max(c.high, candles[i...j].map { $0.high }.max() ?? c.high) + atrValue * 0.15
                let target1 = range.bottom
                let target2 = entry - (range.top - range.bottom)
                return SignalCandidate(
                    def: StrategyRegistry.utadDef,
                    direction: .short,
                    entry: entry,
                    stop: stop,
                    targets: [target1, target2],
                    timeframe: "15m",
                    note: "UTAD above range \(String(format: "%.4f", range.top)); break vol \(String(format: "%.2f", volRatio))× avg; rejection back inside. [WM Phase C]",
                    triggerQuality: true,
                    freshLevel: true)
            }
            return nil
        }
        return nil
    }

    // MARK: - Significant bar SOS/SOW [WM-4]

    static func significantBar(candles: [Candle], atrValue: Double) -> SignalCandidate? {
        guard candles.count > 25, atrValue > 0 else { return nil }
        let c = candles[candles.count - 1]
        let prev = candles.prefix(candles.count - 1)
        let avgRange = Indicators.avgRange(Array(prev), lookback: 20)
        let avgVol = Indicators.avgVolume(Array(prev), lookback: 20)
        guard avgRange > 0, avgVol > 0 else { return nil }
        let wideEnough = c.range >= avgRange * 1.8
        let volEnough = c.volume >= avgVol * 1.5
        guard wideEnough, volEnough else { return nil }
        // Close in direction half + commitment beyond a prior swing extreme.
        let swings = Structure.swings(Array(prev), k: 2)
        if c.isBull {
            let bodyMidOK = c.close >= c.low + c.range * 0.5
            let priorHigh = swings.filter { $0.isHigh }.last?.price
            let beyond = priorHigh.map { c.close > $0 } ?? (c.close > (prev.last?.high ?? .infinity))
            guard bodyMidOK, beyond else { return nil }
            return SignalCandidate(
                def: StrategyRegistry.sosBarDef, direction: .long,
                entry: c.close, stop: c.low - atrValue * 0.15,
                targets: [c.close + c.range, c.close + c.range * 2],
                timeframe: "15m",
                note: "SOS bar: range \(String(format: "%.1f", c.range / avgRange))× avg, vol \(String(format: "%.1f", c.volume / avgVol))× avg, close in upper half above prior high. [WM-4]",
                triggerQuality: true, freshLevel: true)
        } else {
            let bodyMidOK = c.close <= c.high - c.range * 0.5
            let priorLow = swings.filter { !$0.isHigh }.last?.price
            let beyond = priorLow.map { c.close < $0 } ?? (c.close < (prev.last?.low ?? -.infinity))
            guard bodyMidOK, beyond else { return nil }
            return SignalCandidate(
                def: StrategyRegistry.sowBarDef, direction: .short,
                entry: c.close, stop: c.high + atrValue * 0.15,
                targets: [c.close - c.range, c.close - c.range * 2],
                timeframe: "15m",
                note: "SOW bar: range \(String(format: "%.1f", c.range / avgRange))× avg, vol \(String(format: "%.1f", c.volume / avgVol))× avg, close in lower half below prior low. [WM-4]",
                triggerQuality: true, freshLevel: true)
        }
    }

    // MARK: - Test / No Demand / No Supply [WM-7]

    /// Valid test: volume LOWER than BOTH of the two previous candles; narrow range;
    /// bearish narrow candle in strength context = No Supply (long); bull narrow in weakness = No Demand (short).
    static func test(candles: [Candle], atrValue: Double) -> SignalCandidate? {
        guard candles.count >= 25, atrValue > 0 else { return nil }
        let n = candles.count
        let c = candles[n - 1]
        let c1 = candles[n - 2], c2 = candles[n - 3]
        let avgRange = Indicators.avgRange(candles, lookback: 20)
        guard c.volume < c1.volume, c.volume < c2.volume else { return nil }
        guard c.range <= avgRange * 0.6 else { return nil }
        // Context: near the top of a recent range in strength (No Supply, long) — approximate with
        // position within the recent channel.
        let recentHigh = candles.suffix(40).map { $0.high }.max() ?? c.high
        let recentLow = candles.suffix(40).map { $0.low }.min() ?? c.low
        let pos = recentHigh > recentLow ? (c.close - recentLow) / (recentHigh - recentLow) : 0.5
        if !c.isBull && pos <= 0.35 {
            return SignalCandidate(
                def: StrategyRegistry.testNoSupplyDef, direction: .long,
                entry: c.close, stop: c.low - atrValue * 0.3,
                targets: [c.close + atrValue * 2, c.close + atrValue * 3.5],
                timeframe: "15m",
                note: "No Supply test: vol < both 2 prior candles, narrow bear candle at channel lows. [WM-7]",
                triggerQuality: true, freshLevel: false)
        }
        if c.isBull && pos >= 0.65 {
            return SignalCandidate(
                def: StrategyRegistry.testNoDemandDef, direction: .short,
                entry: c.close, stop: c.high + atrValue * 0.3,
                targets: [c.close - atrValue * 2, c.close - atrValue * 3.5],
                timeframe: "15m",
                note: "No Demand test: vol < both 2 prior candles, narrow bull candle at channel highs. [WM-7]",
                triggerQuality: true, freshLevel: false)
        }
        return nil
    }

    // MARK: - Effort vs result [Law 2] → scoring feature

    /// Harmony: impulse volume rising vs pullback volume falling.
    static func volumeHarmony(candles: [Candle]) -> (harmony: Bool, detail: String) {
        guard candles.count > 20 else { return (false, "insufficient data") }
        let last15 = candles.suffix(15)
        let upVol = last15.filter { $0.isBull }.map { $0.volume }
        let downVol = last15.filter { !$0.isBull }.map { $0.volume }
        guard upVol.count >= 3, downVol.count >= 3 else { return (false, "no clear impulses") }
        let upAvg = upVol.reduce(0, +) / Double(upVol.count)
        let downAvg = downVol.reduce(0, +) / Double(downVol.count)
        let trend = Structure.trendDirection(candles) ?? .long
        if trend == .long {
            let ok = upAvg > downAvg * 1.15
            return (ok, ok ? "up-volume \(String(format: "%.1f", upAvg / max(downAvg, 1e-9)))× down-volume" : "down-volume ≥ up-volume")
        } else {
            let ok = downAvg > upAvg * 1.15
            return (ok, ok ? "down-volume \(String(format: "%.1f", downAvg / max(upAvg, 1e-9)))× up-volume" : "up-volume ≥ down-volume")
        }
    }
}
