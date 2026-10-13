import AVFoundation
import AVKit
import Flutter
import UIKit

/// 画中画的原生实现（iOS）。
///
/// 契约见 Dart 侧 `MethodChannelPipBackend`：
/// - 方法通道 `lumebox/pip`：`isSupported` / `start` / `stop`；
/// - 事件通道 `lumebox/pip/events`：`entered` / `exited` / `restored` / `failed`。
///
/// 实现方式：`AVPictureInPictureController(contentSource:)` 绑定一个
/// `AVSampleBufferDisplayLayer` 作为内容源。这是 iOS 15+ 给**非 AVPlayer 内核**
/// （本项目里的 MPV / MDK）准备的官方通路——内核把解码后的帧交给这个 layer，
/// 系统负责画中画窗口与手势。
///
/// AVPlayer 内核不经过这里：它自带 `AVPictureInPictureController(playerLayer:)`，
/// 由 video_player 插件在原生侧直接处理（见播放器文档的画中画规范）。
///
/// 开窗前由 Dart 主动送首帧；进入后持续转发 MPV 画面。
final class PipController: NSObject {
  private let methodChannelName = "lumebox/pip"
  private let eventChannelName = "lumebox/pip/events"

  private var eventSink: FlutterEventSink?
  private var controller: AVPictureInPictureController?
  private var frameLayer: AVSampleBufferDisplayLayer?
  private var paused = false
  private var durationSeconds: Double = 0

  /// 帧泵：把 Dart 送来的 BGRA 帧包成 CMSampleBuffer 上屏。
  private let framePump = PipFramePump()

  /// 帧通道：与 Dart 侧 `PipFrameSource` 的帧提交一一对应。
  private let frameChannelName = "lumebox/pip/frames"


  func register(with messenger: FlutterBinaryMessenger) {
    let methods = FlutterMethodChannel(name: methodChannelName, binaryMessenger: messenger)
    methods.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }

    let events = FlutterEventChannel(name: eventChannelName, binaryMessenger: messenger)
    events.setStreamHandler(self)

    // 帧通道：Dart 每送一帧（BGRA 字节），这里包成 CMSampleBuffer 上屏。
    let frames = FlutterMethodChannel(name: frameChannelName, binaryMessenger: messenger)
    frames.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(nil)
        return
      }
      switch call.method {
      case "submitFrame":
        self.handleFrame(call, result: result)
      case "teardown":
        self.framePump.teardown()
        self.frameLayer = nil
        self.controller = nil
        result(nil)
      case "stats":
        result([
          "received": self.framePump.receivedFrames,
          "dropped": self.framePump.droppedFrames,
        ])
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// 收一帧：BGRA 字节 → CMSampleBuffer → 显示层。
  private func handleFrame(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let data = args["pixels"] as? FlutterStandardTypedData,
          let width = args["width"] as? Int,
          let height = args["height"] as? Int
    else {
      result(false)
      return
    }
    let timestampMs = (args["timestampMs"] as? Int) ?? 0

    // 首帧到达时才建层并绑定内容源——没有帧就没有内容源，避免「支持但黑屏」。
    if frameLayer == nil {
      framePump.ensureDisplayLayer()
      if let layer = framePump.displayLayer {
        attach(frameLayer: layer)
      }
    }

    let ok = framePump.submit(
      pixels: data.data,
      width: width,
      height: height,
      timestampMs: timestampMs
    )
    result(ok)
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isSupported":
      result(isSupported())
    case "start":
      start(result: result)
    case "stop":
      stop(result: result)
    case "updateState":
      let args = call.arguments as? [String: Any] ?? [:]
      paused = !((args["playing"] as? Bool) ?? false)
      durationSeconds = (args["durationMs"] as? Double ?? 0) / 1000
      if #available(iOS 15.0, *) { controller?.invalidatePlaybackState() }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// 能力判定不依赖首帧；内容源由开窗前的准备步骤建立。
  private func isSupported() -> Bool {
    guard #available(iOS 15.0, *) else { return false }
    guard AVPictureInPictureController.isPictureInPictureSupported() else { return false }
    return true
  }

  /// 绑定内容源：内核把解码帧写进这个 layer，系统据此渲染画中画窗口。
  ///
  /// 首帧到达时绑定内容源并挂入窗口视图。
  @available(iOS 15.0, *)
  func attach(frameLayer layer: AVSampleBufferDisplayLayer) {
    frameLayer = layer
    if let host = UIApplication.shared.connectedScenes
      .compactMap({ $0 as? UIWindowScene }).flatMap({ $0.windows })
      .first(where: { $0.isKeyWindow })?.rootViewController?.view {
      layer.frame = host.bounds
      host.layer.insertSublayer(layer, at: 0)
    }
    let source = AVPictureInPictureController.ContentSource(
      sampleBufferDisplayLayer: layer,
      playbackDelegate: self
    )
    let controller = AVPictureInPictureController(contentSource: source)
    controller.delegate = self
    self.controller = controller
  }

  private func start(result: @escaping FlutterResult) {
    guard #available(iOS 15.0, *) else {
      result(FlutterError(code: "unsupported", message: "画中画需要 iOS 15 及以上", details: nil))
      return
    }
    guard AVPictureInPictureController.isPictureInPictureSupported() else {
      result(FlutterError(code: "unsupported", message: "当前设备不支持画中画", details: nil))
      return
    }
    guard let controller else {
      // 首帧还未到达时不能请求开窗。
      result(FlutterError(
        code: "noContentSource",
        message: "画中画视频帧未就绪，请等画面出现后重试",
        details: nil
      ))
      return
    }
    startWhenReady(controller, attempts: 20, result: result)
  }

  @available(iOS 15.0, *)
  private func startWhenReady(_ candidate: AVPictureInPictureController,
                             attempts: Int, result: @escaping FlutterResult) {
    guard controller === candidate else {
      result(FlutterError(code: "cancelled", message: "画中画内容源已释放", details: nil))
      return
    }
    if candidate.isPictureInPicturePossible {
      candidate.startPictureInPicture()
      result(nil)
    } else if attempts > 0 {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
        guard let self else { result(nil); return }
        self.startWhenReady(candidate, attempts: attempts - 1, result: result)
      }
    } else {
      result(FlutterError(code: "notReady", message: "系统画中画尚未就绪，请重试", details: nil))
    }
  }

  private func stop(result: @escaping FlutterResult) {
    controller?.stopPictureInPicture()
    result(nil)
  }

  private func emit(kind: String, message: String?) {
    var payload: [String: Any] = ["kind": kind]
    if let message { payload["message"] = message }
    eventSink?(payload)
  }
}

