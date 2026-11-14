//  ScoringEngine.swift
//  ToobitSniper — confluence scoring (STRATEGY_SPEC §2) + signal orchestration
//
//  Base score (strategy robustness) + confluence bonuses C1..C10, Renko demotion penalty,
//  cap 100. Threshold by mode: Aggressive 55 / Balanced 70 / Conservative 85 (user selected
//  AGGRESSIVE). Miner's four-state table VETOES candidates the momentum state forbids.

import Foundation

enum ScoringMode: String, Codable, CaseIterable {
    case aggressive = "Aggressive"
    case balanced = "Balanced"
    case conservative = "Conservative"

    var threshold: Int {
        switch self {
        case .aggressive: return 55
        case .balanced: return 70
        case .conservative: return 85
        }
    }
}

struct ScoringFeatures {
    var htfMomentum: MomentumState = .neutral
    var mtfMomentum: MomentumState = .neutral
    var renkoTrend: TradeDirection?
    var renkoRun: Int = 0
    var volumeHarmony: Bool = false
    var harmonyDetail: String = ""
    var fibZones: [FibZone] = []
    var sdZones: [SDZone] = []
    var vpNodes: [VPNode] = []
    var ofLevels: [OFLevel] = []
    var htfCross: TradeDirection?
    var spreadBps: Double = 0
    var atr: Double = 0.001
}

enum ScoringEngine {

