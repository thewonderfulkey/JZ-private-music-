import Foundation
import WebKit

// MARK: - 网易 afp 指纹引擎（WKWebView 承载 wasm）
//
// 网易 `audio/match` 不要 key，但只认自家 afp 指纹（把别的算法指纹提交上去会被判 noMatchReason=10），
// 而算法在 `afp.wasm` 里。Android 用 WebView + `recognizer.html` 承载，iOS 这里换成 WKWebView：
//
//   · 资源：Bundle 根下的 recognizer.html / afp_wasm_b64.js / sandbox.bundle.js
//     （从 android/app/src/main/assets 原样拷来，由 tools/ios/add_pbx_resources.py 登记进 Resources）
//   · 桥：页面调 `window.AndroidBridge.onResult(kind, payload)`，我们用 WKUserScript 注入一个同名对象，
//     转发到 `window.webkit.messageHandlers.bridge`
//   · 取指纹：`evaluateJavaScript("window.__encode('<8k Float32 base64>')")` → 桥回调 'ok'
//
// 为什么必须在视图层级里：WKWebView 不挂在窗口上时不保证执行 JS（尤其是 wasm 编译），
// 所以识曲页用一个 1×1 的宿主视图把它挂起来。
@MainActor
final class NeteaseFingerprint {

    static let shared = NeteaseFingerprint()

    enum State: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var lastError = ""

    private var webView: WKWebView?
    private var encodeResult: (ok: Bool, payload: String)?

    private init() {}

    // MARK: 宿主

    /// 由识曲页的宿主视图调用一次（重复调用返回同一个 WKWebView）
    func hostWebView() -> WKWebView {
        if let webView { return webView }

        let controller = WKUserContentController()
        let bridge = Bridge()
        bridge.owner = self
        controller.add(bridge, name: "bridge")
        controller.addUserScript(WKUserScript(source: Self.shim, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true))

        let config = WKWebViewConfiguration()
        config.userContentController = controller
        config.allowsInlineMediaPlayback = true

        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: config)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.isUserInteractionEnabled = false
        webView = web
        load()
        return web
    }

    private func load() {
        guard let url = Bundle.main.url(forResource: "recognizer", withExtension: "html") else {
            state = .failed("指纹页面没打进包（recognizer.html 缺失）")
            return
        }
        state = .loading
        webView?.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    // MARK: 就绪

    func waitReady(timeout: TimeInterval = 6) async -> Bool {
        _ = hostWebView()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            switch state {
            case .ready: return true
            case .failed: return false
            default: break
            }
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        return state == .ready
    }

    var isReady: Bool { state == .ready }

    // MARK: 取指纹

    /// 8k Int16 PCM → 指纹字符串。引擎没就绪 / 超时 / 出错一律返回 nil（调用方跳过网易通道）。
    func encode(pcm16: Data) async -> String? {
        guard await waitReady() else { return nil }
        guard let base64 = FingerprintPCM.float32Base64(pcm16: pcm16) else { return nil }

        encodeResult = nil
        let js = "window.__encode('\(base64)')"
        _ = try? await webView?.evaluateJavaScript(js)

        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if let result = encodeResult {
                encodeResult = nil
                guard result.ok, !result.payload.isEmpty else {
                    lastError = result.payload
                    return nil
                }
                return result.payload
            }
            try? await Task.sleep(nanoseconds: 60_000_000)
        }
        lastError = "指纹引擎超时"
        return nil
    }

    // MARK: 桥

    /// 页面里的 `AndroidBridge.onResult(kind, payload)` 由这段脚本转发到原生
    private static let shim = """
    window.AndroidBridge = {
      onResult: function (kind, payload) {
        try {
          window.webkit.messageHandlers.bridge.postMessage({
            kind: String(kind),
            payload: String(payload)
          });
        } catch (e) { /* 页面销毁后回调失败，忽略 */ }
      }
    };
    """

    fileprivate func handle(kind: String, payload: String) {
        switch kind {
        case "ready":
            state = payload == "1" ? .ready : .failed("指纹引擎加载失败")
        case "ok":
            encodeResult = (true, payload)
        case "error":
            lastError = payload
            encodeResult = (false, payload)
        default:
            break
        }
    }

    /// 桥接（弱引用，避免 WKUserContentController 把单例钉死）
    private final class Bridge: NSObject, WKScriptMessageHandler {
        weak var owner: NeteaseFingerprint?

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let kind = body["kind"] as? String,
                  let payload = body["payload"] as? String else { return }
            Task { @MainActor [weak owner] in
                owner?.handle(kind: kind, payload: payload)
            }
        }
    }
}
