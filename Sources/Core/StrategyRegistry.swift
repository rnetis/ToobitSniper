//  StrategyRegistry.swift
//  ToobitSniper — strategy definitions & per-book base scores (STRATEGY_SPEC §3)

import Foundation

enum StrategyRegistry {

    // Wyckoff family
    static let springDef = StrategyDef(id: "S1", name: "Wyckoff Spring", baseScore: 45,
        book: "The Wyckoff Methodology in Depth (Villahermosa)", family: .wyckoff)
    static let utadDef = StrategyDef(id: "S2", name: "Wyckoff UTAD", baseScore: 45,
        book: "The Wyckoff Methodology in Depth (Villahermosa)", family: .wyckoff)
    static let sosBarDef = StrategyDef(id: "S3a", name: "SOS Bar", baseScore: 40,
        book: "The Wyckoff Methodology in Depth (Villahermosa)", family: .wyckoff)
    static let sowBarDef = StrategyDef(id: "S3b", name: "SOW Bar", baseScore: 40,
        book: "The Wyckoff Methodology in Depth (Villahermosa)", family: .wyckoff)
    static let testNoSupplyDef = StrategyDef(id: "S4a", name: "Test / No Supply", baseScore: 34,
        book: "The Wyckoff Methodology in Depth (Villahermosa)", family: .wyckoff)
    static let testNoDemandDef = StrategyDef(id: "S4b", name: "Test / No Demand", baseScore: 34,
        book: "The Wyckoff Methodology in Depth (Villahermosa)", family: .wyckoff)

    // Supply/Demand family [Lebin]
    static let demandZoneDef = StrategyDef(id: "S5", name: "Lebin Demand Zone", baseScore: 40,
        book: "Trade Like Pro: Supply & Demand (Lebin)", family: .supplyDemand)
    static let supplyZoneDef = StrategyDef(id: "S6", name: "Lebin Supply Zone", baseScore: 40,
        book: "Trade Like Pro: Supply & Demand (Lebin)", family: .supplyDemand)

    // Order-flow family [Dale]
    static let stackedImbalanceDef = StrategyDef(id: "S7", name: "Dale Stacked Imbalance", baseScore: 40,
        book: "Order Flow Trading Setups (Trader Dale)", family: .orderFlow)
    static let absorptionDef = StrategyDef(id: "S8", name: "Dale Absorption", baseScore: 36,
        book: "Order Flow Trading Setups (Trader Dale)", family: .orderFlow)
    static let deltaDivDef = StrategyDef(id: "S9", name: "Delta Divergence", baseScore: 36,
        book: "Order Flow Trading Setups (Trader Dale)", family: .orderFlow)
    static let volumeClusterDef = StrategyDef(id: "S10", name: "Volume Cluster Retest", baseScore: 38,
        book: "Order Flow Trading Setups (Trader Dale)", family: .orderFlow)

    // Momentum/MTF family [Miner, Bryan Lee]
    static let minerMTFDef = StrategyDef(id: "S11", name: "Miner MTF Momentum", baseScore: 35,
        book: "High Probability Trading Strategies (Miner)", family: .momentum)
    static let fibZoneDef = StrategyDef(id: "S12", name: "Fib Zone Reversal", baseScore: 32,
        book: "High Probability Trading Strategies (Miner)", family: .momentum)
    static let maCrossDef = StrategyDef(id: "S17", name: "MA Crossover Regime", baseScore: 30,
        book: "How to Day Trade for a Living (Bryan Lee)", family: .momentum)
    static let rsiExtremeDef = StrategyDef(id: "S18", name: "RSI Extreme Fade", baseScore: 22,
        book: "How to Day Trade for a Living (Bryan Lee)", family: .momentum)

    // Price-action family [Shantharaj]
    static let trendlinePullbackDef = StrategyDef(id: "S13", name: "Trendline Pullback", baseScore: 32,
        book: "Price Action Trading (Shantharaj)", family: .priceAction)
    static let rejectionDef = StrategyDef(id: "S14a", name: "Price Rejection", baseScore: 32,
        book: "Price Action Trading (Shantharaj)", family: .priceAction)
    static let acceptanceDef = StrategyDef(id: "S14b", name: "Price Acceptance", baseScore: 32,
        book: "Price Action Trading (Shantharaj)", family: .priceAction)

    // Scalping family [Forexop]
    static let trendScalperDef = StrategyDef(id: "S15", name: "Trend Scalper", baseScore: 28,
        book: "Scalping Strategies Revealed (Forexop)", family: .scalping)
    static let bbRetraceDef = StrategyDef(id: "S16", name: "BB Retrace Scalp", baseScore: 25,
        book: "Scalping Strategies Revealed (Forexop)", family: .scalping)

    // Renko [user mandate + DTB dull-market logic]
    static let renkoFlipDef = StrategyDef(id: "S19", name: "Renko Flip", baseScore: 30,
        book: "Renko overlay (DTB dull-market logic)", family: .renko)

    static var all: [StrategyDef] {
        [springDef, utadDef, sosBarDef, sowBarDef, testNoSupplyDef, testNoDemandDef,
         demandZoneDef, supplyZoneDef, stackedImbalanceDef, absorptionDef, deltaDivDef,
         volumeClusterDef, minerMTFDef, fibZoneDef, maCrossDef, rsiExtremeDef,
         trendlinePullbackDef, rejectionDef, acceptanceDef, trendScalperDef, bbRetraceDef,
         renkoFlipDef]
    }
}
