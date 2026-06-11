extends RefCounted
## This is the implementation stub of a Web3 client for EVM networks.
## In web games, this hits an EIP-1193 wallet wrapped into window.web3
## (Web3, from web3js library). In non-web games, a custom binding is
## used instead.
##
## The surface methods are defined here, and they're redirected to the
## underlying respective binding immediately.

# The binding class. While a game is running, only a binding class will
# be used for all the instances. This depends on whether the platform
# is web (then, an EIP-1193-enabled binding will be used) or one of the
# native formats (desktop or mobile).
static var _binding_class: Script = null

static func _create_binding() -> Object:
	if _binding_class == null:
		if OS.has_feature("web"):
			_binding_class = load("./bindings/web/index.gd")
		else:
			_binding_class = load("./bindings/native/index.gd")

	return _binding_class.new()

# The binding for this facade in particular.
var _binding = null

func _init():
	_binding = _create_binding()

# The bindings need to implement the following methods:
#
# --------- Essential, non-contract, methods ---------
#
# 1. (asynchronous) initialize(Callable) returning:
#    - {"ok": true, "value": Array[String]}
#      Where value is the array of addresses that belong to valid
#      accounts, configured in the current game (native) or allowed
#      when connecting to the page's domain (web).
#    - {"ok": false, "error": String}
#      Where error is an error code. Typically: "user_rejected".
#      Other possible options are "no_valid_chains" if no chains
#      are configured, or "no_valid_accounts" if no accounts are
#      configured (neither by import nor by seed). Another possible
#      code is "incomplete_binding" if, somehow, the binding could
#      not be created (e.g. the native implementation is somehow
#      not available).
#
# 2. (asynchronous) get_chain_id() returning:
#    - {"ok": true, "value": int}
#      Where value is the id of the current chain. It will be
#      0 if this client is not connected to any chain.
#    - {"ok": false, "error": String}
#      Where error is an error code. Typically: "not_ready". This
#      means this client is not ready yet (even in the case that
#      the initialization failed).
#
# 3. (asynchronous) set_chain_id(chain_id: int) returning:
#    - {"ok": true, "value": null}
#    - {"ok": false, "error": String}
#      Where error is an error code. Typically: "not_ready". This
#      means this client is not ready yet. Another possible option
#      is "invalid_chain", meaning that either the ID is invalid
#      or does not belong to a configured chain.
#
# 4. (asynchronous) get_accounts() returning:
#    - {"ok": true, "value": Array[String]}
#    - {"ok": false, "error": String}
#      Where error is an error code. Typically: "not_ready". This
#      means this client is not ready yet (even in the case that
#      the initialization failed).
#
# 5. signal chain_changed(chain_id: int)
#    Where chain_id stands for a valid, non-zero, id of a chain
#    already configured in the underlying binding's engine.
#
# 6. signal accounts_changed(accounts: Array[String])
#    Where accounts stands for a valid, non-empty, array of
#    addresses. Those addresses are configured in the underlying
#    binding's engine.
#
# 7. (asynchronous) get_balance(address: String) returning:
#    - {"ok": true, "value": String}
#      Where the value is a numeric string. A big number, like
#      1000000000000000000 representing 1 ether.
#    - {"ok": false, "error": String}
#      Where error is an error code. Typically: "not_ready". This
#      means this client is not ready yet (even in the case that
#      the initialization failed). Alternatively, "invalid_address"
#      if the address is not valid or is 0x000...000.
#
# 8. (asynchronous) transfer(address: String, amount: String, tx_config: Variant) returning:
#    - {"ok": true, "value": String}
#      Where value is the tx. hash.
#    - {"ok": false, "error": String}
#      Where error is an error code. Many errors can occur here, like
#      "not_ready" if the client is not ready yet, "invalid_address"
#      if the address is not valid or "0x000...000" or "invalid_amount"
#      if the amount is not a numeric string.
#
# 9. (asynchronous) wait_for(tx_hash: String) returning:
#    - {"ok": true, "value": Dictionary}
#      Where value is the full tx. result object.
#    - {"ok": false, "error": String | Dictionary}
#      Where the error is a dictionary with the revert details.
#      Alternatively, it can be a string like "not_ready" or even
#      "invalid_tx_hash" (for when the hash is invalid or the
#      client is not ready, even in the case that the initialization
#      failed).
#
# 10. (asynchronous) request(method: String, params: Array) returning:
#     - {"ok": true, "value": Variant}
#       Where value is a valid JSON-compatible value. The syntax and
#       semantics is defined by the underlying RPC execution.
#     - {"ok": false, "error": Variant}
#       Where error is a valid JSON-compatible value. The syntax and
#       semantics is defined by the underlying RPC execution.
#
# --------- ABI-related methods ---------
#
# 11. set_abi(key: String, abi: Array[Dictionary]) returning:
#     - {"ok": true, "value": null}
#     - {"ok": false, "error": String}
#       Where error can be "incomplete_binding" if, somehow, the binding
#       could not be created (e.g. the native implementation is somehow
#       not available). Also, "invalid_abi" if the ABI does not have the
#       appropriate format or is an empty array, or "invalid_key" if
#       the key is not a [a-zA-Z0-9_]+ identifier.
#
# 12. get_abi(key: String) returning:
#     - {"ok": true, "value": Array[Dictionary]}
#       Where value is the ABI that was set in a previous set_abi call.
#     - {"ok": false, "error": String}
#       Where error can be "incomplete_binding" if, somehow, the binding
#       could not be created (e.g. the native implementation is somehow
#       not available). Also "not_found" if no ABI exists at given key.

