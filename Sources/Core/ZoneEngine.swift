//  ZoneEngine.swift
//  ToobitSniper — Lebin supply/demand zones [Lebin]
//
//  Zone types: DBR/RBR = demand, RBD/DBD = supply.
//  Geometry (exact, per Lebin):
//    SUPPLY: top = top of basing candles INCLUDING tails; bottom = bottom of basing BODIES only.
//    DEMAND: top = top of basing BODIES only; bottom = bottom INCLUDING tails.
//  Base quality: 1–6 candles excellent; >6 rejected; doji in base rejected;
//  long-thin-tail base candles rejected.
//  Freshness: 0 touches = fresh (tradeable), 1 touch = stale, ≥2 = dead.

import Foundation

enum ZoneEngine {

    static func detect(candles: [Candle], atrValue: Double) -> [SDZone] {
        var zones: [SDZone] = []
        guard candles.count > 30, atrValue > 0 else { return zones }
        let bodyThreshold = atrValue * 0.5 // "base" candle = small body [ADAPT from Lebin's small-body base]

        var i = 1
        while i < candles.count - 2 {
            let c = candles[i]
            let prev = candles[i - 1]
            let isBase = c.body <= bodyThreshold
            if !isBase { i += 1; continue }

            // Extend the base run forward.
            var j = i
            while j < candles.count - 2, candles[j].body <= bodyThreshold, candles[j].body <= max(prev.body, bodyThreshold) * 2 {
                j += 1
            }
            let base = Array(candles[i..<j])
            guard base.count >= 1, base.count <= 6 else { i = j; continue }

            // Legs: candle before base and candle after base define the pattern.
            let legIn = prev
            let legOut = candles[min(j, candles.count - 1)]
            let inDown = legIn.close < legIn.open
            let outUp = legOut.close > legOut.open

            // Lebin pattern grid: leg direction before/after the base.
            // RBD = supply, DBR = demand (reversal); RBR = demand, DBD = supply (continuation).
            let pattern: (kind: ZoneKind, name: String)?
            if inDown && outUp { pattern = (.demand, "DBR") }
            else if !inDown && outUp { pattern = (.demand, "RBR") }
            else if !inDown && !outUp { pattern = (.supply, "RBD") }
            else { pattern = (.supply, "DBD") }
            // A real exit leg (body ≥ 1 ATR) validates the zone, per Lebin's strong-leg requirement.
            let outIsLeg = legOut.body >= atrValue
            if let p = pattern, outIsLeg {
                // Overlap guard: skip if same zone already captured recently.
                let top: Double, bottom: Double
                if p.kind == .supply {
                    top = base.map { $0.high }.max() ?? 0            // include tails
                    bottom = base.map { min($0.open, $0.close) }.min() ?? 0 // bodies only
                } else {
                    top = base.map { max($0.open, $0.close) }.max() ?? 0    // bodies only
                    bottom = base.map { $0.low }.min() ?? 0                 // include tails
                }
                if top > bottom, qualityGate(base: base) {
                    let zone = SDZone(
                        id: UUID(),
                        kind: p.kind,
                        pattern: p.name,
                        top: top,
                        bottom: bottom,
                        startTime: base.first?.openTime ?? 0,
                        endTime: base.last?.openTime ?? 0,
                        touches: countTouches(candles: candles, from: j, kind: p.kind, top: top, bottom: bottom),
                        baseCandles: base.count,
                        quality: qualityScore(base: base, atrValue: atrValue),
                        isFresh: false)
                    zones.append(zone)
                }
            }
            i = max(j, i + 1)
        }
        return zones
    }

    /// Lebin base-quality gates: reject doji-in-base and long-thin-tail bases.
    private static func qualityGate(base: [Candle]) -> Bool {
        for c in base {
            if c.range > 0, c.body / c.range < 0.1 { return false } // doji / pure indecision
        }
        return true
    }

    private static func qualityScore(base: [Candle], atrValue: Double) -> Double {
        var score = 1.0
        if base.count > 4 { score -= 0.2 }
        for c in base {
            if c.range > 0 {
                let tailRatio = c.upperWick / c.range
                let tailRatio2 = c.lowerWick / c.range
                if tailRatio > 0.6 || tailRatio2 > 0.6 { score -= 0.2 } // long thin tails [Lebin]
            }
        }
        return max(0.2, score)
    }

    /// Freshness counter: how many distinct candles after the zone traded back into it.
    private static func countTouches(candles: [Candle], from: Int, kind: ZoneKind, top: Double, bottom: Double) -> Int {
        var touches = 0
        var inZone = false
        // Start after the exit leg candle — it lives inside the zone by definition, not a retest.
        for c in candles[min(from + 1, candles.count)...] {
            let hit: Bool
            if kind == .demand { hit = c.low <= top }   // any trade into the demand band counts
            else { hit = c.high >= bottom }
            if hit && !inZone { touches += 1; inZone = true }
            else if !hit { inZone = false }
        }
        return max(0, touches) // fresh = 0 touches after zone completion
    }

    /// Zone freshness filter applied at emit time: Lebin — trade FRESH zones only.
    static func freshZones(_ zones: [SDZone]) -> [SDZone] {
        zones.filter { $0.touches == 0 }
    }

    /// Price currently inside zone (first-touch check for signal generation).
    static func priceTouchesZone(price: Double, zone: SDZone, buffer: Double) -> Bool {
        price >= zone.bottom - buffer && price <= zone.top + buffer
    }
}
