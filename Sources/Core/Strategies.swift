//  Strategies.swift
//  ToobitSniper — all 19 strategy evaluators (STRATEGY_SPEC §3)
//
//  Each evaluator is a pure function: market data → [SignalCandidate].
//  Book-derived numbers are cited in the notes; [ADAPT] marks crypto adaptations
//  where the original formula (pips/futures points) is converted to ATR units.

import Foundation

struct StrategyContext {
    let data: SymbolMarketData
    let atr15m: Double
    let atr5m: Double
    let atr1h: Double
    let swings15m: [SwingPoint]
    let swings5m: [SwingPoint]
    let range: TradingRange?
    let sdZones: [SDZone]
    let fibZones: [FibZone]
    let vpNodes: [VPNode]
    let ofLevels: [OFLevel]
    let cumDeltaDiv: (direction: TradeDirection, strength: Double)?
    let htfMomentum: MomentumEngine.Snapshot?
    let mtfMomentum: MomentumEngine.Snapshot?
    let stfMomentum: MomentumEngine.Snapshot?
    let renkoBricks: [RenkoBrick]
    let renkoSize: Double
    let renkoTrend: TradeDirection?
    let renkoRun: Int
    let htfCross: TradeDirection?
    let rsi1h: Double?
    let spreadBps: Double
}

enum Strategies {

    // MARK: S5/S6 — Lebin zones: limit at zone edge, stop at far edge, target opposing zone [Lebin]

    static func lebinZones(_ ctx: StrategyContext) -> [SignalCandidate] {
        var out: [SignalCandidate] = []
        let price = ctx.data.ticker.lastPrice
        guard price > 0 else { return out }
        let buffer = ctx.atr15m * 0.2
        for zone in ctx.sdZones where zone.isFresh && zone.quality >= 0.6 {
            guard ZoneEngine.priceTouchesZone(price: price, zone: zone, buffer: buffer) else { continue }
            if zone.kind == .demand {
                let entry = zone.top                       // buy LIMIT at the TOP of the demand zone
                let stop = zone.bottom                     // STOP at the BOTTOM of the zone
                let targets = opposingZones(of: .supply, zones: ctx.sdZones, above: entry)
                let t1 = targets.first ?? entry + (entry - stop) * 3 // 3:1 fallback [Lebin]
                out.append(SignalCandidate(
                    def: StrategyRegistry.demandZoneDef, direction: .long,
                    entry: entry, stop: stop, targets: targets.isEmpty ? [t1] : targets,
                    timeframe: "15m",
                    note: "\(zone.pattern) demand zone \(fmt(zone.bottom))–\(fmt(zone.top)), \(zone.baseCandles)-candle base, fresh (0 touches), quality \(String(format: "%.0f", zone.quality * 100))%. [Lebin]",
                    triggerQuality: zone.baseCandles <= 6, freshLevel: true))
            } else {
                let entry = zone.bottom                    // sell LIMIT at the BOTTOM of the supply zone
                let stop = zone.top
                let targets = opposingZones(of: .demand, zones: ctx.sdZones, below: entry)
                let t1 = targets.first ?? entry - (stop - entry) * 3
                out.append(SignalCandidate(
                    def: StrategyRegistry.supplyZoneDef, direction: .short,
                    entry: entry, stop: stop, targets: targets.isEmpty ? [t1] : targets,
                    timeframe: "15m",
                    note: "\(zone.pattern) supply zone \(fmt(zone.bottom))–\(fmt(zone.top)), \(zone.baseCandles)-candle base, fresh (0 touches), quality \(String(format: "%.0f", zone.quality * 100))%. [Lebin]",
                    triggerQuality: zone.baseCandles <= 6, freshLevel: true))
            }
        }
        return out
    }

    private static func opposingZones(of kind: ZoneKind, zones: [SDZone], above: Double? = nil, below: Double? = nil) -> [Double] {
        var candidates = zones.filter { $0.kind == kind }
        if let above = above { candidates = candidates.filter { $0.bottom > above }.sorted { $0.bottom < $1.bottom } }
        if let below = below { candidates = candidates.filter { $0.top < below }.sorted { $0.top > $1.top } }
        return candidates.map { $0.kind == .supply ? $0.bottom : $0.top }
    }