// MARK: - FlutterStreamHandler

extension PipController: FlutterStreamHandler {
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }
}

// MARK: - AVPictureInPictureControllerDelegate

extension PipController: AVPictureInPictureControllerDelegate {
  func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
    emit(kind: "entered", message: nil)
  }

  func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
    emit(kind: "exited", message: nil)
  }

  func pictureInPictureController(
    _ controller: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    emit(kind: "failed", message: error.localizedDescription)
  }
}

// MARK: - AVPictureInPictureSampleBufferPlaybackDelegate

/// 播放控制委托：系统画中画窗口上的播放 / 暂停 / 进度条都经这里回到内核。
///
/// 系统窗口操作经事件通道回到 Dart；播放状态由 updateState 同步。
extension PipController: AVPictureInPictureSampleBufferPlaybackDelegate {
  func pictureInPictureController(
    _ controller: AVPictureInPictureController,
    setPlaying playing: Bool
  ) {
    paused = !playing
    emit(kind: playing ? "play" : "pause", message: nil)
  }

  func pictureInPictureControllerTimeRangeForPlayback(
    _ controller: AVPictureInPictureController
  ) -> CMTimeRange {
    if durationSeconds > 0 {
      return CMTimeRange(start: .zero, duration: CMTime(seconds: durationSeconds, preferredTimescale: 1000))
    }
    return CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
  }

  func pictureInPictureControllerIsPlaybackPaused(
    _ controller: AVPictureInPictureController
  ) -> Bool {
    return paused
  }

  func pictureInPictureController(
    _ controller: AVPictureInPictureController,
    didTransitionToRenderSize newRenderSize: CMVideoDimensions
  ) {}

  func pictureInPictureController(
    _ controller: AVPictureInPictureController,
    skipByInterval skipInterval: CMTime,
    completion completionHandler: @escaping () -> Void
  ) {
    let seconds = CMTimeGetSeconds(skipInterval)
    if seconds.isFinite { emit(kind: "skip", message: String(Int(seconds * 1000))) }
    completionHandler()
  }
}
