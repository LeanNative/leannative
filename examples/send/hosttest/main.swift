// The Send example's host test: the generated app driven exactly as `Store` drives it (commands computed
// from the pre-state, each answered by the host and fed back through `SendApp.host`), with the iOS app's
// `SendWallet` answering against Winnow's WalletCore, minus authentication. Then the checks a lying or
// buggy host would fail: every tampered signed summary is refused and nothing is broadcast.
import Foundation
import WalletCore
import TestSupport

var passed = 0
func check(_ cond: Bool, _ what: String) {
    if !cond { print("FAIL: \(what)"); exit(1) }
    passed += 1
    print("ok: \(what)")
}

final class Driver {
    var model = SendApp.initial
    var commands: [Cmd] = []
    let wallet: SendWallet
    init(_ wallet: SendWallet) { self.wallet = wallet }

    func send(_ msg: Msg) async {
        let cs = SendApp.cmds(msg, model)        // the pre-state, as Store.send and Session.step
        model = SendApp.update(msg, model)
        commands += cs
        for c in cs {
            let answer: HostMsg
            switch c {
            case .preview(let id, let entry): answer = await wallet.preview(id, entry)
            case .sign(let d): answer = await wallet.sign(d)
            case .broadcast(let id, let raw): answer = await wallet.broadcast(id, raw)
            }
            await send(SendApp.host(answer))
        }
    }

    func pay(_ address: String, _ amount: String, _ priority: Priority = .medium) async {
        await send(.setDestination(address))
        await send(.setAmount(amount))
        await send(.setPriority(priority))
        await send(.review)
    }
}

let (w, _) = try await fundedWallet(network: .signet, coins: [(.receive, 0, 300_000, 100), (.receive, 1, 200_000, 101)])
let to = try await w.address(chain: .receive, index: 7)
let wallet = SendWallet(wallet: w, network: .signet, chainTip: testChainTip)

// 1. a payment from one coin, end to end
let one = Driver(wallet)
await one.pay(to, "25000")
guard case .review(let d1) = one.model.screen else { print("FAIL: no review: \(one.model.screen)"); exit(1) }
check(d1.amount == 25000 && d1.destination == to && d1.inputs.count == 1, "the draft shows what was typed and spends one coin")
let fee1 = d1.fee
await one.send(.approve)
guard case .sent(let s1, let txid1) = one.model.screen else { print("FAIL: not sent: \(one.model.screen)"); exit(1) }
check(s1.id == d1.id && txid1.count == 64, "approve → sign → authorizes → broadcast → sent (txid \(txid1.prefix(16))…)")
check(one.commands.filter { if case .sign = $0 { return true } else { return false } }.count == 1, "exactly one signing request")
check(await w.balance == 500_000 - 25_000 - Int64(fee1), "the wallet committed exactly the reviewed amount and fee")

// 2. a payment that needs both coins
let two = Driver(wallet)
await two.pay(to, "350000", .high)
guard case .review(let d2) = two.model.screen else { print("FAIL: no review: \(two.model.screen)"); exit(1) }
check(d2.inputs.count == 2, "a larger payment spends two coins")
await two.send(.approve)
guard case .sent = two.model.screen else { print("FAIL: not sent: \(two.model.screen)"); exit(1) }
check(true, "the two-coin payment was signed, matched and broadcast")

// 3. the check before broadcast: every tampered summary is refused, with no broadcast command
let fresh = SendWallet(wallet: try await fundedWallet(network: .signet).wallet, network: .signet, chainTip: testChainTip)
let three = Driver(fresh)
await three.pay(to, "40000")
guard case .review(let d3) = three.model.screen else { print("FAIL: no review"); exit(1) }
let pre = SendApp.update(.approve, three.model)              // signing d3, as after approval
guard case .signed(let honest) = await fresh.sign(d3) else { print("FAIL: sign"); exit(1) }
check(SendApp.authorizes(d3, honest), "the honest summary authorizes the draft")
var lies: [(String, Signed)] = []
var s = honest; s.outputs[0].value += 1; lies.append(("an output one sat larger", s))
s = honest; s.outputs.append(Out(value: 546, script: d3.script)); lies.append(("an extra output", s))
s = honest; s.outputs = s.outputs.map { $0.script == d3.script ? Out(value: $0.value, script: String($0.script.dropLast(2)) + "00") : $0 }
lies.append(("the payment to another script", s))
s = honest; s.fee += 1; lies.append(("a different fee", s))
s = honest; s.changeAmount = nil; lies.append(("no change", s))
s = honest; s.inputs = [String(s.inputs[0].dropLast()) + "9"]; lies.append(("a different coin", s))
s = honest; s.draftId += 1; lies.append(("another draft", s))
for (what, lie) in lies {
    let cs = SendApp.cmds(.host(.signed(lie)), pre)
    let after = SendApp.update(.host(.signed(lie)), pre)
    let refused: Bool
    switch after.screen { case .failed, .signing: refused = true; default: refused = false }
    check(cs.isEmpty && refused, "refused: \(what)")
}
check(!SendApp.cmds(.host(.signed(honest)), pre).isEmpty, "while the honest summary is broadcast")

print("host test OK (\(passed) checks; WalletCore preview, buildSend and commit through the generated app)")
