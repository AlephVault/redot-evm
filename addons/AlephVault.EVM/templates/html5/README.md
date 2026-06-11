# AlephVault.EVM HTML5 Template

Use `web3-head-include.html` in the Web export preset's `Head Include` field,
or copy its contents into a custom HTML shell before the Godot engine starts.

The snippet loads `web3.js` and initializes:

```js
window.web3 = new Web3(window.ethereum);
```

That gives Godot's `JavaScriptBridge` a stable browser global to call from the
web binding. If the wallet injects `window.ethereum` after the first script pass,
the snippet retries on the standard `ethereum#initialized` browser event and on
page load. It also exposes `window.alephVaultEvmInitWeb3()` so the binding can
retry explicitly before making Web3 calls.

For production builds, consider self-hosting the pinned `web3.min.js` asset
instead of depending on the CDN at runtime.
