//  RiskView.swift
//  ToobitSniper — risk rails dashboard + position sizing calculator
//
//  Ultra-safe rails (STRATEGY_SPEC §4): 1%/trade, 3% open, 5% daily lockout,
//  10% monthly stop, half size after 3 losses, ≤3 alerts/symbol/day.

import SwiftUI

struct RiskView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var governor: RiskGovernor

    @State private var calcEntry: String = ""
    @State private var calcStop: String = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                railGrid
                streakPanel
                sizingPanel
                rulesPanel
            }
            .padding(12)
        }
        .background(Color.terminalBG)
        .navigationTitle("RISK GOVERNOR")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var railGrid: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                railTile(title: "EQUITY", value: "$\(Formatters.qty(governor.config.equity))", color: .accentCyan)
                railTile(title: "RISK/TRADE", value: String(format: "%.1f%%", governor.config.riskPerTradePct), color: .accentAmber)
            }
            HStack(spacing: 10) {
                railTile(title: "DAILY LOSS",
                         value: String(format: "%.1f%% / %.0f%%", governor.dailyLossPct, governor.config.maxDailyLossPct),
                         color: governor.dailyLossPct > 3 ? .shortRed : .terminalText,
                         warn: governor.dailyLockedOut,
                         warnText: "LOCKED OUT [Shantharaj]")
                railTile(title: "MONTHLY DD",
                         value: String(format: "%.1f%% / %.0f%%", governor.monthlyLossPct, governor.config.monthlyStopPct),
                         color: governor.monthlyStopped ? .shortRed : .terminalText,
                         warn: governor.monthlyStopped,
                         warnText: "STOPPED [Miner 10%]")
            }
            HStack(spacing: 10) {
                railTile(title: "OPEN RISK", value: String(format: "%.1f%% / %.0f%%", governor.openRiskPct, governor.config.maxOpenRiskPct), color: .terminalText)
                railTile(title: "CONCURRENT", value: "≤\(governor.config.maxConcurrent)", color: .terminalText)
            }
            equityEditor
        }
    }

    private var equityEditor: some View {
        HStack {
            Text("ACCOUNT EQUITY (USDT)")
                .font(TerminalFont.mono(10))
                .foregroundColor(.terminalMuted)
            Spacer()
            TextField("10000", text: Binding(
                get: { String(Int(governor.config.equity)) },
                set: { governor.config.equity = Double($0) ?? governor.config.equity }))
                .font(TerminalFont.mono(13, weight: .bold))
                .foregroundColor(.terminalText)
                .multilineTextAlignment(.trailing)
                .keyboardType(.numberPad)
                .frame(width: 110)
        }
        .padding(.top, 4)
    }

    private var streakPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("LOSING STREAK").font(TerminalFont.mono(10)).foregroundColor(.terminalMuted)
            HStack {
                ForEach(0..<5, id: \.self) { i in
                    Circle()
                        .fill(i < governor.losingStreak ? Color.shortRed : Color.terminalBorder)
                        .frame(width: 12, height: 12)
                }
                Spacer()
                Text(governor.losingStreak >= governor.config.losingStreakHalfSize
                     ? "HALF SIZE ACTIVE [Lebin]"
                     : "full size")
                    .font(TerminalFont.mono(11, weight: .bold))
                    .foregroundColor(governor.losingStreak >= governor.config.losingStreakHalfSize ? .shortRed : .terminalMuted)
            }
        }
        .panel()
    }

    private var sizingPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("POSITION SIZER — qty = (equity × risk%) / (entry − stop) [Shantharaj]")
                .font(TerminalFont.mono(10)).foregroundColor(.terminalMuted)
            HStack(spacing: 10) {
                field(label: "ENTRY", text: $calcEntry)
                field(label: "STOP", text: $calcStop)
            }
            if let entry = Double(calcEntry), let stop = Double(calcStop),
               let sizing = governor.size(entry: entry, stop: stop) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("QUANTITY").font(TerminalFont.mono(9)).foregroundColor(.terminalMuted)
                        Text(Formatters.qty(sizing.quantity))
                            .font(TerminalFont.mono(14, weight: .bold)).foregroundColor(.longGreen)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("RISK $ / NOTIONAL").font(TerminalFont.mono(9)).foregroundColor(.terminalMuted)
                        Text("$\(Formatters.qty(sizing.riskAmount)) / $\(Formatters.qty(sizing.notional))")
                            .font(TerminalFont.mono(12, weight: .bold)).foregroundColor(.accentAmber)
                    }
                }
                if sizing.halfSize {
                    Text("half size — losing streak ≥\(governor.config.losingStreakHalfSize) [Lebin]")
                        .font(TerminalFont.mono(10))
                        .foregroundColor(.shortRed)
                }
            } else {
                Text("enter entry & stop to size the trade")
                    .font(TerminalFont.mono(10)).foregroundColor(.terminalMuted)
            }
        }
        .panel()
    }

    private func field(label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(TerminalFont.mono(9)).foregroundColor(.terminalMuted)
            TextField("0.0", text: text)
                .font(TerminalFont.mono(13, weight: .bold))
                .foregroundColor(.terminalText)
                .keyboardType(.decimalPad)
                .overlay(Rectangle().frame(height: 1).foregroundColor(Color.terminalBorder), alignment: .bottom)
        }
    }

    private var rulesPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SURVIVAL RULES IN FORCE").font(TerminalFont.mono(10)).foregroundColor(.terminalMuted)
            ruleLine("1% risk per trade — Wyckoff Methodology / Lebin")
            ruleLine("5% daily loss → lockout — Shantharaj")
            ruleLine("10% monthly drawdown → stop for the month — Miner")
            ruleLine("≥3 consecutive losses → half size or stand aside — Lebin")
            ruleLine("≤3 alerts per symbol per day — Shantharaj")
            ruleLine("No averaging down; never move a stop away from price — Lebin / DTB")
            ruleLine("Spread must stay ≤10% of target distance — Forexop")
        }
        .panel()
    }

    private func ruleLine(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("▸").font(TerminalFont.mono(10)).foregroundColor(.accentAmber)
            Text(text).font(TerminalFont.mono(11)).foregroundColor(.terminalText)
        }
    }

    private func railTile(title: String, value: String, color: Color, warn: Bool = false, warnText: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(TerminalFont.mono(9)).foregroundColor(.terminalMuted)
            Text(value).font(TerminalFont.mono(14, weight: .bold)).foregroundColor(color)
            if warn, let warnText = warnText {
                Text(warnText).font(TerminalFont.mono(9, weight: .bold)).foregroundColor(.shortRed)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }
}

