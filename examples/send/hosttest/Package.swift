// swift-tools-version: 6.0
// The Send example's host test (`make host-test`): the generated app, the framework runtime and the iOS
// app's `SendWallet`, run against Winnow's WalletCore on macOS. `make host-test` copies those sources into
// build/hosttest next to this manifest; WINNOW names the Winnow checkout (default ~/src/winnow-claude).
import Foundation
import PackageDescription

let winnow = ProcessInfo.processInfo.environment["WINNOW"]
    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("src/winnow-claude").path

let package = Package(
    name: "SendHostTest",
    platforms: [.macOS(.v14)],
    dependencies: [.package(name: "Winnow", path: winnow)],
    targets: [
        .executableTarget(
            name: "send-host-test",
            dependencies: [.product(name: "WalletCore", package: "Winnow"),
                           .product(name: "TestSupport", package: "Winnow")],
            path: "Sources",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
