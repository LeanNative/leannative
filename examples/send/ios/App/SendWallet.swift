import Foundation
import WalletCore

/// The WalletCore half of the Send app's host: what each command does to the wallet, with no UI and no
/// authentication, so the same code runs in the iOS app (`WalletHost`) and in the headless host test
/// (`examples/send/hosttest`). TRUSTED, not proven: the Lean proofs say what the app does with these
/// answers; this file is what makes the answers true. It follows Winnow's wallet path
/// (`AppModel.previewSend`, then `AppModel.send(preview:)`: `Wallet.buildSend`, broadcast, `commit`).
actor SendWallet {
    let wallet: Wallet
    let network: BitcoinNetwork
    let chainTip: UInt32
    /// Signed but not yet broadcast sends, by draft id (Winnow commits only after the broadcaster has the transaction).
    private var prepared: [Int: Wallet.PreparedSend] = [:]

    init(wallet: Wallet, network: BitcoinNetwork, chainTip: UInt32) {
        self.wallet = wallet
        self.network = network
        self.chainTip = chainTip
    }

    var balance: Int64 { get async { await wallet.balance } }

    static func feeRate(_ p: Priority) -> Double {
        switch p {
        case .low: return FeePolicy.resolve(priority: .low)
        case .medium: return FeePolicy.resolve(priority: .medium)
        case .high: return FeePolicy.resolve(priority: .high)
        }
    }

    static func outpointText(_ o: Transaction.Outpoint) -> String {
        Data(o.txid.reversed()).hex + ":" + String(o.vout)
    }

    /// `Cmd.preview`: Winnow's `previewSend` on the wallet path (address decoding, fee rate, coin selection).
    func preview(_ id: Int, _ entry: Entry) async -> HostMsg {
        let destination = entry.destination.trimmingCharacters(in: .whitespacesAndNewlines)
        let amountText = entry.amount.trimmingCharacters(in: .whitespacesAndNewlines)
        // Plain digits only: the app checks that the reviewed amount prints as exactly what was typed.
        guard !amountText.isEmpty, amountText.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }),
              !(amountText.count > 1 && amountText.hasPrefix("0")),
              let amount = Int64(amountText), amount > 0, amount <= BitcoinAmount.maximum
        else { return .previewFailed(id, "Enter the amount in sats, digits only.") }
        // Winnow resolves a Double rate; the draft carries it in thousandths so that signing rebuilds with the same rate.
        let milli = Int((Self.feeRate(entry.priority) * 1_000).rounded())
        let rate = Double(milli) / 1_000
        do {
            let payment = try Payment(amount: amount, address: destination, network: network)
            let utxos = await wallet.spendableUtxos
            let changeIndex = await wallet.nextChangeIndex
            let changeScript = try await wallet.scriptPubKey(chain: .change, index: changeIndex)
            let selection = try CoinSelection.select(utxos: utxos, payments: [payment],
                                                     changeScriptPubKey: changeScript, feeRateSatPerVByte: rate)
            return .previewReady(Draft(
                id: id, form: entry, destination: destination, script: payment.scriptPubKey.hex,
                amount: Int(amount), fee: Int(selection.fee), feeRateMilli: milli,
                feeRateText: "\(rate.formatted(.number.precision(.fractionLength(0...3)))) sat/vB",
                change: selection.changeAmount.map { Out(value: Int($0), script: changeScript.hex) },
                inputs: selection.selected.map { Self.outpointText($0.outpoint) }))
        } catch {
            return .previewFailed(id, "\(error)")
        }
    }

    /// `Cmd.sign` after authentication: Winnow's `buildSend`, which rebuilds the transaction from scratch
    /// and signs it, and a summary read from the signed transaction (its outputs and inputs, and the fee as
    /// the value of the coins it spends, from the wallet's own coin set, minus the value of its outputs).
    func sign(_ d: Draft) async -> HostMsg {
        guard let script = Data(hex: d.script) else { return .signFailed(d.id, "The draft's script is not hex.") }
        do {
            let utxos = await wallet.spendableUtxos
            let built = try await wallet.buildSend(payments: [Payment(amount: Int64(d.amount), scriptPubKey: script)],
                                                   feeRateSatPerVByte: Double(d.feeRateMilli) / 1_000,
                                                   chainTip: chainTip)
            prepared[d.id] = built
            let tx = built.built.transaction
            var spent: Int64 = 0
            for input in tx.inputs {
                guard let coin = utxos.first(where: { $0.outpoint == input.previousOutput }) else {
                    return .signFailed(d.id, "The signed transaction spends a coin the wallet does not have.")
                }
                spent += coin.amount
            }
            let paid = tx.outputs.reduce(Int64(0)) { $0 + $1.value }
            return .signed(Signed(
                draftId: d.id, fee: Int(spent - paid), changeAmount: built.built.changeAmount.map { Int($0) },
                outputs: tx.outputs.map { Out(value: Int($0.value), script: $0.scriptPubKey.hex) },
                inputs: tx.inputs.map { Self.outpointText($0.previousOutput) },
                txid: Data(tx.txid.reversed()).hex,
                raw: tx.serialized(includeWitness: true).hex))
        } catch {
            return .signFailed(d.id, "\(error)")
        }
    }

    /// `Cmd.broadcast`: simulated (the demo wallet has no peers), then Winnow's `commit`.
    func broadcast(_ id: Int, _ raw: String) async -> HostMsg {
        guard let send = prepared[id] else { return .broadcastFailed(id, "Nothing was signed for this payment.") }
        let tx = send.built.transaction
        guard tx.serialized(includeWitness: true).hex == raw else {
            return .broadcastFailed(id, "That is not the transaction that was signed.")
        }
        do {
            try await wallet.commit(send)
        } catch {
            return .broadcastFailed(id, "\(error)")
        }
        prepared[id] = nil
        return .broadcasted(id, Data(tx.txid.reversed()).hex)
    }
}
