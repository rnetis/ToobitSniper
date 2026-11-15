//  RiskGovernor.swift
//  ToobitSniper — ultra-safe risk rails ("survival solution", STRATEGY_SPEC §4)
//
//  Sources: 1%/trade [Wyckoff Methodology, Lebin], 5% daily lockout [Shantharaj],
//  10% monthly stop [Miner], half size after ≥3 consecutive losses [Lebin],
//  qty = (equity × risk%) / (entry − stop) [Shantharaj formula].

import Foundation
import Combine

struct RiskConfig: Codable {
    var equity: Double = 10_000          // user-editable USDT equity
    var riskPerTradePct: Double = 1.0    // ultra-safe
    var maxOpenRiskPct: Double = 3.0
    var maxDailyLossPct: Double = 5.0
    var monthlyStopPct: Double = 10.0
    var maxConcurrent: Int = 2
    var maxTradesPerSymbolPerDay: Int = 3
    var losingStreakHalfSize: Int = 3
}

struct RiskVerdict {
    let allowed: Bool
    let reason: String
}

final class RiskGovernor: ObservableObject {
    @Published var config: RiskConfig {
        didSet {
            // Editing equity before any P&L is booked re-bases today's starting equity;
            // otherwise the daily-loss percentage would keep using the stale value.
            if realizedToday == 0 { dailyStartEquity = config.equity }
        }
    }
    @Published var dailyStartEquity: Double
    @Published var realizedToday: Double = 0
    @Published var openRiskPct: Double = 0
    @Published var losingStreak: Int = 0
    @Published var monthlyRealized: Double = 0
    @Published var tradesTodayBySymbol: [String: Int] = [:]
    private var monthStamp: String = ""

    init(config: RiskConfig = RiskConfig()) {
        self.config = config
        self.dailyStartEquity = config.equity
    }

    // MARK: - Rails

    var dailyLossPct: Double {
        // realizedToday is a P&L delta (not an equity level): a loss is its negation.
        let loss = -realizedToday
        return dailyStartEquity > 0 ? max(0, loss / dailyStartEquity * 100) : 0
    }

    var monthlyLossPct: Double {
        let base = config.equity
        let loss = -monthlyRealized
        return base > 0 ? max(0, loss / base * 100) : 0
    }

    var dailyLockedOut: Bool { dailyLossPct >= config.maxDailyLossPct }
    var monthlyStopped: Bool { monthlyLossPct >= config.monthlyStopPct }

    func verdict(signal: Signal) -> RiskVerdict {
        if monthlyStopped {
            return RiskVerdict(allowed: false, reason: String(format: "monthly drawdown %.1f%% ≥ %.0f%% — stopped for the month [Miner 10%% rule]", monthlyLossPct, config.monthlyStopPct))
        }
        if dailyLockedOut {
            return RiskVerdict(allowed: false, reason: String(format: "daily loss %.1f%% ≥ %.0f%% — locked out for the day [Shantharaj 5%% rule]", dailyLossPct, config.maxDailyLossPct))
        }
        if openRiskPct + config.riskPerTradePct > config.maxOpenRiskPct {
            return RiskVerdict(allowed: false, reason: String(format: "open risk %.1f%% + %.0f%% would exceed %.0f%% cap", openRiskPct, config.riskPerTradePct, config.maxOpenRiskPct))
        }
        let todays = tradesTodayBySymbol[signal.symbol] ?? 0
        if todays >= config.maxTradesPerSymbolPerDay {
            return RiskVerdict(allowed: false, reason: "\(todays) alerts already for \(signal.symbol) today [Shantharaj ≤3 trades/day]")
        }
        return RiskVerdict(allowed: true, reason: "within rails")
    }

    // MARK: - Position sizing [Shantharaj formula]

    struct Sizing {
        let riskAmount: Double
        let quantity: Double
        let notional: Double
        let halfSize: Bool
    }

    func size(entry: Double, stop: Double) -> Sizing? {
        let dist = abs(entry - stop)
        guard dist > 0, config.equity > 0 else { return nil }
        let riskAmount = config.equity * config.riskPerTradePct / 100
        let half = losingStreak >= config.losingStreakHalfSize
        let qty = riskAmount * (half ? 0.5 : 1.0) / dist
        return Sizing(riskAmount: riskAmount, quantity: qty, notional: qty * entry, halfSize: half)
    }

    // MARK: - Ledger updates (manual, until live trading ships)

    func recordAlert(symbol: String) {
        tradesTodayBySymbol[symbol, default: 0] += 1
    }

    func recordResult(pnl: Double) {
        realizedToday += pnl
        monthlyRealized += pnl
        if pnl < 0 { losingStreak += 1 } else if pnl > 0 { losingStreak = 0 }
    }

    func newDay() {
        // Roll the monthly ledger over once per calendar month (it was never reset before,
        // so a monthly stop would have been permanent).
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM"
        let month = fmt.string(from: Date())
        if month != monthStamp {
            if !monthStamp.isEmpty { monthlyRealized = 0 }
            monthStamp = month
        }
        dailyStartEquity = config.equity
        realizedToday = 0
        tradesTodayBySymbol = [:]
    }
}
