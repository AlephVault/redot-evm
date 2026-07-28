# Redot EVM

`redot-evm` is a Redot/Godot project that packages EVM wallet and RPC access as the `AlephVault.EVM` addon.

The addon lives in:

```text
addons/AlephVault.EVM
```

For the package-level technical reference, including build instructions, HTML5 setup, wallet lifecycle, supported `Web3Client` methods, contract helpers, and UI components, see:

[addons/AlephVault.EVM/README.md](addons/AlephVault.EVM/README.md)

## Overview

The public entry point is:

```gdscript
const EVM = AlephVault__EVM
var client := EVM.Web3Client.new()
```

`Web3Client` chooses the correct binding automatically:

- HTML5/web builds use the web binding and an injected EIP-1193 browser wallet.
- Native builds use the Rust GDExtension binding and its local encrypted wallet.

You usually do not need to choose a binding manually. `Web3Client` checks `OS.has_feature("web")` and loads the correct implementation.

## Basic Usage

Create and initialize a client:

```gdscript
var client := AlephVault__EVM.Web3Client.new()
var response = await client.initialize()
if not response.get("ok", false):
	push_error(str(response.get("error")))
	return

var accounts_response = await client.get_accounts()
var accounts: Array = accounts_response.get("value", [])
```

All public API methods return dictionaries in this shape:

```gdscript
{"ok": true, "value": ...}
{"ok": false, "error": ...}
```

Query a balance and send ETH:

```gdscript
var balance_response = await client.get_balance(accounts[0])
if balance_response.get("ok", false):
	print("Balance in wei: ", balance_response.get("value"))

var tx_response = await client.transfer(
	"0x0000000000000000000000000000000000000001",
	"1000000000000000",
	{"from": accounts[0]}
)
```

Call raw EVM RPC methods when you need lower-level access:

```gdscript
var chain_id_response = await client.request("eth_chainId", [])
```

Native builds require a configured and unlocked local wallet before `initialize()` can succeed. Use `AlephVault__EVM.UI.WalletModal` for that flow:

```gdscript
var wallet_modal := AlephVault__EVM.UI.WalletModal.new()
wallet_modal.client = client
add_child(wallet_modal)

wallet_modal.started.connect(func(lock: Callable):
	_native_wallet_lock = lock
)

if client.manages_wallet():
	wallet_modal.show_from_scratch()
else:
	await client.initialize()
```

For web exports, add this file to the Web export preset's `Head Include` field:

```text
addons/AlephVault.EVM/templates/html5/web3-head-include.html
```

## Repository Layout

- `addons/AlephVault.EVM`: distributable addon package.
- `addons/AlephVault.EVM/rust`: native Rust GDExtension binding.
- `addons/AlephVault.EVM/bindings`: native and web binding implementations.
- `addons/AlephVault.EVM/ui`: reusable modal UI components.
- `addons/AlephVault.EVM/samples`: Godot/Redot sample scenes and scripts.
- `addons/AlephVault.EVM/samples/blockchain`: Hardhat sample project.

## Development

Build the native Rust extension:

```sh
cd addons/AlephVault.EVM/rust
cargo build
```

Run a fast Rust validation pass:

```sh
cd addons/AlephVault.EVM/rust
cargo check
```

The project main scene is:

```text
addons/AlephVault.EVM/samples/hardhat-sample.tscn
```

Its script is:

```text
addons/AlephVault.EVM/samples/hardhat_sample.gd
```
