//  ChartView.swift
//  ToobitSniper — Canvas candlestick + Renko chart with zone & signal overlays
//
//  Renko mode renders ATR bricks [user mandate]; candles mode overlays Lebin zones,
//  fib confluence zones, volume-profile HVNs and signal entry/stop/target rails.

import SwiftUI

struct ChartScreen: View {
    @EnvironmentObject private var store: AppStore
    @State private var selectedSymbol: String = ""
    @State private var timeframe: String = "15m"
    @State private var mode: ChartMode = .candles

    enum ChartMode: String, CaseIterable {
        case candles = "CANDLES"
        case renko = "RENKO"
    }

    var body: some View {
        VStack(spacing: 0) {
            symbolPicker
            controls
            if let data = store.market[selectedSymbol] {
                ChartView(symbol: selectedSymbol, data: data, timeframe: timeframe, mode: mode,
                          latestSignal: store.signals.first { $0.symbol == selectedSymbol })
                    .frame(maxHeight: .infinity)
                legendStrip(data: data)
            } else {
                Spacer()
                Text("loading \(selectedSymbol)…")
                    .font(TerminalFont.mono(12))
                    .foregroundColor(.terminalMuted)
                Spacer()
            }
        }
        .background(Color.terminalBG)
        .onAppear {
            if selectedSymbol.isEmpty {
                selectedSymbol = store.symbols.first ?? "BTC-SWAP-USDT"
            }
        }
    }

