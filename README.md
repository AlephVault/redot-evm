# redot-evm
An implementation of EVM access in Redot, using a native implementation for non-web games, and using Metamask on web games.

## Client initialization

Create `AlephVault__EVM.Web3Client` and call `await client.initialize()` before
using chain, account, balance, transfer, request, or contract methods.
`initialize()` does not take a callback and returns `{"ok": true, "value":
null}` on success. Use `get_accounts()` when you need the account list.

On native builds, the Rust native wallet currently returns a temporary
configuration to the Godot binding:

- Chain id: `1` (Ethereum mainnet)
- RPC URL: `https://ethereum-json-rpc.stakely.io`
- Accounts: `[]`

The Godot binding caches that returned data internally, then the public
`initialize()` call still resolves with `{"ok": true, "value": null}`. This
means native read-only RPC and contract calls can be made after initialization,
while signing or transfers require a future account/private-key source to
provide accounts. On web builds, initialization requests account access from the
injected EIP-1193 wallet.

Use `client.manages_wallet()` to check whether the active binding manages local
wallet/account material. Native bindings return `true`; web bindings return
`false` because account material stays inside the browser wallet.

## HTML5 exports

For web exports, add `addons/AlephVault.EVM/templates/html5/web3-head-include.html`
to the Web export preset's `Head Include` field, or copy it into a custom HTML
shell before the Godot engine starts.

The template initializes `window.web3 = new Web3(window.ethereum)` from an
injected EIP-1193 wallet provider so the web binding can access it through
Godot's `JavaScriptBridge`.
