//  OrderFlowEngine.swift
//  ToobitSniper — footprint approximation from Toobit trade stream [Dale, ADAPT]
//
//  Toobit exposes executed trades with the maker flag ("ibm": true = buyer maker = sell
//  aggressor). Bucketing trades by (1m candle, tick-size price level) yields the bid×ask
//  footprint Dale trades on real footprint charts:
//    • Diagonal imbalance ≥300% [Dale setup #4]: ask(P) ≥ 3×bid(P+1 tick) → buying imbalance.
//    • Stacked imbalance: ≥3 consecutive price levels of the same imbalance.
//    • Absorption [Dale confirmation #2]: total cell volume ≥3× average with BOTH sides active
//      and the containing candle stalling.
//    • Unfinished business [Dale]: both bid AND ask volume > 0 at a candle extreme (auction
//      left unfinished — price tends to revisit).
//    • Delta / cumulative delta from taker-buy split of the 1m klines (no tick stream needed).

import Foundation

enum OrderFlowEngine {

    // MARK: - Footprint from ticks

    static func footprint(ticks: [TradeTick], tickSize: Double, window: Int64 = 300_000) -> [FootprintCell] {
        guard tickSize > 0 else { return [] }
        let cutoff = (Date().timeIntervalSince1970 * 1000) - window
        var cells: [Int64: FootprintCell] = [:]
        for t in ticks where t.time >= cutoff {
            let level = (t.price / tickSize).rounded() * tickSize
            let key = (t.time / 60_000) * 60_000 + Int64(level * 100_000) // bucket: minute + level
            var cell = cells[key] ?? FootprintCell(time: (t.time / 60_000) * 60_000, price: level)
            cell.buyVolume += t.aggressorBuy
            cell.sellVolume += t.aggressorSell
            cells[key] = cell
        }
        return cells.values.sorted { $0.price < $1.price }
    }

    /// Diagonal imbalances at 300% [Dale]. ask(P) vs bid(P + 1 tick) for buying;
    /// bid(P) vs ask(P + 1 tick) for selling.
    static func imbalances(cells: [FootprintCell], tickSize: Double, threshold: Double = 3.0) -> [OFLevel] {
        guard tickSize > 0, cells.count > 3 else { return [] }
        var out: [OFLevel] = []
        let byPrice = Dictionary(grouping: cells) { $0.price }
        for (price, group) in byPrice {
            let ask = group.map { $0.buyVolume }.reduce(0, +)     // aggressive buys hit the ask
            let bid = group.map { $0.sellVolume }.reduce(0, +)    // aggressive sells hit the bid
            let nextPrice = price + tickSize
            let nextGroup = byPrice[nextPrice]
            let nextAsk = nextGroup?.map { $0.buyVolume }.reduce(0, +) ?? 0
            let nextBid = nextGroup?.map { $0.sellVolume }.reduce(0, +) ?? 0
            if nextBid > 0, ask / nextBid >= threshold {
                out.append(OFLevel(id: UUID(), kind: .buyImbalance, direction: .long,
                                   top: price + tickSize, bottom: price, time: group.first?.time ?? 0,
                                   strength: nextBid > 0 ? ask / nextBid : 0, stackedCount: 1))
            }
            if nextAsk > 0, bid / nextAsk >= threshold {
                out.append(OFLevel(id: UUID(), kind: .sellImbalance, direction: .short,
                                   top: price + tickSize, bottom: price, time: group.first?.time ?? 0,
                                   strength: nextAsk > 0 ? bid / nextAsk : 0, stackedCount: 1))
            }
        }
        return stack(out, tickSize: tickSize)
    }

