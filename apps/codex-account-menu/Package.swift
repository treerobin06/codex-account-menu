// swift-tools-version: 6.2

import Foundation
import PackageDescription

func xcrunFind(_ tool: String) -> URL? {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["--find", tool]
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice

    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return nil
    }

    guard process.terminationStatus == 0 else { return nil }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    guard let path = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
        !path.isEmpty
    else {
        return nil
    }
    return URL(fileURLWithPath: path)
}

let testingCompatibilitySettings: ([SwiftSetting], [LinkerSetting]) = {
    guard let swiftExecutable = xcrunFind("swift") else { return ([], []) }

    let selectedToolchainRoot = swiftExecutable
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let frameworksDirectory = selectedToolchainRoot
        .appending(path: "Library/Developer/Frameworks", directoryHint: .isDirectory)
    let librariesDirectory = selectedToolchainRoot
        .appending(path: "Library/Developer/usr/lib", directoryHint: .isDirectory)
    let testingFramework = frameworksDirectory
        .appending(path: "Testing.framework", directoryHint: .isDirectory)
    let testingInteropLibrary = librariesDirectory.appending(path: "lib_TestingInterop.dylib")

    guard FileManager.default.fileExists(atPath: testingFramework.path),
          FileManager.default.fileExists(atPath: testingInteropLibrary.path)
    else {
        return ([], [])
    }

    return (
        [.unsafeFlags(["-F", frameworksDirectory.path])],
        [
            .unsafeFlags([
                "-F", frameworksDirectory.path,
                "-Xlinker", "-rpath", "-Xlinker", frameworksDirectory.path,
                "-Xlinker", "-rpath", "-Xlinker", librariesDirectory.path,
            ]),
            .linkedFramework("Testing"),
        ]
    )
}()

let package = Package(
    name: "CodexAccountMenu",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SwitcherCore", targets: ["SwitcherCore"]),
        .executable(name: "CodexAccountMenu", targets: ["CodexAccountMenu"]),
        .executable(name: "codex-menu", targets: ["MenuCLI"]),
    ],
    targets: [
        .target(name: "SwitcherCore", resources: [.process("Resources")]),
        .executableTarget(name: "CodexAccountMenu", dependencies: ["SwitcherCore"], linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("SwiftUI")]),
        .executableTarget(name: "MenuCLI", dependencies: ["SwitcherCore"]),
        .testTarget(name: "SwitcherCoreTests", dependencies: ["SwitcherCore"], swiftSettings: testingCompatibilitySettings.0, linkerSettings: testingCompatibilitySettings.1),
    ]
)
