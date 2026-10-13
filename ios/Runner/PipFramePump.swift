import AVFoundation
import CoreMedia
import CoreVideo
import Flutter
import UIKit
import CoreImage

/// 画中画帧泵：把 Dart 侧送来的 BGRA 像素包成 `CMSampleBuffer` 交给
/// `AVSampleBufferDisplayLayer` 上屏。
///
/// 为什么要这一层：iOS 的画中画只认 `AVPlayerLayer`（AVPlayer 专用）或
/// `AVSampleBufferDisplayLayer`（通用）。MPV / MDK 不是 AVPlayer，只能走第二条——
/// 内核解码出帧 → Dart 帧源（节流）→ 方法通道 → 本类 → 系统画中画窗口。
///
/// 内存纪律（移动端最要紧的一条）：**复用同一个 CVPixelBufferPool**。
/// 每帧新建 pixel buffer 会在 30fps 下产生持续的分配压力，用池复用能把这块开销
/// 降到几乎为零。池按「首帧尺寸」建立；尺寸变化（旋转 / 换分辨率）时重建。
final class PipFramePump {
  /// 目标层：系统从这里取画面。
  private(set) var displayLayer: AVSampleBufferDisplayLayer?

  let danmaku = PipDanmakuRenderer()
  private let imageContext = CIContext(options: [.cacheIntermediates: false])
  private var pool: CVPixelBufferPool?
  private var poolWidth = 0
  private var poolHeight = 0

  /// 帧计数（诊断）。
  private(set) var receivedFrames = 0
  private(set) var droppedFrames = 0

  /// 建立（或复用）显示层。返回是否为新建。
  @discardableResult
  func ensureDisplayLayer() -> Bool {
    if displayLayer != nil { return false }
    let layer = AVSampleBufferDisplayLayer()
    layer.videoGravity = .resizeAspect
    // 画中画窗口尺寸由系统决定，层本身的 frame 不重要，但要有合法值。
    layer.frame = CGRect(x: 0, y: 0, width: 16, height: 9)
    displayLayer = layer
    return true
  }

  /// 释放显示层与缓冲池（退出画中画 / 页面销毁时调用）。
  func teardown() {
    displayLayer?.flushAndRemoveImage()
    displayLayer?.removeFromSuperlayer()
    displayLayer = nil
    pool = nil
    poolWidth = 0
    poolHeight = 0
    danmaku.update([:])
  }

  /// 接收一帧 BGRA 像素并上屏。
  ///
  /// - Parameters:
  ///   - pixels: BGRA8888 字节（每像素 4 字节，行紧密排列）。
  ///   - width/height: 像素尺寸。
  ///   - timestampMs: 该帧在视频时间轴上的位置（毫秒）。
  /// - Returns: 是否成功入队。
  @discardableResult
  func submit(
    pixels: Data,
    width: Int,
    height: Int,
    timestampMs: Int
  ) -> Bool {
    guard width > 0, height > 0 else { return false }
    let expected = width * height * 4
    guard pixels.count >= expected else {
      droppedFrames += 1
      return false
    }
    ensureDisplayLayer()
    guard let layer = displayLayer else { return false }
    guard let buffer = makePixelBuffer(width: width, height: height) else {
      droppedFrames += 1
      return false
    }

    // 拷像素进 CVPixelBuffer。
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else {
      droppedFrames += 1
      return false
    }
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    pixels.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
      guard let source = raw.baseAddress else { return }
      // 逐行拷贝：CVPixelBuffer 的行距可能大于 width*4（对齐要求）。
      for row in 0..<height {
        let sourceRow = source.advanced(by: row * width * 4)
        let targetRow = base.advanced(by: row * bytesPerRow)
        memcpy(targetRow, sourceRow, width * 4)
      }
    }

