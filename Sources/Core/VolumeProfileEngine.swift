//  VolumeProfileEngine.swift
//  ToobitSniper — volume profile nodes & clusters [Dale]
//
//  Dale's setups trade heavy-volume areas: Volume Clusters (institutional footprint),
//  Multiple HVNs (2+ nodes at the same price), POC, and low-volume pockets (stop placement).
//  Profile is built from 1m candles (total volume), bins sized from tick-size heuristics.

import Foundation

enum VolumeProfileEngine {

    struct Profile {
        let bins: [Bin]
        let poc: Double
        let meanVolume: Double
    }

    struct Bin {
        let bottom: Double
        let top: Double
        let volume: Double
    }

    /// Build a volume profile over the last `lookback` 1m candles.
    static func profile(candles: [Candle], binCount: Int = 60) -> Profile? {
        let window = candles.suffix(500)
        guard window.count > 50 else { return nil }
        let lows = window.map { $0.low }.min() ?? 0
        let highs = window.map { $0.high }.max() ?? 0
        let span = highs - lows
        guard span > 0, binCount > 4 else { return nil }
        let binSize = span / Double(binCount)

        var volumes = [Double](repeating: 0, count: binCount)
        for c in window {
            // Distribute candle volume across the bins its range covers.
            let lo = max(0, Int(((c.low - lows) / binSize).rounded(.down)))
            let hi = min(binCount - 1, Int(((c.high - lows) / binSize).rounded(.down)))
            let binsCovered = hi - lo + 1
            guard binsCovered > 0 else { continue }
            let share = c.volume / Double(binsCovered)
            for b in lo...hi { volumes[b] += share }
        }

        let bins = volumes.enumerated().map { (idx, v) in
            Bin(bottom: lows + Double(idx) * binSize, top: lows + Double(idx + 1) * binSize, volume: v)
        }
        let total = volumes.reduce(0, +)
        let mean = total / Double(binCount)
        let pocIdx = volumes.firstIndex(of: volumes.max() ?? 0) ?? 0
        return Profile(bins: bins, poc: (bins[pocIdx].bottom + bins[pocIdx].top) / 2, meanVolume: mean)
    }

    /// Heavy-volume nodes: bins with volume ≥ 1.5 × mean, merged into contiguous zones [Dale HVN].
    /// `minNodes`: Dale's Multiple-Node rule — 2+ consecutive footprints with HVN at the same price.
    static func heavyNodes(profile: Profile) -> [VPNode] {
        guard profile.meanVolume > 0 else { return [] }
        let hvnBins = profile.bins.filter { $0.volume >= profile.meanVolume * 1.5 }
        var nodes: [VPNode] = []
        var group: [Profile.Bin] = []
        func flush() {
            guard !group.isEmpty else { return }
            let vol = group.map { $0.volume }.reduce(0, +)
            let center = (group.first!.bottom + group.last!.top) / 2
            nodes.append(VPNode(
                id: UUID(),
                center: center,
                top: group.last!.top,
                bottom: group.first!.bottom,
                volume: vol,
                isHVN: true,
                isPOC: abs(center - profile.poc) < (group.last!.top - group.first!.bottom)))
            group = []
        }
        for b in hvnBins {
            if let last = group.last, abs(b.bottom - last.top) < 1e-9 {
                group.append(b)
            } else {
                flush()
                group = [b]
            }
        }
        flush()
        return nodes
    }

    /// Low-volume pockets (bins < 0.5 × mean) — Dale's stop placement zone behind heavy volume.
    static func lowVolumePockets(profile: Profile) -> [VPNode] {
        guard profile.meanVolume > 0 else { return [] }
        return profile.bins.filter { $0.volume < profile.meanVolume * 0.5 }.map { b in
            VPNode(id: UUID(), center: (b.bottom + b.top) / 2, top: b.top, bottom: b.bottom,
                   volume: b.volume, isHVN: false, isPOC: false)
        }
    }

    /// Volume-cluster trend setup [Dale VP Setup #2]: heavy-volume "bump" inside an otherwise
    /// thin profile of a trend move; price pulls back into it.
    static func clusterNearPrice(nodes: [VPNode], price: Double, atrValue: Double) -> VPNode? {
        guard atrValue > 0 else { return nil }
        return nodes.first { price >= $0.bottom - atrValue * 0.3 && price <= $0.top + atrValue * 0.3 }
    }
}