// MARK: - Strategies & settings screen

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        List {
            Section("SCORING MODE") {
                Picker("Mode", selection: Binding(
                    get: { store.engineConfig.mode },
                    set: { store.engineConfig.mode = $0; store.applyConfig() })) {
                    ForEach(ScoringMode.allCases, id: \.self) { mode in
                        Text("\(mode.rawValue) ≥\(mode.threshold)").font(TerminalFont.mono(12))
                    }
                }
                .pickerStyle(.inline)
            }
            Section("STRATEGIES (\(store.engineConfig.disabledStrategies.count) disabled)") {
                ForEach(StrategyRegistry.all) { def in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(def.id) · \(def.name)")
                                .font(TerminalFont.mono(12, weight: .bold))
                                .foregroundColor(.terminalText)
                            Text(def.book)
                                .font(TerminalFont.mono(9))
                                .foregroundColor(.terminalMuted)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { !store.engineConfig.disabledStrategies.contains(def.id) },
                            set: { on in
                                if on { store.engineConfig.disabledStrategies.remove(def.id) }
                                else { store.engineConfig.disabledStrategies.insert(def.id) }
                                store.applyConfig()
                            }))
                            .labelsHidden()
                            .tint(.longGreen)
                    }
                }
            }
            Section("RENKO (1h base)") {
                Picker("Brick = ATR(14) ×", selection: Binding(
                    get: { store.engineConfig.renkoATRRatio },
                    set: { store.engineConfig.renkoATRRatio = $0; store.applyConfig() })) {
                    Text("0.3×").tag(0.3)
                    Text("0.5×").tag(0.5)
                    Text("1.0×").tag(1.0)
                }
                .pickerStyle(.segmented)
            }
            Section("WATCHLIST (USDT-M PERP)") {
                ForEach(store.symbols, id: \.self) { sym in
                    HStack {
                        Text(sym).font(TerminalFont.mono(12)).foregroundColor(.terminalText)
                        Spacer()
                        Button("remove") { store.removeSymbol(sym) }
                            .font(TerminalFont.mono(10))
                            .foregroundColor(.shortRed)
                    }
                }
                if !store.availableSymbols.isEmpty {
                    Menu("add symbol…") {
                        ForEach(store.availableSymbols.filter { !store.symbols.contains($0) }.prefix(120), id: \.self) { sym in
                            Button(sym) { store.addSymbol(sym) }
                        }
                    }
                    .font(TerminalFont.mono(12))
                }
            }
            Section("CONNECTION") {
                HStack {
                    Text("Status").font(TerminalFont.mono(12)).foregroundColor(.terminalMuted)
                    Spacer()
                    Text(store.connectionStatus).font(TerminalFont.mono(12)).foregroundColor(.accentCyan)
                }
                HStack {
                    Text("Data plane").font(TerminalFont.mono(12)).foregroundColor(.terminalMuted)
                    Spacer()
                    Text("REST api.toobit.com + WSS stream.toobit.com").font(TerminalFont.mono(10)).foregroundColor(.terminalMuted)
                }
                HStack {
                    Text("Order execution").font(TerminalFont.mono(12)).foregroundColor(.terminalMuted)
                    Spacer()
                    Text("DISABLED (alerts only)").font(TerminalFont.mono(12, weight: .bold)).foregroundColor(.accentAmber)
                }
            }
            Section("ABOUT") {
                Text("19 strategies distilled from 8 books: Miner, Villahermosa (Wyckoff), Wyckoff 1919, Lebin, Trader Dale, Shantharaj, Forexop, Bryan Lee. Confluence scoring per docs/STRATEGY_SPEC.md. Signals are educational alerts — not financial advice; trade at your own risk.")
                    .font(TerminalFont.mono(10))
                    .foregroundColor(.terminalMuted)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.terminalBG)
        .navigationTitle("SETUP")
        .navigationBarTitleDisplayMode(.inline)
    }
}
