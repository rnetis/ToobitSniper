//  ToobitAPI.swift
//  ToobitSniper — REST client (live-verified spec, docs/STRATEGY_SPEC §5)
//
//  Base https://api.toobit.com. Alert-only build: no signed endpoints are called;
//  the signing helper exists for future optional modules and matches the documented
//  HMAC-SHA256-over-(queryString+body, no separator) scheme with X-BB-APIKEY header.

import Foundation
import CryptoKit

enum ToobitError: LocalizedError {
    case badURL
    case http(Int, String)
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .badURL: return "Bad URL"
        case .http(let code, let body): return "HTTP \(code): \(body.prefix(200))"
        case .decode(let msg): return "Decode error: \(msg)"
        }
    }
}

/// Tolerant JSON value: Toobit mixes numbers-as-strings and raw numbers.
enum JSONValue: Codable, Equatable {
    case number(Double)
    case string(String)
    case other

    var double: Double? {
        switch self {
        case .number(let d): return d
        case .string(let s): return Double(s)
        case .other: return nil
        }
    }

    var int64: Int64? {
        switch self {
        case .number(let d): return Int64(d)
        case .string(let s): return Int64(s)
        case .other: return nil
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let d = try? container.decode(Double.self) {
            self = .number(d)
        } else {
            self = .other
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let d): try container.encode(d)
        case .string(let s): try container.encode(s)
        case .other: try container.encodeNil()
        }
    }
}

struct KlineRow {
    let openTime: Int64
    let open: Double
    let high: Double
    let low: Double
    let close: Double
    let volume: Double
    let takerBuyVolume: Double
}

struct ContractInfo {
    let symbol: String
    let tickSize: Double
    let stepSize: Double
    let status: String
}

final class ToobitAPI {