    danmaku.draw(base: base, width: width, height: height, stride: bytesPerRow, timestampMs: timestampMs)
    guard let sample = makeSampleBuffer(from: buffer, timestampMs: timestampMs) else {
      droppedFrames += 1
      return false
    }
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true)
      as? [NSMutableDictionary], let attachment = attachments.first {
      attachment[kCMSampleAttachmentKey_DisplayImmediately as String] = true
    }

    // 层可能处于「需要重启」状态（切后台回来常见）：先 flush 再入队。
    if layer.status == .failed {
      layer.flush()
    }
    layer.enqueue(sample)
    receivedFrames += 1
    return true
  }

  /// AVPlayerItemVideoOutput shares the same composited PiP frame path.
  @discardableResult
  func submit(buffer source: CVPixelBuffer, timestampMs: Int, transform: CGAffineTransform = .identity) -> Bool {
    var image = CIImage(cvPixelBuffer: source).transformed(by: transform)
    let extent = image.extent
    guard extent.width > 0, extent.height > 0 else { return false }
    image = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
    let scale = min(1.0, min(960.0 / extent.width, 540.0 / extent.height))
    image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let width = max(1, Int(image.extent.width)), height = max(1, Int(image.extent.height))
    guard let buffer = makePixelBuffer(width: width, height: height) else { return false }
    imageContext.render(image, to: buffer)
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    if let base = CVPixelBufferGetBaseAddress(buffer) {
      danmaku.draw(base: base, width: width, height: height, stride: CVPixelBufferGetBytesPerRow(buffer), timestampMs: timestampMs)
    }
    ensureDisplayLayer()
    guard let layer = displayLayer, let sample = makeSampleBuffer(from: buffer, timestampMs: timestampMs) else { return false }
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary], let first = attachments.first {
      first[kCMSampleAttachmentKey_DisplayImmediately as String] = true
    }
    if layer.status == .failed { layer.flush() }
    layer.enqueue(sample)
    receivedFrames += 1
    return true
  }

  // ------------------------------------------------------------ 内部：缓冲

  /// 从池里取一个 pixel buffer（尺寸变化时重建池）。
  private func makePixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
    if pool == nil || poolWidth != width || poolHeight != height {
      pool = makePool(width: width, height: height)
      poolWidth = width
      poolHeight = height
    }
    guard let pool else { return nil }
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
    return status == kCVReturnSuccess ? buffer : nil
  }

  /// 建池：BGRA 格式（与 Dart 侧送的字节一致，省一次转换）。
  private func makePool(width: Int, height: Int) -> CVPixelBufferPool? {
    let attributes: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: width,
      kCVPixelBufferHeightKey as String: height,
      // IOSurface 让系统能零拷贝把 buffer 交给显示层。
      kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
    ]
    var pool: CVPixelBufferPool?
    let status = CVPixelBufferPoolCreate(
      kCFAllocatorDefault,
      nil,
      attributes as CFDictionary,
      &pool
    )
    return status == kCVReturnSuccess ? pool : nil
  }

  /// CVPixelBuffer → CMSampleBuffer（带时间戳，供系统做窗口同步）。
  private func makeSampleBuffer(
    from buffer: CVPixelBuffer,
    timestampMs: Int
  ) -> CMSampleBuffer? {
    var formatDescription: CMVideoFormatDescription?
    let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
      allocator: kCFAllocatorDefault,
      imageBuffer: buffer,
      formatDescriptionOut: &formatDescription
    )
    guard formatStatus == noErr, let format = formatDescription else { return nil }

    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: 30),
      presentationTimeStamp: CMTime(value: CMTimeValue(timestampMs), timescale: 1000),
      decodeTimeStamp: .invalid
    )
    var sample: CMSampleBuffer?
    let status = CMSampleBufferCreateReadyWithImageBuffer(
      allocator: kCFAllocatorDefault,
      imageBuffer: buffer,
      formatDescription: format,
      sampleTiming: &timing,
      sampleBufferOut: &sample
    )
    return status == noErr ? sample : nil
  }
}

