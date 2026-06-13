# redot-evm
An implementation of EVM access in Redot, using a native implementation for non-web games, and using Metamask on web games.

## Client initialization

Create `AlephVault__EVM.Web3Client` and call `await client.initialize()` before
using chain, account, balance, transfer, request, or contract methods.
`initialize()` does not take a callback and returns `{"ok": true, "value":
null}` on success. Use `get_accounts()` when you need the account list.

On native builds, the Rust wallet must already be unlocked and have an account
and chain configured. The Godot binding caches the chain data and address
returned by Rust, then the public `initialize()` call still resolves with
`{"ok": true, "value": null}`. On web builds, initialization requests account
access from the injected EIP-1193 wallet.

Use `client.manages_wallet()` to check whether the active binding manages local
wallet/account material. Native bindings return `true`; web bindings return
`false` because account material stays inside the browser wallet.

Native wallet lifecycle:

- `account_create(password)` creates the single encrypted native account when
  no account is configured. The wallet remains locked afterwards.
- `account_restore(source_path)` restores an encrypted backup when no account
  is configured. The wallet remains locked afterwards and must be unlocked with
  the same password used by that keystore.
- `account_destroy()`, `account_backup(target_path)`, and
  `account_unlock(password)` require a configured but locked native account.
- `account_lock()` and `account_set_password(password)` require an unlocked
  native account. Locking also de-initializes the Godot binding cache.
- `set_chain(rpc_url)` can be called in any native wallet state. It accepts an
  HTTP(S) RPC URL, infers the chain id from `eth_chainId`, and keeps that chain
  configuration only in process memory. Call it again after process restart
  before native `initialize()`.

Native wallets expose only one account address. Private keys are generated,
encrypted, decrypted, and used for signing inside the Rust binding; GDScript
wrappers never receive them. Backups copy the encrypted keystore itself, so the
same password is required after restore. Web bindings return `not_supported`
for every native wallet lifecycle method.

## HTML5 exports

For web exports, add `addons/AlephVault.EVM/templates/html5/web3-head-include.html`
to the Web export preset's `Head Include` field, or copy it into a custom HTML
shell before the Godot engine starts.

The template initializes `window.web3 = new Web3(window.ethereum)` from an
injected EIP-1193 wallet provider so the web binding can access it through
Godot's `JavaScriptBridge`.