    // MARK: S7 — Dale stacked imbalance: pullback into ≥3 stacked imbalances, first touch only [Dale]

    static func stackedImbalance(_ ctx: StrategyContext) -> [SignalCandidate] {
        var out: [SignalCandidate] = []
        let price = ctx.data.ticker.lastPrice
        guard price > 0, ctx.atr15m > 0 else { return out }
        for lvl in ctx.ofLevels where lvl.isStacked && (lvl.kind == .buyImbalance || lvl.kind == .sellImbalance) {
            // First touch ONLY: the zone must be younger than ~6 candles of 5m data and price near it.
            guard price >= lvl.bottom - ctx.atr15m * 0.3, price <= lvl.top + ctx.atr15m * 0.3 else { continue }
            if lvl.kind == .buyImbalance {
                out.append(SignalCandidate(
                    def: StrategyRegistry.stackedImbalanceDef, direction: .long,
                    entry: lvl.top, stop: lvl.bottom - ctx.atr15m * 0.2,
                    targets: [lvl.top + (lvl.top - lvl.bottom) * 3],
                    timeframe: "5m",
                    note: "\(lvl.stackedCount) buying imbalances ≥300% stacked at \(fmt(lvl.bottom))–\(fmt(lvl.top)), first touch. [Dale setup #4]",
                    triggerQuality: true, freshLevel: true))
            } else {
                out.append(SignalCandidate(
                    def: StrategyRegistry.stackedImbalanceDef, direction: .short,
                    entry: lvl.bottom, stop: lvl.top + ctx.atr15m * 0.2,
                    targets: [lvl.bottom - (lvl.top - lvl.bottom) * 3],
                    timeframe: "5m",
                    note: "\(lvl.stackedCount) selling imbalances ≥300% stacked at \(fmt(lvl.bottom))–\(fmt(lvl.top)), first touch. [Dale setup #4]",
                    triggerQuality: true, freshLevel: true))
            }
        }
        return out
    }

    // MARK: S8 — Dale absorption: two-sided volume explosion while price stalls [Dale]

    static func absorption(_ ctx: StrategyContext) -> [SignalCandidate] {
        let price = ctx.data.ticker.lastPrice
        guard price > 0, ctx.atr5m > 0 else { return [] }
        return ctx.ofLevels.filter { $0.kind == .absorption && abs(price - ($0.top + $0.bottom) / 2) < ctx.atr5m * 1.2 }.map { lvl in
            let dist = abs(price - lvl.bottom)
            return SignalCandidate(
                def: StrategyRegistry.absorptionDef,
                direction: lvl.direction,
                entry: price,
                stop: lvl.direction == .long ? lvl.bottom - ctx.atr5m * 0.5 : lvl.top + ctx.atr5m * 0.5,
                targets: [price + (lvl.direction == .long ? 1 : -1) * max(dist, ctx.atr5m * 1.5)],
                timeframe: "5m",
                note: "Absorption: cell volume \(String(format: "%.1f", lvl.strength))× avg with both sides active while price stalled. [Dale confirmation #2]",
                triggerQuality: true, freshLevel: false)
        }
    }

    // MARK: S9 — Delta divergence at a zone [Dale confirmation #4]

