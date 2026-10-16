import Flutter
import UIKit
import Vision
import ImageIO
import CoreML
import Security
import SwiftUI
#if canImport(Translation)
import Translation
#endif

/// Reader-owned jobs; originals never leave the device on this channel.
final class ComicImageToolsController: NSObject, UIAdaptivePresentationControllerDelegate {
  private let queue = DispatchQueue(label: "lumebox.comicImages", qos: .userInitiated)
  private let lock = NSLock()
  private var cancelled = Set<String>()
  private var active = Set<String>()
  private var models: [String: MLModel] = [:]
  private var translationID: String?
  private var translationResult: FlutterResult?
  private var translationHost: UIViewController?
  private var assetPath: ((String) -> String)?

  func register(with registrar: FlutterPluginRegistrar) {
    assetPath = { registrar.lookupKey(forAsset: $0) }
    FlutterMethodChannel(name: "lumebox/comicImages", binaryMessenger: registrar.messenger())
      .setMethodCallHandler { [weak self] call, result in self?.handle(call, result: result) }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    let id = args["id"] as? String ?? UUID().uuidString
    if call.method == "cancel" {
      if let target = args["id"] as? String {
        lock.lock(); if active.contains(target) { cancelled.insert(target) }; lock.unlock()
        if translationID == target { finishTranslation(nil, error: "翻译已取消") }
      }
      result(nil); return
    }
    if call.method == "getKey" || call.method == "setKey" {
      let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "lumebox.comicTranslation", kSecAttrAccount as String: "apiKey"]
      if call.method == "getKey" {
        var read = query; read[kSecReturnData as String] = true
        var value: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &value)
        guard status == errSecSuccess || status == errSecItemNotFound else { result(FlutterError(code: "keychain", message: "无法读取钥匙串", details: nil)); return }
        result((value as? Data).flatMap { String(data: $0, encoding: .utf8) } ?? "")
      } else {
        let key = args["key"] as? String ?? ""
        if key.isEmpty {
          let status = SecItemDelete(query as CFDictionary)
          guard status == errSecSuccess || status == errSecItemNotFound else { result(FlutterError(code: "keychain", message: "无法删除密钥", details: nil)); return }
        } else {
          let data = Data(key.utf8)
          let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
          if status == errSecItemNotFound {
            var write = query; write[kSecValueData as String] = data
            write[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(write as CFDictionary, nil) == errSecSuccess else { result(FlutterError(code: "keychain", message: "无法保存密钥", details: nil)); return }
          } else if status != errSecSuccess { result(FlutterError(code: "keychain", message: "无法更新密钥", details: nil)); return }
        }
        result(nil)
      }
      return
    }
    if call.method == "translate" { startTranslation(args, id: id, result: result); return }
    guard ["recognize", "superResolve", "prepareModel", "clearModels"].contains(call.method) else { result(FlutterMethodNotImplemented); return }
    lock.lock(); active.insert(id); lock.unlock()
    queue.async {
      do {
        try self.check(id)
        let value: Any? = try autoreleasepool {
          switch call.method {
          case "prepareModel": _ = try self.model(args["noise"] as? Int ?? 0, style: args["imageStyle"] as? String ?? "anime"); return nil
          case "clearModels":
            self.models.removeAll()
            let directory = try self.modelDirectory()
            if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
            return nil
          default:
            guard let bytes = args["bytes"] as? FlutterStandardTypedData, bytes.data.count <= 32 * 1024 * 1024,
                  let source = CGImageSourceCreateWithData(bytes.data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 20000, height <= 100000, width * height <= 8_000_000 else { throw self.failure("图片过大或格式不支持，原图保留") }
            if call.method == "superResolve", let threshold = args["threshold"] as? Int, width >= threshold { return bytes }
            guard let decoded = UIImage(data: bytes.data) else { throw self.failure("图片解码失败") }
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
            let normalized = UIGraphicsImageRenderer(size: CGSize(width: CGFloat(width), height: CGFloat(height)), format: format).image { context in
              UIColor.white.setFill(); context.cgContext.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
              decoded.draw(in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            }
            guard let image = normalized.cgImage else { throw self.failure("图片解码失败") }
            if call.method == "recognize" { return try self.recognize(image, source: args["source"] as? String ?? "auto", id: id) }
            guard width * height <= 4_000_000 else { throw self.failure("当前页超过超分内存限制，原图保留") }
            return FlutterStandardTypedData(bytes: try self.enlarge(image, noise: args["noise"] as? Int ?? 0, style: args["imageStyle"] as? String ?? "anime", id: id))
          }
        }
        self.end(id)
        DispatchQueue.main.async { result(value) }
      } catch {
        self.end(id)
        DispatchQueue.main.async { result(FlutterError(code: "image_processing", message: error.localizedDescription, details: nil)) }
      }
    }
  }

  private func failure(_ message: String) -> NSError { NSError(domain: "LumeComicImageTools", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
  private func check(_ id: String) throws { lock.lock(); let stop = cancelled.contains(id); lock.unlock(); if stop { throw failure("处理已取消") } }
  private func end(_ id: String) { lock.lock(); cancelled.remove(id); active.remove(id); lock.unlock() }
  private func modelDirectory() throws -> URL { try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("comic-super-resolution", isDirectory: true) }

  private func model(_ noise: Int, style: String = "anime") throws -> MLModel {
    guard ["anime", "photo"].contains(style) else { throw failure("模型类型无效") }
    let modelKey = "\(style == "photo" ? "photo" : "noise")\(noise)"
    guard (0...3).contains(noise) else { throw failure("降噪级别无效") }
    if let loaded = models[modelKey] { return loaded }
    let directory = try modelDirectory()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let compiled = directory.appendingPathComponent("\(modelKey).mlmodelc")
    if !FileManager.default.fileExists(atPath: compiled.path) {
      guard let key = assetPath?("assets/models/waifu2x/\(modelKey).mlmodel"),
            let source = Bundle.main.url(forResource: key, withExtension: nil) else { throw failure("找不到超分模型") }
      let temporary = try MLModel.compileModel(at: source)
      defer { try? FileManager.default.removeItem(at: temporary) }
      try FileManager.default.copyItem(at: temporary, to: compiled)
    }
    let config = MLModelConfiguration(); config.computeUnits = .all
    let loaded = try MLModel(contentsOf: compiled, configuration: config)
    // Keep only the current variant resident.
    models = [modelKey: loaded]
    return loaded
  }

  private func recognize(_ image: CGImage, source: String, id: String) throws -> [[String: Any]] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate; request.usesLanguageCorrection = false
    if #available(iOS 16.0, *) { request.automaticallyDetectsLanguage = true }
    let supported = try request.supportedRecognitionLanguages()
    let preferred = source == "auto" ? ["ja-JP", "en-US", "zh-Hans", "zh-Hant", "ko-KR"] : [source]
    let matching = preferred.compactMap { candidate in supported.first { $0 == candidate || $0.hasPrefix(candidate + "-") } }
    if !matching.isEmpty { request.recognitionLanguages = matching }
    try VNImageRequestHandler(cgImage: image).perform([request])
    try check(id)
    let found = request.results ?? []
    guard found.count <= 250 else { throw failure("当前页文字过多，请分段处理") }
    return found.compactMap { observation in
      guard let text = observation.topCandidates(1).first?.string, !text.isEmpty else { return nil }
      let box = observation.boundingBox
      return ["text": text, "x": box.minX, "y": 1 - box.maxY, "width": box.width, "height": box.height]
    }
  }

  private func enlarge(_ image: CGImage, noise: Int, style: String, id: String) throws -> Data {
    let model = try self.model(noise, style: style)
    guard let inputName = model.modelDescription.inputDescriptionsByName.keys.first,
          let inputShape = model.modelDescription.inputDescriptionsByName[inputName]?.multiArrayConstraint?.shape,
          inputShape.map({ $0.intValue }) == [3, 156, 156],
          let outputName = model.modelDescription.outputDescriptionsByName.keys.first else { throw failure("超分模型结构不兼容") }
    let width = image.width, height = image.height, outWidth = width * 2, outHeight = height * 2
    var source = [UInt8](repeating: 0, count: width * height * 4)
    let space = CGColorSpaceCreateDeviceRGB()
    let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    let drawn = source.withUnsafeMutableBytes { ptr -> Bool in
      guard let context = CGContext(data: ptr.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space, bitmapInfo: info) else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))); return true
    }
    guard drawn else { throw failure("无法分配图片内存") }
    var output = [UInt8](repeating: 255, count: outWidth * outHeight * 4)
    func reflect(_ position: Int, limit: Int) -> Int {
      if limit <= 1 { return 0 }
      let period = 2 * (limit - 1)
      let positive = ((position % period) + period) % period
      return positive < limit ? positive : period - positive
    }
    for top in stride(from: 0, to: height, by: 142) {
      for left in stride(from: 0, to: width, by: 142) {
        try check(id)
        try autoreleasepool {
          let input = try MLMultiArray(shape: inputShape, dataType: .float32)
          let values = input.dataPointer.assumingMemoryBound(to: Float.self)
          let strides = input.strides.map { $0.intValue }
          for y in 0..<156 {
            for x in 0..<156 {
              let pixel = (reflect(top + y - 7, limit: height) * width + reflect(left + x - 7, limit: width)) * 4
              for channel in 0..<3 { values[channel * strides[0] + y * strides[1] + x * strides[2]] = Float(source[pixel + channel]) / 255 }
            }
          }
          let features = try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(multiArray: input)])
          let prediction = try model.prediction(from: features)
          guard let pixels = prediction.featureValue(for: outputName)?.multiArrayValue,
                pixels.shape.map({ $0.intValue }) == [3, 284, 284] else { throw failure("超分模型输出不兼容") }
          let steps = pixels.strides.map { $0.intValue }
          let doubleValues = pixels.dataType == .double ? pixels.dataPointer.assumingMemoryBound(to: Double.self) : nil
          let floatValues = pixels.dataType == .float32 ? pixels.dataPointer.assumingMemoryBound(to: Float.self) : nil
          for y in 0..<min(284, (height - top) * 2) {
            for x in 0..<min(284, (width - left) * 2) {
              let destination = ((top * 2 + y) * outWidth + left * 2 + x) * 4
              for channel in 0..<3 {
                let offset = channel * steps[0] + y * steps[1] + x * steps[2]
                let value: Double
                if let doubleValues = doubleValues { value = doubleValues[offset] }
                else if let floatValues = floatValues { value = Double(floatValues[offset]) }
                else { value = pixels[offset].doubleValue }
                output[destination + channel] = value.isFinite ? UInt8(max(0, min(255, (value * 255).rounded()))) : 0
              }
            }
          }
        }
      }
    }
    try check(id)
    let provider = CGDataProvider(data: Data(output) as CFData)
    guard let provider = provider,
          let result = CGImage(width: outWidth, height: outHeight, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: outWidth * 4, space: space, bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
          let data = UIImage(cgImage: result).pngData() else { throw failure("无法生成超分图片") }
    return data
  }

  private func startTranslation(_ args: [String: Any], id: String, result: @escaping FlutterResult) {
    #if canImport(Translation)
    if #available(iOS 18.0, *) {
      guard translationResult == nil else { result(FlutterError(code: "busy", message: "已有翻译任务正在进行", details: nil)); return }
      guard let texts = args["texts"] as? [String], !texts.isEmpty, texts.count <= 250,
            texts.reduce(0, { $0 + $1.count }) <= 50000,
            let target = args["target"] as? String else { result(FlutterError(code: "arguments", message: "翻译参数无效", details: nil)); return }
      guard var root = (UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap { $0.windows }.first { $0.isKeyWindow })?.rootViewController else { result(FlutterError(code: "window", message: "无法打开翻译", details: nil)); return }
      while let presented = root.presentedViewController { root = presented }
      translationID = id; translationResult = result
      lock.lock(); active.insert(id); lock.unlock()
      let source = args["source"] as? String ?? "auto"
      let view = ComicTranslationTaskView(texts: texts, source: source, target: target, completion: { [weak self] strings, error in self?.finishTranslation(strings, error: error) })
      let host = UIHostingController(rootView: view)
      translationHost = host
      host.presentationController?.delegate = self
      root.present(host, animated: true) { [weak self, weak host] in host?.presentationController?.delegate = self }
      return
    }
    #endif
    result(FlutterError(code: "unsupported", message: "设备端翻译需要 iOS 18 或以上；也可配置 AI 翻译", details: nil))
  }

  private func finishTranslation(_ strings: [String]?, error: String?) {
    guard let result = translationResult else { return }
    translationResult = nil
    if let id = translationID { end(id) }; translationID = nil
    let host = translationHost; translationHost = nil
    host?.dismiss(animated: true)
    if let strings = strings { result(strings) }
    else { result(FlutterError(code: "translation", message: error ?? "翻译失败", details: nil)) }
  }
  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { finishTranslation(nil, error: "翻译已取消") }
}

#if canImport(Translation)
@available(iOS 18.0, *)
private struct ComicTranslationTaskView: View {
  let texts: [String]
  let source: String
  let target: String
  let completion: ([String]?, String?) -> Void
  @State private var started = false
  var body: some View {
    VStack(spacing: 24) {
      Text("设备端漫画翻译").font(.headline)
      ProgressView("正在准备语言包并翻译…")
      Text("首次使用请按系统提示下载语言包").font(.footnote)
      Button("取消") { completion(nil, "翻译已取消") }
    }.padding(24)
      .translationTask(source: source == "auto" ? nil : Locale.Language(identifier: source), target: Locale.Language(identifier: target)) { session in
        guard !started else { return }; started = true
        do {
          if source != "auto" { try await session.prepareTranslation() }
          var translated: [String] = []
          for text in texts {
            try Task.checkCancellation()
            let response = try await session.translate(text)
            translated.append(response.targetText)
          }
          await MainActor.run { completion(translated, nil) }
        } catch {
          await MainActor.run { completion(nil, "翻译未完成，请检查语言包、原文语言与系统支持") }
        }
      }
  }
}
#endif