# --------- Essential, non-contract, methods ---------
# These are essential methods related to managing sessions in the
# wallet: accounts, current chain, and balance.

## Initializes the binding. Each binding has a different way to do
## the initialization. This method is the FIRST THING TO CALL and
## tells the accounts that are allowed and ready in the binding.
##
## - Web bindings will do it directly against the EIP-1193 wallet.
##   When the wallet is ready (the web3 instance), then this call
##   will resolve successfully.
## - Native bindings will make use of a given node in `obj`. The
##   callback will typically resolve the involved accounts and
##   whatever data is needed (e.g. their private keys, to be used
##   inside the binding).
func initialize(callback: Callable):
	return _binding.initialize(callback)

## Returns the chain id for this binding. A binding is connected
## to a single chain id at a given time, and that chain id may
## change later.
func get_chain_id():
	return _binding.get_chain_id()

## Sets the chain id for this binding. A binding is connected to
## a single chain id at a given time, and that chain id may
## change later.
func set_chain_id(chain_id: int):
	return _binding.set_chain_id(chain_id)

## Gets the accounts for this binding. For simplicity, accounts
## can only be retrieved by this interface, but they can however
## be changed by external interfaces (in the case of EIP-1193
## wallets).
func get_accounts():
	return _binding.get_accounts()

## A signal accounts_changed(accounts: Array[String]) to track
## when the accounts were changed by an external interface (most
## likely, a browser extension).
var accounts_changed:
	get:
		return _binding.accounts_changed
	set(value):
		push_error("accounts_changed cannot be set this way")

## A signal chain_changed(chain_id: int) to track when the chain
## was changed by an external interface (most likely, a browser
## extension) or a call of set_chain_id(chain_id).
var chain_changed:
	get:
		return _binding.chain_changed
	set(value):
		push_error("chain_changed cannot be set this way")

## Gets the balance of an account in the current chain id set
## in this binding. The returned balance is a numeric string.
## In the end, this involves a call to eth_getBalance RPC
## method.
func get_balance(address: String):
	return _binding.get_balance(address)

## Transfers balance to another address. The source address is
## specified in the tx_config (the from: argument). The target
## address and the balance are specified as the first & second
## arguments and must be a valid, non-zero, address and a valid,
## numeric and available, string.
func transfer(address: String, amount: String, tx_config):
	return _binding.transfer(address, amount, tx_config)

## Waits for a transaction. Returns either the transaction's
## result or the revert details.
func wait_for(tx_hash: String):
	return _binding.wait_for(tx_hash)

## Performs an arbitrary RPC, supported by the underlying binding
## or the underlying node. Certain requests are handled only by
## the binding, while the huge majority are forwarded to the node
## the binding is connected to.
func request(method: String, params: Array):
	return _binding.request(method, params)

# --------- ABI-related methods ---------
# These methods are not necessarily standard methods, but the underlying
# idea involves managing the ABIs we care about. These might relate to
# one or more contracts each, and they're all managed by the bindings
# themselves, once they are registered.

## Sets a certain ABI inside the binding, to be used later. This method
## should be invoked before initializing the binding, although it's safe
## to invoke it after initialization.
##
## ABIs set like this can be used later to interact with smart contracts:
## encoding method call, decoding results, and decoding events.
func set_abi(key: String, abi: Array[Dictionary]):
	return _binding.set_abi(key, abi)

## Gets an ABI registered by set_abi by certain key.
func get_abi(key: String):
	return _binding.get_abi(key)
