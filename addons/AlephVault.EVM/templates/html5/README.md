# AlephVault.EVM HTML5 Template

Use `web3-head-include.html` in the Web export preset's `Head Include` field,
or copy its contents into a custom HTML shell before the Godot engine starts.

The snippet loads `web3.js` and initializes:

```js
window.web3 = new Web3(window.ethereum);
```

The bundled include currently pins Web3.js to `1.10.4`. The web binding helper
code is written against the Web3 1.x API surface, including
`web3.eth.Contract`, `web3.eth.abi`, `web3.utils.toBN`, and PromiEvent
transaction handling.

That gives Godot's `JavaScriptBridge` a stable browser global to call from the
web binding. If the wallet injects `window.ethereum` after the first script pass,
the snippet retries on the standard `ethereum#initialized` browser event and on
page load. It also exposes `window.alephVaultEvmInitWeb3()` so the binding can
retry explicitly before making Web3 calls.

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

For production builds, consider self-hosting the pinned `web3.min.js` asset
instead of depending on the CDN at runtime.
