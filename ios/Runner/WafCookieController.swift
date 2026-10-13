import Flutter
import Foundation
import WebKit

/// 内置网页视图的**原生 Cookie 仓库读取**（iOS）。
///
/// 契约见 Dart 侧 `WafWebViewPage`：方法通道 `lumebox/webview` 的 `allCookies`
/// （返回 `[{name, value, domain, path}]`）。
///
/// ## 为什么必须走原生
///
/// Cloudflare 的 `cf_clearance` 是 **HttpOnly** 的——`document.cookie` 看不见它。
/// 用户在 App 内过完真人校验后，真正能复用的那枚凭证只在 `WKHTTPCookieStore`
/// 里；`webview_flutter` 的 Dart API 只能**写** Cookie、不能枚举，因此这里补一层
/// 只读通道，把整套 Cookie（含 HttpOnly）取回来交给 Dart 存进图源会话。
///
/// 只读、不写、不删：网页视图退出后这些 Cookie 仍留在 WKWebView 的数据仓里，
/// 下次打开网页视图仍是同一个登录态（用户不必反复验证）。
final class WafCookieController: NSObject {
  private let channelName = "lumebox/webview"

  func register(with messenger: FlutterBinaryMessenger) {
    imageNetwork.register(with: messenger)
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "allCookies":
        WafCookieController.allCookies(result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private let imageNetwork = ImageNetworkController()

  /// 枚举默认数据仓里的全部 Cookie；`WKHTTPCookieStore` 是异步回调接口。
  ///
  /// `url` 参数当前只用于日志（不过滤）：跨子域分享的 Cookie（如
  /// `.example.com` 域上的 cf_clearance）必须一起带回去，按 url 过滤会漏掉它们。
  private static func allCookies(result: @escaping FlutterResult) {
    let store = WKWebsiteDataStore.default().httpCookieStore
    store.getAllCookies { cookies in
      let list: [[String: Any]] = cookies.map { cookie in
        [
          "name": cookie.name,
          "value": cookie.value,
          "domain": cookie.domain,
          "path": cookie.path,
          "secure": cookie.isSecure,
          "expires": cookie.expiresDate.map { $0.timeIntervalSince1970 as Any } ?? NSNull(),
        ]
      }
      DispatchQueue.main.async { result(list) }
    }
  }
}

/// Use Apple's TLS and HTTP stack for covers on iOS. No shared login cookies.
private final class ImageNetworkController: NSObject, URLSessionTaskDelegate {
  private lazy var session: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.httpCookieStorage = nil
    config.httpShouldSetCookies = false
    config.urlCache = nil
    config.timeoutIntervalForRequest = 30
    config.timeoutIntervalForResource = 45
    config.httpMaximumConnectionsPerHost = 2
    return URLSession(configuration: config, delegate: self, delegateQueue: nil)
  }()

  func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "lumebox/image_network", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "get" else { result(FlutterMethodNotImplemented); return }
      guard let args = call.arguments as? [String: Any],
            let address = args["url"] as? String, let url = URL(string: address),
            ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
        result(FlutterError(code: "bad_url", message: "Invalid image URL", details: nil)); return
      }
      guard let self = self else { return }
      var request = URLRequest(url: url)
      request.allHTTPHeaderFields = args["headers"] as? [String: String]
      self.session.dataTask(with: request) { data, response, error in
        DispatchQueue.main.async {
          if let error = error {
            let native = error as NSError
            let certificate = native.domain == NSURLErrorDomain && [-1201, -1202, -1203, -1204].contains(native.code)
            let message = (certificate ? "CERTIFICATE_VERIFY_FAILED: " : "") + error.localizedDescription
            result(FlutterError(code: "image_network", message: message, details: nil)); return
          }
          guard let response = response as? HTTPURLResponse else {
            result(FlutterError(code: "image_response", message: "Missing HTTP response", details: nil)); return
          }
          var headers: [String: String] = [:]
          for (key, value) in response.allHeaderFields { headers[String(describing: key)] = String(describing: value) }
          result(["status": response.statusCode, "headers": headers,
                  "body": FlutterStandardTypedData(bytes: data ?? Data())])
        }
      }.resume()
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask,
                  willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest,
                  completionHandler: @escaping (URLRequest?) -> Void) {
    guard let url = request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
      completionHandler(nil); return
    }
    var redirected = request
    let old = response.url
    if old?.host != url.host || old?.scheme != url.scheme || old?.port != url.port {
      redirected.setValue(nil, forHTTPHeaderField: "Cookie")
      redirected.setValue(nil, forHTTPHeaderField: "Authorization")
    }
    completionHandler(redirected)
  }
}
