//  MomentumEngine.swift
//  ToobitSniper — Miner's Dual Time Frame Momentum Strategy [Miner ch.2]
//
//  Four-state table (exact):
//    HTF bull & NOT OB → longs only, after LTF bullish reversal made BELOW the OB zone
//    HTF bull & OB     → NO new longs; possible short after LTF bearish reversal
//    HTF bear & NOT OS → shorts only, after LTF bearish reversal made ABOVE the OS zone
//    HTF bear & OS     → NO new shorts; possible long after LTF bullish reversal
//  OB ≈ 75, OS ≈ 25 of the Stochastic(14,3,3) range. A reversal printed inside the opposite
//  extreme zone is ignored. Divergence is a caution flag only — never a standalone system.

import Foundation

enum MomentumEngine {

    static let obLevel: Double = 75
    static let osLevel: Double = 25

    struct Snapshot {
        let k: Double
        let d: Double
        let prevK: Double
        let prevD: Double
        let state: MomentumState
        let freshReversal: Bool   // cross happened within the last 3 bars
        let crossDirection: TradeDirection?
    }

    static func snapshot(_ candles: [Candle], reversalWindow: Int = 3) -> Snapshot? {
        guard candles.count > 20 else { return nil }
        let (_, dSeries) = Indicators.stochastic(candles, kPeriod: 14, dPeriod: 3)
        let n = candles.count
        // Walk back to find the two most recent valid (K, D) pairs.
        var pairs: [(k: Double, d: Double, idx: Int)] = []
        for i in stride(from: n - 1, through: max(0, n - 8), by: -1) {
            if let dv = dSeries[i], dv > 0 {
                // K approximation: recompute raw K for this bar
                let window = candles[max(0, i - 13)...i]
                let hh = window.map { $0.high }.max() ?? 0
                let ll = window.map { $0.low }.min() ?? 0
                let k = hh == ll ? 50.0 : (candles[i].close - ll) / (hh - ll) * 100
                pairs.append((k, dv, i))
            }
            if pairs.count >= 3 { break }
        }
        guard pairs.count >= 2 else { return nil }
        let cur = pairs[0]
        let prev = pairs[1]

        let crossedUp = prev.k <= prev.d && cur.k > cur.d
        let crossedDown = prev.k >= prev.d && cur.k < cur.d
        var crossDir: TradeDirection?
        if crossedUp { crossDir = .long }
        if crossedDown { crossDir = .short }
        let fresh = crossDir != nil && (pairs[0].idx - (pairs.count > 2 ? pairs[2].idx : pairs[1].idx)) <= reversalWindow * 2

        let state: MomentumState
        if cur.k >= obLevel { state = .bullOB }
        else if cur.k <= osLevel { state = .bearOS }
        else if cur.k > cur.d { state = .bullish }
        else { state = .bearish }

        return Snapshot(k: cur.k, d: cur.d, prevK: prev.k, prevD: prev.d,
                        state: state, freshReversal: fresh, crossDirection: crossDir)
    }

    /// Miner's four-state permission check: does the HTF state allow a NEW trade in `direction`?
    static func htfAllows(direction: TradeDirection, htf: MomentumState) -> Bool {
        switch direction {
        case .long: return htf.allowsLong
        case .short: return htf.allowsShort
        }
    }

    /// LTF reversal validity: bullish reversal valid only if made BELOW the OB zone;
    /// bearish reversal valid only if made ABOVE the OS zone [Miner ch.2].
    static func reversalValid(direction: TradeDirection, snap: Snapshot) -> Bool {
        guard snap.crossDirection == direction else { return false }
        switch direction {
        case .long: return snap.k < obLevel
        case .short: return snap.k > osLevel
        }
    }
}
