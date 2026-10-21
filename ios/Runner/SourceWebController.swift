import Flutter
import Foundation
import WebKit
import SwiftSoup

/// On-device source primitives. Uses the same persistent WebKit store as the
/// visible login page. No browser process, downloaded runtime or remote service.
final class SourceWebController {
  private var tasks: [String: SourceWebTask] = [:]
  private var parsingCount = 0
  private let parsing = DispatchQueue(label: "lumebox.source.html", qos: .userInitiated)

  func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "lumebox/source_web", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self, let args = call.arguments as? [String: Any],
            let id = args["requestId"] as? String else {
        result(FlutterError(code: "arguments", message: "网页请求参数无效", details: nil)); return
      }
      switch call.method {
      case "cancel":
        self.tasks[id]?.cancel()
        result(nil)
      case "extract":
        guard self.parsingCount < 4 else {
          result(FlutterError(code: "html_busy", message: "HTML 解析队列忙，请稍后重试", details: nil)); return
        }
        self.parsingCount += 1
        self.parsing.async {
          do {
            let rows = try SourceWebController.extract(args)
            DispatchQueue.main.async { self.parsingCount -= 1; result(rows) }
          } catch {
            DispatchQueue.main.async {
              self.parsingCount -= 1
              result(FlutterError(code: "html_extract", message: "HTML 或 CSS 提取规则无效", details: nil))
            }
          }
        }
      case "render":
        guard self.tasks.count < 4, self.tasks[id] == nil,
              let text = args["url"] as? String, let url = URL(string: text),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil,
              (args["steps"] as? [Any] ?? []).count <= 16 else {
          result(FlutterError(code: "browser_busy", message: "网页会话忙或地址无效", details: nil)); return
        }
        guard self.tasks.values.filter({ $0.host == url.host }).count < 2 else {
          result(FlutterError(code: "browser_busy", message: "该站点网页请求过于频繁，请稍后重试", details: nil)); return
        }
        let task = SourceWebTask(url: url, options: args) { [weak self] value in
          self?.tasks.removeValue(forKey: id)
          result(value)
        }
        self.tasks[id] = task
        task.start()
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  static func extract(_ args: [String: Any]) throws -> [[String: Any]] {
    guard let html = args["html"] as? String, html.utf8.count <= 2 * 1024 * 1024,
          let fields = args["fields"] as? [String: [String: Any]],
          !fields.isEmpty, fields.count <= 32 else { throw SourceWebError.invalid }
    let document = try SwiftSoup.parse(html, args["baseUrl"] as? String ?? "")
    let selector = args["rowSelector"] as? String ?? ""
    let roots: [Element]
    if selector.isEmpty { roots = [document] }
    else { roots = try document.select(selector).array() }
    var rows: [[String: Any]] = []
    for root in roots.prefix(500) {
      var row: [String: Any] = [:]
      for (name, field) in fields {
        let css = field["selector"] as? String ?? ""
        let matches = css.isEmpty ? [root] : try root.select(css).array()
        var values: [String] = []
        for element in matches.prefix(500) {
          if let attribute = field["attribute"] as? String {
            values.append(try element.attr(attribute))
          } else if field["html"] as? Bool == true {
            values.append(try element.html())
          } else {
            values.append(try element.text())
          }
          if field["all"] as? Bool != true { break }
        }
        if field["all"] as? Bool == true { row[name] = values }
        else { row[name] = values.first ?? (field["defaultValue"] as? String ?? "") }
      }
      rows.append(row)
    }
    guard try JSONSerialization.data(withJSONObject: rows).count <= 1024 * 1024 else {
      throw SourceWebError.invalid
    }
    return rows
  }
}

private enum SourceWebError: Error { case invalid }

final class SourceWebTask: NSObject, WKNavigationDelegate, WKUIDelegate {
  private let webView: WKWebView
  private let url: URL
  var host: String? { url.host }
  private let options: [String: Any]
  private var callback: ((Any) -> Void)?
  private var timeout: DispatchWorkItem?
  private var status = 200
  private var navigating = false
  private var evaluating = false
  private var generation = 0
  private var index = 0
  private var steps: [[String: Any]] {
    var values = options["steps"] as? [[String: Any]] ?? []
    if let selector = options["waitForSelector"] as? String, !selector.isEmpty {
      values.insert(["type": "wait", "selector": selector], at: 0)
    }
    return values
  }

  init(url: URL, options: [String: Any], completion: @escaping (Any) -> Void) {
    self.url = url
    self.options = options
    self.callback = completion
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .default()
    config.defaultWebpagePreferences.allowsContentJavaScript = true
    config.mediaTypesRequiringUserActionForPlayback = .all
    webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
    super.init()
    webView.navigationDelegate = self
    webView.uiDelegate = self
    webView.customUserAgent = options["userAgent"] as? String
  }

  func start(html: String? = nil) {
    let budget = min(8000, max(100, (options["timeoutMs"] as? NSNumber)?.doubleValue ?? 6000))
    let work = DispatchWorkItem { [weak self] in self?.fail("timeout", "等待网页内容或交互超时") }
    timeout = work
    DispatchQueue.main.asyncAfter(deadline: .now() + budget / 1000, execute: work)
    var request = URLRequest(url: url)
    request.timeoutInterval = budget / 1000
    request.allHTTPHeaderFields = options["headers"] as? [String: String]
    request.httpMethod = options["method"] as? String ?? "GET"
    request.httpBody = (options["body"] as? String)?.data(using: .utf8)
    if let html = html { webView.loadHTMLString(html, baseURL: url) }
    else { webView.load(request) }
  }

