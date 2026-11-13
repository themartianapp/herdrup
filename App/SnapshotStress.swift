#if DEBUG
import Darwin
import QuartzCore
import SwiftUI
import UIKit
import WebKit

/// The background-snapshot stress run (`Tools/ci/snapshot-stress.sh`, the `snapshot-stress`
/// macserve shard). The owner's phone killed the app in the BACKGROUND with 0x8BADF00D: going
/// to the background, iOS snapshots the scene in the other orientation and in the other
/// appearance, and each snapshot lays the whole SwiftUI tree out again on the main thread,
/// which after hours of use took more than the watchdog's 10 s.
///
/// `HERDR_SNAPSHOT_STRESS=<rounds>` over the `chatview` mock with `HERDR_MOCK_CHAT_GROWTH`
/// (the agents keep working, so their transcripts grow) and `HERDR_MOCK_CHAT_ANSWERED`
/// (omp works, so Chat polls every 3 s) plays hours of use in minutes: each round fronts
/// herdr-app (Chat), llm-opt (Chat), keephair (Terminal) and the Gram tab, then herdr-app
/// again. Every `HERDR_SNAPSHOT_STRESS_EVERY` rounds (and after the last) it writes one JSON
/// line to `tmp/snapshot-stress.jsonl` in the app's container:
///   phys_footprint (task_vm_info), CALayers and UIViews under the scene's windows (recursive),
///   live WKWebViews, chat rows held, and the main thread's longest block while the scene
///   turns to landscape and back (`requestGeometryUpdate`) and while the window's appearance
///   flips light and back (`overrideUserInterfaceStyle`): the two relayouts a snapshot forces.
/// Then `{"done":true}`. After that, sending the app to the background writes the longest
/// main-thread block between resigning active and four seconds into the background
/// (`{"background_block_ms":…}`): the real snapshot's relayout, as the simulator does it.
@MainActor
enum SnapshotStress {
    static let rounds = ProcessInfo.processInfo.environment["HERDR_SNAPSHOT_STRESS"].flatMap(Int.init)
    private static let every = ProcessInfo.processInfo.environment["HERDR_SNAPSHOT_STRESS_EVERY"]
        .flatMap(Int.init) ?? 5
    /// How long each fronted screen stays up, in seconds.
    private static let dwell = ProcessInfo.processInfo.environment["HERDR_SNAPSHOT_STRESS_DWELL"]
        .flatMap(Double.init) ?? 2.5
    private static let panes = [ChatMockTransport.paneID, "w9:p3", "w9:p2"]

    /// Every WKWebView the app makes (Mermaid's renderer, the HTML viewer), held weakly.
    private static let webViews = NSHashTable<WKWebView>.weakObjects()
    /// Chat rows each live ChatModel holds, by model.
    private static let chatModels = NSHashTable<ChatModel>.weakObjects()
    private static var started = false
    private static let output = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("snapshot-stress.jsonl")

    static func track(_ web: WKWebView) { webViews.add(web) }
    static func track(_ model: ChatModel) { chatModels.add(model) }
    /// Rows the chat of `model` draws now (its body reports them; 0 once it is gone).
    static func noteDrawn(_ model: ChatModel, rows: Int) { drawnRows[ObjectIdentifier(model)] = rows }
    private static var drawnRows: [ObjectIdentifier: Int] = [:]

    static func startIfRequested() {
        guard let rounds, rounds > 0, !started else { return }
        started = true
        try? FileManager.default.removeItem(at: output)
        MainThreadBlocks.shared.install()
        BackgroundWatch.shared.install()
        Task { await SnapshotStress.run(rounds: rounds) }
    }

    private static func run(rounds: Int) async {
        await sleep(4)
        var start: [String: Any] = ["round": 0, "phase": "start"]
        start.merge(metrics()) { $1 }
        write(start)
        for round in 1...rounds {
            for pane in panes {
                PushCenter.shared.tapped(paneID: pane)
                await sleep(dwell)
            }
            PushCenter.shared.tappedGram()
            await sleep(1)
            PushCenter.shared.tapped(paneID: ChatMockTransport.paneID)
            await sleep(dwell)
            if round % every == 0 || round == rounds {
                await measure(round: round)
            }
        }
        write(["done": true])
    }

