import Flutter
import Foundation
import WebKit
import UIKit

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
      case "readVerifiedResource":
        guard let args = call.arguments as? [String: Any], let text = args["url"] as? String,
              let url = URL(string: text), url.scheme == "https", url.user == nil,
              self.imageReads.count < 4 else {
          result(FlutterError(code: "invalid_image", message: "Image session unavailable", details: nil)); return
        }
        let id = UUID()
        let task = VerifiedImageRead(url: url, userAgent: args["userAgent"] as? String,
                                     method: args["method"] as? String ?? "GET",
                                     headers: args["headers"] as? [String: String] ?? [:],
                                     body: args["body"] as? String) { response in
          self.imageReads.removeValue(forKey: id)
          result(response)
        }
        self.imageReads[id] = task
        task.start()
      case "readVerifiedPage":
        guard let args = call.arguments as? [String: Any], let text = args["url"] as? String,
              let url = URL(string: text), ["https", "http"].contains(url.scheme ?? ""), url.user == nil else {
          result(FlutterError(code: "invalid_url", message: "Invalid page URL", details: nil)); return
        }
        guard self.reads.count < 4 else {
          result(FlutterError(code: "busy", message: "Browser session busy", details: nil)); return
        }
        let id = UUID()
        let task = VerifiedPageRead(url: url, userAgent: args["userAgent"] as? String) { response in
          self.reads.removeValue(forKey: id)
          result(response)
        }
        self.reads[id] = task
        task.start()
      case "allCookies":
        WafCookieController.allCookies(result: result)
      case "clearWebsiteDataForHosts":
        let args = call.arguments as? [String: Any] ?? [:]
        WafCookieController.clearWebsiteData(
          hosts: args["hosts"] as? [String] ?? [],
          protectedHosts: args["protectedHosts"] as? [String] ?? [], result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private let imageNetwork = ImageNetworkController()
  private var reads: [UUID: VerifiedPageRead] = [:]
  private var imageReads: [UUID: VerifiedImageRead] = [:]

  /// 枚举默认数据仓里的全部 Cookie；`WKHTTPCookieStore` 是异步回调接口。
  ///
  /// `url` 参数当前只用于日志（不过滤）：跨子域分享的 Cookie（如
  /// `.example.com` 域上的 cf_clearance）必须一起带回去，按 url 过滤会漏掉它们。
  /// Clear only requested station domains. Shared domains still used by another section are retained.
  private static func clearWebsiteData(hosts: [String], protectedHosts: [String], result: @escaping FlutterResult) {
    let targets = hosts.map { $0.lowercased() }.filter { !$0.isEmpty }
    let protected = protectedHosts.map { $0.lowercased() }.filter { !$0.isEmpty }
    func matches(_ domain: String, _ host: String) -> Bool {
      let value = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
      return !value.isEmpty && (host == value || host.hasSuffix("." + value))
    }
    func removable(_ domain: String) -> Bool {
      targets.contains { matches(domain, $0) } && !protected.contains { matches(domain, $0) }
    }
    guard !targets.isEmpty else { result(nil); return }
    let dataStore = WKWebsiteDataStore.default()
    dataStore.httpCookieStore.getAllCookies { cookies in
      let group = DispatchGroup()
      for cookie in cookies where removable(cookie.domain) {
        group.enter()
        dataStore.httpCookieStore.delete(cookie) { group.leave() }
      }
      for cookie in HTTPCookieStorage.shared.cookies ?? [] where removable(cookie.domain) {
        HTTPCookieStorage.shared.deleteCookie(cookie)
      }
      group.notify(queue: .main) {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        dataStore.fetchDataRecords(ofTypes: types) { records in
          let selected = records.filter { removable($0.displayName) }
          dataStore.removeData(ofTypes: types, for: selected) { result(nil) }
        }
      }
    }
  }

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

/// Use Apple's TLS/HTTP stack. Only matching Cloudflare verification cookies may be reused.
private final class ImageNetworkController: NSObject, URLSessionTaskDelegate {
  private lazy var session: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.httpCookieStorage = nil
    config.httpShouldSetCookies = false
    config.urlCache = nil
    config.timeoutIntervalForRequest = 15
    config.timeoutIntervalForResource = 20
    config.httpMaximumConnectionsPerHost = 3
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
      request.timeoutInterval = min(15, max(3, args["timeoutSeconds"] as? Double ?? 15))
      request.allHTTPHeaderFields = args["headers"] as? [String: String]
      request.httpMethod = args["method"] as? String ?? "GET"
      if let body = args["body"] as? String { request.httpBody = body.data(using: .utf8) }
      let start: (URLRequest) -> Void = { outgoing in
      self.session.dataTask(with: outgoing) { data, response, error in
        DispatchQueue.main.async {
          if let error = error {
            let native = error as NSError
            let certificate = native.domain == NSURLErrorDomain && [-1201, -1202, -1203, -1204].contains(native.code)
            let tls = native.domain == NSURLErrorDomain && native.code == -1200
            let message = (certificate ? "CERTIFICATE_VERIFY_FAILED: " : tls ? "TLS_HANDSHAKE_FAILED: " : "") + error.localizedDescription
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
      if args["reuseVerification"] as? Bool == true {
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
          let host = url.host?.lowercased() ?? ""
          let selected = cookies.filter { cookie in
            guard ["cf_clearance", "__cf_bm"].contains(cookie.name),
                  cookie.expiresDate.map({ $0 > Date() }) ?? true,
                  !cookie.isSecure || url.scheme == "https" else { return false }
            let domain = cookie.domain.lowercased()
            let bare = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
            let matches = host == bare || (domain.hasPrefix(".") && host.hasSuffix("." + bare))
            let cookiePath = cookie.path.isEmpty ? "/" : cookie.path
            let path = url.path.isEmpty ? "/" : url.path
            return matches && (path == cookiePath || path.hasPrefix(cookiePath.hasSuffix("/") ? cookiePath : cookiePath + "/"))
          }.sorted { $0.path.count > $1.path.count }
          var scoped = request
          var chosen: [String: String] = [:]
          for cookie in selected where chosen[cookie.name] == nil { chosen[cookie.name] = cookie.value }
          if !chosen.isEmpty {
            var existing = (scoped.value(forHTTPHeaderField: "Cookie") ?? "").split(separator: ";")
              .map { $0.trimmingCharacters(in: .whitespaces) }
              .filter { !chosen.keys.contains(String($0.split(separator: "=", maxSplits: 1).first ?? "")) && !$0.isEmpty }
            existing.append(contentsOf: chosen.map { "\($0.key)=\($0.value)" })
            scoped.setValue(existing.joined(separator: "; "), forHTTPHeaderField: "Cookie")
          }
          start(scoped)
        }
      } else { start(request) }
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


/// Navigation uses the same default WebKit data store as the visible verification page.
/// It does not solve challenges: a remaining challenge is returned as an ordinary 403.
private final class VerifiedPageRead: NSObject, WKNavigationDelegate {
  private let webView: WKWebView
  private let url: URL
  private var completion: ((Any) -> Void)?
  private var timeout: DispatchWorkItem?
  private var poll: DispatchWorkItem?
  private var status = 200
  private var mime = "text/html"
  init(url: URL, userAgent: String?, completion: @escaping (Any) -> Void) {
    self.url = url
    self.completion = completion
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .default()
    webView = WKWebView(frame: CGRect(x: -1000, y: -1000, width: 390, height: 600), configuration: configuration)
    super.init()
    webView.customUserAgent = userAgent
    webView.navigationDelegate = self
  }
  func start() {
    let work = DispatchWorkItem { [weak self] in
      self?.finish(FlutterError(code: "timeout", message: "Verified page timed out", details: nil))
    }
    timeout = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 18, execute: work)
    webView.load(URLRequest(url: url))
  }
  func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
               decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
    if navigationResponse.isForMainFrame, let response = navigationResponse.response as? HTTPURLResponse {
      status = response.statusCode
      mime = response.mimeType ?? "text/html"
    }
    decisionHandler(.allow)
  }
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    readDocument(force: true)
  }
  func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
    scheduleRead()
  }
  private func scheduleRead() {
    guard completion != nil else { return }
    let work = DispatchWorkItem { [weak self] in self?.readDocument(force: false) }
    poll = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
  }
  private func readDocument(force: Bool) {
    guard completion != nil else { return }
    let body = mime.contains("html") ? "document.documentElement.outerHTML" : "document.body.innerText"
    let script = "({ready: document.readyState, body: \(body)})"
    webView.evaluateJavaScript(script) { [weak self] value, error in
      guard let self = self else { return }
      if let error = error { self.finish(FlutterError(code: "read_failed", message: error.localizedDescription, details: nil)); return }
      let document = value as? [String: Any] ?? [:]
      let text = document["body"] as? String ?? ""
      // A committed challenge document is not the final navigation result.
      // Give WebKit time to reuse the user's existing verification session.
      let challenge = text.range(of: "cf-chl-|challenge-platform|<title[^>]*>\\s*(Just a moment|Attention Required)",
                                 options: [.regularExpression, .caseInsensitive]) != nil
      if document["ready"] as? String == "loading" || challenge {
        self.scheduleRead(); return
      }
      guard text.utf8.count <= 10 * 1024 * 1024 else {
        self.finish(FlutterError(code: "too_large", message: "Page too large", details: nil)); return
      }
      self.finish(["status": self.status, "body": text, "contentType": self.mime])
    }
  }
  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    finish(FlutterError(code: "navigation_failed", message: error.localizedDescription, details: nil))
  }
  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    finish(FlutterError(code: "navigation_failed", message: error.localizedDescription, details: nil))
  }
  private func finish(_ value: Any) {
    guard let callback = completion else { return }
    completion = nil
    timeout?.cancel()
    poll?.cancel()
    webView.stopLoading()
    webView.navigationDelegate = nil
    callback(value)
  }
}