/// Bakes text into the video buffer, so system PiP includes it outside Flutter.
final class PipDanmakuRenderer {
  private var settings: [String: Any] = [:]
  private var items: [[String: Any]] = []
  private var labels: [String: NSAttributedString] = [:]
  var playing = true
  private var lastPosition = -1
  private var anchor: CFTimeInterval = 0
  var enabled: Bool { bool("enabled", true) && bool("pipEnabled", true) && !items.isEmpty }
  func update(_ args: [String: Any]) {
    settings = args["settings"] as? [String: Any] ?? [:]
    items = (args["items"] as? [[String: Any]] ?? []).sorted { number($0["time"]) < number($1["time"]) }
    labels.removeAll()
    lastPosition = -1
  }
  private func bool(_ key: String, _ fallback: Bool) -> Bool { settings[key] as? Bool ?? fallback }
  private func value(_ key: String, _ fallback: Double) -> Double { (settings[key] as? NSNumber)?.doubleValue ?? fallback }
  private func number(_ value: Any?) -> Double { (value as? NSNumber)?.doubleValue ?? 0 }
  func draw(base: UnsafeMutableRawPointer, width: Int, height: Int, stride: Int, timestampMs: Int) {
    guard enabled else { return }
    let now = CACurrentMediaTime()
    if timestampMs != lastPosition { lastPosition = timestampMs; anchor = now }
    let position = Double(timestampMs) + (playing ? min(500, (now - anchor) * 1000) * value("playbackRate", 1) : 0) - value("delayMs", 0)
    let scale = Double(width) / 320
    let fontSize = 16 * value("fontScale", 1) * scale
    let rowHeight = max(16 * scale, fontSize * value("lineSpacing", 1.35))
    let available = Double(height) * (bool("avoidSubtitles", true) ? 0.82 : 1)
    let rows = Int(value("rows", 3))
    let region = rows > 0 ? available : min(available, Double(height) * value("displayArea", 0.5))
    let count = min(rows > 0 ? rows : 64, Int(region / rowHeight))
    guard count > 0, let context = CGContext(data: base, width: width, height: height, bitsPerComponent: 8, bytesPerRow: stride, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
    context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
    context.clip(to: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(min(Double(height), Double(count) * rowHeight))))
    UIGraphicsPushContext(context)
    defer { UIGraphicsPopContext() }
    let span = 8000 / max(0.5, value("speedScale", 1))
    var low = 0, high = items.count
    while low < high { let mid = (low + high) / 2; if number(items[mid]["time"]) < position - max(5000, span) { low = mid + 1 } else { high = mid } }
    var lanes = Array(repeating: -Double.infinity, count: count)
    var recent: [String: Double] = [:]
    var second = -1, rate = 0, visible = 0
    let blocked = (settings["blockedWords"] as? [String] ?? []).map { $0.lowercased() }
    for index in low..<items.count {
      let item = items[index], time = number(item["time"])
      if time > position { break }
      guard let text = item["text"] as? String, !text.isEmpty else { continue }
      let mode = item["mode"] as? String ?? "scroll"
      if mode == "scroll" && !bool("showScroll", true) || mode == "top" && !bool("showTop", true) || mode == "bottom" && !bool("showBottom", true) { continue }
      if blocked.contains(where: { text.lowercased().contains($0) }) { continue }
      let sec = Int(time / 1000)
      if sec != second { second = sec; rate = 0 }
      if rate >= Int(value("maxPerSecond", 8)) { continue }
      if bool("mergeDuplicates", true), let previous = recent[text], time - previous < 5000 { continue }
      let order = mode == "bottom" ? Array((0..<count).reversed()) : Array(0..<count)
      guard let lane = order.first(where: { lanes[$0] <= time }) else { continue }
      let duration = mode == "scroll" ? span : 4000
      lanes[lane] = time + duration; rate += 1; recent[text] = time
      let age = position - time
      if age < 0 || age >= duration { continue }
      if visible >= Int(value("maxOnScreen", 60)) { break }
      visible += 1
      let size = fontSize * min(3, max(0.5, number(item["fontSize"]) == 0 ? 1 : number(item["fontSize"])))
      let rgb = bool("allowColored", true) ? Int(number(item["color"])) : 0xFFFFFF
      let key = "\(text)|\(rgb)|\(size)"
      var label = labels[key]
      if label == nil {
        let color = UIColor(red: CGFloat((rgb >> 16) & 255)/255, green: CGFloat((rgb >> 8) & 255)/255, blue: CGFloat(rgb & 255)/255, alpha: CGFloat(value("opacity", 0.9)))
        label = NSAttributedString(string: text, attributes: [.font: UIFont.systemFont(ofSize: CGFloat(size), weight: bool("bold", true) ? .semibold : .regular), .foregroundColor: color, .strokeColor: UIColor.black.withAlphaComponent(CGFloat(value("opacity", 0.9))), .strokeWidth: -value("strokeWidth", 1.2) * scale / size * 100])
        if labels.count >= 1000 { labels.removeAll() }
        labels[key] = label
      }
      guard let label = label else { continue }
      let measured = label.size()
      let x = mode == "scroll" ? Double(width) - (Double(width) + Double(measured.width)) * age / duration : (Double(width) - Double(measured.width)) / 2
      let y = Double(lane) * rowHeight
      if Double(measured.height) > rowHeight { continue }
      label.draw(at: CGPoint(x: x.rounded(), y: y.rounded()))
    }
  }
}
