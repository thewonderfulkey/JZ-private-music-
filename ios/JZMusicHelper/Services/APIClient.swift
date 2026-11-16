import Foundation

// MARK: - 统一 HTTP 客户端
//
// 与 Android `ApiClient.kt` 同口径：移动 UA + 默认 Referer + Accept，每类调用可覆盖超时。
// Android 用 OkHttp 的 hostnameVerifier 给 `mobilecdn.kugou.com` 开过一个洞（该域名证书不匹配）；
// iOS 这边**不开 ATS 例外**——酷狗搜索已改用 `mobiles.kugou.com`（证书正常），
// 所以这个洞不需要带过来（见 docs/ios/IOS-NETWORK.md §3.3）。
final class APIClient {

    static let shared = APIClient()

    /// 移动端浏览器 UA（多个源会校验，如酷我防盗链）
    static let mobileUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1"

    static let acceptJSON = "application/json, text/javascript, */*; q=0.01"

    private let session: URLSession

    private init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: cfg)
    }

    // MARK: 请求

    /// GET 原始文本（内部做 UA / Accept / Referer 补全）
    func getString(_ urlString: String,
                   headers: [String: String] = [:],
                   timeout: TimeInterval = 15) async throws -> String {
        let data = try await getData(urlString, headers: headers, timeout: timeout)
        // 所有接口都带 encoding=utf8（酷我 r.s 亦然），UTF-8 失败时按 Latin1 兜底以便看清乱码而不是拿空串
        if let s = String(data: data, encoding: .utf8) { return s }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    /// GET 原始字节
    func getData(_ urlString: String,
                 headers: [String: String] = [:],
                 timeout: TimeInterval = 15) async throws -> Data {
        guard let url = URL(string: urlString) else {
            throw APIError.invalidURL(urlString)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.httpMethod = "GET"
        request.setValue(APIClient.mobileUA, forHTTPHeaderField: "User-Agent")
        request.setValue(APIClient.acceptJSON, forHTTPHeaderField: "Accept")
        request.setValue("https://music.qq.com/", forHTTPHeaderField: "Referer")
        for (k, v) in headers {
            request.setValue(v, forHTTPHeaderField: k)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.httpStatus(http.statusCode)
        }
        return data
    }

    /// GET → JSON 对象
    func getJSON(_ urlString: String,
                 headers: [String: String] = [:],
                 timeout: TimeInterval = 15) async throws -> [String: Any] {
        let text = try await getString(urlString, headers: headers, timeout: timeout)
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.notJSON
        }
        return obj
    }

    /// GET → JSON 数组
    func getJSONArray(_ urlString: String,
                      headers: [String: String] = [:],
                      timeout: TimeInterval = 15) async throws -> [Any] {
        let text = try await getString(urlString, headers: headers, timeout: timeout)
        guard let data = text.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            throw APIError.notJSON
        }
        return arr
    }

    // MARK: 编码

    /// 与 Android `urlEncode` 等价：百分号编码，空格 → %20（不用 `+`）
    /// 只保留 ASCII 字母数字与 `-._~`，中文/全角一律编码（CharacterSet.alphanumerics 会把汉字当字母放过，不能用）
    static func encode(_ s: String) -> String {
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}

// MARK: - 错误

enum APIError: LocalizedError, Equatable {
    case invalidURL(String)
    case invalidResponse
    case httpStatus(Int)
    case notJSON
    case parse(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .invalidURL(let u): return "无效 URL: \(u)"
        case .invalidResponse: return "无效响应"
        case .httpStatus(let c): return "HTTP \(c)"
        case .notJSON: return "响应不是 JSON"
        case .parse(let m): return "解析失败: \(m)"
        case .timeout: return "超时"
        }
    }
}

// MARK: - 超时包装

/// 与 Kotlin `withTimeoutOrNull` 等价：到点返回 nil（不抛错），底层任务被取消。
func withTimeoutOrNil<T: Sendable>(_ seconds: TimeInterval,
                                   _ op: @escaping @Sendable () async throws -> T) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask {
            do { return try await op() } catch { return nil }
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

// MARK: - JSON 取值小工具

extension Dictionary where Key == String {
    /// 从嵌套字典链中取值：keys 依次下钻，缺任一层返回 nil
    func nested(_ keys: [String]) -> Any? {
        var current: Any? = self
        for k in keys {
            guard let dict = current as? [String: Any], let v = dict[k] else { return nil }
            current = v
        }
        return current
    }

    func string(_ keys: [String]) -> String? {
        guard let v = nested(keys) else { return nil }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    func int(_ keys: [String]) -> Int? {
        guard let v = nested(keys) else { return nil }
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        if let s = v as? String { return Int(s) }
        return nil
    }

    func double(_ keys: [String]) -> Double? {
        guard let v = nested(keys) else { return nil }
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String { return Double(s) }
        return nil
    }
}
