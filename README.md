# Redot EVM

`redot-evm` provides EVM wallet and RPC access for Redot/Godot projects.

The public entry point is:

```gdscript
const EVM = AlephVault__EVM
var client := EVM.Web3Client.new()
```

The environment is detected automatically:

- HTML5/web builds use the web binding and an injected EIP-1193 browser wallet.
- Native builds use the Rust GDExtension binding and its local encrypted wallet.

You usually do not need to choose a binding manually. `Web3Client` checks `OS.has_feature("web")` and loads the correct implementation.

## Building The Rust Extension

The native binding lives in:

```text
addons/AlephVault.EVM/rust
```

Build the debug library used by the editor:

```sh
cd addons/AlephVault.EVM/rust
cargo build
```

Build the release library:

```sh
cd addons/AlephVault.EVM/rust
cargo build --release
```

The GDExtension manifest is:

```text
addons/AlephVault.EVM/AlephVault.EVM.gdextension
```

It maps platform targets to the Rust output files, for example:

```text
linux.debug.x86_64 = res://addons/AlephVault.EVM/rust/target/debug/libalephvault_evm_gdextension.so
linux.release.x86_64 = res://addons/AlephVault.EVM/rust/target/release/libalephvault_evm_gdextension.so
```

Use `cargo check` for a fast Rust validation pass:

```sh
cd addons/AlephVault.EVM/rust
cargo check
```

## HTML5 Setup

For web exports, add this file to the Web export preset's `Head Include` field:

```text
addons/AlephVault.EVM/templates/html5/web3-head-include.html
```

The template initializes `window.web3` from the injected browser wallet provider before the Godot engine starts. The web binding then accesses it through `JavaScriptBridge`.

## Basic Client Use

Create a `Web3Client`, initialize it, then call the supported methods:

```gdscript
var client := AlephVault__EVM.Web3Client.new()
var response = await client.initialize()
if not response.get("ok", false):
	push_error(str(response.get("error")))
	return

var accounts_response = await client.get_accounts()
var accounts: Array = accounts_response.get("value", [])
```

All API methods return dictionaries in this shape:

```gdscript
{"ok": true, "value": ...}
{"ok": false, "error": ...}
```

Some methods are asynchronous and should be called with `await`; synchronous methods can be called directly. When in doubt, using `await` on documented asynchronous methods keeps the call site explicit.

## Native Pre-Initialize Wallet Flow

Native builds require local wallet/account setup before `client.initialize()` can succeed. Use `AlephVault__EVM.UI.WalletModal` for that pre-initialize flow.

See the UI documentation:

[addons/AlephVault.EVM/ui/README.md](addons/AlephVault.EVM/ui/README.md)

Minimal setup:

```gdscript
var wallet_modal := AlephVault__EVM.UI.WalletModal.new()
wallet_modal.client = client
add_child(wallet_modal)

wallet_modal.started.connect(func(lock: Callable):
	# client.initialize() already succeeded inside the modal.
	# Store lock if the app needs to force the native wallet back to Welcome.
	_native_wallet_lock = lock
)

if client.manages_wallet():
	wallet_modal.show_from_scratch()
else:
	var response = await client.initialize()
```

`client.manages_wallet()` returns `true` for native bindings and `false` for web bindings.

## Hardhat Sample

The project main scene is:

```text
addons/AlephVault.EVM/samples/hardhat-sample.tscn
```

Its script is:

```text
addons/AlephVault.EVM/samples/hardhat_sample.gd
```

Use the values from your Hardhat project README to update these constants at the top of `hardhat_sample.gd`:

```gdscript
const HARDHAT_RPC_URL := "http://127.0.0.1:8545"
const DEV_ACCOUNT_ADDRESS := "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
const DEV_ACCOUNT_PRIVATE_KEY := "0xac0974..."
const SMPL_CONTRACT_ADDRESS := "0x5FbDB2315678afecb367f032d93F642f64180aa3"
const SMPL_ABI: Array[Dictionary] = [...]
```

`SMPL_CONTRACT_ADDRESS` matches the address documented by the included sample Hardhat project. `SMPL_ABI` is initialized with a minimal ERC-20 style ABI for `balanceOf`, `transfer`, and `Transfer`. If your deployment address changes, update `SMPL_CONTRACT_ADDRESS`. If your contract names or event signatures differ, replace `SMPL_ABI` with the ABI from your deployment output.

The sample UI includes:

- ETH balance query and ETH transfer.
- SMPL balance query and SMPL transfer through the contract helper API.
- Per-transaction event decoding after a mined SMPL transfer.
- A background `Transfer` event feed in a separate tab.
- `personal_sign` creation and verification.
- EIP-712 typed-data signature creation and verification.

Runtime behavior differs by target:

- Web exports call `client.initialize()` immediately and show the contract UI after the browser wallet grants account access.
- Native exports first show `AlephVault__EVM.UI.WalletModal`. Create, restore, or unlock the native wallet there; when the wallet starts successfully, the sample hides the modal and shows the contract UI.
- The native UI has a `Lock wallet` button. Locking hides the contract UI and reopens the wallet modal. Web deployments do not show this button because locking/unlocking is wallet-external there.

For native Hardhat testing with the provided dev key, create a text file containing `DEV_ACCOUNT_PRIVATE_KEY`, choose `Restore` in the wallet modal, then unlock with password `default`. This is intended only for local Hardhat development accounts.

## Supported Web3Client Methods

### Initialization And Accounts

