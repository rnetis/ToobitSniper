//  FibEngine.swift
//  ToobitSniper — Miner's Dynamic Price Strategies [Miner ch.4]
//
//  Ratio sets (exact, from the book):
//    Internal retracements (In-Ret): 38.2 / 50 / 61.8 / 78.6  — most corrections end near 50 or 61.8;
//        close beyond 78.6 = NOT a correction (trend continues to a new extreme).
//    Alternate Price Projections (APP): corrective structure 61.8 / 100 / 162 (100% most frequent);
//        trend structure 38.2 / 61.8 / 100.
//    External retracements (Ex-Ret): 127 / 162 (262 rarely reached — omitted for intraday [ADAPT]).
//  A zone where ≥2 projections coincide (ideally one from each set) = high-probability reversal zone.

import Foundation

enum FibEngine {

    struct Leg {
        let start: Double
        let end: Double
        let startIndex: Int
        let endIndex: Int
        let endTime: Int64
    }

    /// Extract the last two directional legs from swings.
    static func legs(candles: [Candle], swings: [SwingPoint]) -> (legA: Leg?, legB: Leg?) {
        guard swings.count >= 3, let last = candles.last else { return (nil, nil) }
        let pts = Array(swings.suffix(4))
        guard pts.count >= 3 else { return (nil, nil) }
        func leg(_ a: SwingPoint, _ b: SwingPoint) -> Leg {
            Leg(start: a.price, end: b.price, startIndex: a.index, endIndex: b.index, endTime: b.time)
        }
        let l1 = leg(pts[pts.count - 3], pts[pts.count - 2])
        let l2 = leg(pts[pts.count - 2], pts[pts.count - 1])
        // legB = most recent completed swing-to-swing leg; extend end to current price
        let legB = Leg(start: l2.start, end: last.close, startIndex: l2.startIndex, endIndex: candles.count - 1, endTime: last.openTime)
        return (l1, legB)
    }

    /// Build clustered reversal zones for the current price context.
    static func zones(candles: [Candle], swings: [SwingPoint], atrValue: Double) -> [FibZone] {
        guard atrValue > 0, candles.count > 30 else { return [] }
        let (legA, legB) = legs(candles: candles, swings: swings)
        guard let legB = legB else { return [] }
        var levels: [FibLevel] = []

        let legRange = legB.end - legB.start
        let downLeg = legRange < 0 // last leg was a decline → look for demand zones (longs)
        let kind: ZoneKind = downLeg ? .demand : .supply

        // 1) Internal retracements of the last leg (price recovering against the leg).
        let inRets: [Double] = [0.382, 0.5, 0.618, 0.786]
        for r in inRets {
            let price = legB.end - legRange * r   // for down leg: end - negative*r → retraces upward
            levels.append(FibLevel(ratio: r, price: price, kind: .inRet))
        }

        // 2) APPs of the prior same-direction leg (legA) projected from legB's end.
        if let legA = legA {
            let aRange = legA.end - legA.start
            let appRets: [Double] = [0.618, 1.0, 1.618]
            for r in appRets {
                let price = legB.end + aRange * r
                levels.append(FibLevel(ratio: r, price: price, kind: .app))
            }
            // 3) Ex-Ret of legB range projected beyond its end: 127% / 162%.
            for r in [1.27, 1.618] {
                let price = legB.end + legRange * r
                levels.append(FibLevel(ratio: r, price: price, kind: .exRet))
            }
        }

        // Cluster levels within 0.3 × ATR.
        let tolerance = atrValue * 0.3
        var clusters: [[FibLevel]] = []
        let sorted = levels.sorted { $0.price < $1.price }
        var current: [FibLevel] = []
        for lvl in sorted {
            if let first = current.first, abs(lvl.price - first.price) <= tolerance {
                current.append(lvl)
            } else {
                if current.count >= 1 { clusters.append(current) }
                current = [lvl]
            }
        }
        if !current.isEmpty { clusters.append(current) }

        // Keep clusters with ≥2 levels (Miner: confluence needs ≥2 projections; 1 alone = minor S/R).
        return clusters.filter { $0.count >= 2 && $0.allSatisfy { $0.price > 0 } }.map { group in
            let prices = group.map { $0.price }
            return FibZone(
                id: UUID(),
                kind: kind,
                top: prices.max() ?? 0,
                bottom: prices.min() ?? 0,
                levels: group)
        }
    }

    /// Price inside (or within buffer of) a fib zone?
    static func priceInZone(price: Double, zone: FibZone, buffer: Double) -> Bool {
        price >= zone.bottom - buffer && price <= zone.top + buffer
    }
}
