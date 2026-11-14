//  SignalsView.swift
//  ToobitSniper — live signal feed with confluence breakdown
//
//  Each card: score ring, direction, strategy + book tag, entry/stop/targets,
//  R:R, risk verdict, expandable C1..C10 confluence chips (STRATEGY_SPEC §2).

import SwiftUI

struct SignalsView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        NavigationStack {
            Group {
                if store.signals.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "bolt.slash")
                            .font(.system(size: 40))
                            .foregroundColor(.terminalMuted)
                        Text("No signals above \(store.engineConfig.mode.threshold) yet")
                            .font(TerminalFont.mono(13))
                            .foregroundColor(.terminalMuted)
                        Text("Engine re-arms on every closed candle across \(store.symbols.count) symbols × 19 strategies")
                            .font(TerminalFont.mono(11))
                            .foregroundColor(.terminalMuted)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.terminalBG)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(store.signals) { signal in
                                NavigationLink(value: signal.id) {
                                    SignalCard(signal: signal)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                    }
                    .background(Color.terminalBG)
                }
            }
            .navigationTitle("SIGNAL FEED")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: UUID.self) { id in
                if let signal = store.signals.first(where: { $0.id == id }) {
                    SignalDetailView(signal: signal)
                }
            }
            .refreshable {
                for sym in store.symbols { store.evaluate(symbol: sym) }
            }
        }
    }
}

struct SignalCard: View {
    let signal: Signal

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(signal.direction.symbol)
                    .font(TerminalFont.mono(13, weight: .bold))
                    .foregroundColor(signal.directionColor)
                Text(signal.symbol.replacingOccurrences(of: "-SWAP-USDT", with: ""))
                    .font(TerminalFont.mono(14, weight: .bold))
                    .foregroundColor(.terminalText)
                Text(signal.def.name)
                    .font(TerminalFont.mono(11))
                    .foregroundColor(.terminalMuted)
                Spacer()
                ScoreRing(score: signal.score, color: signal.tierColor)
            }
            HStack(spacing: 14) {
                levelBlock(label: "ENTRY", value: Formatters.price(signal.entry), color: .accentCyan)
                levelBlock(label: "STOP", value: Formatters.price(signal.stop), color: .shortRed)
                levelBlock(label: "TP1", value: Formatters.price(signal.targets.first ?? 0), color: .longGreen)
                levelBlock(label: "R:R", value: String(format: "%.1f", signal.rr), color: .accentAmber)
                levelBlock(label: "TF", value: signal.timeframe, color: .terminalMuted)
                Spacer()
            }
            HStack {
                Text(signal.timeframe.isEmpty ? "" : signal.def.book)
                    .font(TerminalFont.mono(9))
                    .foregroundColor(.terminalMuted)
                    .lineLimit(1)
                Spacer()
                if !signal.allowedByRisk {
                    Image(systemName: "lock.fill")
                        .font(TerminalFont.mono(10))
                        .foregroundColor(.shortRed)
                }
                Text(Formatters.time(signal.createdAt))
                    .font(TerminalFont.mono(9))
                    .foregroundColor(.terminalMuted)
            }
        }
        .panel()
    }

    private func levelBlock(label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(TerminalFont.mono(9)).foregroundColor(.terminalMuted)
            Text(value).font(TerminalFont.mono(12, weight: .bold)).foregroundColor(color)
        }
    }
}

struct ScoreRing: View {
    let score: Int
    let color: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.terminalBorder, lineWidth: 3)
            Circle()
                .trim(from: 0, to: CGFloat(score) / 100)
                .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(score)")
                .font(TerminalFont.mono(11, weight: .bold))
                .foregroundColor(color)
        }
        .frame(width: 34, height: 34)
    }
}

struct SignalDetailView: View {
    let signal: Signal

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(signal.direction.symbol)
                        .font(TerminalFont.mono(16, weight: .bold))
                        .foregroundColor(signal.directionColor)
                    Text(signal.symbol)
                        .font(TerminalFont.mono(14))
                        .foregroundColor(.terminalText)
                    Spacer()
                    Text(signal.scoreTier.rawValue)
                        .font(TerminalFont.mono(11, weight: .bold))
                        .foregroundColor(signal.tierColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(signal.tierColor, lineWidth: 1))
                }
                .panel()

                VStack(alignment: .leading, spacing: 6) {
                    Text("SETUP NOTE").font(TerminalFont.mono(10)).foregroundColor(.terminalMuted)
                    Text(signal.note)
                        .font(TerminalFont.mono(12))
                        .foregroundColor(.terminalText)
                    Text("SOURCE: \(signal.def.book)")
                        .font(TerminalFont.mono(10))
                        .foregroundColor(.accentAmber)
                }
                .panel()

                VStack(alignment: .leading, spacing: 6) {
                    Text("CONFLUENCE \(signal.confluences.count) FACTORS · BASE \(signal.baseScore)")
                        .font(TerminalFont.mono(10)).foregroundColor(.terminalMuted)
                    ForEach(signal.confluences) { c in
                        HStack(alignment: .top, spacing: 8) {
                            Text(c.code)
                                .font(TerminalFont.mono(10, weight: .bold))
                                .foregroundColor(.accentCyan)
                                .frame(width: 30, alignment: .leading)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(c.name)
                                    .font(TerminalFont.mono(12, weight: .bold))
                                    .foregroundColor(.terminalText)
                                Text(c.detail)
                                    .font(TerminalFont.mono(10))
                                    .foregroundColor(.terminalMuted)
                            }
                            Spacer()
                            Text("\(c.points >= 0 ? "+" : "")\(c.points)")
                                .font(TerminalFont.mono(12, weight: .bold))
                                .foregroundColor(c.points >= 0 ? .longGreen : .shortRed)
                        }
                        .padding(.vertical, 3)
                        Divider().overlay(Color.terminalBorder)
                    }
                }
                .panel()

                if !signal.allowedByRisk, let note = signal.riskNote {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.shortRed)
                        Text("RISK GOVERNOR: \(note)")
                            .font(TerminalFont.mono(11))
                            .foregroundColor(.shortRed)
                    }
                    .panel()
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("EXECUTION PLAN (manual — alerts only)").font(TerminalFont.mono(10)).foregroundColor(.terminalMuted)
                    HStack {
                        Text("Entry \(Formatters.price(signal.entry))  ·  Stop \(Formatters.price(signal.stop))  ·  TP1 \(Formatters.price(signal.targets.first ?? 0))")
                            .font(TerminalFont.mono(12, weight: .bold))
                            .foregroundColor(.terminalText)
                    }
                    Text("Stop distance \(Formatters.price(signal.stopDistance)). Move stop to breakeven after first partial [Miner two-unit rule]; trail remainder beyond each new swing [Shantharaj trail rule].")
                        .font(TerminalFont.mono(11))
                        .foregroundColor(.terminalMuted)
                }
                .panel()
            }
            .padding(12)
        }
        .background(Color.terminalBG)
        .navigationTitle(signal.def.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
