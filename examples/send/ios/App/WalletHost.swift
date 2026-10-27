import Foundation
import LocalAuthentication
import WalletCore
import TestSupport

/// The host of the Send app on iOS: authenticates the owner before signing (Winnow's
/// `authenticateSensitiveAction`) and otherwise hands each command to `SendWallet`. TRUSTED, not proven.
///
/// The wallet is Winnow's test fixture: the all-zero test mnemonic on signet, funded with two coins,
/// in memory, with no peers. Broadcast is simulated: the transaction is committed to the wallet's
/// state as Winnow does after handing it to the broadcaster, but it never leaves the device.
@MainActor
final class WalletHost: CmdHost {
    typealias App = SendApp

    static let disclosure = "Demo wallet: Winnow's test-mnemonic signet wallet with two coins, in memory and offline. "
        + "Previews and signatures are real WalletCore calls; broadcasting is simulated."

    private var wallet: SendWallet?
    private weak var store: Store<SendApp>?

    func start(_ store: Store<SendApp>) async {
        self.store = store
        do {
            // key derivation is slow in a debug build: keep it off the main actor
            let w = try await Task.detached {
                try await fundedWallet(network: .signet, coins: [
                    (.receive, 0, 300_000, 100), (.receive, 1, 200_000, 101),
                ]).wallet
            }.value
            wallet = SendWallet(wallet: w, network: .signet, chainTip: testChainTip)
            await reportBalance()
        } catch {
            store.hostSays(.balance("Wallet unavailable: \(error.localizedDescription)"))
        }
    }

    private func reportBalance() async {
        guard let w = wallet else { return }
        store?.hostSays(.balance("\(await w.balance) sats available"))
    }

    func run(_ cmd: Cmd) async -> HostMsg {
        guard let w = wallet else {
            switch cmd {
            case .preview(let id, _): return .previewFailed(id, "The wallet is not ready.")
            case .sign(let d): return .signFailed(d.id, "The wallet is not ready.")
            case .broadcast(let id, _): return .broadcastFailed(id, "The wallet is not ready.")
            }
        }
        switch cmd {
        case .preview(let id, let entry):
            return await w.preview(id, entry)
        case .sign(let d):
            if let failure = await authenticate("Send \(d.amount) sats to \(d.destination)") {
                return .signFailed(d.id, failure)
            }
            return await w.sign(d)
        case .broadcast(let id, let raw):
            let answer = await w.broadcast(id, raw)
            await reportBalance()
            return answer
        }
    }

    /// Device-owner authentication (Face ID, Touch ID or the passcode); nil when it passed.
    private func authenticate(_ reason: String) async -> String? {
        let context = LAContext()
        var unavailable: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &unavailable) else {
            #if targetEnvironment(simulator)
            return nil   // a simulator with no passcode set: nothing to check against (stated in the README)
            #else
            return "Set a device passcode to send payments."
            #endif
        }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
                ? nil : "Authentication failed."
        } catch {
            return error.localizedDescription
        }
    }
}
