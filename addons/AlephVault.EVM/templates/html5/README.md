# AlephVault.EVM HTML5 Template

Use `web3-head-include.html` in the Web export preset's `Head Include` field,
or copy its contents into a custom HTML shell before the Godot engine starts.

The snippet loads `web3.js` and initializes from an injected browser wallet:

```js
window.web3 = new Web3(window.ethereum);
```

If no wallet is injected, the include can initialize a read-only RPC provider
instead. Configure it from GDScript before calling `initialize()`:

```gdscript
var client = AlephVault__EVM.Web3Client.new()
var chain_response = client.set_read_only_rpc_url("https://your-evm-rpc.example")
if chain_response.get("ok", false):
	await client.initialize()
```

On web, `set_read_only_rpc_url()` sets the browser helper's read-only RPC URL.
On native/Rust bindings it returns `{"ok": false, "error": "not_supported"}`.
For custom HTML shells, the helper also exposes
`window.alephVaultEvmSetReadOnlyRpcUrl(url)` and still honors
`window.alephVaultEvmReadOnlyRpcUrl` if it is defined before the include runs.
Use `client.is_read_only()` after initialization to check whether the active
binding is the read-only fallback. Native/Rust bindings always return `false`.

In that mode `Web3Client.initialize()` succeeds with an empty account list.
Read-only operations such as `get_chain_id()`, `get_balance()`, contract
view/pure calls, event queries, and read-only JSON-RPC requests can run through
the RPC endpoint. Signing methods, wallet methods, chain switching,
`transfer()`, `eth_send_transaction()`, and non-view contract invocations fail
with `read_only`.

The bundled include currently pins Web3.js to `1.10.4` and
`@metamask/eth-sig-util` to `8.2.0`. The web binding helper code is written
against the Web3 1.x API surface, including `web3.eth.Contract`,
`web3.eth.abi`, `web3.utils.toBN`, and PromiEvent transaction handling.
MetaMask's signature utility is used as a fallback for EIP-712 typed-data
signature recovery when Web3's optional typed-data recovery helper is absent.

That gives Godot's `JavaScriptBridge` a stable browser global to call from the
web binding. If the wallet injects `window.ethereum` after the first script pass,
the snippet retries on the standard `ethereum#initialized` browser event and on
page load. It also exposes `window.alephVaultEvmInitWeb3()` so the binding can
retry explicitly before making Web3 calls. If a wallet appears later, the helper
prefers the wallet over the read-only RPC provider on the next initialization
attempt.

It also exposes `window.alephVaultEvmProcessAsync(promise, callback)`. The web
binding uses it to attach `then`/`catch` handlers to JavaScript promises, assign
request ids, and forward a JSON result back to Godot.

The web helper also owns the binding-side caches:

- `window.alephVaultEvmAbiCache` stores ABIs registered with `set_abi`.
- `window.alephVaultEvmContractCache` stores `web3.eth.Contract` instances
  created with `contract_create`.

The Godot binding only calls into these helpers. ABI lookup, contract instance
reuse, method resolution, event decoding, and event filtering are handled in the
JavaScript side so cached Web3 objects never need to cross the JavaScriptBridge
boundary.

The include also exposes `recoverPersonalSign`, `recoverEthSign`,
`recoverTypedData`, and `recoverSentTransaction` helpers used by the
`Web3Client` recovery methods. The recover helpers return the recovered signer
or sender address; `Web3Client` implements verification as a thin address
comparison over those recovery methods. Typed-data recovery uses
`web3.eth.accounts.recoverTypedSignature` when available, otherwise it falls
back to `@metamask/eth-sig-util`. `recoverSentTransaction` is asynchronous and
uses `web3.eth.getTransaction(txHash)` to return the submitted transaction's
`from` address.

For production builds, consider self-hosting the pinned Web3 and
`@metamask/eth-sig-util` assets instead of depending on the CDN at runtime.