```gdscript
await client.initialize()
await client.get_chain_id()
client.can_set_chain_id()
await client.set_chain_id(chain_id)
await client.get_accounts()
client.accounts_changed
client.chain_changed
```

`initialize()` requests account access on web. On native, the wallet must already be unlocked and configured, which is what `WalletModal` handles.

### RPC, Balance, And Transfers

```gdscript
await client.get_balance(address)
await client.transfer(address, amount, tx_config)
await client.wait_for(tx_hash)
await client.request(method, params)
```

`amount` is a decimal string denominated in wei. `tx_config` is a JSON-compatible dictionary. Common transaction keys include `from`, `value`, `gas`, `gasLimit`, `gasPrice`, `maxFeePerGas`, `maxPriorityFeePerGas`, `nonce`, `chainId`, `chain_id`, and `data`.

### Signing And Verification

```gdscript
await client.personal_sign(message, address)
await client.eth_sign_typed_data(typed_data, address)
client.recover_personal_sign(message, signature)
client.verify_personal_sign(address, message, signature)
client.recover_eth_sign_typed_data(typed_data, signature)
client.verify_eth_sign_typed_data(address, typed_data, signature)
```

`personal_sign()` and `eth_sign_typed_data()` are top-level helpers over `request()`. They do not add new binding methods for signing:

- `personal_sign(message, address = "")` calls `personal_sign` with `[message, address]`.
- `eth_sign_typed_data(typed_data, address = "")` calls `eth_signTypedData` with `[address, typed_data]`.

If `address` is empty, the helper uses the first account returned by `get_accounts()`. `message` can be a `String` or `PackedByteArray`; byte arrays are encoded as `0x`-prefixed hex strings before signing or verification.

Recovery and verification helpers are binding-backed. `recover_personal_sign()` and `recover_eth_sign_typed_data()` return `{"ok": true, "value": address}` with the recovered signer address. `verify_personal_sign()` and `verify_eth_sign_typed_data()` return `{"ok": true, "value": bool}` after comparing the recovered signer against the expected address.

`recover_personal_sign()` and `verify_personal_sign()` use the EIP-191/personal-sign message hash. `recover_eth_sign_typed_data()` and `verify_eth_sign_typed_data()` use the EIP-712 typed-data hash. Web typed-data recovery uses `web3.eth.accounts.recoverTypedSignature` when available, otherwise it falls back to the included `@metamask/eth-sig-util` helper. If neither helper is available, typed-data recovery and verification return `incomplete_binding`.

### ABI Utilities

```gdscript
client.set_abi(key, abi)
client.get_abi(key)
client.abi_encode(args)
client.abi_encode_packed(args)
client.abi_decode(bytes, spec)
```

ABI argument arrays can contain plain values or dictionaries like:

```gdscript
{"type": "uint256", "value": "1000000000000000000"}
```

### Data Utilities

```gdscript
client.keccak256(bytes)
client.from_wei(amount, unit)
client.to_wei(amount, unit)
client.from_hex(hex)
client.to_checksum_address(address)
client.to_hex(bytes)
client.decimal_to_hex(decimal)
client.hex_to_decimal(hex)
client.validate_block_tag(tag)
client.validate_uint(value, size)
client.validate_int(value, size)
client.validate_bytes(value, size)
client.validate_address(value, checksum)
```

### Native Wallet Lifecycle

These methods are intended for native bindings. Web bindings return `not_supported`.

```gdscript
client.manages_wallet()
client.account_exists()
await client.account_create(password)
await client.account_restore(source_path)
await client.account_unlock(password)
await client.account_backup(target_path)
client.account_destroy()
client.account_lock()
await client.account_set_password(password)
client.account_private_key()
await client.set_chain(rpc_url)
```

Native wallet notes:

- Native bindings manage one encrypted local account.
- Private keys only cross into GDScript when an unlocked wallet explicitly calls `account_private_key()`.
- `account_create(password)` creates the encrypted account and leaves it locked.
- `account_restore(source_path)` restores an encrypted backup and leaves it locked. It can also import a plain unencrypted private-key file in exactly these formats: a text file containing `0x...`, JSON containing `{"private_key": "0x..."}`, or JSON containing `{"privateKey": "0x..."}`. Plain imports validate the private key and create the encrypted wallet with password `default`.
- `account_unlock(password)` unlocks the wallet. Call `initialize()` afterwards.
- `account_lock()` locks the wallet and clears the initialized binding state.
- `account_set_password(password)` requires an unlocked wallet.
- `account_private_key()` requires an unlocked wallet and returns the private key as `0x`-prefixed hex.
- `set_chain(rpc_url)` is awaitable, probes `eth_chainId`, accepts an HTTP(S) RPC URL, and keeps the chain configuration in process memory.

### Contract Helpers

```gdscript
client.contract_create(address, abi_key)
await client.contract_invoke(address, method, params, tx_params)
await client.contract_get_events(address, event, topics, from, to)
client.contract_get_tx_events(tx_obj, event)
```

`method` and `event` can be a name or an ABI dictionary. Contract view calls may include `block` or `blockTag` in `tx_params`.

## UI Components

The UI namespace exposes:

```gdscript
AlephVault__EVM.UI.Modal
AlephVault__EVM.UI.ModalStep
AlephVault__EVM.UI.WalletModal
```

See [addons/AlephVault.EVM/ui/README.md](addons/AlephVault.EVM/ui/README.md) for modal step layout, theming, and `WalletModal` setup.