    static func deltaDivergence(_ ctx: StrategyContext) -> [SignalCandidate] {
        guard let div = ctx.cumDeltaDiv else { return [] }
        let price = ctx.data.ticker.lastPrice
        guard price > 0, ctx.atr15m > 0 else { return [] }
        // Only meaningful AT a zone (fib/S&D/VP) per Dale — divergence without zone context is ignored.
        let nearZone = ctx.fibZones.contains { FibEngine.priceInZone(price: price, zone: $0, buffer: ctx.atr15m * 0.3) }
            || ctx.sdZones.contains { ZoneEngine.priceTouchesZone(price: price, zone: $0, buffer: ctx.atr15m * 0.3) }
            || ctx.vpNodes.contains { price >= $0.bottom - ctx.atr15m * 0.3 && price <= $0.top + ctx.atr15m * 0.3 }
        guard nearZone else { return [] }
        if div.direction == .long {
            return [SignalCandidate(
                def: StrategyRegistry.deltaDivDef, direction: .long,
                entry: price, stop: price - ctx.atr15m * 0.8,
                targets: [price + ctx.atr15m * 2],
                timeframe: "1m",
                note: "Price pushing lower while cumulative delta holds higher at a zone (buyers absorbing). [Dale confirmation #4]",
                triggerQuality: true, freshLevel: false)]
        } else {
            return [SignalCandidate(
                def: StrategyRegistry.deltaDivDef, direction: .short,
                entry: price, stop: price + ctx.atr15m * 0.8,
                targets: [price - ctx.atr15m * 2],
                timeframe: "1m",
                note: "Price pushing higher while cumulative delta rolls lower at a zone (sellers absorbing). [Dale confirmation #4]",
                triggerQuality: true, freshLevel: false)]
        }
    }

    // MARK: S10 — Volume cluster retest [Dale setups #1/#1b/#2]

    static func volumeCluster(_ ctx: StrategyContext) -> [SignalCandidate] {
        let price = ctx.data.ticker.lastPrice
        guard price > 0, ctx.atr15m > 0 else { return [] }
        // Trend direction from 15m structure decides which side the cluster defends.
        let trend = Structure.trendDirection(ctx.data.klines15m)
        guard let trend = trend else { return [] }
        guard let node = VolumeProfileEngine.clusterNearPrice(nodes: ctx.vpNodes, price: price, atrValue: ctx.atr15m) else { return [] }
        let dir: TradeDirection = trend // uptrend cluster → long; downtrend cluster → short
        return [SignalCandidate(
            def: StrategyRegistry.volumeClusterDef,
            direction: dir,
            entry: price,
            stop: dir == .long ? node.bottom - ctx.atr15m * 0.25 : node.top + ctx.atr15m * 0.25,
            targets: dir == .long ? [node.top + (node.top - node.bottom) * 2] : [node.bottom - (node.top - node.bottom) * 2],
            timeframe: "15m",
            note: "Pullback into heavy-volume cluster \(fmt(node.bottom))–\(fmt(node.top)) in a \(trend == .long ? "up" : "down")trend; institutional defenders. [Dale VP setups #1/#2]",
            triggerQuality: true, freshLevel: false)]
    }

    // MARK: S11 — Miner MTF momentum with 5m one-bar trigger [Miner ch.2, ch.6]

    static func minerMTF(_ ctx: StrategyContext) -> [SignalCandidate] {
        guard let htf = ctx.htfMomentum, let mtf = ctx.mtfMomentum, let stf = ctx.stfMomentum else { return [] }
        var out: [SignalCandidate] = []
        let price = ctx.data.ticker.lastPrice
        guard price > 0, ctx.atr5m > 0 else { return out }

        for dir in [TradeDirection.long, .short] {
            guard MomentumEngine.htfAllows(direction: dir, htf: htf.state) else { continue }
            guard MomentumEngine.reversalValid(direction: dir, snap: mtf) else { continue }
            // Entry trigger Tr-1BH/L: one tick beyond the last completed 5m bar [Miner ch.6].
            let last5 = ctx.data.klines5m.last
            guard let bar = last5 else { continue }
            let trigger = dir == .long ? bar.high + ctx.data.ticker.tickSize : bar.low - ctx.data.ticker.tickSize
            let stop = dir == .long ? bar.low - ctx.atr5m * 0.2 : bar.high + ctx.atr5m * 0.2
            let app = ctx.fibZones.first { $0.kind == (dir == .long ? .supply : .demand) }
            let t1 = app.map { dir == .long ? $0.bottom : $0.top } ?? price + (dir == .long ? 1 : -1) * (price - stop) * 2
            out.append(SignalCandidate(
                def: StrategyRegistry.minerMTFDef, direction: dir,
                entry: trigger, stop: stop, targets: [t1],
                timeframe: "5m",
                note: "1h \(htf.state.rawValue) + 15m \(dir == .long ? "bullish" : "bearish") reversal at K=\(String(format: "%.0f", mtf.k)) + 5m Tr-1B trigger \(fmt(trigger)). [Miner dual-TF momentum + Tr-1BH/L]",
                triggerQuality: stf.freshReversal && stf.crossDirection == dir, freshLevel: false))
        }
        return out
    }