    static let shared = ToobitAPI()
    private let base = "https://api.toobit.com"
    private let session: URLSession

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: cfg)
    }

    // MARK: - Market data (public, weight 1 each; 3000 weight/min budget)

    /// GET /quote/v1/klines — array-of-arrays: [openTime, o, h, l, c, v, _, qv, trades, takerBuyBase, takerBuyQuote]
    func klines(symbol: String, interval: String, limit: Int = 500) async throws -> [Candle] {
        let url = URL(string: "\(base)/quote/v1/klines?symbol=\(symbol)&interval=\(interval)&limit=\(limit)")!
        let (data, resp) = try await session.data(from: url)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw ToobitError.http((resp as? HTTPURLResponse)?.statusCode ?? -1, String(data: data, encoding: .utf8) ?? "")
        }
        let rows = try JSONDecoder().decode([[JSONValue]].self, from: data)
        return rows.compactMap { r -> Candle? in
            guard r.count >= 10,
                  let t = r[0].int64,
                  let o = r[1].double, let h = r[2].double, let l = r[3].double, let c = r[4].double,
                  let v = r[5].double,
                  let tb = r[9].double else { return nil }
            return Candle(openTime: t, open: o, high: h, low: l, close: c, volume: v, takerBuyVolume: tb)
        }
    }

    /// GET /quote/v1/contract/ticker/24hr — {t,a,b,s,c,o,h,l,v,qv,pc,pcp} (tolerant string/number)
    func ticker24h(symbol: String) async throws -> TickerSnapshot {
        let url = URL(string: "\(base)/quote/v1/contract/ticker/24hr?symbol=\(symbol)")!
        let (data, resp) = try await session.data(from: url)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw ToobitError.http((resp as? HTTPURLResponse)?.statusCode ?? -1, String(data: data, encoding: .utf8) ?? "")
        }
        struct RawTicker: Decodable {
            let s: JSONValue?
            let c: JSONValue?
            let o: JSONValue?
            let h: JSONValue?
            let l: JSONValue?
            let pcp: JSONValue?
        }
        // The endpoint returns an array of ticker objects; tolerate a bare object too.
        var snap = TickerSnapshot()
        let decoder = JSONDecoder()
        if let rows = try? decoder.decode([RawTicker].self, from: data), let row = rows.first {
            snap.lastPrice = row.c?.double ?? 0
            snap.changePct = row.pcp?.double ?? 0
        } else if let row = try? decoder.decode(RawTicker.self, from: data) {
            snap.lastPrice = row.c?.double ?? 0
            snap.changePct = row.pcp?.double ?? 0
        }
        if snap.lastPrice == 0 { throw ToobitError.decode("24hr ticker empty for \(symbol)") }
        return snap
    }

    /// GET /quote/v1/depth — {"t", "b": [[p,q]], "a": [[p,q]]}
    func depth(symbol: String, limit: Int = 100) async throws -> DepthSnapshot {
        let url = URL(string: "\(base)/quote/v1/depth?symbol=\(symbol)&limit=\(limit)")!
        let (data, resp) = try await session.data(from: url)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw ToobitError.http((resp as? HTTPURLResponse)?.statusCode ?? -1, String(data: data, encoding: .utf8) ?? "")
        }
        return try Self.decodeDepth(data)
    }

    static func decodeDepth(_ data: Data) throws -> DepthSnapshot {
        struct RawDepth: Decodable {
            let t: JSONValue
            let b: [[JSONValue]]
            let a: [[JSONValue]]
        }
        let raw = try JSONDecoder().decode(RawDepth.self, from: data)
        let bids = raw.b.compactMap { pair -> PriceLevel? in
            guard pair.count >= 2, let p = pair[0].double, let q = pair[1].double else { return nil }
            return PriceLevel(price: p, qty: q)
        }
        let asks = raw.a.compactMap { pair -> PriceLevel? in
            guard pair.count >= 2, let p = pair[0].double, let q = pair[1].double else { return nil }
            return PriceLevel(price: p, qty: q)
        }
        return DepthSnapshot(time: raw.t.int64 ?? 0, bids: bids, asks: asks)
    }

    /// GET /quote/v1/trades — [{"p","q","t","ibm"}] (max 60)
    func trades(symbol: String, limit: Int = 60) async throws -> [TradeTick] {
        let url = URL(string: "\(base)/quote/v1/trades?symbol=\(symbol)&limit=\(limit)")!
        let (data, resp) = try await session.data(from: url)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw ToobitError.http((resp as? HTTPURLResponse)?.statusCode ?? -1, String(data: data, encoding: .utf8) ?? "")
        }
        struct RawTrade: Decodable {
            let p: JSONValue
            let q: JSONValue
            let t: JSONValue
            let ibm: Bool?
        }
        let rows = try JSONDecoder().decode([RawTrade].self, from: data)
        return rows.enumerated().compactMap { idx, r -> TradeTick? in
            guard let p = r.p.double, let q = r.q.double, let t = r.t.int64 else { return nil }
            return TradeTick(id: Int64(idx) + t, time: t, price: p, qty: q, buyerIsMaker: r.ibm ?? false)
        }
    }

    /// GET /api/v1/futures/fundingRate
    func fundingRate(symbol: String) async throws -> Double {
        let url = URL(string: "\(base)/api/v1/futures/fundingRate?symbol=\(symbol)")!
        let (data, resp) = try await session.data(from: url)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw ToobitError.http((resp as? HTTPURLResponse)?.statusCode ?? -1, String(data: data, encoding: .utf8) ?? "")
        }
        struct RawFunding: Decodable {
            let rate: JSONValue
        }
        let rows = try JSONDecoder().decode([RawFunding].self, from: data)
        return rows.first?.rate.double ?? 0
    }

    /// GET /quote/v1/openInterest
    func openInterest(symbol: String) async throws -> Double {
        let url = URL(string: "\(base)/quote/v1/openInterest?symbol=\(symbol)")!
        let (data, resp) = try await session.data(from: url)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw ToobitError.http((resp as? HTTPURLResponse)?.statusCode ?? -1, String(data: data, encoding: .utf8) ?? "")
        }
        struct RawOI: Decodable {
            let openInterestList: [RawEntry]
            struct RawEntry: Decodable { let size: JSONValue; let symbol: String }
        }
        let raw = try JSONDecoder().decode(RawOI.self, from: data)
        return raw.openInterestList.first?.size.double ?? 0
    }

    /// GET /api/v1/exchangeInfo — contracts array with PRICE_FILTER.tickSize and LOT_SIZE.stepSize
    func exchangeInfo() async throws -> [ContractInfo] {
        let url = URL(string: "\(base)/api/v1/exchangeInfo")!
        let (data, resp) = try await session.data(from: url)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw ToobitError.http((resp as? HTTPURLResponse)?.statusCode ?? -1, String(data: data, encoding: .utf8) ?? "")
        }
        struct RawInfo: Decodable {
            struct RawFilter: Decodable {
                let filterType: String
                let tickSize: JSONValue?
                let stepSize: JSONValue?
            }
            struct RawContract: Decodable {
                let symbol: String
                let status: String
                let filters: [RawFilter]
            }
            let contracts: [RawContract]
        }
        let raw = try JSONDecoder().decode(RawInfo.self, from: data)
        return raw.contracts.map { c in
            let tick = c.filters.first { $0.filterType == "PRICE_FILTER" }?.tickSize?.double ?? 0.01
            let step = c.filters.first { $0.filterType == "LOT_SIZE" }?.stepSize?.double ?? 0.001
            return ContractInfo(symbol: c.symbol, tickSize: tick, stepSize: step, status: c.status)
        }
    }

    // MARK: - Signature helper (unused in alert-only build; documented for optional modules)

    /// HMAC-SHA256 lowercase hex over queryString + requestBody concatenated with NO separator,
    /// appended as &signature=…; key sent in X-BB-APIKEY header [Toobit docs].
    static func sign(params: String, secret: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(params.utf8), using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }
}
