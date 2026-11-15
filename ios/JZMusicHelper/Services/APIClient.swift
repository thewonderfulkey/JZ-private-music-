import Foundation

// MARK: - 网络客户端
/// 统一 HTTP GET 客户端：带浏览器 UA/Referer、超时控制、JSON 解析。
final class APIClient {

    static let shared = APIClient()

    /// 移动端浏览器 UA（部分源需要，如酷我系防盗链）
    static let mobileUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1"
    static let desktopUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"

    private init() {}

    // MARK: 请求

    /// GET 请求，返回 Data。
    /// - Parameters:
    ///   - urlString: 完整 URL（含查询参数）
    ///   - headers: 附加请求头
    ///   - timeout: 超时秒数
    ///   - allowTextPlain: 允许 text/plain 响应（酷我旧搜索返回该类型）
    func getData(_ urlString: String,
                 headers: [String: String] = [:],
                 timeout: TimeInterval = 15,
                 allowTextPlain: Bool = false) async throws -> Data {
        guard let url = URL(string: urlString) else {
            throw APIError.invalidURL(urlString)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.httpMethod = "GET"
        request.setValue(APIClient.mobileUA, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, text/javascript, */*; q=0.01", forHTTPHeaderField: "Accept")
        request.setValue("https://music.qq.com/", forHTTPHeaderField: "Referer")
        for (k, v) in headers {
            request.setValue(v, forHTTPHeaderField: k)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.httpStatus(http.statusCode)
        }
        return data
    }

    /// GET 请求，尝试解析为 JSON（[String: Any]）。
    func getJSON(_ urlString: String,
                 headers: [String: String] = [:],
                 timeout: TimeInterval = 15) async throws -> [String: Any] {
        let data = try await getData(urlString, headers: headers, timeout: timeout)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.notJSON
        }
        return obj
    }

    /// GET 请求，尝试解析为 JSON 数组。
    func getJSONArray(_ urlString: String,
                      headers: [String: String] = [:],
                      timeout: TimeInterval = 15) async throws -> [Any] {
        let data = try await getData(urlString, headers: headers, timeout: timeout)
        guard let arr = try JSONSerialization.jsonObject(with: data) as? [Any] else {
            throw APIError.notJSON
        }
        return arr
    }
}

// MARK: - 错误
enum APIError: LocalizedError {
    case invalidURL(String)
    case invalidResponse
    case httpStatus(Int)
    case notJSON
    case parse(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let u): return "无效 URL: \(u)"
        case .invalidResponse: return "无效响应"
        case .httpStatus(let c): return "HTTP \(c)"
        case .notJSON: return "响应不是 JSON"
        case .parse(let m): return "解析失败: \(m)"
        }
    }
}

// MARK: - JSON 取值小工具
extension Dictionary where Key == String {
    /// 从嵌套字典链中取值：keys 依次下钻，缺任一层返回 nil。
    func nested(_ keys: [String]) -> Any? {
        var current: Any? = self
        for k in keys {
            if let d = current as? [String: Any], let v = d[k] {
                current = v
            } else if let d = current as? [AnyHashable: Any], let v = d[k] {
                current = v
            } else {
                return nil
            }
        }
        return current
    }

    func string(_ keys: [String]) -> String? {
        guard let v = nested(keys) else { return nil }
        return "\(v)"
    }

    func double(_ keys: [String]) -> Double? {
        guard let v = nested(keys) else { return nil }
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String { return Double(s) }
        return nil
    }
}
