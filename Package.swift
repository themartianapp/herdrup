// swift-tools-version:5.9
import PackageDescription

// HerdrKit is the transport + protocol layer for the iOS herdr client.
//
// It deliberately contains NO UIKit/SwiftUI so it builds and tests on Linux,
// where it can be exercised against a real herdr server. The iOS target
// consumes it unchanged.
let package = Package(
    name: "HerdrKit",
    // REQUIRED, and its absence was invisible from Linux. With no `platforms`,
    // SwiftPM assumes macOS 10.10 and every modern-concurrency symbol this
    // package is built on becomes unavailable — Task, AsyncThrowingStream,
    // CancellationError, withTaskCancellationHandler, and the rest. Linux does
    // no availability checking at all, so the package compiled there while
    // being unbuildable on any Apple platform.
    //
    // The floors are chosen, not defaults: macOS 14 for the toolchain that runs
    // the tests (Citadel requires .macOS(.v14); a v13 floor fails `swift build`
    // on macOS with a dependency-floor mismatch — invisible on Linux, which
    // ignores `platforms:` entirely), iOS 17 because that is the floor the app
    // target will inherit and it decides which SwiftUI is available to the UI
    // work (and it matches Citadel's iOS floor, which is why iOS already builds).
    // `platforms` constrains Apple platforms only, so the "builds on Linux too"
    // property above is untouched.
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "HerdrKit", targets: ["HerdrKit"])
    ],
    dependencies: [
        // The pure-Swift SSH stack (swift-nio-ssh + Citadel's key parsing and
        // BoringSSL crypto). Cross-platform — this is what lets HerdrKit link
        // into iOS, which libssh2 cannot. Pinned exactly: Citadel pulls a
        // swift-nio-ssh FORK (Wellz26/swift-nio-ssh), and a fork carrying the
        // transport's crypto is worth a fixed, reviewed revision rather than a
        // range. Proven to build+link for iOS-simulator (spike/citadel-ios).
        //
        // Citadel is OUR FORK too: jerryfane/Citadel tag 0.12.1-herdr.1 is upstream
        // 0.12.1 (ae8562f8) plus `SSHClientSettings.loginTimeout`. Upstream fixes the
        // handshake + auth timer at 10 s, below the app's 15 s connect budget, and a
        // slow link's handshake hit it first (5–8 s measured on a 600 ms, 5 % loss
        // link; over 10 s with other traffic on it). The fork also closes the socket of
        // a handshake that fails instead of leaking it. Package identity is the URL's
        // last path component, so `package: "Citadel"` below is unchanged. Drop the
        // fork once upstream makes the timer configurable.
        .package(url: "https://github.com/jerryfane/Citadel.git",
                 revision: "160e41bff00ef08b2275369f49b4d919adc18f36"),
        // swift-nio-ssh is OVERRIDDEN with our own fork of Citadel's fork, at one
        // revision. Wellz26 0.3.6 (a05e6bbe) killed the app (Mac crash, build 220):
        // a read buffered in the multiplexer was delivered after a child channel had
        // closed locally, servicing it sent a window adjust, and
        // ChildChannelStateMachine.sendChannelWindowAdjust hit preconditionFailure
        // (ChildChannelStateMachine.swift:432, from SSHChildChannel.swift:942 via
        // NIOSSHHandler.channelReadComplete). jerryfane/swift-nio-ssh tag
        // 0.3.6-herdr.1 is a05e6bbe plus the fix: no window adjust once either side
        // has sent CHANNEL_CLOSE, and the closed states throw instead of crashing as
        // proposed upstream in https://github.com/apple/swift-nio-ssh/pull/239.
        //
        // HOW THE OVERRIDE WORKS: package identity is the URL's last path component,
        // so this root dependency and Citadel's Wellz26 one are the same package
        // `swift-nio-ssh`; the root's location wins, and a `revision:` requirement at
        // the root overrides Citadel's "0.3.4"..<"0.4.0" range. SwiftPM warns that
        // Citadel's dependency "conflicts with dependency on" this URL; that warning
        // is expected. Drop this override once Citadel ships a swift-nio-ssh with
        // the fix, and bump the revision with any Citadel bump.
        .package(url: "https://github.com/jerryfane/swift-nio-ssh.git",
                 revision: "7d87c52e86e5affae0480a411b9baaf1dd121aba"),
    ],
    targets: [
        // libssh2 is gone: CitadelTransport (pure-Swift nio-ssh + Citadel)
        // replaced SSHTransport, and with it CSSH, DescriptorAudit, LiveChannel
        // and the fd-ownership thread pool. This is what lets HerdrKit build for
        // iOS at all — the libssh2 XCFramework could not link there.
        .target(
            name: "HerdrKit",
            dependencies: [.product(name: "Citadel", package: "Citadel"),
                           // Imported directly (HostKeyPinning), and names the override above.
                           .product(name: "NIOSSH", package: "swift-nio-ssh")]),
        // `AgentActivityState` IS A TEST DEPENDENCY HERE, and it is the mechanical
        // cross-check I previously reported as impossible. The forcing argument against
        // sharing these types is about the SHIPPED binaries — the widget links only
        // WidgetKit/SwiftUI/ActivityKit and cannot link HerdrKit, and a HerdrKit dependency
        // would duplicate Shared's symbols in the app binary. NEITHER CONSTRAINT REACHES A
        // TEST TARGET, which is linked into the test bundle and into nothing else. So the
        // two duplicated wording tables, and HerdrKit's activity mapping against the state
        // type it feeds, can both be pinned by real assertions instead of a "change both"
        // comment. Reported as unfixable in note 102391; a reviewer showed it was one word.
        .testTarget(
            name: "HerdrKitTests",
            dependencies: ["HerdrKit", "AgentActivityState",
                           .product(name: "Citadel", package: "Citadel")],
            // Read from disk by path (#filePath), like the README checks.
            exclude: ["Fixtures"]),
        // The Live Activity's ContentState, compiled WITHOUT ActivityKit so it can be
        // tested on Linux. `sources` names the one file deliberately: its sibling in the
        // same directory imports ActivityKit and must stay out of this target.
        //
        // Nothing links this product. The Xcode app and widget targets compile the whole
        // Shared directory as sources, exactly as before, so these symbols are not in
        // either binary twice. The target exists ONLY so the tests below can run: while
        // these types were nested in the ActivityKit-importing file, a one-line revert in
        // LiveActivityController reintroduced a shipped defect and survived everything.
        .target(
            name: "AgentActivityState",
            path: "Shared",
            exclude: ["AgentActivityAttributes.swift", "Assets.xcassets"],
            sources: ["AgentActivityState.swift"]),
        .testTarget(
            name: "AgentActivityStateTests",
            dependencies: ["AgentActivityState"]),
        // Main-actor types whose plain constants must stay readable from any context
        // (a default argument is evaluated in the caller's). Warnings are errors here, so a
        // constant that slips back onto the main actor fails the build, not just warns.
        .testTarget(
            name: "HerdrKitIsolationTests",
            dependencies: ["HerdrKit"],
            swiftSettings: [.unsafeFlags(["-warnings-as-errors"])]),
        // The question-push logic behind the lock-screen buttons (#483). Like AgentActivityState
        // above, nothing links this product: the app and the notification service
        // extension compile these files as sources (the extension only AskPush.swift, so
        // it stays free of HerdrKit's SSH stack). The target exists so Linux CI tests them.
        .target(
            name: "AskPush",
            path: "AskPush"),
        .testTarget(
            name: "AskPushTests",
            dependencies: ["AskPush"]),
    ]
)