  func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
               for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
    if action.targetFrame == nil, let address = action.request.url,
       ["http", "https"].contains(address.scheme?.lowercased() ?? "") {
      webView.load(action.request)
    }
    return nil
  }

  func cancel() { fail("cancelled", "网页请求已取消") }

  func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
               decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    let scheme = action.request.url?.scheme?.lowercased() ?? ""
    decisionHandler(["http", "https", "about"].contains(scheme) ? .allow : .cancel)
  }

  func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
               decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
    if response.isForMainFrame, let http = response.response as? HTTPURLResponse { status = http.statusCode }
    decisionHandler(.allow)
  }

  func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
    navigating = true
    generation += 1
    evaluating = false
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    navigating = false
    advance()
  }

  private func advance() {
    guard callback != nil, !navigating, !evaluating else { return }
    let items = steps
    let step = index < items.count ? items[index] : nil
    let type = step?["type"] as? String
    var program = Self.prelude
    var arguments: [String: Any] = [:]
    if let step = step {
      arguments["step"] = step
      switch type {
      case "wait": program += "await find(step.selector); return null;"
      case "click": program += "(await find(step.selector)).click(); return null;"
      case "fill": program += #"""
        const element = await find(step.selector);
        const proto = element.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
        Object.getOwnPropertyDescriptor(proto, 'value').set.call(element, String(step.value == null ? '' : step.value));
        element.dispatchEvent(new Event('input', {bubbles: true}));
        element.dispatchEvent(new Event('change', {bubbles: true})); return null;
        """#
      case "evaluate": program += step["script"] as? String ?? "return null;"
      default: fail("arguments", "不支持的网页交互步骤"); return
      }
    } else {
      // This is intentionally source JavaScript, not interpolated form values.
      program += "const result = await (async()=>{\n" + (options["script"] as? String ?? "return null;") + "\n})();\n"
      program += Self.capture
    }
    // Navigation-producing operations are consumed once, even when WebKit
    // destroys the old JS context. Waits resume against the new document.
    let consumed = type == "click" || type == "evaluate"
    if consumed { index += 1 }
    evaluating = true
    generation += 1
    let current = generation
    webView.callAsyncJavaScript(program, arguments: arguments, in: nil, in: .page) { [weak self] response in
      guard let self = self, self.callback != nil, current == self.generation else { return }
      self.evaluating = false
      switch response {
      case .failure(let error):
        let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? ""
        if message.contains("NEED_WEBVIEW_VERIFY") { self.fail("verification", "网页需要人工验证") }
        else { self.fail("javascript", "网页交互或 JavaScript 执行失败") }
      case .success(let value):
        if let info = value as? [String: Any], info["requiresVerification"] as? Bool == true {
          self.fail("verification", "网页需要人工验证"); return
        }
        if step != nil {
          if !consumed { self.index += 1 }
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.advance() }
        } else {
          guard var result = value as? [String: Any],
                let html = result["html"] as? String, html.utf8.count <= 512 * 1024,
                let data = try? JSONSerialization.data(withJSONObject: result), data.count <= 768 * 1024 else {
            self.fail("result_size", "网页结果超过上限或不能转换为 JSON"); return
          }
          result["status"] = self.status
          self.finish(result)
        }
      }
    }
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    if (error as NSError).code != NSURLErrorCancelled { fail("navigation", "网页加载失败") }
  }
  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    if (error as NSError).code != NSURLErrorCancelled { fail("navigation", "网页加载失败") }
  }
  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { fail("terminated", "网页进程已结束，请重试") }

  private func fail(_ code: String, _ message: String) {
    finish(FlutterError(code: code, message: message, details: nil))
  }
  private func finish(_ value: Any) {
    guard let done = callback else { return }
    callback = nil
    timeout?.cancel()
    webView.stopLoading()
    webView.navigationDelegate = nil
    webView.uiDelegate = nil
    webView.removeFromSuperview()
    // Stop pending JS polling/media and release the document on cancellation.
    webView.loadHTMLString("", baseURL: nil)
    done(value)
  }

  static let prelude = #"""
  const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
  const needsVerification = () => !!document.querySelector('#challenge-running,#cf-challenge-running,#challenge-stage')
    || (/^(just a moment|attention required|checking your browser)/i.test(document.title.trim())
      && !!document.querySelector('script[src*="challenge-platform"],.cf-error-details,.cf-browser-verification,#challenge-form'));
  if (needsVerification()) return {requiresVerification: true};
  const find = async selector => {
    while (true) {
      if (needsVerification()) throw new Error('NEED_WEBVIEW_VERIFY');
      const element = document.querySelector(selector);
      if (element) return element;
      await sleep(50);
    }
  };
  """#

  static let capture = #"""
  const media = new Set();
  for (const element of document.querySelectorAll('video,audio,source')) {
    const url = element.currentSrc || element.src;
    if (url && /^https?:/i.test(url)) media.add(url);
  }
  for (const entry of performance.getEntriesByType('resource')) {
    if (/\.(m3u8|mpd|mp4|m4a|mp3)([?#]|$)/i.test(entry.name)) media.add(entry.name);
  }
  return {url: location.href, title: document.title, html: document.documentElement.outerHTML,
    result: result == null ? null : JSON.parse(JSON.stringify(result)),
    media: Array.from(media).slice(0, 100).map(url => ({url,
      headers: {'User-Agent': navigator.userAgent, 'Referer': location.href}}))};
  """#
}
