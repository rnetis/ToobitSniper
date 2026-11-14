//  DashboardView.swift
//  ToobitSniper — market dashboard: watchlist, live prices, delta, Renko badge, signal count

import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    statusPill
                    ForEach(store.symbols, id: \.self) { sym in
                        if let data = store.market[sym] {
                            WatchlistRow(symbol: sym,
                                         data: data,
                                         signalCount: store.signals.filter { $0.symbol == sym }.count)
                        }
                    }
                    recentSignalsPreview
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 20)
            }
            .background(Color.terminalBG)
            .navigationTitle("TOOBIT SNIPER")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: UUID.self) { id in
                if let signal = store.signals.first(where: { $0.id == id }) {
                    SignalDetailView(signal: signal)
                }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(store.bootstrapped ? Color.longGreen : Color.accentAmber)
                            .frame(width: 8, height: 8)
                        Text(store.connectionStatus.uppercased())
                            .font(TerminalFont.mono(11))
                            .foregroundColor(.terminalMuted)
                    }
                }
            }
        }
    }

    private var statusPill: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("MODE").font(TerminalFont.mono(10)).foregroundColor(.terminalMuted)
                Text("\(store.engineConfig.mode.rawValue.uppercased()) ≥\(store.engineConfig.mode.threshold)")
                    .font(TerminalFont.mono(13, weight: .bold))
                    .foregroundColor(.accentAmber)
            }
            Spacer()
            VStack(alignment: .center, spacing: 2) {
                Text("ALERTS").font(TerminalFont.mono(10)).foregroundColor(.terminalMuted)
                Text("\(store.signals.filter { $0.allowedByRisk }.count)")
                    .font(TerminalFont.mono(13, weight: .bold))
                    .foregroundColor(.accentCyan)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("DAILY LOSS").font(TerminalFont.mono(10)).foregroundColor(.terminalMuted)
                Text(String(format: "%.1f%%", store.governor.dailyLossPct))
                    .font(TerminalFont.mono(13, weight: .bold))
                    .foregroundColor(store.governor.dailyLockedOut ? .shortRed : .terminalText)
            }
        }
        .panel()
    }

    private var recentSignalsPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("LATEST SIGNALS").font(TerminalFont.mono(11)).foregroundColor(.terminalMuted)
            if store.signals.isEmpty {
                Text("engine armed — waiting for confluence…")
                    .font(TerminalFont.mono(11))
                    .foregroundColor(.terminalMuted)
            }
            ForEach(store.signals.prefix(3)) { signal in
                NavigationLink(value: signal.id) {
                    HStack {
                        Text(signal.direction == .long ? "▲" : "▼")
                            .foregroundColor(signal.directionColor)
                            .font(TerminalFont.mono(12, weight: .bold))
                        Text("\(signal.symbol.replacingOccurrences(of: "-SWAP-USDT", with: "")) \(signal.def.name)")
                            .font(TerminalFont.mono(12))
                            .foregroundColor(.terminalText)
                        Spacer()
                        Text("\(signal.score)")
                            .font(TerminalFont.mono(13, weight: .bold))
                            .foregroundColor(signal.tierColor)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .panel()
    }
}

struct WatchlistRow: View {
    let symbol: String
    let data: SymbolMarketData
    let signalCount: Int

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(symbol.replacingOccurrences(of: "-SWAP-USDT", with: ""))
                    .font(TerminalFont.mono(15, weight: .bold))
                    .foregroundColor(.terminalText)
                Text("PERP")
                    .font(TerminalFont.mono(9))
                    .foregroundColor(.terminalMuted)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.terminalPanelAlt)
                    .cornerRadius(3)
                Spacer()
                if signalCount > 0 {
                    Text("\(signalCount) SIG")
                        .font(TerminalFont.mono(10, weight: .bold))
                        .foregroundColor(.accentAmber)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.accentAmber, lineWidth: 1))
                }
            }
            HStack {
                Text(Formatters.price(data.ticker.lastPrice))
                    .font(TerminalFont.mono(18, weight: .bold))
                    .foregroundColor(.terminalText)
                Text(Formatters.pct(data.ticker.changePct))
                    .font(TerminalFont.mono(12))
                    .foregroundColor(data.ticker.changePct >= 0 ? .longGreen : .shortRed)
                Spacer()
                deltaBadge
                fundingBadge
            }
        }
        .panel()
    }

    private var deltaBadge: some View {
        let recent = data.klines1m.suffix(15)
        let delta = recent.map { $0.delta }.reduce(0, +)
        return HStack(spacing: 4) {
            Text("Δ15m")
                .font(TerminalFont.mono(9))
                .foregroundColor(.terminalMuted)
            Text(delta >= 0 ? "+" : "")
                .font(TerminalFont.mono(11, weight: .bold))
            Text(Formatters.qty(delta))
                .font(TerminalFont.mono(11, weight: .bold))
                .foregroundColor(delta >= 0 ? .longGreen : .shortRed)
        }
    }

    private var fundingBadge: some View {
        let rate = data.ticker.fundingRate * 100
        return HStack(spacing: 4) {
            Text("FND")
                .font(TerminalFont.mono(9))
                .foregroundColor(.terminalMuted)
            Text(String(format: "%.3f%%", rate))
                .font(TerminalFont.mono(11))
                .foregroundColor(rate >= 0 ? .longGreen : .shortRed)
        }
    }
}
