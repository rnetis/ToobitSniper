//  Indicators.swift
//  ToobitSniper — pure-function indicator library
//
//  Periods used by strategies: Stochastic(14,3,3) Miner momentum [Miner ch.2],
//  RSI(14) counter-trading [Bryan Lee], BB(20,2) Meta scalper [Forexop],
//  EMA20/EMA50 trend scalper [Forexop], EMA50/EMA200 crossover [Bryan Lee],
//  ATR(14) brick sizing & stop buffers [Dale 10–20% daily-range rule, ADAPT].

import Foundation

enum Indicators {

    static func sma(_ values: [Double], _ period: Int) -> [Double?] {
        guard period > 0, values.count >= period else { return Array(repeating: nil, count: values.count) }
        var out = [Double?](repeating: nil, count: values.count)
        var sum = values.prefix(period).reduce(0, +)
        out[period - 1] = sum / Double(period)
        for i in period..<values.count {
            sum += values[i] - values[i - period]
            out[i] = sum / Double(period)
        }
        return out
    }

    static func ema(_ values: [Double], _ period: Int) -> [Double?] {
        guard period > 0, !values.isEmpty else { return Array(repeating: nil, count: values.count) }
        let k = 2.0 / Double(period + 1)
        var out = [Double?](repeating: nil, count: values.count)
        var prev = values.prefix(period).reduce(0, +) / Double(min(period, values.count))
        for (i, v) in values.enumerated() {
            if i < period - 1 { continue }
            if i == period - 1 { out[i] = prev; continue }
            prev = v * k + prev * (1 - k)
            out[i] = prev
        }
        return out
    }

    /// Wilder RSI.
    static func rsi(_ candles: [Candle], period: Int = 14) -> [Double?] {
        guard candles.count > period else { return Array(repeating: nil, count: candles.count) }
        var out = [Double?](repeating: nil, count: candles.count)
        var avgGain = 0.0, avgLoss = 0.0
        for i in 1...period {
            let ch = candles[i].close - candles[i - 1].close
            avgGain += max(ch, 0) / Double(period)
            avgLoss += max(-ch, 0) / Double(period)
        }
        out[period] = avgLoss == 0 ? 100 : 100 - 100 / (1 + avgGain / avgLoss)
        for i in (period + 1)..<candles.count {
            let ch = candles[i].close - candles[i - 1].close
            avgGain = (avgGain * Double(period - 1) + max(ch, 0)) / Double(period)
            avgLoss = (avgLoss * Double(period - 1) + max(-ch, 0)) / Double(period)
            out[i] = avgLoss == 0 ? 100 : 100 - 100 / (1 + avgGain / avgLoss)
        }
        return out
    }

    /// Stochastic %K/%D — Miner's momentum indicator [Miner ch.2].
    static func stochastic(_ candles: [Candle], kPeriod: Int = 14, dPeriod: Int = 3) -> ([Double?], [Double?]) {
        let n = candles.count
        guard n >= kPeriod + dPeriod else { return (Array(repeating: nil, count: n), Array(repeating: nil, count: n)) }
        var rawK = [Double?](repeating: nil, count: n)
        for i in (kPeriod - 1)..<n {
            let window = candles[(i - kPeriod + 1)...i]
            let hh = window.map { $0.high }.max() ?? 0
            let ll = window.map { $0.low }.min() ?? 0
            rawK[i] = hh == ll ? 50 : (candles[i].close - ll) / (hh - ll) * 100
        }
        var k = [Double?](repeating: nil, count: n)
        for i in (kPeriod + dPeriod - 2)..<n {
            let vals = (i - dPeriod + 1...i).compactMap { rawK[$0] }
            if vals.count == dPeriod { k[i] = vals.reduce(0, +) / Double(dPeriod) }
        }
        return (rawK, k)
    }

    /// Wilder ATR.
    static func atr(_ candles: [Candle], period: Int = 14) -> [Double?] {
        guard candles.count > period else { return Array(repeating: nil, count: candles.count) }
        var out = [Double?](repeating: nil, count: candles.count)
        var prev = candles.prefix(period).map { $0.range }.reduce(0, +) / Double(period)
        out[period] = prev
        for i in (period + 1)..<candles.count {
            prev = (prev * Double(period - 1) + candles[i].range) / Double(period)
            out[i] = prev
        }
        return out
    }

    static func atrLast(_ candles: [Candle], period: Int = 14) -> Double {
        let series = atr(candles, period: period)
        for v in series.reversed() { if let v = v { return v } }
        let r = candles.suffix(14).map { $0.range }
        return r.isEmpty ? 0.001 : r.reduce(0, +) / Double(r.count)
    }

    /// Bollinger Bands(20, 2) — Meta scalper [Forexop].
    static func bollinger(_ candles: [Candle], period: Int = 20, mult: Double = 2.0)
        -> (mid: [Double?], upper: [Double?], lower: [Double?]) {
        let closes = candles.map { $0.close }
        let mid = sma(closes, period)
        var upper = [Double?](repeating: nil, count: candles.count)
        var lower = [Double?](repeating: nil, count: candles.count)
        for i in (period - 1)..<candles.count {
            guard let m = mid[i] else { continue }
            let window = closes[(i - period + 1)...i]
            let variance = window.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(period)
            let sd = sqrt(variance)
            upper[i] = m + mult * sd
            lower[i] = m - mult * sd
        }
        return (mid, upper, lower)
    }

