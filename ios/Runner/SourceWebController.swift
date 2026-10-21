import Flutter
import Foundation
import WebKit
import SwiftSoup
import UIKit
import CoreFoundation

/// Shared by all managed off-screen WebKit readers, including legacy fallbacks.
enum SourceWebBudget {
  private(set) static var active = 0
  static func take() -> Bool { if active >= 3 { return false }; active += 1; return true }
  static func release() { active = max(0,active - 1) }
}

/// On-device source primitives. Uses the same persistent WebKit store as the
/// visible login page. No browser process, downloaded runtime or remote service.
final class SourceWebController {
  private var tasks: [String: SourceWebTask] = [:]
  private var parsingCount = 0
  private var retained: SourceWebTask?
  private var retainedID: String?
  private var retainedExpiry: DispatchWorkItem?
  private var memoryObserver: NSObjectProtocol?
  private var inspectable = false
  private static var seededCookies: Set<String> = []

  init() {
    memoryObserver = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
      object: nil, queue: .main) { [weak self] _ in
        guard let self = self else { return }
        for task in Array(self.tasks.values) { task.cancel() }
        if self.retained?.isPresented != true { self.retained?.destroy(); self.retained = nil }
        Self.clearTransientData(force:true)
      }
  }
  deinit { if let observer = memoryObserver { NotificationCenter.default.removeObserver(observer) } }
  private static var lastCleanup = Date.distantPast
  private static func clearTransientData(force: Bool = false) {
    if !force && (SourceWebBudget.active > 0 || Date().timeIntervalSince(lastCleanup) < 300) { return }
    lastCleanup = Date()
    URLCache.shared.removeAllCachedResponses()
    // Login cookies and local storage are intentionally retained.
    WKWebsiteDataStore.default().removeData(ofTypes: [WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeDiskCache],
      modifiedSince: .distantPast) {}
  }

  private let parsing = DispatchQueue(label: "lumebox.source.html", qos: .userInitiated)

  func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "lumebox/source_web", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self, let args = call.arguments as? [String: Any] else {
        result(FlutterError(code: "arguments", message: "网页请求参数无效", details: nil)); return
      }
      let id = args["requestId"] as? String ?? ""
      switch call.method {
      case "configure":
        self.inspectable = args["inspectable"] as? Bool == true
        for task in self.tasks.values { task.setInspectable(self.inspectable) }
        self.retained?.setInspectable(self.inspectable)
        let hosts = args["clearVerificationHosts"] as? [String] ?? []
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
          let group = DispatchGroup()
          for cookie in cookies where ["cf_clearance","__cf_bm"].contains(cookie.name) {
            let domain = cookie.domain.trimmingCharacters(in:CharacterSet(charactersIn:"."))
            if hosts.contains(where: { $0==domain || (cookie.domain.hasPrefix(".") && $0.hasSuffix("."+domain)) }) {
              group.enter(); WKWebsiteDataStore.default().httpCookieStore.delete(cookie) { group.leave() }
            }
          }
          group.notify(queue:.main) { result(nil) }
        }
      case "session":
        self.inspectable = args["inspectable"] as? Bool ?? self.inspectable
        Self.session(args, result: result)
      case "decodeText":
        guard let encoded = args["body"] as? String, encoded.count <= 12 * 1024 * 1024,
          let data = Data(base64Encoded: encoded) else {
          result(FlutterError(code: "encoding", message: "文本编码输入无效", details: nil)); return
        }
        let label = args["charset"] as? String ?? "gb18030"
        guard let text = Self.decodeText(data, charset:label) else {
          result(FlutterError(code: "encoding", message: "无法识别或转换网页编码", details: nil)); return
        }
        result(text)
      case "verify":
        guard let task = self.retained, self.retainedID == id else { result(nil); return }
        self.retainedExpiry?.cancel()
        task.presentVerification { value in
          self.retained = nil; self.retainedID = nil
          result(value)
          Self.clearTransientData()
        }
      case "cancel":
        self.tasks[id]?.cancel()
        if self.retainedID == id { self.retained?.cancel(); self.retained=nil; self.retainedID=nil }
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
        guard !id.isEmpty, self.tasks.count < 2, self.tasks[id] == nil,
              let text = args["url"] as? String, let url = URL(string: text),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil,
              (args["steps"] as? [Any] ?? []).count <= 16 else {
          result(FlutterError(code: "browser_busy", message: "网页会话忙或地址无效", details: nil)); return
        }
        guard self.tasks.values.filter({ $0.host == url.host }).count < 2 else {
          result(FlutterError(code: "browser_busy", message: "该站点网页请求过于频繁，请稍后重试", details: nil)); return
        }
        var settings = args
        settings["inspectable"] = self.inspectable
        let task = SourceWebTask(url: url, options: settings) { [weak self] value in
          guard let self = self else { return }
          let finished = self.tasks.removeValue(forKey: id)
          if let error = value as? FlutterError, error.code == "verification", let task = finished {
            self.retained?.destroy()
            self.retained = task; self.retainedID = id
            self.retainedExpiry?.cancel()
            let expiry = DispatchWorkItem { [weak self] in
              guard self?.retainedID == id else { return }
              self?.retained?.destroy(); self?.retained = nil; self?.retainedID = nil
            }
            self.retainedExpiry = expiry
            DispatchQueue.main.asyncAfter(deadline: .now() + 180, execute: expiry)
          } else if self.tasks.isEmpty && self.retained == nil { Self.clearTransientData() }
          result(value)
        }
        self.tasks[id] = task
        task.start()
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  static func decodeText(_ data: Data, charset: String) -> String? {
    if data.starts(with:[0xff,0xfe]) { return String(data:data,encoding:.utf16LittleEndian) }
    if data.starts(with:[0xfe,0xff]) { return String(data:data,encoding:.utf16BigEndian) }
    let cf = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
    guard cf != kCFStringEncodingInvalidId else { return nil }
    return String(data:data,encoding:String.Encoding(rawValue:CFStringConvertEncodingToNSStringEncoding(cf)))
  }

  private static func session(_ args: [String: Any], result: @escaping FlutterResult) {
    guard let address = args["url"] as? String, let url = URL(string: address),
      ["http","https"].contains(url.scheme ?? ""), let host = url.host else {
      result(FlutterError(code: "arguments", message: "站点地址无效", details: nil)); return
    }
    let store = WKWebsiteDataStore.default().httpCookieStore
    let headers = args["headers"] as? [String:String] ?? [:]
    store.getAllCookies { current in
    let group = DispatchGroup()
    // Explicit script/config cookies are host-only; never broaden their domain.
    for pair in (headers.first { $0.key.lowercased() == "cookie" }?.value ?? "").split(separator: ";").prefix(128) {
      let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      if parts.count != 2 { continue }
      let name = parts[0].trimmingCharacters(in: .whitespaces)
      let identity = host + "|" + name
      if seededCookies.contains(identity) && args["forceCookies"] as? Bool != true { continue }
      if seededCookies.count >= 1024 { seededCookies.removeAll() }
      seededCookies.insert(identity)
      let existing = current.first { $0.name == name && ($0.domain == host || ($0.domain.hasPrefix(".") && host.hasSuffix($0.domain))) }
      if let existing=existing {
        if args["forceCookies"] as? Bool == true, existing.value != String(parts[1]), var properties=existing.properties {
          properties[.value]=String(parts[1])
          if let cookie=HTTPCookie(properties:properties) { group.enter(); store.setCookie(cookie) { group.leave() } }
        }
        continue
      }
      var properties: [HTTPCookiePropertyKey: Any] = [.name: parts[0].trimmingCharacters(in: .whitespaces),
        .value: String(parts[1]), .domain: host, .path: "/"]
      if url.scheme == "https" { properties[.secure] = "TRUE" }
      if let cookie = HTTPCookie(properties: properties) {
        group.enter(); store.setCookie(cookie) { group.leave() }
      }
    }
    group.notify(queue: .main) {
      store.getAllCookies { cookies in
        let selected = cookies.filter { cookie in
          let bare = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
          return host.lowercased() == bare || (cookie.domain.hasPrefix(".") && host.lowercased().hasSuffix("." + bare))
        }.prefix(256)
        result(["cookies": selected.map { cookie -> [String:Any] in
          ["name":cookie.name, "value":cookie.value, "domain":cookie.domain, "path":cookie.path,
           "secure":cookie.isSecure, "expires":cookie.expiresDate.map { $0.timeIntervalSince1970 as Any } ?? NSNull()]
        }])
      }
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
  private var holdsPermit = false
  deinit { if holdsPermit { SourceWebBudget.release() } }
  private var navigating = false
  private var evaluating = false
  private var generation = 0
  private var index = 0
  private var verificationController: UINavigationController?
  private var verificationPoll: DispatchWorkItem?
  private var verificationResult: ((Any) -> Void)?
  var isPresented: Bool { verificationController != nil }
  private var loadTimeout: DispatchWorkItem?
  private var loadBudget: Double { min(30000,max(100,(options["pageTimeoutMs"] as? NSNumber)?.doubleValue ?? 6000)) }
  private var elementBudget: Double { min(30000,max(100,(options["elementTimeoutMs"] as? NSNumber)?.doubleValue ?? 4000)) }

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
    config.userContentController.addUserScript(WKUserScript(source: Self.helpers,
      injectionTime: .atDocumentStart, forMainFrameOnly: false))
    webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
    super.init()
    webView.navigationDelegate = self
    webView.uiDelegate = self
    webView.customUserAgent = options["userAgent"] as? String
    if #available(iOS 16.4, *) { webView.isInspectable = options["inspectable"] as? Bool == true }
  }

  func start(html: String? = nil) {
    guard SourceWebBudget.take() else { fail("browser_busy","网页会话数量已达上限"); return }
    holdsPermit = true
    let budget = min(8000, max(100, (options["timeoutMs"] as? NSNumber)?.doubleValue ?? 6000))
    let work = DispatchWorkItem { [weak self] in self?.fail("total_timeout", "网页操作总预算已用完") }
    timeout = work
    DispatchQueue.main.asyncAfter(deadline: .now() + budget / 1000, execute: work)
    var request = URLRequest(url: url)
    request.timeoutInterval = budget / 1000
    request.allHTTPHeaderFields = options["headers"] as? [String: String]
    request.httpMethod = options["method"] as? String ?? "GET"
    request.httpBody = (options["body"] as? String)?.data(using: .utf8)
    let load = {
      if let html = html { self.webView.loadHTMLString(html, baseURL: self.url) }
      else { self.webView.load(request) }
    }
    var rules: [[String:Any]] = []
    if options["blockAds"] as? Bool != false {
      rules.append(["trigger":["url-filter":"^https?://([^/]+\\.)?(doubleclick\\.net|google-analytics\\.com|googlesyndication\\.com)/", "load-type":["third-party"]],"action":["type":"block"]])
    }
    if options["blockImages"] as? Bool == true {
      rules.append(["trigger":["url-filter":".*", "resource-type":["image"]],"action":["type":"block"]])
    }
    if rules.isEmpty { load(); return }
    let key = "lume-source-\(options["blockAds"] as? Bool != false)-\(options["blockImages"] as? Bool == true)"
    let encoded = String(data: try! JSONSerialization.data(withJSONObject: rules), encoding: .utf8)!
    WKContentRuleListStore.default().compileContentRuleList(forIdentifier: key, encodedContentRuleList: encoded) { [weak self] list, _ in
      guard let self = self, self.callback != nil else { return }
      if let list = list { self.webView.configuration.userContentController.add(list) }
      load()
    }
  }

  func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
               for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
    if action.targetFrame == nil, let address = action.request.url,
       ["http", "https"].contains(address.scheme?.lowercased() ?? "") {
      webView.load(action.request)
    }
    return nil
  }

  func cancel() {
    if verificationResult != nil { completeVerification(false) }
    else if callback == nil { destroy() }
    else { fail("cancelled", "网页请求已取消") }
  }

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
    loadTimeout?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.fail("page_timeout", "页面加载超时") }
    loadTimeout = work
    DispatchQueue.main.asyncAfter(deadline: .now() + loadBudget / 1000, execute: work)
    generation += 1
    evaluating = false
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    navigating = false
    loadTimeout?.cancel()
    if verificationResult != nil { pollVerification(); return }
    advance()
  }

  private func advance() {
    guard callback != nil, !navigating, !evaluating else { return }
    let items = steps
    let step = index < items.count ? items[index] : nil
    let type = step?["type"] as? String
    var program = Self.prelude
    var arguments: [String: Any] = ["elementTimeout":elementBudget,
      "apiTimeout": min(30000,max(100,(options["apiTimeoutMs"] as? NSNumber)?.doubleValue ?? 6000))]
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
        else if message.contains("ELEMENT_NOT_FOUND") { self.fail("element_not_found", "目标元素未找到或等待超时") }
        else if message.contains("API_TIMEOUT") { self.fail("api_timeout", "异步接口请求超时") }
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
    timeout?.cancel(); loadTimeout?.cancel()
    if let error = value as? FlutterError, error.code == "verification" {
      // Retain the exact challenge document for a bounded manual handoff.
      done(value); return
    }
    destroy()
    done(value)
  }
  func destroy() {
    if holdsPermit { SourceWebBudget.release(); holdsPermit=false }
    timeout?.cancel(); loadTimeout?.cancel(); verificationPoll?.cancel()
    webView.stopLoading()
    webView.navigationDelegate = nil
    webView.uiDelegate = nil
    webView.removeFromSuperview()
    // Stop pending JS polling/media and release the document on cancellation.
    webView.loadHTMLString("", baseURL: nil)
    webView.configuration.userContentController.removeAllUserScripts()
    webView.configuration.userContentController.removeAllContentRuleLists()
    verificationController?.dismiss(animated: true)
    verificationController = nil
  }

  func setInspectable(_ value: Bool) {
    if #available(iOS 16.4, *) { webView.isInspectable=value }
  }
  func presentVerification(completion: @escaping (Any) -> Void) {
    webView.configuration.userContentController.removeAllContentRuleLists()
    webView.evaluateJavaScript("document.querySelectorAll('img').forEach(i=>{if(!i.complete||!i.naturalWidth)i.src=i.src})",completionHandler:nil)
    guard verificationController == nil else { completion(FlutterError(code:"browser_busy",message:"验证窗口已打开",details:nil)); return }
    guard var presenter = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
      .flatMap({ $0.windows }).first(where: { $0.isKeyWindow })?.rootViewController else {
      completion(FlutterError(code:"verification",message:"无法打开验证窗口",details:nil)); destroy(); return
    }
    while let next = presenter.presentedViewController { presenter = next }
    verificationResult = completion
    let content = UIViewController()
    content.title = "请完成网页验证"
    content.view.backgroundColor = .systemBackground
    content.view.addSubview(webView)
    webView.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([webView.topAnchor.constraint(equalTo:content.view.safeAreaLayoutGuide.topAnchor),
      webView.bottomAnchor.constraint(equalTo:content.view.bottomAnchor), webView.leadingAnchor.constraint(equalTo:content.view.leadingAnchor),
      webView.trailingAnchor.constraint(equalTo:content.view.trailingAnchor)])
    content.navigationItem.leftBarButtonItem = UIBarButtonItem(title:"取消",style:.plain,target:self,action:#selector(cancelVerification))
    let nav = UINavigationController(rootViewController:content)
    nav.isModalInPresentation = true
    verificationController = nav
    presenter.present(nav, animated:true) { self.pollVerification() }
    let work = DispatchWorkItem { [weak self] in self?.completeVerification(false) }
    timeout = work
    DispatchQueue.main.asyncAfter(deadline:.now()+180,execute:work)
  }
  @objc private func cancelVerification() { completeVerification(false) }
  private func completeVerification(_ passed: Bool) {
    guard let done = verificationResult else { return }
    verificationResult = nil
    let value: [String:Any] = ["verified":passed,"url":webView.url?.absoluteString ?? url.absoluteString,
      "userAgent":webView.customUserAgent ?? ""]
    destroy(); done(value)
  }
  private func pollVerification() {
    guard verificationResult != nil else { return }
    webView.callAsyncJavaScript(Self.prelude + "return !needsVerification() && document.readyState === 'complete' && document.body.innerText.trim().length > 40;",
      arguments:["elementTimeout":1000,"apiTimeout":1000],in:nil,in:.page) { [weak self] result in
      guard let self = self, self.verificationResult != nil else { return }
      if case .success(let value) = result, value as? Bool == true, self.webView.url?.host == self.url.host { self.completeVerification(true); return }
      let work = DispatchWorkItem { [weak self] in self?.pollVerification() }
      self.verificationPoll = work
      DispatchQueue.main.asyncAfter(deadline:.now()+1,execute:work)
    }
  }

  static let helpers = #"""
  (()=>{
    const api = {
      css: (s,root=document)=>Array.from(root.querySelectorAll(s)),
      xpath: (s,root=document)=>{const r=document.evaluate(s,root,null,XPathResult.ORDERED_NODE_SNAPSHOT_TYPE,null);
        return Array.from({length:r.snapshotLength},(_,i)=>r.snapshotItem(i));},
      request: async (url,options={})=>{const c=new AbortController();
        const timer=setTimeout(()=>c.abort(),Math.min(30000,options.timeoutMs||globalThis.__lumeApiTimeout||6000));
        try{return await fetch(url,{...options,signal:c.signal});}
        catch(e){if(e.name==='AbortError')throw new Error('API_TIMEOUT');throw e;}finally{clearTimeout(timer);}}
    };
    Object.defineProperty(globalThis,'LumeWeb',{value:api,configurable:false});
    const records = globalThis.__lumeRequests=[];
    const record=(url,status,type,body='')=>{
      if(!/^https?:/i.test(url))return;
      if(records.length>=16)records.shift();
      records.push({url,status,type,body:String(body).slice(0,16384)});
    };
    const original=fetch;
    globalThis.fetch=async function(...args){
      const response=await original.apply(this,args);
      const url=response.url;
      // Same-origin readable data only. No CORS bypass or opaque response access.
      if(response.type!=='opaque') {
        record(url,response.status,'fetch');
        const length=Number(response.headers.get('content-length'));
        if(length>0&&length<=16384&&/json|text/.test(response.headers.get('content-type')||'')){
          response.clone().text().then(body=>{const r=records.slice().reverse().find(x=>x.url===url);if(r)r.body=body.slice(0,16384);}).catch(()=>{});
        }
      }
      return response;
    };
    const open=XMLHttpRequest.prototype.open;
    XMLHttpRequest.prototype.open=function(method,url,...args){
      this.__lumeURL=new URL(url,location.href).href;
      return open.call(this,method,url,...args);
    };
    const send=XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.send=function(...args){
      this.addEventListener('loadend',()=>{
        let text='';try{if(this.responseType===''||this.responseType==='text')text=this.responseText.slice(0,16384);}catch(_){}
        record(this.responseURL||this.__lumeURL,this.status,'xhr',text);
      },{once:true});
      return send.apply(this,args);
    };
  })();
  """#

  static let prelude = #"""
  globalThis.__lumeApiTimeout = apiTimeout;
  const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
  const needsVerification = () => !!document.querySelector('#challenge-running,#cf-challenge-running,#challenge-stage,form[action*="captcha"],#captcha-container')
    || (/^(just a moment|attention required|checking your browser)/i.test(document.title.trim())
      && !!document.querySelector('script[src*="challenge-platform"],.cf-error-details,.cf-browser-verification,#challenge-form'));
  if (needsVerification()) return {requiresVerification: true};
  const find = async selector => {
    const deadline = Date.now() + elementTimeout;
    while (true) {
      if (Date.now() > deadline) throw new Error('ELEMENT_NOT_FOUND');
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
    if (/\.(m3u8|mpd|mp4|m4a|mp3|flv)([?#]|$)/i.test(entry.name)) media.add(entry.name);
  }
  return {url: location.href, title: document.title, html: document.documentElement.outerHTML,
    result: result == null ? null : JSON.parse(JSON.stringify(result)),
    requests: (globalThis.__lumeRequests || []).slice(-16),
    media: Array.from(media).slice(0, 100).map(url => ({url,
      headers: {'User-Agent': navigator.userAgent, 'Referer': location.href}}))};
  """#
}
