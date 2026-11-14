# TOOBIT SNIPER — Unified Strategy Specification v1.0

> Every rule below is derived from the 8 source books (see citations). Numeric constants
> are the books' own values unless marked `[ADAPT]` (crypto-adapted, original formula preserved).
> This document is the contract between the books, the Swift signal engine, and the PDF playbook.

## 1. Mission profile

- **Market**: Toobit USDT-M perpetual futures (`BTC-SWAP-USDT`, `ETH-SWAP-USDT`, `SOL-SWAP-USDT`, …).
- **Style**: intraday day trading + scalping. Multi-timeframe ladder = **1h / 15m / 5m / 1m**.
  (Lebin day-trading ladder 1h/15m/5m `[Lebin]`; scalping ladder 15m/5m/1m `[Lebin]`.)
- **Renko overlay**: ATR-based Renko bricks on 1h data act as the *survival filter* — a signal
  that fights the current Renko trend is demoted, a signal that agrees with it is promoted.
  Renko removes intrabar noise (Wyckoff's "rut"/dull-market logic, `[DTB]` ch. on dull markets).
- **Mode**: ALERTS ONLY. No order execution is shipped in v1. Entry/stop/target levels are displayed
  and pushed as notifications.
- **Signal strictness (user-selected)**: AGGRESSIVE — score threshold **55/100**, ~10+ alerts/day
  across the watchlist. Confluence breakdown is shown for every signal so the trader can
  hand-filter up to "perfect".

## 2. Signal scoring engine

Every strategy evaluator emits a `SignalCandidate` with a **base score** (strategy robustness,
from how rule-complete the book's system is) plus **confluence bonuses**:

| Confluence | Max pts | Source rule |
|---|---:|---|
| C1 Multi-TF momentum alignment | +15 | Miner dual-time-frame momentum state machine (60m bull/bear + 15m reversal) `[Miner ch.2]` |
| C2 Renko trend agreement | +12 | Renko trend (≥2 same-color bricks) agrees with signal direction `[ADAPT — user mandate]` |
| C3 Volume harmony (effort vs result) | +10 | Impulse volume rising, pullback volume falling; climax warning `[Wyckoff Methodology — Law 2]` |
| C4 Zone confluence (fib/S&D/VP overlap) | +12 | Miner APP/In-Ret/Ex-Ret clusters; Lebin overlap rule; VP HVN `[Miner ch.4, Lebin, Dale]` |
| C5 Order-flow confirmation | +12 | Dale: delta divergence, absorption, stacked imbalance ≥300%, big-limit print `[Dale]` |
| C6 Candle trigger quality | +8 | Shantharaj confirmation-candle entries; Miner Tr-1BH/L & Swing Entry `[Shantharaj, Miner ch.6]` |
| C7 Risk-reward ≥2:1 (3:1 → full) | +8 | Lebin 3:1 filter (2:1 tolerated) `[Lebin]` |
| C8 Fresh level (first touch) | +4 | Lebin freshness: fresh only; 2+ touches = dead `[Lebin]` |
| C9 HTF trend agreement | +3 | Wyckoff "trade only in favor of the larger structure" `[Wyckoff Methodology]` |
| C10 Liquidity/spread pass | +5 | Forexop spread rule: spread ≤10% of target `[Forexop]` |

Base scores: Wyckoff Spring/UTAD 45 · SOS/SOW bar 40 · Lebin fresh zone 40 · Dale stacked imbalance
40 · volume-cluster retest 38 · absorption/delta-divergence 36 · Miner MTF+trigger 35 · trendline
pullback 32 · rejection/acceptance 32 · Renko flip 30 · trend scalper 28 · BB retrace 25 · MA cross 30 ·
RSI extreme 22. Cap 100, threshold per mode (Aggressive=55, Balanced=70, Conservative=85).

Signal lifecycle: emit → dedup (per symbol+strategy+direction, 15-min cooldown) → risk-governor
check → alert. Max 12 live signals, 6h retention.

## 3. Strategy suite (v1, full stack)

| # | Strategy | Trigger summary | Stop | Target | Book |
|---|---|---|---|---|---|
| S1 | **Wyckoff Spring** | Trading range + close below range low on falling volume + close back inside | below Spring low | range opposite end / measured | Wyckoff Methodology |
| S2 | **Wyckoff UTAD** | Close above range high + rejection back inside (distribution) | above UTAD high | range opposite end | Wyckoff Methodology |
| S3 | **SOS / SOW bar** | Wide-range bar, volume > avg, close in direction half, close beyond prior swing | other side of bar & structure | 1:1 structure projection | Wyckoff Methodology |
| S4 | **Test (No Demand/No Supply)** | Narrow candle, volume < both 2 prior candles, at key level in Wyckoff context | beyond shake extreme | Creek route | Wyckoff Methodology |
| S5 | **Lebin Demand zone** | DBR/RBR base (1–6 candles, no doji), fresh, limit at zone top | zone bottom | opposing supply zone | Lebin |
| S6 | **Lebin Supply zone** | RBD/DBD base mirrored | zone top | opposing demand zone | Lebin |
| S7 | **Dale Stacked Imbalance** | ≥3 diagonal imbalances ≥300% stacked, price pulled back 1st time | beyond zone | next heavy-volume area | Trader Dale |
| S8 | **Dale Absorption** | Both-side volume ≥3× average at zone, price stalls | behind zone | volume-based TP | Trader Dale |
| S9 | **Delta divergence** | Price makes new high/low while cumulative delta diverges at zone | beyond zone extreme | pre-HVN exit | Trader Dale |
| S10 | **Volume-cluster retest** | Heavy-volume node left behind by ≥2 full candles, pullback into it | behind cluster | next heavy-volume area | Trader Dale |
| S11 | **Miner MTF momentum** | 1h momentum state allows, 15m reversal below OB/above OS, 5m Tr-1BH/L or swing-break | 1 bar beyond setup swing | two-unit plan | Miner |
| S12 | **Fib zone reversal** | In-Ret 50/61.8 + APP/Ex-Ret cluster + trigger | beyond zone-voiding swing | APP symmetry targets | Miner ch.4 |
| S13 | **Trendline pullback** | ≥3-touch trendline <45°, confirmation candle at line, RR≥1.5 | below confirmation candle | previous swing high | Shantharaj |
| S14 | **Rejection / Acceptance** | Wick pierces level, closes back inside (rejection) or strong close beyond (acceptance) | beyond rejection candle | 50% at 1:2, trail rest | Shantharaj |
| S15 | **Trend scalper** | EMA(50) 5m gradient >0 + EMA(20) pullback touch, 1m trigger | 1×ATR | 1.4×ATR partial, trail rest `[ADAPT]` | Forexop |
| S16 | **BB retrace scalp** | BB(20,2) 1m band touch + retrace bar | 0.5×bandwidth | 8% of bandwidth `[ADAPT]` | Forexop (Meta scalper) |
| S17 | **MA crossover regime** | 1h EMA50×EMA200 cross + RSI agrees | structure | trend-follow | Bryan Lee |
| S18 | **RSI extreme fade** | 1h RSI <30/>70 + 15m momentum reversal + zone | structure | reversion to mean | Bryan Lee |
| S19 | **Renko flip** | ≥2-brick run reverses with new brick | 1 brick | 2–3 bricks | `[ADAPT — user mandate, DTB dull-market logic]` |

S17/S18 fire as *context/regime* signals with wide stops; S19 exists because the user explicitly
mandated Renko assistance — it is a last-resort momentum trade, capped at small size.

## 4. Risk governor (ultra-safe rails — "survival solution")

| Rail | Value | Source |
|---|---|---|
| Risk per trade | **1.0%** of equity | Wyckoff Methodology ("not exceed 1%"), Lebin 1% |
| Max concurrent positions | **2** | ultra-safe `[ADAPT]` |
| Max open exposure | **3.0%** total risk | Miner 6% cap halved for ultra-safe `[ADAPT]` |
| Daily loss lockout | **5.0%** → no new signals for the day | Shantharaj intraday rule |
| Monthly drawdown stop | **10%** → stop for the month | Miner capital-exposure rule |
| Losing streak | ≥3 losses → engine suggests half size | Lebin |
| Sizing formula | qty = (equity × risk%) / (entry − stop) | Shantharaj formula |
| Trades/day advisory | ≤3 per symbol per day | Shantharaj |

Alerts are suppressed if a rail is violated (state banner explains why).

## 5. Toobit data plane (live-verified spec)

- REST base `https://api.toobit.com`; WS `wss://stream.toobit.com/quote/ws/v1`.
- Klines: `GET /quote/v1/klines?symbol=BTC-SWAP-USDT&interval=1m|5m|15m|1h&limit=1000`
  → `[openTime, o, h, l, c, vol, _, quoteVol, trades, takerBuyBase, takerBuyQuote]`.
  Taker-buy split ⇒ per-candle delta = `2·takerBuy − volume` (aggressor buy − aggressor sell).
- Depth: `GET /quote/v1/depth?symbol=…&limit=100`; Trades: `GET /quote/v1/trades?symbol=…&limit=60`
  (`p,q,t,ibm` — `ibm=true` = buyer maker = **sell aggressor**, Binance-style semantics).
- WS topics: `kline_1m`, `kline_5m`, `kline_15m`, `kline_1h`, `trade`, `depth`, `bookTicker`,
  `markPrice`; sub `{"symbol":"BTC-SWAP-USDT","topic":"kline_1m","event":"sub","params":{"binary":"false"}}`;
  heartbeat `{"ping":<ms>}` → `{"pong":<ms>}` every ≤4 min; first kline push carries only the live bar,
  so REST bootstrap is mandatory.
- Funding: `GET /api/v1/futures/fundingRate`; OI: `GET /quote/v1/openInterest`.
- Footprint approximation `[ADAPT]`: trades stream bucketed by tick-size price levels inside each
  candle gives bid/ask volumes for diagonal imbalance (300% rule), absorption and unfinished-business
  checks — the same logic Dale runs on footprint charts.
- Rate limits: 3000 weight/min, 60 orders/2s (irrelevant in alert-only mode).

## 6. Book citation map

| Short tag | Book |
|---|---|
| `[Miner]` | Robert Miner — *High Probability Trading Strategies* (Wiley) |
| `[Wyckoff Methodology]` | Rubén Villahermosa — *The Wyckoff Methodology in Depth* |
| `[DTB]` | Richard D. Wyckoff — *The Day Traders Bible* (1919) |
| `[Lebin]` | Jode Lebin — *Trade Like Pro: Master Supply & Demand* |
| `[Dale]` | Trader Dale — *Order Flow Trading Setups* |
| `[Shantharaj]` | Indrazith Shantharaj — *Price Action Trading* |
| `[Forexop]` | S. Connell — *Scalping Strategies Revealed* |
| `[Bryan Lee]` | Bryan Lee — *How to Day Trade for a Living* |

Note: the Bryan Lee book on file is the 2019 edition whose concrete content is the MA systems
(2-day mean reversion, 50/200 crossover), RSI counter-trading and turtle-style discipline — no
VWAP/scanner chapters exist in it; those were sourced from the other books instead.