    /// The metrics, then the two forced relayouts, with herdr-app's Chat in front.
    private static func measure(round: Int) async {
        var line: [String: Any] = ["round": round]
        line.merge(metrics()) { $1 }
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let window = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first
        else {
            write(line)
            return
        }
        // Rotation: the main thread's longest block while the scene turns and settles.
        let wasPortrait = window.bounds.height >= window.bounds.width
        line["rotate_ms"] = await longestBlock(seconds: 2) {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: wasPortrait ? .landscapeRight : .portrait)) { error in
                let text = "\(error)"
                Task { @MainActor in SnapshotStress.write(["rotate_error": text]) }
            }
        }
        line["rotated_to"] = window.bounds.height >= window.bounds.width ? "portrait" : "landscape"
        line["rotate_back_ms"] = await longestBlock(seconds: 2) {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: wasPortrait ? .portrait : .landscapeRight)) { _ in }
        }
        // Appearance: flip the window's style and lay it out now, as the snapshot does.
        let style = window.overrideUserInterfaceStyle
        let flipped: UIUserInterfaceStyle = window.traitCollection.userInterfaceStyle == .dark ? .light : .dark
        line["appearance_ms"] = await longestBlock(seconds: 1) {
            window.overrideUserInterfaceStyle = flipped
            window.layoutIfNeeded()
            CATransaction.flush()
        }
        line["appearance_back_ms"] = await longestBlock(seconds: 1) {
            window.overrideUserInterfaceStyle = style
            window.layoutIfNeeded()
            CATransaction.flush()
        }
        write(line)
    }

    /// Runs `change`, then returns the longest main-thread block (ms) in the next `seconds`,
    /// counting `change` itself.
    private static func longestBlock(seconds: Double, _ change: () -> Void) async -> Int {
        MainThreadBlocks.shared.reset()
        let start = CACurrentMediaTime()
        change()
        let direct = CACurrentMediaTime() - start
        await sleep(seconds)
        return Int((max(direct, MainThreadBlocks.shared.longest) * 1000).rounded())
    }

    static func metrics() -> [String: Any] {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        let models = chatModels.allObjects
        return [
            "footprint_mb": (Double(footprint()) / 1_048_576).rounded(),
            "layers": windows.reduce(0) { $0 + layerCount($1.layer) },
            "views": windows.reduce(0) { $0 + viewCount($1) },
            "webviews": webViews.allObjects.count,
            "webviews_in_window": windows.reduce(0) { $0 + webViewCount($1) },
            "chat_models": models.count,
            "chat_rows": models.reduce(0) { $0 + $1.rowCount },
            "chat_rows_drawn": models.reduce(0) { $0 + (drawnRows[ObjectIdentifier($1)] ?? 0) },
        ]
    }

    private static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    private static func layerCount(_ layer: CALayer) -> Int {
        1 + (layer.sublayers ?? []).reduce(0) { $0 + layerCount($1) }
    }

    private static func viewCount(_ view: UIView) -> Int {
        1 + view.subviews.reduce(0) { $0 + viewCount($1) }
    }

    private static func webViewCount(_ view: UIView) -> Int {
        (view is WKWebView ? 1 : 0) + view.subviews.reduce(0) { $0 + webViewCount($1) }
    }

    private static func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    static func write(_ line: [String: Any]) {
        var line = line
        line["t"] = (Date().timeIntervalSince1970 * 10).rounded() / 10
        guard let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
        let text = String(decoding: data, as: UTF8.self)
        print("snapshot-stress: \(text)")
        let bytes = Data((text + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: output) {
            handle.seekToEndOfFile()
            handle.write(bytes)
            try? handle.close()
        } else {
            try? bytes.write(to: output)
        }
    }
}

/// The main run loop's longest busy stretch (from waking to going back to sleep) since
/// `reset()`: a relayout blocks the main thread for one such stretch.
@MainActor
final class MainThreadBlocks {
    static let shared = MainThreadBlocks()
    private(set) var longest: CFTimeInterval = 0
    private var wokeAt: CFTimeInterval?
    private var observer: CFRunLoopObserver?

    func install() {
        guard observer == nil else { return }
        let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
        observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, 0) { _, activity in
            MainActor.assumeIsolated { MainThreadBlocks.shared.note(activity) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    func reset() {
        longest = 0
        wokeAt = CACurrentMediaTime()
    }

    private func note(_ activity: CFRunLoopActivity) {
        let now = CACurrentMediaTime()
        if activity == .afterWaiting {
            wokeAt = now
        } else if let wokeAt {
            longest = max(longest, now - wokeAt)
            self.wokeAt = nil
        }
    }
}

/// The longest main-thread block from resigning active until four seconds into the
/// background: what iOS's snapshots cost. Held open by a background task so it is written.
@MainActor
final class BackgroundWatch {
    static let shared = BackgroundWatch()
    private var tokens: [NSObjectProtocol] = []

    func install() {
        guard tokens.isEmpty else { return }
        let center = NotificationCenter.default
        tokens.append(center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil,
                                         queue: .main) { _ in
            MainActor.assumeIsolated { MainThreadBlocks.shared.reset() }
        })
        tokens.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil,
                                         queue: .main) { _ in
            MainActor.assumeIsolated { BackgroundWatch.shared.entered() }
        })
    }

    private var backgroundTask = UIBackgroundTaskIdentifier.invalid

    private func entered() {
        backgroundTask = UIApplication.shared.beginBackgroundTask {
            MainActor.assumeIsolated { BackgroundWatch.shared.endTask() }
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            var line = SnapshotStress.metrics()
            line["background_block_ms"] = Int((MainThreadBlocks.shared.longest * 1000).rounded())
            SnapshotStress.write(line)
            endTask()
        }
    }

    private func endTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
#endif
