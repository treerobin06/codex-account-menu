import Foundation
import Darwin
import Testing
@testable import SwitcherCore

private let relayNode = URL(fileURLWithPath: "/opt/homebrew/bin/node")
private let relayScript = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Sources/SwitcherCore/Resources/codex-api-relay.mjs")

@Suite(.enabled(if: FileManager.default.isExecutableFile(atPath: relayNode.path)))
struct APIRelayControllerTests {
    @Test func separateControllersReuseTheSamePersistentHelper() async throws {
        try await withRelayFixture { fixture in
            var first: APIRelayController? = fixture.controller()
            let initial = try await first!.ensureRunning()
            fixture.record(initial)
            #expect(!initial.enabled)
            #expect(initial.testMode)
            #expect(initial.upstreamPort == fixture.upstreamPort)
            #expect(initial.host == "127.0.0.1")
            let enabled = try await first!.setEnabled(true)
            #expect(enabled.enabled)
            first = nil

            let second = fixture.controller()
            let reused = try await second.ensureRunning()
            #expect(reused.pid == initial.pid)
            #expect(reused.instanceId == initial.instanceId)
            #expect(reused.port == initial.port)
            #expect(reused.enabled)
            #expect(try await relayHTTP(reused.baseURL + "/models") == 200)
            let disabled = try await second.setEnabled(false)
            #expect(!disabled.enabled)
            #expect(try await relayHTTP(reused.baseURL + "/models") == 503)
            _ = try await second.shutdown()
            try await relayWait { !FileManager.default.fileExists(atPath: fixture.socketURL.path) }
            #expect(try await second.status() == nil)
        }
    }

    @Test func aCrashedOwnedHelperLeavesAPrivateSocketThatCanBeRecovered() async throws {
        try await withRelayFixture { fixture in
            let controller = fixture.controller()
            let original = try await controller.ensureRunning()
            fixture.record(original)
            #expect(Darwin.kill(original.pid, SIGKILL) == 0)
            try await relayWait { Darwin.kill(original.pid, 0) != 0 }
            #expect(FileManager.default.fileExists(atPath: fixture.socketURL.path))
            #expect(try await controller.status() == nil)
            #expect(FileManager.default.fileExists(atPath: fixture.socketURL.path))

            let replacement = try await controller.ensureRunning()
            fixture.record(replacement)
            #expect(replacement.pid != original.pid)
            #expect(replacement.instanceId != original.instanceId)
            #expect(!replacement.enabled)
            #expect(replacement.activeRequests == 0)
            #expect(replacement.activeWebSockets == 0)
            _ = try await controller.shutdown()
            try await relayWait { !FileManager.default.fileExists(atPath: fixture.socketURL.path) }
        }
    }

    @Test func anActiveHTTPStreamPreventsDisableAndShutdown() async throws {
        try await withRelayFixture { fixture in
            let controller = fixture.controller()
            let initial = try await controller.ensureRunning()
            fixture.record(initial)
            let enabled = try await controller.setEnabled(true)
            let request = Task { try await relayHTTP(enabled.baseURL + "/responses?hold=1", post: true) }
            try await relayWait { try await controller.status()?.activeRequests == 1 }

            do {
                _ = try await controller.setEnabled(false)
                Issue.record("Disabling an active stream must be refused.")
            } catch APIRelayError.busy { }
            do {
                _ = try await controller.shutdown()
                Issue.record("Shutting down an active stream must be refused.")
            } catch APIRelayError.busy { }
            #expect(try await controller.status()?.enabled == true)
            fixture.releaseStreams()
            #expect(try await request.value == 200)
            try await relayWait { try await controller.status()?.isIdle == true }
            #expect(try await controller.setEnabled(false).enabled == false)
            _ = try await controller.shutdown()
            try await relayWait { !FileManager.default.fileExists(atPath: fixture.socketURL.path) }
        }
    }

    @Test(arguments: [false, true])
    func aForeignFileOrSymlinkIsNeverReplaced(symlink: Bool) async throws {
        try await withRelayFixture { fixture in
            try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            let content = Data("foreign-fixture-must-survive".utf8)
            if symlink {
                let target = fixture.root.appendingPathComponent("foreign-target")
                try content.write(to: target)
                try FileManager.default.createSymbolicLink(at: fixture.socketURL, withDestinationURL: target)
            } else {
                try content.write(to: fixture.socketURL)
            }
            do {
                _ = try await fixture.controller().ensureRunning()
                Issue.record("A foreign control path must be refused before starting a helper.")
            } catch APIRelayError.unexpectedService { }
            #expect(try Data(contentsOf: fixture.socketURL) == content)
            #expect(try fixture.socketURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == symlink)
            #expect(fixture.ownedRelayPIDs.isEmpty)
        }
    }
}

