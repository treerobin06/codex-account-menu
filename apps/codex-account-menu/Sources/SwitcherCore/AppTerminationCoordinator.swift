import AppKit

/// All normal AppKit quit routes share the same asynchronous preparation.
@MainActor
public final class AppTerminationCoordinator {
    private var preparing = false
    private let isBusy: () -> Bool
    private let prepare: () async -> Bool

    public init(isBusy: @escaping () -> Bool, prepare: @escaping () async -> Bool) {
        self.isBusy = isBusy
        self.prepare = prepare
    }

    public func request(reply: @escaping (Bool) -> Void) -> NSApplication.TerminateReply {
        if preparing { return .terminateLater }
        guard !isBusy() else { return .terminateCancel }
        preparing = true
        Task {
            let ready = await prepare()
            preparing = false
            reply(ready)
        }
        return .terminateLater
    }
}
