//  ToobitSniperApp.swift
//  ToobitSniper — entry point & root tab navigation
//
//  ALERTS ONLY: this app never places orders. It watches Toobit USDT-M futures,
//  scores 19 book-derived setups with a 10-factor confluence engine, overlays
//  ATR-Renko trend state, enforces ultra-safe risk rails, and pushes alerts.

import SwiftUI

@main
struct ToobitSniperApp: App {
    @StateObject private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(store.governor)
                .preferredColorScheme(.dark)
                .onAppear {
                    store.requestNotificationPermission()
                    store.start()
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        TabView {
            DashboardView()
                .tabItem { Label("Market", systemImage: "chart.bar.fill") }
            ChartScreen()
                .tabItem { Label("Chart", systemImage: "candlestick.chart") }
            SignalsView()
                .tabItem { Label("Signals", systemImage: "bolt.fill") }
            RiskView()
                .tabItem { Label("Risk", systemImage: "shield.lefthalf.filled") }
            SettingsView()
                .tabItem { Label("Setup", systemImage: "gearshape.fill") }
        }
        .tint(.accentCyan)
    }
}
