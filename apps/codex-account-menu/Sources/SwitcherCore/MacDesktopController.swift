import AppKit
import Foundation

public struct MacDesktopController: DesktopControlling {
    public let applicationURL: URL
    public let bundleIdentifier: String
    public let timeout: TimeInterval

    public init(applicationURL: URL = URL(fileURLWithPath: "/Applications/ChatGPT.app"),
                bundleIdentifier: String = "com.openai.codex", timeout: TimeInterval = 30) {
        self.applicationURL = applicationURL
        self.bundleIdentifier = bundleIdentifier
        self.timeout = timeout
    }

    @MainActor public func closeDesktop() async throws {
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        let expected = applicationURL.resolvingSymlinksInPath().standardizedFileURL
        guard applications.allSatisfy({ $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == expected }) else {
            throw DesktopControlError.unexpectedApplication
        }
        for application in applications where !application.isTerminated {
            guard application.terminate() else { throw DesktopControlError.terminationRefused }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(max(0, timeout)))
        while applications.contains(where: { !$0.isTerminated }) {
            guard ContinuousClock.now < deadline else { throw DesktopControlError.terminationTimedOut }
            try await Task.sleep(for: .milliseconds(100))
        }
        // Recheck in case Launch Services relaunched the application during exit.
        guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty else {
            throw DesktopControlError.applicationStillRunning
        }
    }

    @MainActor public func reopenDesktop() async throws {
        guard Bundle(url: applicationURL)?.bundleIdentifier == bundleIdentifier else {
            throw DesktopControlError.unexpectedApplication
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let application = try await NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration)
        guard application.bundleIdentifier == bundleIdentifier,
              application.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == applicationURL.resolvingSymlinksInPath().standardizedFileURL,
              !application.isTerminated else { throw DesktopControlError.launchFailed }
    }

    @MainActor public func isDesktopStopped() async throws -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }
}

public enum DesktopControlError: LocalizedError, Sendable {
    case unexpectedApplication, terminationRefused, terminationTimedOut, applicationStillRunning, launchFailed
    public var errorDescription: String? {
        switch self {
        case .unexpectedApplication: "The application path and bundle identifier do not match."
        case .terminationRefused: "Codex declined a normal quit request; no credentials were changed."
        case .terminationTimedOut: "Codex did not finish quitting before the deadline; no process was force-terminated."
        case .applicationStillRunning: "Codex is still running or restarted while quitting."
        case .launchFailed: "Codex could not be reopened."
        }
    }
}
