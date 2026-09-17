#!/bin/bash
set -euo pipefail
umask 077
task_root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d /tmp/codex-menu-desktop.XXXXXX)
probe="$work/Restart Probe.app"
mkdir -p "$probe/Contents/MacOS"
cat > "$work/probe.swift" <<'SWIFT'
import AppKit
import Foundation
@MainActor final class Delegate: NSObject, NSApplicationDelegate {
    func record(_ event: String) {
        guard let path = Bundle.main.object(forInfoDictionaryKey: "ProbeLogPath") as? String else { return }
        let value: [String: Any] = ["event": event, "pid": ProcessInfo.processInfo.processIdentifier]
        var bytes = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        bytes.append(10)
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        let handle = try! FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try! handle.seekToEnd(); try! handle.write(contentsOf: bytes); try! handle.close()
    }
    func applicationDidFinishLaunching(_ notification: Notification) { record("started") }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { record("normal_quit"); return .terminateNow }
}
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let delegate = Delegate()
app.delegate = delegate
withExtendedLifetime(delegate) { app.run() }
SWIFT
cat > "$work/driver.swift" <<'SWIFT'
import Foundation
import AppKit
public protocol DesktopControlling: Sendable {
    func closeDesktop() async throws
    func reopenDesktop() async throws
    func isDesktopStopped() async throws -> Bool
}
@main struct Driver {
    @MainActor static func main() async {
        let controller = MacDesktopController(applicationURL: URL(fileURLWithPath: CommandLine.arguments[1]), bundleIdentifier: CommandLine.arguments[2], timeout: 8)
        do {
            try await controller.reopenDesktop()
            guard try await !controller.isDesktopStopped() else { throw DesktopControlError.launchFailed }
            try await Task.sleep(for: .milliseconds(300))
            try await controller.closeDesktop()
            guard try await controller.isDesktopStopped() else { throw DesktopControlError.applicationStillRunning }
            try await controller.reopenDesktop()
            try await Task.sleep(for: .milliseconds(300))
            try await controller.closeDesktop()
            guard try await controller.isDesktopStopped() else { throw DesktopControlError.applicationStillRunning }
            print("NATIVE_DESKTOP_QUIT_REOPEN_OK")
        } catch {
            print("DESKTOP_TEST_FAILED: \(error)")
            try? await controller.closeDesktop()
            exit(1)
        }
    }
}
SWIFT
bundle_id="com.tree.codex-menu-test.$(uuidgen | tr '[:upper:]' '[:lower:]')"
python3 - "$probe" "$work/events.jsonl" "$bundle_id" <<'PY'
from pathlib import Path
import plistlib,sys
app,log,identifier=sys.argv[1:]
with (Path(app)/'Contents/Info.plist').open('wb') as f:
 plistlib.dump({'CFBundleIdentifier':identifier,'CFBundleExecutable':'RestartProbe','CFBundleName':'Restart Probe','CFBundlePackageType':'APPL','LSUIElement':True,'NSPrincipalClass':'NSApplication','ProbeLogPath':log},f)
PY
swiftc -swift-version 6 "$work/probe.swift" -o "$probe/Contents/MacOS/RestartProbe"
codesign --force --sign - --timestamp=none "$probe" >/dev/null 2>&1
swiftc -swift-version 6 "$task_root/Sources/SwitcherCore/MacDesktopController.swift" "$work/driver.swift" -o "$work/driver"
"$work/driver" "$probe" "$bundle_id"
python3 - "$work/events.jsonl" <<'PY'
import json,sys
events=[json.loads(line) for line in open(sys.argv[1])]
assert [e['event'] for e in events]==['started','normal_quit','started','normal_quit'],events
assert events[0]['pid'] != events[2]['pid'],events
print(json.dumps({'native_starts':2,'normal_quits':2,'different_process_ids':True,'events':events}))
PY
echo "Native fixture evidence: $work"