    private var symbolPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(store.symbols, id: \.self) { sym in
                    Button(action: { selectedSymbol = sym }) {
                        Text(sym.replacingOccurrences(of: "-SWAP-USDT", with: ""))
                            .font(TerminalFont.mono(12, weight: selectedSymbol == sym ? .bold : .regular))
                            .foregroundColor(selectedSymbol == sym ? .accentCyan : .terminalMuted)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(selectedSymbol == sym ? Color.terminalPanelAlt : Color.clear)
                            .cornerRadius(4)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Picker("TF", selection: $timeframe) {
                ForEach(["1m", "5m", "15m", "1h"], id: \.self) { Text($0).font(TerminalFont.mono(11)) }
            }
            .pickerStyle(.segmented)
            .frame(width: 160)
            Picker("MODE", selection: $mode) {
                ForEach(ChartMode.allCases, id: \.self) { Text($0.rawValue).font(TerminalFont.mono(11)) }
            }
            .pickerStyle(.segmented)
            .frame(width: 180)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func legendStrip(data: SymbolMarketData) -> some View {
        let harmony = WyckoffEngine.volumeHarmony(candles: data.klines15m)
        let (rt, run) = RenkoEngine.trend(bricks: RenkoEngine.build(candles: data.klines1h, config: RenkoConfig(atrRatio: store.engineConfig.renkoATRRatio)).bricks)
        return HStack(spacing: 14) {
            Label("1h EMA50×200: \(Structure.crossRegime(data.klines1h)?.rawValue.uppercased() ?? "—")", systemImage: "arrow.left.arrow.right")
                .font(TerminalFont.mono(10)).foregroundColor(.terminalMuted)
            Label("renko: \(rt?.rawValue.uppercased() ?? "FLAT") ×\(run)", systemImage: "square.stack.3d.up")
                .font(TerminalFont.mono(10))
                .foregroundColor(rt == .long ? .longGreen : (rt == .short ? .shortRed : .terminalMuted))
            Label("volume: \(harmony.harmony ? "harmony" : "divergence")", systemImage: "waveform")
                .font(TerminalFont.mono(10))
                .foregroundColor(harmony.harmony ? .longGreen : .accentAmber)
            Spacer()
            Text("upd \(data.lastEvaluatedAt.map(Formatters.time) ?? "—")")
                .font(TerminalFont.mono(10)).foregroundColor(.terminalMuted)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Renderer

struct ChartView: View {
    let symbol: String
    let data: SymbolMarketData
    let timeframe: String
    let mode: ChartScreen.ChartMode
    var latestSignal: Signal? = nil

    var body: some View {
        Canvas { context, size in
            switch mode {
            case .candles: renderCandles(context: context, size: size)
            case .renko: renderRenko(context: context, size: size)
            }
        }
        .padding(.horizontal, 12)
        .clipped()
    }

    private var renkoResult: (bricks: [RenkoBrick], size: Double) {
        RenkoEngine.build(candles: data.klines1h, config: RenkoConfig(atrRatio: 0.5))
    }

    private func drawRail(context: GraphicsContext, size: CGSize, price: Double, yMin: Double, yMax: Double, color: Color, label: String, dashed: Bool) {
        func y(_ p: Double) -> CGFloat {
            size.height - CGFloat((p - yMin) / max(yMax - yMin, 1e-9)) * size.height
        }
        var line = Path()
        line.move(to: CGPoint(x: 0, y: y(price)))
        line.addLine(to: CGPoint(x: size.width, y: y(price)))
        let style: StrokeStyle = dashed ? StrokeStyle(lineWidth: 1, dash: [4, 3]) : StrokeStyle(lineWidth: 1)
        context.stroke(line, with: .color(color), style: style)
        let text = Text(label).font(TerminalFont.mono(9)).foregroundColor(color)
        context.draw(text, at: CGPoint(x: size.width - 46, y: y(price) - 6), anchor: .leading)
    }

    private func renderCandles(context: GraphicsContext, size: CGSize) {
        let candles = data.candles(for: timeframe).suffix(120)
        guard candles.count > 2 else { return }
        let low = candles.map { $0.low }.min() ?? 0
        let high = candles.map { $0.high }.max() ?? 1
        let pad = (high - low) * 0.06
        let yMin = low - pad, yMax = high + pad
        func y(_ price: Double) -> CGFloat {
            size.height - CGFloat((price - yMin) / max(yMax - yMin, 1e-9)) * size.height
        }
        let cw = size.width / CGFloat(candles.count)
        let atr = Indicators.atrLast(data.candles(for: timeframe), period: 14)

        // Zone overlays (Lebin + fib)
        let zones: [(Color, Double, Double)] =
            ZoneEngine.detect(candles: data.candles(for: timeframe), atrValue: atr).map { zone in
                (zone.kind == .demand ? Color.longGreen.opacity(0.14) : Color.shortRed.opacity(0.14), zone.bottom, zone.top)
            }
        + FibEngine.zones(candles: data.candles(for: timeframe),
                          swings: Structure.swings(data.candles(for: timeframe), k: 2),
                          atrValue: atr).map { zone in
                (Color.accentCyan.opacity(0.12), zone.bottom, zone.top)
            }
        for (color, bottom, top) in zones {
            let rectTop = y(top), rectBottom = y(bottom)
            let h = abs(rectBottom - rectTop)
            let rect = CGRect(x: 0, y: min(rectTop, rectBottom), width: size.width, height: max(h, 2))
            context.fill(Path(rect), with: .color(color))
        }

        // Candles
        for (i, c) in candles.enumerated() {
            let x = CGFloat(i) * cw + cw / 2
            let color = c.isBull ? Color.longGreen : Color.shortRed
            var line = Path()
            line.move(to: CGPoint(x: x, y: y(c.high)))
            line.addLine(to: CGPoint(x: x, y: y(c.low)))
            context.stroke(line, with: .color(color), lineWidth: 1)
            let bodyTop = y(max(c.open, c.close))
            let bodyBot = y(min(c.open, c.close))
            let bodyRect = CGRect(x: x - cw * 0.35, y: bodyTop, width: cw * 0.7, height: max(bodyBot - bodyTop, 1))
            context.fill(Path(bodyRect), with: .color(color))
        }

        // Latest signal rails: entry (solid), stop (red dashed), first target (green dashed)
        if let sig = latestSignal {
            drawRail(context: context, size: size, price: sig.entry, yMin: yMin, yMax: yMax,
                     color: .accentCyan, label: "ENTRY", dashed: false)
            drawRail(context: context, size: size, price: sig.stop, yMin: yMin, yMax: yMax,
                     color: .shortRed, label: "STOP", dashed: true)
            if let t = sig.targets.first {
                drawRail(context: context, size: size, price: t, yMin: yMin, yMax: yMax,
                         color: .longGreen, label: "TP1", dashed: true)
            }
        }
    }

    private func renderRenko(context: GraphicsContext, size: CGSize) {
        let result = renkoResult
        let bricks = Array(result.bricks.suffix(120))
        guard bricks.count > 2 else { return }
        let low = bricks.map { min($0.open, $0.close) }.min() ?? 0
        let high = bricks.map { max($0.open, $0.close) }.max() ?? 1
        let yMin = low - result.size, yMax = high + result.size
        func y(_ price: Double) -> CGFloat {
            size.height - CGFloat((price - yMin) / max(yMax - yMin, 1e-9)) * size.height
        }
        let bh = max(size.height * CGFloat(result.size / max(yMax - yMin, 1e-9)), 3)
        let bw = size.width / CGFloat(bricks.count)
        for (i, brick) in bricks.enumerated() {
            let color = brick.direction == .up ? Color.longGreen : Color.shortRed
            let top = y(max(brick.open, brick.close))
            let rect = CGRect(x: CGFloat(i) * bw, y: top, width: bw * 0.85, height: bh)
            context.fill(Path(rect), with: .color(color.opacity(0.9)))
        }
        // Current run label
        let (trend, run) = RenkoEngine.trend(bricks: bricks)
        if let trend = trend {
            let text = Text("\(trend.rawValue.uppercased()) ×\(run)")
                .font(TerminalFont.mono(11, weight: .bold))
                .foregroundColor(trend == .long ? Color.longGreen : Color.shortRed)
            context.draw(text, at: CGPoint(x: size.width - 52, y: 16), anchor: .center)
        }
    }
}