private func relayHTTP(_ address: String, post: Bool = false) async throws -> Int {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.connectionProxyDictionary = [:]
    configuration.timeoutIntervalForRequest = 3
    configuration.timeoutIntervalForResource = 5
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: URL(string: address)!)
    if post {
        request.httpMethod = "POST"
        request.httpBody = Data("{\"input\":\"synthetic-fixture\"}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    let (_, response) = try await session.data(for: request)
    return (response as? HTTPURLResponse)?.statusCode ?? 0
}

private func relayWait(_ condition: () async throws -> Bool) async throws {
    for _ in 0..<120 {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(25))
    }
    throw RelayFixtureFailure.timeout
}

private func withRelayFixture(_ operation: (RelayControllerFixture) async throws -> Void) async throws {
    let fixture = try await RelayControllerFixture.create()
    do { try await operation(fixture); await fixture.cleanup() }
    catch { await fixture.cleanup(); throw error }
}

private enum RelayFixtureFailure: Error { case timeout, invalidUpstream }

private final class RelayControllerFixture: @unchecked Sendable {
    let root: URL
    var directory: URL { root.appendingPathComponent("bridge") }
    var socketURL: URL { directory.appendingPathComponent("control.sock") }
    let upstream: Process
    let input: FileHandle
    let upstreamPort: Int
    private(set) var ownedRelayPIDs: Set<Int32> = []
    private var controllers: [APIRelayController] = []

    private init(root: URL, upstream: Process, input: FileHandle, upstreamPort: Int) {
        self.root = root; self.upstream = upstream; self.input = input; self.upstreamPort = upstreamPort
    }

    static func create() async throws -> RelayControllerFixture {
        // Short canonical Unix paths fit sockaddr_un; never use production 4141/4142.
        // Foundation can fold /private/tmp back to /tmp when resolving symlinks;
        // use the physical path directly so the helper rejects no ancestor.
        let temporary = URL(fileURLWithPath: "/private/tmp")
        let root = temporary.appendingPathComponent("relay-swift-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let source = root.appendingPathComponent("upstream.mjs")
        try Data(upstreamSource.utf8).write(to: source)
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = relayNode
        process.arguments = [source.path]
        process.environment = ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"]
        process.currentDirectoryURL = root
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let reader = LinePump(handle: output.fileHandleForReading)
        try process.run()
        guard let line = try await reader.next(),
              let value = try JSONSerialization.jsonObject(with: line) as? [String: Int],
              let port = value["port"], port > 0, port != 4141, port != 4142 else {
            if process.isRunning { process.terminate() }
            throw RelayFixtureFailure.invalidUpstream
        }
        output.fileHandleForReading.readabilityHandler = nil
        return RelayControllerFixture(root: root, upstream: process, input: input.fileHandleForWriting, upstreamPort: port)
    }

    func controller() -> APIRelayController {
        let controller = APIRelayController(directory: directory, nodeURL: relayNode, scriptURL: relayScript,
            listenPort: 0, testUpstreamPort: upstreamPort)
        controllers.append(controller)
        return controller
    }

    func record(_ state: APIRelayStatus) { ownedRelayPIDs.insert(state.pid) }
    func releaseStreams() { try? input.write(contentsOf: Data("release\n".utf8)) }

    func cleanup() async {
        releaseStreams()
        for controller in controllers {
            for _ in 0..<30 {
                do { _ = try await controller.shutdown(); break }
                catch APIRelayError.busy { try? await Task.sleep(for: .milliseconds(20)) }
                catch { break }
            }
        }
        // Signals are restricted to PIDs returned by newly created test helpers.
        for pid in ownedRelayPIDs where Darwin.kill(pid, 0) == 0 { _ = Darwin.kill(pid, SIGTERM) }
        try? input.write(contentsOf: Data("stop\n".utf8))
        try? input.close()
        for _ in 0..<100 {
            if !upstream.isRunning { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        if upstream.isRunning { upstream.terminate() }
        for _ in 0..<100 {
            if !upstream.isRunning { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        if upstream.isRunning { _ = Darwin.kill(upstream.processIdentifier, SIGKILL) }
        try? FileManager.default.removeItem(at: root)
    }

    private static let upstreamSource = """
    import http from 'node:http';
    import readline from 'node:readline';
    const held = new Set(), sockets = new Set();
    const server = http.createServer((request, response) => {
      request.on('end', () => {
        response.writeHead(200, {'content-type':'text/plain'});
        if (request.url.includes('hold=1')) {
          response.write('first'); held.add(response);
          response.on('close', () => held.delete(response));
        } else response.end('fixture');
      });
      request.resume();
    });
    server.on('connection', socket => { sockets.add(socket); socket.on('error',()=>{}); socket.on('close',()=>sockets.delete(socket)); });
    function release() { for (const response of held) response.end('last'); held.clear(); }
    function stop() { release(); for (const socket of sockets) socket.destroy(); server.close(()=>process.exit(0)); }
    const commands = readline.createInterface({input:process.stdin});
    commands.on('line', line => { if (line==='release') release(); if (line==='stop') stop(); });
    commands.on('close', stop);
    server.listen(0,'127.0.0.1',()=>console.log(JSON.stringify({port:server.address().port})));
    """
}
