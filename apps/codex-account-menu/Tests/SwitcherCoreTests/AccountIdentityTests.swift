import Foundation
import Testing
@testable import SwitcherCore

struct AccountIdentityTests {
    private let alice = AccountProfile(id: UUID(), displayName: "Alice", email: "alice@example.test",
        accountID: "shared-workspace", createdAt: Date())

    @Test func equalAccountIDDoesNotMaskAConcreteEmailConflict() {
        #expect(!AccountIdentity(accountID: alice.accountID, email: "bob@example.test").matches(alice))
        #expect(AccountIdentity(accountID: alice.accountID, email: "ALICE@example.test").matches(alice))
        #expect(!AccountIdentity(accountID: "other-workspace", email: alice.email).matches(alice))
        #expect(!AccountIdentity(accountID: alice.accountID, email: nil).matches(alice))
        #expect(!AccountIdentity(accountID: alice.accountID, email: " ").matches(alice))
    }

    @Test(arguments: [nil, "", "bob@example.test"] as [String?])
    func localOAuthRejectsMissingOrConflictingEmail(_ email: String?) throws {
        let bytes = syntheticOAuthCredential(accountID: "shared-workspace", email: email)
        #expect(throws: AccountStoreError.self) { try validateOAuthCredential(bytes, matching: alice) }
    }

    @Test func localOAuthRejectsMalformedJWTAndConflictingAccountClaim() throws {
        var object = try JSONSerialization.jsonObject(with: syntheticOAuthCredential(
            accountID: "shared-workspace", email: alice.email)) as! [String: Any]
        var tokens = object["tokens"] as! [String: String]
        for token in ["opaque-not-a-jwt", syntheticIDToken(email: alice.email, accountID: "different-workspace")] {
            tokens["id_token"] = token
            object["tokens"] = tokens
            let bytes = try JSONSerialization.data(withJSONObject: object)
            #expect(throws: AccountStoreError.self) { try validateOAuthCredential(bytes, matching: alice) }
        }
        try validateOAuthCredential(syntheticOAuthCredential(accountID: "shared-workspace", email: "ALICE@example.test"), matching: alice)
    }

    @Test func importingAnotherUserWithTheSameAccountIDPreservesTheFirstCredential() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("identity-binding-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let store = AccountStore(baseURL: root.appendingPathComponent("store"), activeHomeURL: home)
        let auth = home.appendingPathComponent("auth.json")
        let aliceBytes = syntheticOAuthCredential(accountID: "shared-workspace", email: alice.email, tag: "alice")
        try aliceBytes.write(to: auth)
        try await store.registerActiveIdentity(AccountIdentity(accountID: alice.accountID, email: alice.email))
        let first = try #require(try await store.loadRegistry().accounts.first)
        let bobBytes = syntheticOAuthCredential(accountID: "shared-workspace", email: "bob@example.test", tag: "bob")
        try bobBytes.write(to: auth, options: .atomic)
        await #expect(throws: AccountStoreError.self) { try await store.saveCurrentCredential() }
        try await store.registerActiveIdentity(AccountIdentity(accountID: "shared-workspace", email: "bob@example.test"))
        let registry = try await store.loadRegistry()
        #expect(registry.accounts.count == 2)
        #expect(registry.activeAccountID != first.id)
        #expect(try Data(contentsOf: await store.profileHome(id: first.id).appendingPathComponent("auth.json")) == aliceBytes)
        let active = try #require(registry.activeAccountID)
        #expect(try Data(contentsOf: await store.profileHome(id: active).appendingPathComponent("auth.json")) == bobBytes)
    }
}