    /// Merge consecutive same-kind imbalance levels; ≥3 stacked = Dale's zone [Dale setup #4].
    private static func stack(_ levels: [OFLevel], tickSize: Double) -> [OFLevel] {
        guard tickSize > 0 else { return levels }
        var out: [OFLevel] = []
        for kind in [OFKind.buyImbalance, .sellImbalance] {
            let group = levels.filter { $0.kind == kind }.sorted { $0.bottom < $1.bottom }
            var run: [OFLevel] = []
            for lvl in group {
                if let last = run.last, abs(lvl.bottom - last.bottom - tickSize) < tickSize * 0.01 {
                    run.append(lvl)
                } else {
                    if !run.isEmpty { out.append(merged(run, kind: kind)) }
                    run = [lvl]
                }
            }
            if !run.isEmpty { out.append(merged(run, kind: kind)) }
        }
        return out
    }

    private static func merged(_ run: [OFLevel], kind: OFKind) -> OFLevel {
        let best = run.max { $0.strength < $1.strength } ?? run[0]
        return OFLevel(id: UUID(), kind: kind, direction: best.direction,
                       top: run.map { $0.top }.max() ?? 0, bottom: run.map { $0.bottom }.min() ?? 0,
                       time: best.time, strength: best.strength, stackedCount: run.count)
    }

    /// Absorption [Dale confirmation #2]: cell volume ≥3× average cell volume, both sides ≥25%,
    /// inside a candle whose range stalls (< 0.6 × average range).
    static func absorption(cells: [FootprintCell], candles: [Candle], tickSize: Double) -> [OFLevel] {
        guard !cells.isEmpty, !candles.isEmpty, tickSize > 0 else { return [] }
        let avgCell = cells.map { $0.total }.reduce(0, +) / Double(cells.count)
        guard avgCell > 0 else { return [] }
        let avgRange = Indicators.avgRange(candles, lookback: 20)
        var out: [OFLevel] = []
        let byMinute = Dictionary(grouping: cells) { $0.time }
        for (minute, group) in byMinute {
            let total = group.map { $0.total }.reduce(0, +)
            guard total >= avgCell * 3 else { continue }
            let buys = group.map { $0.buyVolume }.reduce(0, +)
            let sells = group.map { $0.sellVolume }.reduce(0, +)
            guard buys >= total * 0.25, sells >= total * 0.25 else { continue }
            if let c = candles.first(where: { $0.openTime == minute }) {
                guard c.range <= avgRange * 0.6 else { continue }
                // Absorption defends the side that DIDN'T move: heavy selling absorbed at lows → long.
                let dir: TradeDirection = c.isBull ? .long : .short
                out.append(OFLevel(id: UUID(), kind: .absorption, direction: dir,
                                   top: group.map { $0.price + tickSize }.max() ?? 0,
                                   bottom: group.map { $0.price }.min() ?? 0,
                                   time: minute, strength: total / avgCell, stackedCount: 1))
            }
        }
        return out
    }

    /// Unfinished business [Dale]: a finished extreme has ZERO aggressor volume on the side that
    /// got filled last — the top needs 0 sell-side fill at the very top tick, etc. Approximated
    /// with the taker split of the candle: if the extreme tick traded on both sides → unfinished.
    static func unfinishedBusiness(ticks: [TradeTick], tickSize: Double, window: Int64 = 300_000) -> [OFLevel] {
        guard tickSize > 0, !ticks.isEmpty else { return [] }
        let cutoff = (Date().timeIntervalSince1970 * 1000) - window
        let recent = ticks.filter { $0.time >= cutoff }
        let byMinute = Dictionary(grouping: recent) { ($0.time / 60_000) * 60_000 }
        var out: [OFLevel] = []
        for (minute, group) in byMinute {
            guard let hi = group.map({ $0.price }).max(), let lo = group.map({ $0.price }).min() else { continue }
            let topBand = group.filter { $0.price >= hi - tickSize }
            let botBand = group.filter { $0.price <= lo + tickSize }
            let topBuy = topBand.map { $0.aggressorBuy }.reduce(0, +)
            let topSell = topBand.map { $0.aggressorSell }.reduce(0, +)
            let botBuy = botBand.map { $0.aggressorBuy }.reduce(0, +)
            let botSell = botBand.map { $0.aggressorSell }.reduce(0, +)
            if topBuy > 0 && topSell > 0 {   // both sides traded at the high → unfinished auction
                out.append(OFLevel(id: UUID(), kind: .unfinishedBusiness, direction: .short,
                                   top: hi + tickSize, bottom: hi, time: minute,
                                   strength: min(topBuy, topSell), stackedCount: 1))
            }
            if botBuy > 0 && botSell > 0 {
                out.append(OFLevel(id: UUID(), kind: .unfinishedBusiness, direction: .long,
                                   top: lo + tickSize, bottom: lo, time: minute,
                                   strength: min(botBuy, botSell), stackedCount: 1))
            }
        }
        return out
    }

