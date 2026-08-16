// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "roost",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RoostCore", targets: ["RoostCore"]),
    ],
    dependencies: [
        // A fork, pinned to a commit, until migueldeicaza/SwiftTerm#636 lands.
        //
        // It carries one change: the Metal renderer's row cache survives a
        // scroll. Upstream rebuilds every visible row on every frame while
        // output is coming in — the vertices were written in screen
        // coordinates, so `yDisp` was part of the cache signature — and that
        // was the single most expensive thing this app did, 8.5% of a core
        // with two panes running. It is 15× cheaper per frame with the fix.
        //
        // By revision rather than by branch: a release has to build the same
        // way twice, and a branch moves. When the pull request is merged this
        // goes back to `from: "1.15.0"` and the fork can be deleted.
        .package(
            url: "https://github.com/IKatsuba/SwiftTerm.git",
            revision: "4044974748152db20f01d94e91622e27c2fc51e1"
        ),
    ],
    targets: [
        // All the logic without a single AppKit import: that is why `swift test`
        // runs in seconds and needs neither Xcode nor a screen.
        .target(name: "RoostCore"),
        .testTarget(name: "RoostCoreTests", dependencies: ["RoostCore"]),

        // The app itself. Built through SPM rather than Xcode: for SwiftTerm's
        // Metal shader Xcode 26 demands a separate Metal Toolchain, which
        // `swift build` never asks for. The bundle is assembled by
        // tool/bundle.sh.
        .executableTarget(
            name: "Roost",
            dependencies: [
                "RoostCore",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            // Geist Mono travels with the app: the interface is set in it, and a
            // machine that does not have it installed would otherwise fall back
            // to whatever monospaced face it has. The licence rides along, as
            // the OFL requires.
            resources: [.process("Resources")]
        ),
    ]
)