    static func score(candidate: SignalCandidate, features: ScoringFeatures, mode: ScoringMode) -> (score: Int, confluences: [Confluence]) {
        var pts = candidate.def.baseScore
        var cs: [Confluence] = []

        // C1 Multi-TF momentum alignment [Miner] (+15)
        let momentumOK: Bool
        if candidate.direction == .long {
            momentumOK = features.htfMomentum == .bullish || features.htfMomentum == .bearOS
        } else {
            momentumOK = features.htfMomentum == .bearish || features.htfMomentum == .bullOB
        }
        if momentumOK {
            pts += 15
            cs.append(Confluence(code: "C1", name: "MTF momentum aligned", points: 15, detail: "1h \(features.htfMomentum.rawValue) permits \(candidate.direction.rawValue) [Miner four-state table]"))
        }

        // C2 Renko trend agreement (+12) / demotion penalty (−8) — user mandate
        if features.renkoTrend == candidate.direction {
            pts += 12
            cs.append(Confluence(code: "C2", name: "Renko trend agrees", points: 12, detail: "\(features.renkoRun)-brick run in signal direction"))
        } else if let rt = features.renkoTrend, rt == candidate.direction.opposite {
            pts -= 8
            cs.append(Confluence(code: "C2", name: "Renko opposes", points: -8, detail: "\(features.renkoRun)-brick run against the signal — demoted"))
        }

        // C3 Volume harmony / effort vs result [Wyckoff Law 2] (+10)
        if features.volumeHarmony {
            pts += 10
            cs.append(Confluence(code: "C3", name: "Volume harmony", points: 10, detail: features.harmonyDetail))
        }

        // C4 Zone confluence [Miner fib clusters, Lebin overlap, VP HVN] (+12)
        var zoneHits = 0
        let price = candidate.entry
        if features.fibZones.contains(where: { FibEngine.priceInZone(price: price, zone: $0, buffer: features.atr * 0.3) }) { zoneHits += 1 }
        if features.sdZones.contains(where: { $0.top >= price - features.atr * 0.3 && $0.bottom <= price + features.atr * 0.3 }) { zoneHits += 1 }
        if features.vpNodes.contains(where: { price >= $0.bottom - features.atr * 0.3 && price <= $0.top + features.atr * 0.3 }) { zoneHits += 1 }
        if zoneHits >= 2 {
            pts += 12
            cs.append(Confluence(code: "C4", name: "Multi-system zone confluence", points: 12, detail: "\(zoneHits) independent zone systems overlap at entry"))
        } else if zoneHits == 1 {
            pts += 6
            cs.append(Confluence(code: "C4", name: "Zone confluence", points: 6, detail: "one zone system marks entry"))
        }

        // C5 Order-flow confirmation [Dale] (+12)
        let flowHit = features.ofLevels.contains { lvl in
            lvl.direction == candidate.direction
                && lvl.isStacked || (lvl.kind == .absorption && lvl.direction == candidate.direction)
        }
        if flowHit {
            pts += 12
            cs.append(Confluence(code: "C5", name: "Order-flow confirmation", points: 12, detail: "stacked imbalance / absorption supports \(candidate.direction.rawValue) [Dale]"))
        }

        // C6 Candle trigger quality (+8)
        if candidate.triggerQuality {
            pts += 8
            cs.append(Confluence(code: "C6", name: "Book-defined trigger", points: 8, detail: "confirmation trigger present"))
        }

        // C7 Risk-reward [Lebin 3:1 filter] (+8 full / +6 / +3)
        let dist = abs(candidate.entry - candidate.stop)
        let targetDist = candidate.targets.map { abs($0 - candidate.entry) }.max() ?? 0
        let rr = dist > 0 ? targetDist / dist : 0
        if rr >= 3 {
            pts += 8
            cs.append(Confluence(code: "C7", name: "R:R ≥ 3:1", points: 8, detail: String(format: "%.1fR [Lebin 3:1 filter]", rr)))
        } else if rr >= 2 {
            pts += 6
            cs.append(Confluence(code: "C7", name: "R:R ≥ 2:1", points: 6, detail: String(format: "%.1fR", rr)))
        } else if rr >= 1.5 {
            pts += 3
            cs.append(Confluence(code: "C7", name: "R:R ≥ 1.5:1", points: 3, detail: String(format: "%.1fR [Shantharaj minimum]", rr)))
        }

        // C8 Fresh level [Lebin freshness] (+4)
        if candidate.freshLevel {
            pts += 4
            cs.append(Confluence(code: "C8", name: "Fresh level", points: 4, detail: "never retested [Lebin: trade fresh only]"))
        }

        // C9 HTF trend agreement [Wyckoff: trade with the larger structure] (+3)
        if features.htfCross == candidate.direction {
            pts += 3
            cs.append(Confluence(code: "C9", name: "HTF trend agrees", points: 3, detail: "1h EMA50/200 in direction"))
        }

        // C10 Spread ≤10% of target distance [Forexop spread rule] (+5)
        if targetDist > 0, features.spreadBps >= 0 {
            let spreadUnits = price * features.spreadBps / 10_000
            if spreadUnits <= targetDist * 0.10 {
                pts += 5
                cs.append(Confluence(code: "C10", name: "Spread budget OK", points: 5, detail: String(format: "spread %.1f%% of target [Forexop ≤10%% rule]", spreadUnits / targetDist * 100)))
            }
        }

        return (min(100, max(0, pts)), cs)
    }

    /// Miner's veto: drop candidates the 1h momentum state forbids entirely.
    static func vetoed(candidate: SignalCandidate, htf: MomentumState) -> Bool {
        !MomentumEngine.htfAllows(direction: candidate.direction, htf: htf)
    }
}

// MARK: - Signal orchestration

struct EngineConfig: Codable {
    var mode: ScoringMode = .aggressive
    var disabledStrategies: Set<String> = []
    var renkoATRRatio: Double = 0.5
    var cooldownSeconds: Double = 900
    var maxLiveSignals: Int = 12
    var alertSound: Bool = true
}

final class SignalEngine {

    let config: EngineConfig

    init(config: EngineConfig) { self.config = config }

