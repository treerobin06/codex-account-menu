import AppKit
import SwiftUI
import SwitcherCore

@main
struct CodexAccountMenuApp: App {
    @NSApplicationDelegateAdaptor(MenuAppDelegate.self) private var appDelegate
    @StateObject private var model = MenuModel.shared

    var body: some Scene {
        MenuBarExtra {
            AccountMenuView(model: model)
        } label: {
            Image(systemName: "person.crop.circle")
                .accessibilityLabel("Codex 账号")
        }
        .menuBarExtraStyle(.window)

    }
}

@MainActor
final class MenuAppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: MenuAppDelegate?
    private var accountWindow: NSWindow?
    private var activityWindow: NSWindow?
    private lazy var termination = AppTerminationCoordinator(
        isBusy: { MenuModel.shared.isBusy },
        prepare: { await MenuModel.shared.prepareToQuit() }
    )

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        termination.request { sender.reply(toApplicationShouldTerminate: $0) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { await MenuModel.shared.start() }

        if CommandLine.arguments.contains("--show")
            || Bundle.main.object(forInfoDictionaryKey: "CodexAccountMenuDemo") as? Bool == true {
            showAccountWindow()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showAccountWindow()
        return false
    }

    private func showAccountWindow() {
        if accountWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 360, height: 620),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = MenuModel.shared.isDemo ? "Codex 账号 · 演示" : "Codex 账号"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: AccountMenuView(model: .shared, onHeightChanged: { [weak window] height in
                guard let window else { return }
                let availableHeight = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
                window.setContentSize(NSSize(width: 360, height: min(height, availableHeight - 60)))
            }))
            window.center()
            accountWindow = window
        }
        accountWindow?.deminiaturize(nil)
        accountWindow?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func showActivityWindow(selecting threadID: UUID? = nil, allowAutomaticSelection: Bool = true) {
        if activityWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 680),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = MenuModel.shared.isDemo ? "对话与请求 · 演示" : "对话与请求"
            window.contentMinSize = NSSize(width: 760, height: 520)
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            window.center()
            activityWindow = window
        }
        // A new view refreshes its bounded snapshot whenever the user opens it.
        // No SwiftUI Window scene: login launches only the menu bar item.
        activityWindow?.contentView = NSHostingView(rootView: ConversationActivityView(model: .shared,
            initialSelectionID: threadID, allowAutomaticSelection: allowAutomaticSelection))
        activityWindow?.deminiaturize(nil)
        activityWindow?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
