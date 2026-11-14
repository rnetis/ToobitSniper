//  RenkoEngine.swift
//  ToobitSniper — Renko brick builder
//
//  User mandate: "whenever you think is necessary use help of renko chart".
//  Brick size = max(ATR(14) on the base timeframe × ratio, minimum ticks) [ADAPT].
//  Classic Renko rules: a new brick requires price to move a full brick beyond the last
//  brick's edge; reversal requires 2× brick (open beyond the far side of the prior brick).
//  Wyckoff's "rut"/dull-market logic [DTB] is the intellectual ancestor: Renko strips the
//  noise so trend state is unambiguous.

import Foundation

struct RenkoConfig {
    /// ATR multiplier for brick size (0.5 × ATR(14) is a common intraday setting) [ADAPT].
    var atrRatio: Double = 0.5
    /// Minimum brick size as fraction of price (guards against dead ATR).
    var minFraction: Double = 0.0015 // 0.15% of price
    var atrPeriod: Int = 14
}

enum RenkoEngine {

    static func brickSize(candles: [Candle], price: Double, config: RenkoConfig) -> Double {
        let a = Indicators.atrLast(candles, period: config.atrPeriod)
        let byAtr = a * config.atrRatio
        let byFraction = price * config.minFraction
        return max(max(byAtr, byFraction), 1e-9)
    }

    /// Build bricks from candle closes. Volume is attributed to the candle that closes the brick.
    static func build(candles: [Candle], config: RenkoConfig) -> (bricks: [RenkoBrick], size: Double) {
        guard candles.count > 5 else { return ([], 0) }
        let size = brickSize(candles: candles, price: candles.last?.close ?? 0, config: config)
        var bricks: [RenkoBrick] = []
        var anchor = candles[0].close
        var brickIndex = 0
        // Track cumulative volume of candles consumed since the last emitted brick.
        var pendingVolume = 0.0
        var pendingStart = candles[0].openTime

        func emit(open: Double, close: Double, dir: RenkoDirection, at i: Int) {
            brickIndex += 1
            bricks.append(RenkoBrick(
                index: brickIndex,
                direction: dir,
                open: open,
                close: close,
                openTime: pendingStart,
                closeTime: candles[i].openTime,
                volume: pendingVolume))
            pendingVolume = 0
            pendingStart = candles[i].openTime
            anchor = close
        }

        for (i, c) in candles.enumerated() {
            pendingVolume += c.volume
            var guardCount = 0
            while guardCount < 200 {
                guardCount += 1
                if let last = bricks.last {
                    if last.direction == .up {
                        // anchor = top edge of last up brick; reversal needs 2× brick (classic rule)
                        if c.close >= anchor + size { emit(open: anchor, close: anchor + size, dir: .up, at: i) }
                        else if c.close <= anchor - 2 * size { emit(open: anchor - size, close: anchor, dir: .down, at: i) }
                        else { break }
                    } else {
                        if c.close <= anchor - size { emit(open: anchor, close: anchor - size, dir: .down, at: i) }
                        else if c.close >= anchor + 2 * size { emit(open: anchor + size, close: anchor, dir: .up, at: i) }
                        else { break }
                    }
                } else {
                    if c.close >= anchor + size { emit(open: anchor, close: anchor + size, dir: .up, at: i) }
                    else if c.close <= anchor - size { emit(open: anchor - size, close: anchor, dir: .down, at: i) }
                    else { break }
                }
            }
        }
        return (bricks, size)
    }

    /// Current trend: direction of the last ≥2 bricks (single brick = not yet a trend).
    static func trend(bricks: [RenkoBrick]) -> (direction: TradeDirection?, run: Int) {
        guard let last = bricks.last else { return (nil, 0) }
        let run = bricks.reversed().prefix { $0.direction == last.direction }.count
        guard run >= 2 else { return (nil, run) }
        return (last.direction.tradeDirection, run)
    }

    /// Renko flip signal: a run of ≥2 bricks reverses with a fresh opposite brick [S19].
    static func flipSignal(bricks: [RenkoBrick]) -> (direction: TradeDirection, priorRun: Int)? {
        guard bricks.count >= 3 else { return nil }
        let last = bricks[bricks.count - 1]
        let prev = bricks[bricks.count - 2]
        guard last.direction != prev.direction else { return nil }
        let priorRun = bricks.reversed().dropFirst().prefix { $0.direction == prev.direction }.count
        guard priorRun >= 2 else { return nil }
        return (last.direction.tradeDirection, priorRun)
    }
}