    // MARK: S12 — Fib zone reversal [Miner ch.4]

    static func fibZone(_ ctx: StrategyContext) -> [SignalCandidate] {
        let price = ctx.data.ticker.lastPrice
        guard price > 0, ctx.atr15m > 0 else { return [] }
        var out: [SignalCandidate] = []
        for zone in ctx.fibZones {
            guard FibEngine.priceInZone(price: price, zone: zone, buffer: ctx.atr15m * 0.15) else { continue }
            // Momentum reversal required at the zone [Miner: zone + reversal = ideal setup].
            guard let mtf = ctx.mtfMomentum else { continue }
            if zone.kind == .demand && MomentumEngine.reversalValid(direction: .long, snap: mtf) {
                out.append(SignalCandidate(
                    def: StrategyRegistry.fibZoneDef, direction: .long,
                    entry: price, stop: zone.bottom - ctx.atr15m * 0.2,
                    targets: [price + ctx.atr15m * 2.5],
                    timeframe: "15m",
                    note: "Fib confluence zone \(fmt(zone.bottom))–\(fmt(zone.top)) (\(zone.weight) projections: \(zoneLevels(zone))) + 15m bullish reversal. [Miner Dynamic Price]",
                    triggerQuality: true, freshLevel: false))
            }
            if zone.kind == .supply && MomentumEngine.reversalValid(direction: .short, snap: mtf) {
                out.append(SignalCandidate(
                    def: StrategyRegistry.fibZoneDef, direction: .short,
                    entry: price, stop: zone.top + ctx.atr15m * 0.2,
                    targets: [price - ctx.atr15m * 2.5],
                    timeframe: "15m",
                    note: "Fib confluence zone \(fmt(zone.bottom))–\(fmt(zone.top)) (\(zone.weight) projections: \(zoneLevels(zone))) + 15m bearish reversal. [Miner Dynamic Price]",
                    triggerQuality: true, freshLevel: false))
            }
        }
        return out
    }

    private static func zoneLevels(_ zone: FibZone) -> String {
        zone.levels.map { lv in
            let kindName: String
            switch lv.kind {
            case .inRet: kindName = "IR"
            case .app: kindName = "APP"
            case .exRet: kindName = "XR"
            }
            return "\(kindName)\(String(format: "%.0f", lv.ratio * 100))"
        }.joined(separator: "/")
    }

    // MARK: S13 — Trendline pullback with confirmation candle [Shantharaj]

    static func trendlinePullback(_ ctx: StrategyContext) -> [SignalCandidate] {
        guard let dir = Structure.trendDirection(ctx.data.klines15m) else { return [] }
        guard let line = Structure.trendline(ctx.data.klines15m, kind: dir, atrValue: ctx.atr15m) else { return [] }
        let price = ctx.data.ticker.lastPrice
        guard price > 0 else { return [] }
        // Price at the line + confirmation candle [Shantharaj: entry beyond confirmation candle].
        let c = ctx.data.klines15m.last
        guard let c = c, abs(price - line.price) <= ctx.atr15m * 0.5 else { return [] }
        if dir == .long {
            guard c.isBull, c.body > 0 else { return [] }
            let rrTarget = line.price + (c.close - line.price) + ctx.atr15m * 2
            let swingTarget = ctx.swings15m.filter { $0.isHigh }.last?.price
            let t1 = swingTarget.map { max($0, line.price + (c.high - c.low)) } ?? rrTarget
            return [SignalCandidate(
                def: StrategyRegistry.trendlinePullbackDef, direction: .long,
                entry: c.high, stop: c.low - ctx.atr15m * 0.1,
                targets: [t1],
                timeframe: "15m",
                note: "\(line.touches)-touch rising trendline (<45° slope), bullish confirmation candle at the line; target = previous swing high. [Shantharaj trend following 1:1.5]",
                triggerQuality: true, freshLevel: false)]
        } else {
            guard !c.isBull, c.body > 0 else { return [] }
            let swingTarget = ctx.swings15m.filter { !$0.isHigh }.last?.price
            let t1 = swingTarget.map { min($0, line.price - (c.high - c.low)) } ?? line.price - ctx.atr15m * 2
            return [SignalCandidate(
                def: StrategyRegistry.trendlinePullbackDef, direction: .short,
                entry: c.low, stop: c.high + ctx.atr15m * 0.1,
                targets: [t1],
                timeframe: "15m",
                note: "\(line.touches)-touch falling trendline (<45° slope), bearish confirmation candle at the line; target = previous swing low. [Shantharaj trend following 1:1.5]",
                triggerQuality: true, freshLevel: false)]
        }
    }

