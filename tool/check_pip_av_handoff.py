"""Run the production AVPlayerItem output ownership checks on macOS (no simulator)."""
from pathlib import Path
import subprocess
import tempfile

source = Path("ios/Runner/PipController.swift").read_text(encoding="utf-8")
binding = source.split("// BEGIN PiP AV frame binding\n", 1)[1].split(
    "// END PiP AV frame binding", 1
)[0]
pump = Path("ios/Runner/PipFramePump.swift").read_text(encoding="utf-8")
timeline = pump.split("// BEGIN PiP playback timeline\n", 1)[1].split(
    "// END PiP playback timeline", 1
)[0]
checks = r'''
@main struct Check {
  static func main() {
    func item(_ name: String) -> AVPlayerItem {
      AVPlayerItem(url: URL(fileURLWithPath: "/tmp/lumebox-pip-\(name).mp4"))
    }
    let first = item("first"), second = item("second"), third = item("third")
    let player = AVPlayer(playerItem: first)
    let binding = PipAVFrameBinding()
    precondition(binding.bind(player))
    let oldOutput = binding.output!
    precondition(first.outputs.contains { $0 === oldOutput })
    precondition(!binding.bind(player), "same item must retain its existing output")
    precondition(binding.output === oldOutput)
    player.replaceCurrentItem(with: second)
    precondition(binding.bind(player), "same player with a new item must rebind")
    precondition(!first.outputs.contains { $0 === oldOutput })
    precondition(binding.item === second && binding.output !== oldOutput)
    let secondOutput = binding.output!
    let nextPlayer = AVPlayer(playerItem: third)
    precondition(binding.bind(nextPlayer), "new native player ID must transfer frame ownership")
    precondition(!second.outputs.contains { $0 === secondOutput })
    precondition(binding.player === nextPlayer && binding.item === third)
    let thirdOutput = binding.output!
    binding.reset()
    precondition(!third.outputs.contains { $0 === thirdOutput })
    precondition(binding.output == nil && binding.item == nil && binding.player == nil)
    binding.reset()
    print("PIP_AV_HANDOFF_OK: same item, replacement item, replacement player, teardown")
    let timeline = PipPlaybackTimeline()
    func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 1000) }
    timeline.record(milliseconds: 99900, displayTime: time(99.9))
    precondition(CMTimeRangeContainsTime(timeline.range(duration: 100, now: time(100), transitioning: false), time: time(100)),
      "EOF must leave time for the auto-next request")
    let loading = timeline.range(duration: 0, now: time(100), transitioning: true)
    precondition(CMTimeRangeContainsTime(loading, time: time(130)), "loading the next episode must not expose an expired range")
    timeline.record(milliseconds: 0, displayTime: time(100))
    let nextRange = timeline.range(duration: 120, now: time(100), transitioning: false)
    precondition(nextRange.start == time(100), "episode zero maps onto the existing display clock")
    precondition(CMTimeRangeContainsTime(nextRange, time: time(100)))
    timeline.record(milliseconds: 90000, displayTime: time(102))
    precondition(CMTimeRangeContainsTime(timeline.range(duration: 120, now: time(102), transitioning: false), time: time(102)),
      "seeking must preserve a valid display-clock range")
    print("PIP_TIMELINE_OK: EOF, loading gap, episode zero, seek")
  }
}
'''
with tempfile.TemporaryDirectory(prefix="lumebox-pip-handoff-") as folder:
    root = Path(folder)
    swift = root / "Handoff.swift"
    swift.write_text("import Foundation\nimport AVFoundation\nimport CoreVideo\nimport CoreMedia\n" + binding + timeline + checks)
    binary = root / "handoff"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(swift), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=30)