    static func macd(_ candles: [Candle], fast: Int = 12, slow: Int = 26, signalPeriod: Int = 9)
        -> (line: [Double?], signal: [Double?], hist: [Double?]) {
        let closes = candles.map { $0.close }
        let f = ema(closes, fast), s = ema(closes, slow)
        var line = [Double?](repeating: nil, count: closes.count)
        for i in 0..<closes.count where f[i] != nil && s[i] != nil {
            line[i] = f[i]! - s[i]!
        }
        let lineVals = line.map { $0 ?? 0 }
        let sig = ema(lineVals, signalPeriod)
        var hist = [Double?](repeating: nil, count: closes.count)
        for i in 0..<closes.count where line[i] != nil && sig[i] != nil {
            hist[i] = line[i]! - sig[i]!
        }
        return (line, sig, hist)
    }

    /// Moving-average gradient ΔMA = (MAt2 − MAt1)/(t2 − t1) — Simple Trend Scalper [Forexop].
    /// Returned in price units per bar; sign gives trend direction.
    static func maGradient(_ values: [Double?], lookback: Int = 3) -> Double {
        let n = values.count
        guard n > lookback, let a = values[n - 1 - lookback], let b = values[n - 1] else { return 0 }
        return (b - a) / Double(lookback)
    }

    static func avgVolume(_ candles: [Candle], lookback: Int = 20) -> Double {
        let v = candles.suffix(lookback).map { $0.volume }
        return v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count)
    }

    static func avgRange(_ candles: [Candle], lookback: Int = 20) -> Double {
        let v = candles.suffix(lookback).map { $0.range }
        return v.isEmpty ? 0.001 : v.reduce(0, +) / Double(v.count)
    }
}

// MARK: - Swing / structure detection

enum Structure {

    /// Fractal pivots: a high whose `k` neighbors on each side are lower (classic swing detector).
    static func swings(_ candles: [Candle], k: Int = 2) -> [SwingPoint] {
        var out: [SwingPoint] = []
        guard candles.count > k * 2 + 1 else { return out }
        for i in k..<(candles.count - k) {
            let c = candles[i]
            let leftH = candles[(i - k)..<i].allSatisfy { $0.high <= c.high }
            let rightH = candles[(i + 1)...(i + k)].allSatisfy { $0.high < c.high }
            let leftL = candles[(i - k)..<i].allSatisfy { $0.low >= c.low }
            let rightL = candles[(i + 1)...(i + k)].allSatisfy { $0.low > c.low }
            if leftH && rightH { out.append(SwingPoint(index: i, time: c.openTime, price: c.high, isHigh: true)) }
            else if leftL && rightL { out.append(SwingPoint(index: i, time: c.openTime, price: c.low, isHigh: false)) }
        }
        return out
    }

    /// HH/HL (up) vs LL/LH (down) structure — intermediate-TF trend step of Lebin's ladder [Lebin].
    static func trendDirection(_ candles: [Candle]) -> TradeDirection? {
        let s = swings(candles, k: 3)
        guard s.count >= 4 else { return nil }
        let highs = s.filter { $0.isHigh }.suffix(2)
        let lows = s.filter { !$0.isHigh }.suffix(2)
        guard highs.count == 2, lows.count == 2 else { return nil }
        let higherHighs = highs[1].price > highs[0].price
        let higherLows = lows[1].price > lows[0].price
        let lowerHighs = highs[1].price < highs[0].price
        let lowerLows = lows[1].price < lows[0].price
        if higherHighs && higherLows { return .long }
        if lowerHighs && lowerLows { return .short }
        return nil
    }

    /// EMA50×EMA200 on 1h — Bryan Lee crossover regime [Bryan Lee ch.3].
    static func crossRegime(_ candles: [Candle]) -> TradeDirection? {
        guard candles.count >= 210 else { return nil }
        let closes = candles.map { $0.close }
        let e50 = Indicators.ema(closes, 50), e200 = Indicators.ema(closes, 200)
        guard let f = e50.last ?? nil, let s = e200.last ?? nil else { return nil }
        return f > s ? .long : .short
    }

    /// Trendline with ≥3 touches and slope < 45° [Shantharaj ch.3].
    /// Returns (line price at last bar, touches, isResistance) or nil.
    static func trendline(_ candles: [Candle], kind: TradeDirection, atrValue: Double) -> (price: Double, touches: Int)? {
        let s = swings(candles, k: 2)
        guard s.count >= 3 else { return nil }
        let points = kind == .long ? s.filter { !$0.isHigh }.suffix(6) : s.filter { $0.isHigh }.suffix(6)
        guard points.count >= 3 else { return nil }
        // Least-squares fit through the pivots.
        let n = Double(points.count)
        let sumX = points.reduce(0.0) { $0 + Double($1.index) }
        let sumY = points.reduce(0.0) { $0 + $1.price }
        let sumXY = points.reduce(0.0) { $0 + Double($1.index) * $1.price }
        let sumXX = points.reduce(0.0) { $0 + Double($1.index) * Double($1.index) }
        let denom = n * sumXX - sumX * sumX
        guard denom != 0 else { return nil }
        let slope = (n * sumXY - sumX * sumY) / denom // price per bar
        let intercept = (sumY - slope * sumX) / n
        // Shantharaj: slope must be < 45° — normalize by ATR: 1 ATR per bar ≈ 45°.
        guard atrValue > 0, abs(slope) < atrValue * 0.9 else { return nil }
        // ≥3 touches: pivots within 0.3 ATR of the line.
        let touches = points.filter { abs($0.price - (slope * Double($0.index) + intercept)) < atrValue * 0.3 }.count
        guard touches >= 3 else { return nil }
        let lastPrice = slope * Double(candles.count - 1) + intercept
        return (lastPrice, touches)
    }
}