    // MARK: S14 — Rejection / Acceptance [Shantharaj]

    static func rejectionAcceptance(_ ctx: StrategyContext) -> [SignalCandidate] {
        var out: [SignalCandidate] = []
        guard let c = ctx.data.klines15m.last, ctx.atr15m > 0 else { return out }
        let price = ctx.data.ticker.lastPrice
        guard price > 0 else { return out }

        for zone in ctx.sdZones {
            let near = ZoneEngine.priceTouchesZone(price: price, zone: zone, buffer: ctx.atr15m * 0.2)
            guard near else { continue }
            if zone.kind == .demand {
                // REJECTION: wick pierces below zone, candle closes back above zone top [Shantharaj].
                if c.low < zone.bottom && c.close > zone.top && c.lowerWick >= c.body * 2 {
                    out.append(SignalCandidate(
                        def: StrategyRegistry.rejectionDef, direction: .long,
                        entry: c.high, stop: c.low - ctx.atr15m * 0.1,
                        targets: [price + (c.high - c.low) * 2, price + (c.high - c.low) * 3],
                        timeframe: "15m",
                        note: "Rejection wick pierced the demand zone and closed back inside (smart-money snap). 50% off at 1:2, trail rest. [Shantharaj price rejection]",
                        triggerQuality: true, freshLevel: zone.isFresh))
                }
                // ACCEPTANCE: strong bullish close above resistance-turned-support [Shantharaj].
                if c.close > zone.top && c.body >= ctx.atr15m * 0.8 && c.isBull {
                    out.append(SignalCandidate(
                        def: StrategyRegistry.acceptanceDef, direction: .long,
                        entry: c.close, stop: c.low,
                        targets: [c.close + (c.close - c.low) * 1.5],
                        timeframe: "15m",
                        note: "Acceptance: strong close above the zone edge — sellers failed to reject. [Shantharaj price acceptance]",
                        triggerQuality: true, freshLevel: zone.isFresh))
                }
            } else {
                if c.high > zone.top && c.close < zone.bottom && c.upperWick >= c.body * 2 {
                    out.append(SignalCandidate(
                        def: StrategyRegistry.rejectionDef, direction: .short,
                        entry: c.low, stop: c.high + ctx.atr15m * 0.1,
                        targets: [price - (c.high - c.low) * 2, price - (c.high - c.low) * 3],
                        timeframe: "15m",
                        note: "Rejection wick pierced the supply zone and closed back below (buyers trapped). 50% off at 1:2, trail rest. [Shantharaj price rejection]",
                        triggerQuality: true, freshLevel: zone.isFresh))
                }
                if c.close < zone.bottom && c.body >= ctx.atr15m * 0.8 && !c.isBull {
                    out.append(SignalCandidate(
                        def: StrategyRegistry.acceptanceDef, direction: .short,
                        entry: c.close, stop: c.high,
                        targets: [c.close - (c.high - c.close) * 1.5],
                        timeframe: "15m",
                        note: "Acceptance: strong bearish close below the zone edge — buyers failed. [Shantharaj price acceptance]",
                        triggerQuality: true, freshLevel: zone.isFresh))
                }
            }
        }
        return out
    }