    // MARK: - Delta from klines

    /// Cumulative delta series (daily-reset approximation over the window) from 1m klines.
    static func cumulativeDelta(_ candles: [Candle]) -> [Double] {
        var out: [Double] = []
        var sum = 0.0
        for c in candles { sum += c.delta; out.append(sum) }
        return out
    }

    /// Dale's delta divergence [Dale confirmation #4 / footprint divergence]: over the last
    /// `lookback` bars price prints a new extreme while cumulative delta fails to confirm.
    static func deltaDivergence(candles: [Candle], lookback: Int = 30) -> (direction: TradeDirection, strength: Double)? {
        guard candles.count > lookback + 2 else { return nil }
        let cd = cumulativeDelta(candles)
        let window = Array(candles.suffix(lookback))
        let deltaWindow = Array(cd.suffix(lookback))
        let priceHighIdx = window.enumerated().max { $0.element.high < $1.element.high }?.offset ?? 0
        let priceLowIdx = window.enumerated().min { $0.element.low < $1.element.low }?.offset ?? 0
        let lastIdx = window.count - 1
        // Price made its high recently but delta's high is earlier → bearish divergence (short).
        if priceHighIdx >= lastIdx - 5, deltaWindow.max().map({ v -> Bool in
            let dIdx = deltaWindow.firstIndex(of: v) ?? 0
            return dIdx < priceHighIdx - 3
        }) == true {
            let strength = (deltaWindow.max() ?? 0) - (deltaWindow[min(priceHighIdx, deltaWindow.count - 1)])
            return (.short, abs(strength))
        }
        // Price made its low recently but delta's low is earlier → bullish divergence (long).
        if priceLowIdx >= lastIdx - 5, deltaWindow.min().map({ v -> Bool in
            let dIdx = deltaWindow.firstIndex(of: v) ?? 0
            return dIdx < priceLowIdx - 3
        }) == true {
            let strength = (deltaWindow[min(priceLowIdx, deltaWindow.count - 1)]) - (deltaWindow.min() ?? 0)
            return (.long, abs(strength))
        }
        return nil
    }

    /// Big-limit print approximation [Dale confirmation #1]: a single price level holding an
    /// unusually large resting quantity on one side of the current book.
    static func bigLimitLevels(depth: DepthSnapshot?, avgTopQty: Double) -> [OFLevel] {
        guard let depth = depth, avgTopQty > 0 else { return [] }
        var out: [OFLevel] = []
        for b in depth.bids where b.qty >= avgTopQty * 5 {
            out.append(OFLevel(id: UUID(), kind: .bigLimit, direction: .long,
                               top: b.price, bottom: b.price, time: depth.time, strength: b.qty / avgTopQty, stackedCount: 1))
        }
        for a in depth.asks where a.qty >= avgTopQty * 5 {
            out.append(OFLevel(id: UUID(), kind: .bigLimit, direction: .short,
                               top: a.price, bottom: a.price, time: depth.time, strength: a.qty / avgTopQty, stackedCount: 1))
        }
        return out
    }
}
