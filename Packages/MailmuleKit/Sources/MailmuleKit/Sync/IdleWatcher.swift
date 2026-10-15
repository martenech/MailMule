import Foundation

/// Keeps a dedicated IMAP connection idling on INBOX and calls `onChange` whenever the server
/// reports new or changed mail. Reconnects with backoff after errors (sleep, network changes).
public actor IdleWatcher {
    public nonisolated let account: Account
    private let password: String
    private let onChange: @Sendable () async -> Void
    private let onError: @Sendable (String) async -> Void
    private var loop: Task<Void, Never>?
    private var current: IMAPClient?

    public init(account: Account, password: String,
                onChange: @escaping @Sendable () async -> Void,
                onError: @escaping @Sendable (String) async -> Void = { _ in }) {
        self.account = account
        self.password = password
        self.onChange = onChange
        self.onError = onError
    }

    public func start() {
        guard loop == nil else { return }
        loop = Task { await run() }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
        // Closing the socket ends a pending IDLE read right away.
        if let current {
            self.current = nil
            Task { await current.disconnect() }
        }
    }

    /// Drops the current connection and reconnects right away (e.g. after the Mac wakes up).
    public func restart() {
        stop()
        start()
    }

    private func run() async {
        var backoff: Duration = .seconds(5)
        while !Task.isCancelled {
            let client = IMAPClient(host: account.imapHost, port: account.imapPort, username: account.username, password: password,
                                security: account.imapSecurity)
            current = client
            do {
                try await client.connect()
                guard await client.supportsIdle else {
                    // Without IDLE the periodic sync is all we can do.
                    await client.disconnect()
                    return
                }
                backoff = .seconds(5)
                while !Task.isCancelled {
                    if try await client.idle(in: "INBOX") {
                        await onChange()
                    }
                }
                await client.disconnect()
            } catch {
                await client.disconnect()
                guard !Task.isCancelled else { return }
                await onError("\(error.localizedDescription)")
                try? await Task.sleep(for: backoff)
                backoff = min(backoff * 2, .seconds(300))
            }
        }
    }
}