    // MARK: S15 — Trend scalper: MA gradient + pullback [Forexop Simple Trend Scalper]

    static func trendScalper(_ ctx: StrategyContext) -> [SignalCandidate] {
        let k5 = ctx.data.klines5m
        guard k5.count > 55, ctx.atr5m > 0 else { return [] }
        let closes = k5.map { $0.close }
        let fast = Indicators.ema(closes, 20)
        let slow = Indicators.ema(closes, 50)
        let grad = Indicators.maGradient(slow, lookback: 3) // ΔMAt of the slow MA [Forexop]
        let price = ctx.data.ticker.lastPrice
        guard price > 0, let f = fast.last ?? nil else { return [] }
        // Buy: gradient > 0 AND ask below fast MA (pullback trough); sell mirrored.
        if grad > 0, price < f {
            let stop = price - ctx.atr5m // fixed stop ≈ 8 pips in the book [ADAPT → 1×ATR]
            return [SignalCandidate(
                def: StrategyRegistry.trendScalperDef, direction: .long,
                entry: price, stop: stop,
                targets: [price + ctx.atr5m * 1.4], // ≈ book's 8-pip SL vs ~10-pip winner ratio [ADAPT]
                timeframe: "5m",
                note: "EMA50 gradient positive (Δ=\(String(format: "%.5f", grad))) + price pulled back below EMA20. Partial off at 1×ATR, rest runs. [Forexop trend scalper]",
                triggerQuality: true, freshLevel: false)]
        }
        if grad < 0, price > f {
            let stop = price + ctx.atr5m
            return [SignalCandidate(
                def: StrategyRegistry.trendScalperDef, direction: .short,
                entry: price, stop: stop,
                targets: [price - ctx.atr5m * 1.4],
                timeframe: "5m",
                note: "EMA50 gradient negative (Δ=\(String(format: "%.5f", grad))) + price popped above EMA20. [Forexop trend scalper]",
                triggerQuality: true, freshLevel: false)]
        }
        return []
    }

    // MARK: S16 — BB retrace scalp [Forexop Meta scalper]

    static func bbRetrace(_ ctx: StrategyContext) -> [SignalCandidate] {
        let k1 = ctx.data.klines1m
        guard k1.count > 25 else { return [] }
        let bands = Indicators.bollinger(k1, period: 20, mult: 2.0)
        guard let lower = bands.lower.last ?? nil, let upper = bands.upper.last ?? nil else { return [] }
        let width = upper - lower
        guard width > 0 else { return [] }
        let price = ctx.data.ticker.lastPrice
        guard price > 0 else { return [] }
        let c = k1[k1.count - 1]
        let prev = k1[k1.count - 2]
        // Long: bar touched the LOWER band and the current bar retraces back toward the mean.
        if prev.low <= lower && c.close > prev.close && c.isBull {
            return [SignalCandidate(
                def: StrategyRegistry.bbRetraceDef, direction: .long,
                entry: price, stop: price - width * 0.5,           // stop ≤ half band width [Forexop]
                targets: [price + width * 0.08],                   // ~5% of band width target [Forexop]
                timeframe: "1m",
                note: "Lower BB(20,2) touch + retrace candle. Target ≈8% of bandwidth; range-bound regime only. [Forexop Meta scalper]",
                triggerQuality: true, freshLevel: false)]
        }
        if prev.high >= upper && c.close < prev.close && !c.isBull {
            return [SignalCandidate(
                def: StrategyRegistry.bbRetraceDef, direction: .short,
                entry: price, stop: price + width * 0.5,
                targets: [price - width * 0.08],
                timeframe: "1m",
                note: "Upper BB(20,2) touch + retrace candle. Target ≈8% of bandwidth. [Forexop Meta scalper]",
                triggerQuality: true, freshLevel: false)]
        }
        return []
    }

    // MARK: S17 — MA crossover regime [Bryan Lee ch.3]

