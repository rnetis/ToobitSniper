# ToobitSniper — Day-Trading & Scalping Signal Engine for Toobit USDT-M Futures (iOS)

> 19 strategies distilled from 8 trading books · 10-factor confluence scoring · ATR-Renko overlay ·
> Toobit live market data · ultra-safe risk rails · **alerts only — never places orders**.

## What this is

A SwiftUI iOS app (dark terminal UI) that watches Toobit USDT-M perpetual futures, evaluates
**19 book-derived strategies** on every closed candle across **1m / 5m / 15m / 1h**, scores each
setup with a **10-factor confluence engine** (multi-timeframe momentum, Renko trend agreement,
volume harmony, zone confluence, order-flow confirmation, R:R, freshness, spread budget…),
enforces **ultra-safe risk rails** (1%/trade, 5% daily lockout, 10% monthly stop, half size after
3 losses), and pushes **local notifications** with entry/stop/target levels.

Everything numeric traces to the source books — see `docs/STRATEGY_SPEC.md` for the full mapping
and the PDF playbook for the human-readable version with citations.

## Strategy suite (v1)

| Family | Strategies | Source |
|---|---|---|
| Wyckoff | Spring · UTAD · SOS/SOW bar · Test (No Demand/No Supply) | Villahermosa *The Wyckoff Methodology in Depth* |
| Supply/Demand | DBR/RBR demand zones · RBD/DBD supply zones (fresh-only, 1–6 candle bases) | Lebin *Trade Like Pro* |
| Order Flow | Stacked imbalances ≥300% · Absorption · Delta divergence · Volume-cluster retest | Trader Dale *Order Flow Trading Setups* |
| Momentum/MTF | Miner dual-TF momentum + Tr-1BH/L · Fib confluence zones · EMA50×200 regime · RSI extreme fade | Miner *High Probability Trading Strategies* · Bryan Lee |
| Price Action | Trendline pullback (<45°, 3+ touches) · Rejection · Acceptance | Shantharaj *Price Action Trading* |
| Scalping | Trend scalper (MA gradient) · BB(20,2) retrace scalp | Forexop *Scalping Strategies Revealed* |
| Renko | ATR-Renko flip rider (2–3 brick targets) | Renko overlay + Wyckoff 1919 dull-market logic |

## Architecture

```
Sources/
├── Core/
│   ├── Models.swift            # Candle, zones, signals, scoring types
│   ├── Indicators.swift        # SMA/EMA/RSI/Stoch/ATR/BB/MACD + swings/structure
│   ├── RenkoEngine.swift       # classic 2×-reversal ATR bricks
│   ├── ZoneEngine.swift        # Lebin S&D zones (geometry, quality, freshness)
│   ├── FibEngine.swift         # Miner In-Ret/APP/Ex-Ret clusters
│   ├── VolumeProfileEngine.swift  # HVN/POC/low-volume pockets
│   ├── OrderFlowEngine.swift   # footprint from trade stream: 300% diagonal imbalances,
│   │                           # absorption, unfinished business, delta divergence
│   ├── WyckoffEngine.swift     # range, Spring/UTAD, significant bars, tests, harmony
│   ├── MomentumEngine.swift    # Miner four-state dual-TF momentum table
│   ├── StrategyRegistry.swift  # 19 strategy definitions + base scores
│   ├── Strategies.swift        # all evaluators
│   ├── ScoringEngine.swift     # C1..C10 confluence scoring + orchestration
│   └── RiskGovernor.swift      # survival rails + position sizer
├── Toobit/
│   ├── ToobitAPI.swift         # REST: klines/depth/trades/funding/OI/exchangeInfo + HMAC helper
│   └── ToobitSocket.swift      # WSS kline/trade/depth/bookTicker + ping-pong keepalive
├── App/
│   ├── ToobitSniperApp.swift   # entry + tabs
│   ├── AppStore.swift          # data pipeline → engine → alerts
│   └── Theme.swift             # dark terminal styling
└── Views/                      # Dashboard, Chart (candles/Renko + overlays), Signals, Risk, Setup
```

## Build the IPA

The repo ships with **XcodeGen** (`project.yml`) and a GitHub Actions workflow
(`.github/workflows/build-ipa.yml`):

1. Push this repo to GitHub (branch `main`).
2. The workflow runs on `macos-15`, generates the Xcode project with XcodeGen, archives with
   `CODE_SIGNING_ALLOWED=NO`, and packages **`ToobitSniper-unsigned.ipa`** as a workflow artifact.
3. Install the unsigned IPA via any of:
   - **TrollStore** (accepts unsigned IPAs directly, iOS 14–16.6.1 / 17.0),
   - **Sideloadly** or **AltStore** (re-signs with a free/regular Apple ID, 7-day free profile),
   - or the optional `sign` job: set repo variable `SIGNING_ENABLED=true` plus secrets
     `BUILD_CERTIFICATE_BASE64`, `P12_PASSWORD`, `PROVISIONING_PROFILE_BASE64`,
     `PROVISIONING_PROFILE_SPECIFIER`, `DEVELOPMENT_TEAM` to get a signed ad-hoc IPA.
4. Local build: `brew install xcodegen && xcodegen generate && open ToobitSniper.xcodeproj`.
5. Before a release, run `./scripts/run-engine-smoke.sh` — it compiles `Sources/Core` with
   `scripts/engine-smoke/main.swift` and pushes seeded synthetic datasets through
   `SignalEngine.evaluate`, so a trap in the signal engine fails the run instead of the app.
   The workflow runs it before archiving.

## Data plane (live-verified)

- REST `https://api.toobit.com` — `/quote/v1/klines` (interval 1m/5m/15m/1h, limit ≤1000),
  `/quote/v1/depth`, `/quote/v1/trades`, `/quote/v1/openInterest`, `/api/v1/futures/fundingRate`,
  `/api/v1/exchangeInfo` (tick/step size per symbol).
- WSS `wss://stream.toobit.com/quote/ws/v1` — topics `kline_1m…1h`, `trade`, `depth`, `bookTicker`;
  heartbeat `{"ping":ms}` every 4 min (server drops after 5 min without it); first kline push
  contains only the live bar, so REST bootstrap always precedes streaming.
- Per-candle delta comes from the kline **taker-buy split** (`2·takerBuy − volume`), so order-flow
  features (cumulative delta, delta divergence) work without any private API. Footprint features
  (diagonal imbalances, absorption, unfinished business) approximate Dale's footprint logic from
  the live trade stream bucketed by tick-size price levels.

## Risk rails (ultra-safe, "survival solution")

1% risk/trade · 3% max open risk · 5% daily loss → lockout · 10% monthly → stop ·
2 concurrent positions · ≤3 alerts/symbol/day · half size after 3 straight losses ·
sizer `(equity × 1%) / (entry − stop)` · spread ≤10% of target distance.

## Legal

Educational software. Signals are algorithmic alerts from published trading literature —
not financial advice. Crypto futures are high-risk; the ultra-safe rails exist because most
day traders lose money. No order execution is implemented: the app cannot touch your funds.

## Signed endpoint note

The alert-only build never signs requests. `ToobitAPI.sign(params:secret:)` implements the
documented Toobit HMAC-SHA256 scheme (`X-BB-APIKEY` header, lowercase hex over
`queryString + requestBody` with no separator) for any future opt-in module — paste your own
keys only if you choose to extend it.