/// Fetch an image in its own WebKit origin, retaining only the browser's
/// domain-scoped cookies and TLS identity. No source-site credentials are copied.
private final class VerifiedImageRead: NSObject, WKNavigationDelegate {
  private let webView: WKWebView
  private let url: URL
  private let method: String
  private let headers: [String: String]
  private let body: String?
  private var completion: ((Any) -> Void)?
  private var timeout: DispatchWorkItem?
  private var fetching = false
  init(url: URL, userAgent: String?, method: String, headers: [String: String], body: String?, completion: @escaping (Any) -> Void) {
    self.url = url
    self.method = method; self.headers = headers; self.body = body
    self.completion = completion
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .default()
    webView = WKWebView(frame: CGRect(x: -1000, y: -1000, width: 390, height: 600), configuration: configuration)
    super.init()
    webView.customUserAgent = userAgent
    webView.navigationDelegate = self
  }
  func start() {
    let work = DispatchWorkItem { [weak self] in
      self?.finish(FlutterError(code: "timeout", message: "Image verification session timed out", details: nil))
    }
    timeout = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 18, execute: work)
    var origin = URLComponents(url: url, resolvingAgainstBaseURL: false)!
    origin.path = "/"; origin.query = nil; origin.fragment = nil
    webView.load(URLRequest(url: origin.url!))
  }
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard completion != nil, !fetching else { return }
    fetching = true
    let script = """
      const target = new URL(address);
      if (target.origin !== location.origin) throw new Error('Image origin changed');
      const options = {credentials:'same-origin', method, headers};
      if (method !== 'GET' && method !== 'HEAD' && body !== null) options.body = body;
      const response = await fetch(target.href, options);
      const blob = await response.blob();
      if (blob.size > 20 * 1024 * 1024) throw new Error('Image too large');
      const data = await new Promise((resolve,reject) => {
        const reader = new FileReader(); reader.onload = () => resolve(reader.result);
        reader.onerror = () => reject(new Error('Image read failed')); reader.readAsDataURL(blob);
      });
      return {status:response.status, contentType:response.headers.get('content-type') || '',
              body:data.substring(data.indexOf(',') + 1)};
      """
    webView.callAsyncJavaScript(script, arguments: ["address": url.absoluteString, "method": method, "headers": headers, "body": body as Any? ?? NSNull()], in: nil, in: .page) { [weak self] result in
      guard let self = self else { return }
      switch result {
      case .success(let value):
        guard var response = value as? [String: Any], let encoded = response["body"] as? String,
              let bytes = Data(base64Encoded: encoded) else {
          self.finish(FlutterError(code: "image_response", message: "Invalid browser image response", details: nil)); return
        }
        response["body"] = FlutterStandardTypedData(bytes: bytes)
        self.finish(response)
      case .failure(let error):
        self.finish(FlutterError(code: "image_read", message: error.localizedDescription, details: nil))
      }
    }
  }
  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    finish(FlutterError(code: "image_navigation", message: error.localizedDescription, details: nil))
  }
  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    finish(FlutterError(code: "image_navigation", message: error.localizedDescription, details: nil))
  }
  private func finish(_ value: Any) {
    guard let callback = completion else { return }
    completion = nil; timeout?.cancel()
    webView.stopLoading(); webView.navigationDelegate = nil
    callback(value)
  }
}