    static func maCross(_ ctx: StrategyContext) -> [SignalCandidate] {
        guard let dir = ctx.htfCross, let rsi = ctx.rsi1h, ctx.atr1h > 0 else { return [] }
        let price = ctx.data.ticker.lastPrice
        guard price > 0 else { return [] }
        // Cross + RSI must not contradict [Bryan Lee: "if the RSI does not show signs… wait"].
        if dir == .long && rsi > 50 {
            return [SignalCandidate(
                def: StrategyRegistry.maCrossDef, direction: .long,
                entry: price, stop: price - ctx.atr1h * 1.5,
                targets: [price + ctx.atr1h * 4],
                timeframe: "1h",
                note: "1h EMA50 above EMA200 (golden-cross regime) with RSI \(String(format: "%.0f", rsi)) agreeing. [Bryan Lee MA crossover]",
                triggerQuality: false, freshLevel: false)]
        }
        if dir == .short && rsi < 50 {
            return [SignalCandidate(
                def: StrategyRegistry.maCrossDef, direction: .short,
                entry: price, stop: price + ctx.atr1h * 1.5,
                targets: [price - ctx.atr1h * 4],
                timeframe: "1h",
                note: "1h EMA50 below EMA200 (death-cross regime) with RSI \(String(format: "%.0f", rsi)) agreeing. [Bryan Lee MA crossover]",
                triggerQuality: false, freshLevel: false)]
        }
        return []
    }

    // MARK: S18 — RSI extreme fade [Bryan Lee ch.5]

    static func rsiExtreme(_ ctx: StrategyContext) -> [SignalCandidate] {
        guard let rsi = ctx.rsi1h, ctx.atr1h > 0 else { return [] }
        let price = ctx.data.ticker.lastPrice
        guard price > 0 else { return [] }
        // Counter-trade the extreme only with an MTF momentum reversal agreeing [Bryan Lee RSI + Miner].
        guard let mtf = ctx.mtfMomentum else { return [] }
        if rsi <= 30 && MomentumEngine.reversalValid(direction: .long, snap: mtf) {
            return [SignalCandidate(
                def: StrategyRegistry.rsiExtremeDef, direction: .long,
                entry: price, stop: price - ctx.atr1h,
                targets: [price + ctx.atr1h * 1.5],
                timeframe: "15m",
                note: "1h RSI \(String(format: "%.0f", rsi)) (oversold) + 15m momentum bullish reversal. [Bryan Lee RSI counter-trading]",
                triggerQuality: true, freshLevel: false)]
        }
        if rsi >= 70 && MomentumEngine.reversalValid(direction: .short, snap: mtf) {
            return [SignalCandidate(
                def: StrategyRegistry.rsiExtremeDef, direction: .short,
                entry: price, stop: price + ctx.atr1h,
                targets: [price - ctx.atr1h * 1.5],
                timeframe: "15m",
                note: "1h RSI \(String(format: "%.0f", rsi)) (overbought) + 15m momentum bearish reversal. [Bryan Lee RSI counter-trading]",
                triggerQuality: true, freshLevel: false)]
        }
        return []
    }

    // MARK: S19 — Renko flip [user mandate; DTB dull-market breakout logic]

    static func renkoFlip(_ ctx: StrategyContext) -> [SignalCandidate] {
        guard let flip = RenkoEngine.flipSignal(bricks: ctx.renkoBricks), ctx.renkoSize > 0 else { return [] }
        let price = ctx.data.ticker.lastPrice
        guard price > 0 else { return [] }
        let dir = flip.direction
        return [SignalCandidate(
            def: StrategyRegistry.renkoFlipDef, direction: dir,
            entry: price,
            stop: dir == .long ? price - ctx.renkoSize : price + ctx.renkoSize,
            targets: dir == .long ? [price + ctx.renkoSize * 2, price + ctx.renkoSize * 3] : [price - ctx.renkoSize * 2, price - ctx.renkoSize * 3],
            timeframe: "1h(Renko)",
            note: "Renko flip after \(flip.priorRun)-brick run (brick \(fmt(ctx.renkoSize))). Cap size — this is the momentum rider. [S19]",
            triggerQuality: true, freshLevel: false)]
    }

    private static func fmt(_ v: Double) -> String {
        String(format: "%.4f", v)
    }
}