    /// Full evaluation for one symbol. Returns scored signals above threshold.
    func evaluate(_ data: SymbolMarketData) -> [Signal] {
        let price = data.ticker.lastPrice
        guard price > 0, data.klines1m.count > 60, data.klines5m.count > 60, data.klines15m.count > 60 else { return [] }
        guard data.klines1h.count > 30 else { return [] }

        let atr15m = Indicators.atrLast(data.klines15m, period: 14)
        let atr5m = Indicators.atrLast(data.klines5m, period: 14)
        let atr1h = Indicators.atrLast(data.klines1h, period: 14)
        guard atr15m > 0, atr5m > 0, atr1h > 0 else { return [] }

        let swings15m = Structure.swings(data.klines15m, k: 2)
        let swings5m = Structure.swings(data.klines5m, k: 2)
        let range = WyckoffEngine.detectRange(data.klines15m, swings: swings15m, atrValue: atr15m)
        let sdZones = ZoneEngine.detect(candles: data.klines15m, atrValue: atr15m)
        let fibZones = FibEngine.zones(candles: data.klines15m, swings: swings15m, atrValue: atr15m)
        let profile = VolumeProfileEngine.profile(data.klines1m)
        let vpNodes = profile.map { VolumeProfileEngine.heavyNodes(profile: $0) } ?? []
        let footprint = OrderFlowEngine.footprint(ticks: data.ticks, tickSize: data.ticker.tickSize)
        let imbalances = OrderFlowEngine.imbalances(cells: footprint, tickSize: data.ticker.tickSize)
        let absorptions = OrderFlowEngine.absorption(cells: footprint, candles: data.klines1m, tickSize: data.ticker.tickSize)
        let bigLimits = OrderFlowEngine.bigLimitLevels(depth: data.depth, avgTopQty: avgTopQuantity(data.depth))
        var ofLevels = imbalances + absorptions + bigLimits
        let unfinished = OrderFlowEngine.unfinishedBusiness(ticks: data.ticks, tickSize: data.ticker.tickSize)
        ofLevels.append(contentsOf: unfinished.filter { $0.strength > 0 })
        let div = OrderFlowEngine.deltaDivergence(data.klines1m)
        let (bricks, renkoSize) = RenkoEngine.build(candles: data.klines1h, config: RenkoConfig(atrRatio: config.renkoATRRatio))
        let (renkoTrend, renkoRun) = RenkoEngine.trend(bricks: bricks)

        let ctx = StrategyContext(
            data: data,
            atr15m: atr15m, atr5m: atr5m, atr1h: atr1h,
            swings15m: swings15m, swings5m: swings5m,
            range: range, sdZones: sdZones, fibZones: fibZones,
            vpNodes: vpNodes, ofLevels: ofLevels,
            cumDeltaDiv: div,
            htfMomentum: MomentumEngine.snapshot(data.klines1h),
            mtfMomentum: MomentumEngine.snapshot(data.klines15m),
            stfMomentum: MomentumEngine.snapshot(data.klines5m),
            renkoBricks: bricks, renkoSize: renkoSize,
            renkoTrend: renkoTrend, renkoRun: renkoRun,
            htfCross: Structure.crossRegime(data.klines1h),
            rsi1h: Indicators.rsi(data.klines1h).last ?? nil,
            spreadBps: spreadBps(data))

        // Run all enabled evaluators.
        var candidates: [SignalCandidate] = []
        let enabled = { (def: StrategyDef) -> Bool in !self.config.disabledStrategies.contains(def.id) }
        if enabled(StrategyRegistry.springDef), let r = range, let c = WyckoffEngine.spring(data.klines15m, range: r, atrValue: atr15m) { candidates.append(c) }
        if enabled(StrategyRegistry.utadDef), let r = range, let c = WyckoffEngine.utad(data.klines15m, range: r, atrValue: atr15m) { candidates.append(c) }
        if enabled(StrategyRegistry.sosBarDef), let c = WyckoffEngine.significantBar(data.klines15m, atrValue: atr15m), c.direction == .long { candidates.append(c) }
        if enabled(StrategyRegistry.sowBarDef), let c = WyckoffEngine.significantBar(data.klines15m, atrValue: atr15m), c.direction == .short { candidates.append(c) }
        if enabled(StrategyRegistry.testNoSupplyDef) || enabled(StrategyRegistry.testNoDemandDef), let c = WyckoffEngine.test(data.klines15m, atrValue: atr15m) { candidates.append(c) }
        candidates.append(contentsOf: Strategies.lebinZones(ctx))
        candidates.append(contentsOf: Strategies.stackedImbalance(ctx))
        candidates.append(contentsOf: Strategies.absorption(ctx))
        candidates.append(contentsOf: Strategies.deltaDivergence(ctx))
        candidates.append(contentsOf: Strategies.volumeCluster(ctx))
        candidates.append(contentsOf: Strategies.minerMTF(ctx))
        candidates.append(contentsOf: Strategies.fibZone(ctx))
        candidates.append(contentsOf: Strategies.trendlinePullback(ctx))
        candidates.append(contentsOf: Strategies.rejectionAcceptance(ctx))
        candidates.append(contentsOf: Strategies.trendScalper(ctx))
        candidates.append(contentsOf: Strategies.bbRetrace(ctx))
        candidates.append(contentsOf: Strategies.maCross(ctx))
        candidates.append(contentsOf: Strategies.rsiExtreme(ctx))
        candidates.append(contentsOf: Strategies.renkoFlip(ctx))

        candidates = candidates.filter { enabled($0.def) }

        // Features for scoring.
        var features = ScoringFeatures()
        features.htfMomentum = ctx.htfMomentum?.state ?? .neutral
        features.mtfMomentum = ctx.mtfMomentum?.state ?? .neutral
        features.renkoTrend = renkoTrend
        features.renkoRun = renkoRun
        let harmony = WyckoffEngine.volumeHarmony(data.klines15m)
        features.volumeHarmony = harmony.harmony
        features.harmonyDetail = harmony.detail
        features.fibZones = fibZones
        features.sdZones = sdZones
        features.vpNodes = vpNodes
        features.ofLevels = ofLevels
        features.htfCross = ctx.htfCross
        features.spreadBps = ctx.spreadBps
        features.atr = atr15m

        var signals: [Signal] = []
        for cand in candidates {
            // Miner veto on the 1h state.
            if ScoringEngine.vetoed(candidate: cand, htf: features.htfMomentum) { continue }
            let (score, confluences) = ScoringEngine.score(candidate: cand, features: features, mode: config.mode)
            guard score >= config.mode.threshold else { continue }
            let dist = abs(cand.entry - cand.stop)
            let targetDist = cand.targets.map { abs($0 - cand.entry) }.max() ?? 0
            let rr = dist > 0 ? targetDist / dist : 0
            signals.append(Signal(
                id: UUID(), symbol: data.symbol, def: cand.def, direction: cand.direction,
                score: score, baseScore: cand.def.baseScore, confluences: confluences,
                entry: cand.entry, stop: cand.stop, targets: cand.targets, rr: rr,
                timeframe: cand.timeframe, createdAt: Date(), note: cand.note,
                allowedByRisk: true, riskNote: nil))
        }
        // Keep the best signal per (strategy, direction).
        var best: [String: Signal] = [:]
        for s in signals {
            let key = "\(s.symbol)-\(s.def.id)-\(s.direction.rawValue)"
            if let existing = best[key] {
                if s.score > existing.score { best[key] = s }
            } else {
                best[key] = s
            }
        }
        return best.values.sorted { $0.score > $1.score }
    }

    private func spreadBps(_ data: SymbolMarketData) -> Double {
        if let bt = data.bookTicker, bt.mid > 0 {
            return (bt.ask - bt.bid) / bt.mid * 10_000
        }
        return 2.0 // conservative default for USDT-M perps [ADAPT]
    }

    private func avgTopQuantity(_ depth: DepthSnapshot?) -> Double {
        guard let depth = depth, !depth.bids.isEmpty, !depth.asks.isEmpty else { return 0 }
        let bidAvg = depth.bids.suffix(10).map { $0.qty }.reduce(0, +) / Double(min(10, depth.bids.count))
        let askAvg = depth.asks.suffix(10).map { $0.qty }.reduce(0, +) / Double(min(10, depth.asks.count))
        return (bidAvg + askAvg) / 2
    }
}
