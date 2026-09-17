import Foundation
import Testing
@testable import SwitcherCore

struct AccountStoreBindingTests {
    @Test func secondHomeCannotChangeTheFirstAccountOrCredential() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let first = AccountStore(baseURL: f.base, activeHomeURL: f.home)
        let credential = syntheticOAuthCredential(accountID: "A", email: "a@example.test")
        try credential.write(to: f.home.appendingPathComponent("auth.json"))
        try await first.registerActiveIdentity(AccountIdentity(accountID: "A", email: "a@example.test"))
        let registry = try Data(contentsOf: f.base.appendingPathComponent("accounts.json"))
        let marker = try Data(contentsOf: f.marker)
        let other = AccountStore(baseURL: f.base, activeHomeURL: f.root.appendingPathComponent("other"))
        await #expect(throws: AccountStoreBindingError.differentHome) { _ = try await other.loadRegistry() }
        await #expect(throws: AccountStoreBindingError.differentHome) { try await other.clearActiveCredential() }
        #expect(try Data(contentsOf: f.base.appendingPathComponent("accounts.json")) == registry)
        #expect(try Data(contentsOf: f.marker) == marker)
        #expect(try Data(contentsOf: f.home.appendingPathComponent("auth.json")) == credential)
        try await first.saveCurrentCredential()
    }

    @Test func pathAliasesShareAnIdempotentBinding() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let alias = f.root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.home)
        _ = try await AccountStore(baseURL: f.base, activeHomeURL: f.home).loadRegistry()
        let before = try SourceFileSnapshot.read(f.marker)
        _ = try await AccountStore(baseURL: f.base, activeHomeURL: alias).loadRegistry()
        try before.requireUnchanged()
        let permissions = try FileManager.default.attributesOfItem(atPath: f.marker.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    @Test func existingUnboundCustomStateIsPreservedAndRejected() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let registry = f.base.appendingPathComponent("accounts.json")
        let bytes = Data("legacy private state".utf8)
        try bytes.write(to: registry)
        await #expect(throws: AccountStoreBindingError.unboundExistingStore) {
            _ = try await AccountStore(baseURL: f.base, activeHomeURL: f.home).loadRegistry()
        }
        #expect(try Data(contentsOf: registry) == bytes)
        #expect(!FileManager.default.fileExists(atPath: f.marker.path))
    }

    @Test func explicitlyRecognizedLegacyStoreCanBindWithoutChangingItsFiles() throws {
        let f = try Fixture()
        defer { f.clean() }
        let registry = f.base.appendingPathComponent("accounts.json")
        let bytes = Data("legacy private state".utf8)
        try bytes.write(to: registry)
        try AccountStoreBinding.ensure(base: f.base, home: f.home, allowExistingUnbound: true)
        #expect(try Data(contentsOf: registry) == bytes)
        #expect(throws: AccountStoreBindingError.differentHome) {
            try AccountStoreBinding.ensure(base: f.base, home: f.root, allowExistingUnbound: true)
        }
    }

    @Test func defaultStoreRejectsACustomHomeBeforeTouchingRealState() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let defaultStore = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Codex Account Menu")
        // The check is before all reads/writes of the default state directory.
        await #expect(throws: AccountStoreBindingError.differentHome) {
            _ = try await AccountStore(baseURL: defaultStore, activeHomeURL: f.home).loadRegistry()
        }
    }

    @Test func bindingIsRecheckedAfterItChangesOrDisappears() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let store = AccountStore(baseURL: f.base, activeHomeURL: f.home)
        _ = try await store.loadRegistry()
        try Data("broken".utf8).write(to: f.marker)
        await #expect(throws: AccountStoreBindingError.invalidBinding) { _ = try await store.loadRegistry() }
        try FileManager.default.removeItem(at: f.marker)
        await #expect(throws: AccountStoreBindingError.unboundExistingStore) { _ = try await store.loadRegistry() }
    }

    @Test func symlinkBindingCannotOverwriteItsTarget() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let target = f.root.appendingPathComponent("unrelated")
        try Data("preserve".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: f.marker, withDestinationURL: target)
        await #expect(throws: SourceFileError.self) {
            _ = try await AccountStore(baseURL: f.base, activeHomeURL: f.home).loadRegistry()
        }
        #expect(try Data(contentsOf: target) == Data("preserve".utf8))
    }

    @Test func twoHomesRacingForAnEmptyStoreHaveOnlyOneWinner() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let homes = [f.home, f.root.appendingPathComponent("other")]
        let winners = await withTaskGroup(of: Int?.self, returning: [Int].self) { group in
            for (index, home) in homes.enumerated() {
                group.addTask {
                    do {
                        _ = try await AccountStore(baseURL: f.base, activeHomeURL: home).loadRegistry()
                        return index
                    } catch { return nil }
                }
            }
            var results: [Int] = []
            for await result in group { if let result { results.append(result) } }
            return results
        }
        let winner = try #require(winners.first)
        #expect(winners.count == 1)
        _ = try await AccountStore(baseURL: f.base, activeHomeURL: homes[winner]).loadRegistry()
        await #expect(throws: AccountStoreBindingError.differentHome) {
            _ = try await AccountStore(baseURL: f.base, activeHomeURL: homes[1 - winner]).loadRegistry()
        }
    }

    private struct Fixture: Sendable {
        let root: URL, base: URL, home: URL, marker: URL
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("store-binding-test-\(UUID())")
            base = root.appendingPathComponent("store")
            home = root.appendingPathComponent("home")
            marker = base.appendingPathComponent(AccountStoreBinding.filename)
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        }
        func clean() { try? FileManager.default.removeItem(at: root) }
    }
}
