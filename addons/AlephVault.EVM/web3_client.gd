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

static func _success(value: Variant) -> Dictionary:
	return {"ok": true, "value": value}

static func _failed(error: String) -> Dictionary:
	return {"ok": false, "error": error}

static func _is_hex_code(code: int) -> bool:
	return (code >= 48 and code <= 57) or (code >= 65 and code <= 70) or (code >= 97 and code <= 102)

static func _hex_code_to_int(code: int) -> int:
	if code >= 48 and code <= 57:
		return code - 48
	if code >= 65 and code <= 70:
		return code - 55
	return code - 87

static func _strip_optional_0x(hex: String) -> String:
	if hex.begins_with("0x"):
		return hex.substr(2)
	return hex

static func _has_misplaced_0x(hex: String) -> bool:
	return hex.find("0x", 1) != -1

static func _is_even_hex(hex: String) -> bool:
	if _has_misplaced_0x(hex):
		return false

	var stripped := _strip_optional_0x(hex)
	if stripped.length() % 2 != 0:
		return false

	for i in range(stripped.length()):
		if not _is_hex_code(stripped.unicode_at(i)):
			return false

	return true

static func _is_prefixed_hex_quantity(hex: String) -> bool:
	if not hex.begins_with("0x") or hex.length() == 2:
		return false

	if _has_misplaced_0x(hex):
		return false

	if hex.length() > 3 and hex.unicode_at(2) == 48:
		return false

	for i in range(2, hex.length()):
		if not _is_hex_code(hex.unicode_at(i)):
			return false

	return true

static func _is_named_block_tag(tag: String) -> bool:
	return tag == "earliest" or tag == "latest" or tag == "pending" or tag == "safe" or tag == "finalized"

static func _create_binding() -> Object:
	if _binding_class == null:
		if OS.has_feature("web"):
			_binding_class = load("res://addons/AlephVault.EVM/bindings/web/index.gd")
		else:
			_binding_class = load("res://addons/AlephVault.EVM/bindings/native/index.gd")

	return _binding_class.new()

# The binding for this facade in particular.
var _binding = null
var _tx_confirm_modal = null

## Native-only transaction/signature confirmation modal.
##
## Assign an AlephVault__EVM.UI.TXConfirmModal in native builds. Web wallets
## provide their own approval UI, so assignment fails with a push_error() and
## leaves the property unchanged.
var confirm_modal:
	get:
		return _tx_confirm_modal
	set(value):
		var response = _set_confirm_modal(value)
		if not response.get("ok", false):
			push_error(str(response.get("error", "invalid_modal")))

func _init():
	_binding = _create_binding()

# The bindings need to implement the following methods:
#
# --------- Essential, non-contract, methods ---------
#
# 1. (asynchronous) initialize() returning:
#    - {"ok": true, "value": null}
#      Where success means the binding finished its asynchronous initialization
#      and subsequent ready-gated calls may be attempted.
#    - {"ok": false, "error": String}
#      Where error is an error code. Typically: "user_rejected".
#      Another possible code is "incomplete_binding" if, somehow, the
#      binding could not be created (e.g. the native implementation is
#      somehow not available).
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
# 8. (asynchronous) transfer(address: String, amount: String, tx_config: Dictionary) returning:
#    - {"ok": true, "value": String}
#      Where value is the tx. hash.
#    - {"ok": false, "error": String}
#      Where error is an error code. Many errors can occur here, like
#      "not_ready" if the client is not ready yet, "invalid_address"
#      if the address is not valid or "0x000...000" or "invalid_amount"
#      if the amount is not a numeric string.
#    tx_config is a JSON-serializable EVM transaction configuration
#    dictionary. Common keys are "from", "value", "gas", "gasLimit",
#    "gasPrice", "maxFeePerGas", "maxPriorityFeePerGas", "nonce",
#    "chainId", "chain_id", and "data". Numeric fields accept decimal
#    strings, 0x-prefixed hex quantities, or JSON integers; use strings for
#    large values. transfer() sets "to" and "value" from address and amount,
#    so callers should not rely on conflicting tx_config values for those keys.
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
# 11. (asynchronous) eth_sign(message: String | PackedByteArray, address: String = "") returning:
#     - {"ok": true, "value": String}
#       Where value is the eth_sign signature.
#     - {"ok": false, "error": Variant}
#       Where error follows the provider/RPC response or addon validation.
#
# 12. (asynchronous) eth_sign_typed_data(typed_data: Dictionary | String, address: String = "") returning:
#     - {"ok": true, "value": String}
#       Where value is the EIP-712 typed-data signature.
#     - {"ok": false, "error": Variant}
#       Where error follows the provider/RPC response or addon validation.
#
# 13. (asynchronous) eth_send_transaction(tx_config: Dictionary) returning:
#     - {"ok": true, "value": String}
#       Where value is the transaction hash.
#     - {"ok": false, "error": Variant}
#       Where error follows the provider/RPC response.
#
# 14. recover_personal_sign(message: String | PackedByteArray, signature: String) returning:
#     - {"ok": true, "value": String}
#       Where value is the recovered signer address for the
#       personal_sign/EIP-191 message hash.
#     - {"ok": false, "error": String}
#       Where error can be "invalid_message", "invalid_signature", or
#       "incomplete_binding".
#
# 15. verify_personal_sign(address: String, message: String | PackedByteArray, signature: String) returning:
#     - {"ok": true, "value": bool}
#       Where value is true when signature recovers to address using the
#       personal_sign/EIP-191 message hash.
#     - {"ok": false, "error": String}
#       Where error can be "invalid_address", "invalid_message",
#       "invalid_signature", or "incomplete_binding".
#
# 16. recover_eth_sign(message: String | PackedByteArray, signature: String) returning:
#     - {"ok": true, "value": String}
#       Where value is the recovered signer address for the raw eth_sign
#       Keccak message hash.
#     - {"ok": false, "error": String}
#       Where error can be "invalid_message", "invalid_signature", or
#       "incomplete_binding".
#
# 17. verify_eth_sign(address: String, message: String | PackedByteArray, signature: String) returning:
#     - {"ok": true, "value": bool}
#       Where value is true when signature recovers to address using the raw
#       eth_sign Keccak message hash.
#     - {"ok": false, "error": String}
#       Where error can be "invalid_address", "invalid_message",
#       "invalid_signature", or "incomplete_binding".
#
# 18. recover_eth_sign_typed_data(typed_data: Dictionary | String, signature: String) returning:
#     - {"ok": true, "value": String}
#       Where value is the recovered signer address for the EIP-712 typed-data
#       hash.
#     - {"ok": false, "error": String}
#       Where error can be "invalid_typed_data", "invalid_signature", or
#       "incomplete_binding".
#
# 19. verify_eth_sign_typed_data(address: String, typed_data: Dictionary | String, signature: String) returning:
#     - {"ok": true, "value": bool}
#       Where value is true when signature recovers to address using the
#       EIP-712 typed-data hash.
#     - {"ok": false, "error": String}
#       Where error can be "invalid_address", "invalid_typed_data",
#       "invalid_signature", or "incomplete_binding".
#
# 20. (asynchronous) recover_eth_send_transaction(tx_hash: String) returning:
#     - {"ok": true, "value": String}
#       Where value is the transaction sender address reported by
#       eth_getTransactionByHash.
#     - {"ok": false, "error": String}
#       Where error can be "invalid_tx_hash", "not_found",
#       "invalid_transaction", or the provider/RPC error.
#
# 21. (asynchronous) verify_eth_send_transaction(address: String, tx_hash: String) returning:
#     - {"ok": true, "value": bool}
#       Where value is true when the submitted transaction sender matches
#       address.
#     - {"ok": false, "error": String}
#       Where error can be "invalid_address", "invalid_tx_hash", "not_found",
#       "invalid_transaction", or the provider/RPC error.
#
# --------- ABI-related methods ---------
#
# 22. set_abi(key: String, abi: Array[Dictionary]) returning:
#     - {"ok": true, "value": null}
#     - {"ok": false, "error": String}
#       Where error can be "incomplete_binding" if, somehow, the binding
#       could not be created (e.g. the native implementation is somehow
#       not available). Also, "invalid_abi" if the ABI does not have the
#       appropriate format or is an empty array, or "invalid_key" if
#       the key is not a [a-zA-Z0-9_]+ identifier.
#
# 23. get_abi(key: String) returning:
#     - {"ok": true, "value": Array[Dictionary]}
#       Where value is the ABI that was set in a previous set_abi call.
#     - {"ok": false, "error": String}
#       Where error can be "incomplete_binding" if, somehow, the binding
#       could not be created (e.g. the native implementation is somehow
#       not available). Also "not_found" if no ABI exists at given key.
#
# 24. abi_encode(args: Array) returning:
#     - {"ok": true, "value": PackedByteArray}
#       Where value is the standard ABI encoding of the provided
#       arguments.
#     - {"ok": false, "error": String}
#       Where error can be "incomplete_binding" if the binding could
#       not be created, "invalid_args" if args is not a valid ABI
#       argument list, "invalid_type" if an explicitly declared type
#       is not a valid EVM type, or "invalid_value" if a value cannot
#       be encoded for its resolved type.
#
# 25. abi_encode_packed(args: Array) returning:
#     - {"ok": true, "value": PackedByteArray}
#       Where value is the packed ABI encoding of the provided
#       arguments.
#     - {"ok": false, "error": String}
#       Where error can be "incomplete_binding", "invalid_args",
#       "invalid_type", or "invalid_value". They're the same ones that
#       were described for `abi_encode`.
#
# 26. abi_decode(args: PackedByteArray, spec: Array) returning:
#     - {"ok": true, "value": Array}
#       Where value contains the decoded values as non-dictionary
#       elements.
#     - {"ok": false, "error": String}
#       Where error can be "incomplete_binding", "invalid_args",
#       "invalid_type", "invalid_value", or "invalid_spec" if spec
#       is not a valid ABI type specification array.
#
# ABI encoding arguments are an array where each element can be:
#    - A non-dictionary value to encode. The binding resolves the
#      ABI type for this value. Boolean values infer as bool, numbers as
#      uint256, strings starting with 0x as bytes, other strings as string,
#      and byte integer arrays as bytes. Solidity arrays require an explicit
#      array type.
#    - A dictionary in the form {"type": String, "value": Variant}.
#      The type must be a valid EVM type, such as "string" or
#      "uint256", and value must be valid for that type.
#
# ABI decoding spec is an array where each element can be:
#    - A string with a valid EVM type, such as "string" or "uint256".
#    - A dictionary describing an ABI type, using keys such as "type",
#      "internalType", "components", and "name".
#
# --------- Data-related methods ---------
#
# 27. keccak256(b: PackedByteArray) returning:
#     - {"ok": true, "value": PackedByteArray}
#       Where value is exactly 32 bytes.
#     - {"ok": false, "error": String}
#       Where error can be "incomplete_binding" if the binding is not
#       complete enough to compute Keccak-256.
#
# 28. from_wei(amount: String, unit: String) returning:
#     - {"ok": true, "value": String}
#       Where value is the amount converted from wei into unit.
#     - {"ok": false, "error": String}
#       Where error can be "invalid_amount" if amount is not a valid
#       numeric string, "invalid_unit" if unit is not supported, or
#       "incomplete_binding" if the binding is not complete enough to
#       perform bigint unit conversions.
#
# 29. to_wei(amount: String, unit: String) returning:
#     - {"ok": true, "value": String}
#       Where value is the amount converted from unit into wei.
#     - {"ok": false, "error": String}
#       Where error can be "invalid_amount" if amount is not a valid
#       numeric string, "invalid_unit" if unit is not supported, or
#       "incomplete_binding" if the binding is not complete enough to
#       perform bigint unit conversions.
#
# 30. from_hex(hex: String) returning:
#     - {"ok": true, "value": PackedByteArray}
#       Where value is the decoded byte array. "" and "0x" decode
#       successfully into an empty PackedByteArray.
#     - {"ok": false, "error": String}
#       Where error can be "invalid_hex" if hex contains non-hex
#       characters, a misplaced 0x prefix, an odd number of hex digits,
#       or another invalid hex representation.
#
# 31. to_checksum_address(address: String) returning:
#     - {"ok": true, "value": String}
#       Where value is the EIP-55 checksummed address.
#     - {"ok": false, "error": String}
#       Where error can be "invalid_address" if address is not in the
#       0x-prefixed 40-hex-digit address format, or "incomplete_binding"
#       if the binding is not complete enough to compute the checksum.
#
# 32. to_hex(value: PackedByteArray) returning:
#     - {"ok": true, "value": String}
#       Where value is a 0x-prefixed hex string.
#
# 33. decimal_to_hex(decimal: String) returning:
#     - {"ok": true, "value": String}
#       Where value is a 0x-prefixed hex string.
#     - {"ok": false, "error": String}
#       Where error can be "invalid_value" or "incomplete_binding" if the
#       binding is not complete enough to perform bigint conversions.
#
# 34. hex_to_decimal(hex: String) returning:
#     - {"ok": true, "value": String}
#       Where value is a decimal numeric string.
#     - {"ok": false, "error": String}
#       Where error can be "invalid_value" or "incomplete_binding" if the
#       binding is not complete enough to perform bigint conversions.
#
# 35. validate_block_tag(tag: String) returning:
#     - {"ok": true, "value": null}
#     - {"ok": false, "error": String}
#       Where error can be "invalid_value". Valid block tags are
#       "earliest", "latest", "pending", "safe", "finalized", or a
#       canonical 0x-prefixed hex quantity without leading zeroes
#       except for "0x0".
#
# 36. validate_uint(value: String, size: int) returning:
#     - {"ok": true, "value": null}
#     - {"ok": false, "error": String}
#       Where error can be "invalid_value" if value is not a valid uint
#       for the requested size, or "invalid_size" if size is not one of
#       8, 16, ..., 256, or "incomplete_binding" if the binding is not
#       complete enough to validate bigint ranges.
#
# 37. validate_int(value: String, size: int) returning:
#     - {"ok": true, "value": null}
#     - {"ok": false, "error": String}
#       Where error can be "invalid_value" if value is not a valid int
#       for the requested size, or "invalid_size" if size is not one of
#       8, 16, ..., 256, or "incomplete_binding" if the binding is not
#       complete enough to validate bigint ranges.
#
# 38. validate_bytes(value: String | PackedByteArray, size: int = 0) returning:
#     - {"ok": true, "value": null}
#     - {"ok": false, "error": String}
#       Where error can be "invalid_value" if value is not valid for
#       bytes or bytesX, or "invalid_size" if size is not in 0..32.
#       If value is a String, it must be hex with an optional 0x prefix.
#       When size is 0, the hex digit count must be even. When size is
#       1..32, the hex digit count must be exactly size * 2.
#
# 39. validate_address(value: String, checksum: bool = false) returning:
#     - {"ok": true, "value": null}
#     - {"ok": false, "error": String}
#       Where error can be "invalid_value". A valid address is a string
#       matching (0x)?[0-9a-fA-F]{40}. When checksum is true, the address
#       must also satisfy the checksum rules. "incomplete_binding" can be
#       returned if checksum validation is requested but the binding is
#       not complete enough to compute/verify the checksum.
#
# 40. manages_wallet() returning bool:
#     Returns true when the binding manages local wallet/account material.
#
# 41. is_read_only() returning bool:
#     Returns true when this binding is currently read-only.
#
# 42. Native wallet lifecycle methods:
#     account_exists(), await account_create(password), account_destroy(),
#     await account_backup(target_path), await account_restore(source_path),
#     await account_unlock(password), account_lock(),
#     await account_set_password(password), account_private_key(), and
#     await set_chain(rpc_url).
#     Web bindings return {"ok": false, "error": "not_supported"} for all of
#     these methods. Web bindings also support set_read_only_rpc_url(rpc_url)
#     before initialize() to configure the browser read-only fallback.
#     Native bindings support a single encrypted account whose
#     private key only crosses into GDScript when account_private_key() is
#     explicitly called while unlocked.
#
# --------- Contract-related methods ---------
#
# 42. contract_create(address: String, abi_key: String) returning:
#     - {"ok": true, "value": null}
#       Where the binding creates and stores a contract reference for the
#       address and ABI, such as window.web3.Contract(...) in web builds.
#     - {"ok": false, "error": String}
#       Where error can be "incomplete_binding" if the binding is not
#       available, "invalid_address" if address is not a valid non-zero
#       address, or "not_found" if abi_key does not match a registered ABI.
#     This method is synchronous and only performs setup.
#
# 43. (asynchronous) contract_invoke(
#       address: String, method: String | Dictionary, params: Array,
#       tx_params: Dictionary
#     ) returning:
#     - {"ok": true, "value": Variant}
#       Where value is a transaction hash String for payable/nonpayable
#       methods, or an ABI-decoded value for view/pure methods.
#     - {"ok": false, "error": String | Variant}
#       Where error can be "incomplete_binding", "not_ready",
#       "invalid_contract", "invalid_method", "invalid_params", or an
#       underlying RPC/provider error.
#     The method can be a function name, or an ABI entry dictionary of
#     type "function". The binding resolves overloads.
#     tx_params uses the same JSON-serializable EVM transaction
#     configuration dictionary syntax as transfer()'s tx_config. Contract
#     view/pure calls may also pass "block" or "blockTag".
#
# 44. (asynchronous) contract_get_events(
#       address: String, event: String | Dictionary, topics: Array | Dictionary,
#       from: String = "0x0", to: String = "latest"
#     ) returning:
#     - {"ok": true, "value": Array}
#       Where value is an array of ABI-decoded events. It can be empty.
#     - {"ok": false, "error": String | Variant}
#       Where error can be "incomplete_binding", "not_ready",
#       "invalid_contract", "invalid_event", "invalid_topic",
#       "invalid_block_tag", "invalid_block_range", or an underlying
#       RPC/provider error.
#     The event can be an event name, or an ABI entry dictionary. The
#     binding resolves overloads. Topics can be an array of up to three
#     topic values, or a dictionary keyed by valid indexed field names.
#
# 45. contract_get_tx_events(
#       tx_obj: Dictionary, event: String | Dictionary | null = null
#     ) returning:
#     - {"ok": true, "value": Array}
#       Where value is an array of decoded events. If event is null, the
#       binding returns all decodable events and raw entries for logs that
#       cannot be decoded with the contract ABI.
#     - {"ok": false, "error": String | Variant}
#       Where error can be "incomplete_binding", "invalid_tx",
#       "invalid_event", or "invalid_log".
#     This method is synchronous and decodes events from a transaction
#     object previously returned by wait_for().
#
# Other agreements related to data marshalling are needed:
#
# - Transaction config dictionaries use the same names in both bindings:
#   "from", "value", "gas", "gasLimit", "gasPrice", "maxFeePerGas",
#   "maxPriorityFeePerGas", "nonce", "chainId", "chain_id", and "data".
#   Numeric fields accept decimal strings, 0x-prefixed hex quantities, or
#   JSON integers; use strings for large values.
# - Contract view calls may also pass "block" or "blockTag".

# --------- Essential, non-contract, methods ---------
# These are essential methods related to managing sessions in the
# wallet: accounts, current chain, and balance.

## Initializes the binding. Each binding has a different way to do the
## initialization. This method is the FIRST THING TO CALL. It is asynchronous
## and should be awaited, but a successful response does not carry a value.
##
## - Web bindings will do it directly against the EIP-1193 wallet.
##   When the wallet is ready (the web3 instance), then this call
##   will resolve successfully with {"ok": true, "value": null}. Web exports
##   configured with a read-only RPC fallback can also initialize without a
##   wallet; get_accounts() will return an empty array and signing or
##   transaction methods will fail with "read_only".
## - Native bindings require the Rust wallet to be unlocked and to have one
##   account plus a configured chain. Success still resolves as
##   {"ok": true, "value": null}; use get_accounts() and get_chain_id() for
##   the initialized address and chain.
func initialize():
	return await _binding.initialize()

## Returns the chain id for this binding. Web bindings can observe wallet-side
## chain changes. Native bindings are initialized with one fixed chain.
func get_chain_id():
	return await _binding.get_chain_id()

## Returns whether this binding can switch chain ids at runtime.
##
## Web bindings can request wallet chain switches. Native bindings are fixed to
## the chain configured during initialize().
func can_set_chain_id() -> bool:
	return _binding.can_set_chain_id()

## Sets the chain id for this binding. Web bindings request a wallet chain
## switch. Native bindings keep this method only for compatibility and return
## {"ok": false, "error": "not_supported"} after initialization.
func set_chain_id(chain_id: int):
	return await _binding.set_chain_id(chain_id)

## Gets the accounts for this binding. For simplicity, accounts
## can only be retrieved by this interface, but they can however
## be changed by external interfaces (in the case of EIP-1193
## wallets).
func get_accounts():
	return await _binding.get_accounts()

## A signal accounts_changed(accounts: Array[String]) to track
## when the accounts were changed by an external interface (most
## likely, a browser extension).
var accounts_changed:
	get:
		return _binding.accounts_changed
	set(value):
		push_error("accounts_changed cannot be set this way")

## A signal chain_changed(chain_id: int) to track web wallet chain changes.
## Native bindings keep the signal for compatibility but never emit it.
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
	return await _binding.get_balance(address)

## Transfers wei to a valid non-zero EVM address.
##
## amount is a decimal numeric string denominated in wei. tx_config is a
## JSON-serializable EVM transaction configuration dictionary. Common keys are
## "from", "value", "gas", "gasLimit", "gasPrice", "maxFeePerGas",
## "maxPriorityFeePerGas", "nonce", "chainId", "chain_id", and "data".
## Numeric fields accept decimal strings, 0x-prefixed hex quantities, or JSON
## integers; use strings for large values. transfer() sets "to" and "value"
## from address and amount, so callers should not rely on conflicting
## tx_config values for those keys.
func transfer(address: String, amount: String, tx_config: Dictionary):
	if _uses_native_confirmations():
		if not _is_non_zero_address_value(address):
			return _failed("invalid_address")
		if not _is_decimal_uint_value(amount):
			return _failed("invalid_amount")
		var tx := tx_config.duplicate(true)
		tx["to"] = address
		var hex_amount = await decimal_to_hex(amount)
		if not hex_amount.get("ok", false):
			return hex_amount
		tx["value"] = hex_amount.get("value", "0x0")
		var normalized_response = await _normalize_transaction_for_confirmation(tx)
		if not normalized_response.get("ok", false):
			return normalized_response
		var normalized_tx = normalized_response.get("value", {})
		var confirmation = await _confirm_wallet_request("eth_sendTransaction", {"kind": "transaction", "transaction": normalized_tx})
		if not confirmation.get("ok", false):
			return confirmation
		return await _binding.request("eth_sendTransaction", [normalized_tx])
	return await _binding.transfer(address, amount, tx_config)

## Waits for a transaction. Returns either the transaction's
## result or the revert details.
func wait_for(tx_hash: String):
	return await _binding.wait_for(tx_hash)

## Performs an arbitrary RPC, supported by the underlying binding
## or the underlying node. Certain requests are handled only by
## the binding, while the huge majority are forwarded to the node
## the binding is connected to.
func request(method: String, params: Array):
	if _uses_native_confirmations():
		var confirmation_payload = await _confirmation_payload_for_request(method, params)
		if not confirmation_payload.get("ok", false):
			return confirmation_payload
		var payload_value = confirmation_payload.get("value", null)
		if payload_value is Dictionary:
			var payload = payload_value
			var confirmation = await _confirm_wallet_request(method, payload)
			if not confirmation.get("ok", false):
				return confirmation
			if payload.has("params"):
				params = payload.get("params", params)
	return await _binding.request(method, params)

## Requests a personal_sign signature from the selected wallet/provider.
##
## message can be a String or PackedByteArray. PackedByteArray values are sent
## as 0x-prefixed hex strings.
func personal_sign(message: Variant, address: String = ""):
	var account := address
	if account.is_empty():
		var accounts = await get_accounts()
		if not accounts.get("ok", false):
			return accounts
		var values = accounts.get("value", [])
		if not (values is Array) or values.is_empty():
			return _failed("no_valid_accounts")
		account = String(values[0])

	var encoded = _signature_message_value(message)
	if encoded == null:
		return _failed("invalid_message")
	return await request("personal_sign", [encoded, account])

## Requests an eth_sign signature from the selected wallet/provider.
##
## message can be a String or PackedByteArray. PackedByteArray values are sent
## as 0x-prefixed hex strings.
func eth_sign(message: Variant, address: String = ""):
	var account := address
	if account.is_empty():
		var accounts = await get_accounts()
		if not accounts.get("ok", false):
			return accounts
		var values = accounts.get("value", [])
		if not (values is Array) or values.is_empty():
			return _failed("no_valid_accounts")
		account = String(values[0])

	var encoded = _signature_message_value(message)
	if encoded == null:
		return _failed("invalid_message")
	return await request("eth_sign", [account, encoded])

## Requests an EIP-712 typed-data signature from the selected wallet/provider.
func eth_sign_typed_data(typed_data: Variant, address: String = ""):
	var account := address
	if account.is_empty():
		var accounts = await get_accounts()
		if not accounts.get("ok", false):
			return accounts
		var values = accounts.get("value", [])
		if not (values is Array) or values.is_empty():
			return _failed("no_valid_accounts")
		account = String(values[0])

	return await request("eth_signTypedData", [account, typed_data])

## Sends a transaction through eth_sendTransaction.
func eth_send_transaction(tx_config: Dictionary):
	return await request("eth_sendTransaction", [tx_config])

## Verifies a personal_sign signature against an expected address.
func verify_personal_sign(address: String, message: Variant, signature: String):
	var recovered = recover_personal_sign(message, signature)
	return _verify_recovered_address(address, recovered)

## Recovers the signer address from a personal_sign signature.
func recover_personal_sign(message: Variant, signature: String):
	var encoded = _signature_message_value(message)
	if encoded == null:
		return _failed("invalid_message")
	return _binding.recover_personal_sign(encoded, signature)

## Verifies an eth_sign signature against an expected address.
func verify_eth_sign(address: String, message: Variant, signature: String):
	var recovered = recover_eth_sign(message, signature)
	return _verify_recovered_address(address, recovered)

## Recovers the signer address from an eth_sign signature.
func recover_eth_sign(message: Variant, signature: String):
	var encoded = _signature_message_value(message)
	if encoded == null:
		return _failed("invalid_message")
	return _binding.recover_eth_sign(encoded, signature)

## Verifies an EIP-712 typed-data signature against an expected address.
func verify_eth_sign_typed_data(address: String, typed_data: Variant, signature: String):
	var recovered = recover_eth_sign_typed_data(typed_data, signature)
	return _verify_recovered_address(address, recovered)

## Recovers the signer address from an EIP-712 typed-data signature.
func recover_eth_sign_typed_data(typed_data: Variant, signature: String):
	return _binding.recover_eth_sign_typed_data(typed_data, signature)

## Verifies an eth_sendTransaction sender against an expected address.
func verify_eth_send_transaction(address: String, tx_hash: String):
	var recovered = await recover_eth_send_transaction(tx_hash)
	return _verify_recovered_address(address, recovered)

## Recovers the sender address from a submitted eth_sendTransaction hash.
func recover_eth_send_transaction(tx_hash: String):
	return await _binding.recover_eth_send_transaction(tx_hash)

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

## Encodes an ABI argument list using standard ABI encoding.
##
## Each argument can be a plain value, or a dictionary in the form
## {"type": String, "value": Variant} to force a specific EVM type. Plain
## byte integer arrays infer as bytes; Solidity arrays require an explicit
## array type.
func abi_encode(args: Array):
	return _binding.abi_encode(args)

## Encodes an ABI argument list using packed ABI encoding.
##
## Each argument follows the same format as abi_encode(args).
func abi_encode_packed(args: Array):
	return _binding.abi_encode_packed(args)

## Decodes ABI-encoded bytes according to the provided ABI type spec.
##
## Each spec element can be a valid EVM type string, or a dictionary
## describing an ABI type with keys such as "type", "internalType",
## "components", and "name".
func abi_decode(args: PackedByteArray, spec: Array):
	return _binding.abi_decode(args, spec)

# --------- Data-related methods ---------

## Computes the Keccak-256 digest of the provided bytes.
##
## This always succeeds when b is a PackedByteArray. The returned value
## is exactly 32 bytes.
func keccak256(b: PackedByteArray):
	return _binding.keccak256(b)

## Converts a wei-denominated numeric string into another EVM unit.
func from_wei(amount: String, unit: String):
	return _binding.from_wei(amount, unit)

## Converts a numeric string from an EVM unit into wei.
func to_wei(amount: String, unit: String):
	return _binding.to_wei(amount, unit)

## Decodes a hex string into bytes.
##
## Valid input is composed of an even number of hex digits, optionally
## prefixed by 0x. Empty strings and "0x" return an empty PackedByteArray.
func from_hex(hex: String):
	if not _is_even_hex(hex):
		return _failed("invalid_hex")

	var stripped := _strip_optional_0x(hex)
	var bytes := PackedByteArray()
	for i in range(0, stripped.length(), 2):
		var high := _hex_code_to_int(stripped.unicode_at(i))
		var low := _hex_code_to_int(stripped.unicode_at(i + 1))
		bytes.append(high * 16 + low)

	return _success(bytes)

## Converts an address into its EIP-55 checksum representation.
##
## Valid addresses are 0x-prefixed and contain exactly 40 hex digits.
func to_checksum_address(address: String):
	return _binding.to_checksum_address(address)

## Encodes bytes into a 0x-prefixed hex string.
func to_hex(value: PackedByteArray):
	var hex := "0x"
	for byte in value:
		hex += "%02x" % byte

	return _success(hex)

## Converts a decimal numeric string into a 0x-prefixed hex string.
func decimal_to_hex(decimal: String):
	return _binding.decimal_to_hex(decimal)

## Converts a hex string into a decimal numeric string.
func hex_to_decimal(hex: String):
	return _binding.hex_to_decimal(hex)

## Validates an EVM JSON-RPC block tag.
##
## Valid values are "earliest", "latest", "pending", "safe", "finalized",
## or a canonical 0x-prefixed hex quantity without leading zeroes except
## for "0x0".
func validate_block_tag(tag: String):
	if _is_named_block_tag(tag):
		return _success(null)

	if not _is_prefixed_hex_quantity(tag):
		return _failed("invalid_value")

	return _success(null)

## Validates an unsigned integer numeric string for uint<size>.
##
## Size must be one of 8, 16, ..., 256.
func validate_uint(value: String, size: int):
	return _binding.validate_uint(value, size)

## Validates a signed integer numeric string for int<size>.
##
## Size must be one of 8, 16, ..., 256.
func validate_int(value: String, size: int):
	return _binding.validate_int(value, size)

## Validates bytes or bytes<size>.
##
## Value must be either PackedByteArray or a hex string with an optional
## 0x prefix. Size 0 means dynamic bytes; size 1..32 means bytes<size>.
func validate_bytes(value: Variant, size: int = 0):
	if size < 0 or size > 32:
		return _failed("invalid_size")

	if value is PackedByteArray:
		var bytes_value: PackedByteArray = value
		if size != 0 and bytes_value.size() != size:
			return _failed("invalid_value")
		return _success(null)

	if not (value is String):
		return _failed("invalid_value")

	var string_value: String = value
	if not _is_even_hex(string_value):
		return _failed("invalid_value")

	var stripped := _strip_optional_0x(string_value)
	if size != 0 and stripped.length() != size * 2:
		return _failed("invalid_value")

	return _success(null)

## Validates an EVM address string.
##
## Valid addresses match (0x)?[0-9a-fA-F]{40}. When checksum is true,
## the address must also satisfy the checksum rules.
func validate_address(value: String, checksum: bool = false):
	return _binding.validate_address(value, checksum)

## Returns whether this binding manages local wallet/account material.
func manages_wallet() -> bool:
	return _binding.manages_wallet()

## Returns whether this binding is currently read-only. Web bindings return true
## when using the read-only RPC fallback; native bindings return false.
func is_read_only() -> bool:
	return _binding.is_read_only()

## Returns whether the native wallet keystore exists. Web bindings return
## {"ok": false, "error": "not_supported"}.
func account_exists():
	return _binding.account_exists()

## Creates the native single-account wallet with password-protected storage.
## The wallet remains locked afterwards. Web bindings return not_supported.
func account_create(password: String):
	return await _binding.account_create(password)

## Destroys the native wallet while it is locked.
## Web bindings return {"ok": false, "error": "not_supported"}.
func account_destroy():
	return _binding.account_destroy()

## Copies the encrypted native keystore to target_path while locked.
## Web bindings return {"ok": false, "error": "not_supported"}.
func account_backup(target_path: String):
	return await _binding.account_backup(target_path)

## Restores an encrypted native keystore from source_path when unset.
## The wallet remains locked afterwards. Web bindings return not_supported.
func account_restore(source_path: String):
	return await _binding.account_restore(source_path)

## Unlocks the native wallet with its password. Call initialize() afterwards to
## initialize the Godot binding cache. Web bindings return not_supported.
func account_unlock(password: String):
	return await _binding.account_unlock(password)

## Locks the native wallet and de-initializes the Godot binding cache.
## Web bindings return {"ok": false, "error": "not_supported"}.
func account_lock():
	return _binding.account_lock()

## Changes the native wallet password while unlocked.
## Web bindings return {"ok": false, "error": "not_supported"}.
func account_set_password(password: String):
	return await _binding.account_set_password(password)

## Returns the unlocked native wallet private key as 0x-prefixed hex.
## Web bindings return {"ok": false, "error": "not_supported"}.
func account_private_key():
	return _binding.account_private_key()

## Asynchronously sets the native wallet HTTP RPC URL and infers chain id from eth_chainId.
## The chain is transient and is not stored on disk. This is independent from
## set_chain_id(); call it again after process restart. Web bindings return
## not_supported.
func set_chain(rpc_url: String):
	return await _binding.set_chain(rpc_url)

## Sets the web read-only fallback HTTP RPC URL to use when no browser wallet is
## injected. Call before initialize(). Native bindings return not_supported.
func set_read_only_rpc_url(rpc_url: String):
	return _binding.set_read_only_rpc_url(rpc_url)

# --------- Contract-related methods ---------

## Creates and stores a binding-side contract reference for address and ABI.
##
## This is synchronous setup. The address must be valid and non-zero, and
## abi_key must refer to a previously registered ABI.
func contract_create(address: String, abi_key: String):
	return _binding.contract_create(address, abi_key)

## Invokes a contract method.
##
## Method can be a function name or an ABI entry dictionary of type
## "function". Params are passed to the contract method builder. tx_params uses
## the same JSON-serializable EVM transaction configuration dictionary syntax
## as transfer()'s tx_config. Contract view/pure calls may also pass "block"
## or "blockTag".
func contract_invoke(address: String, method: Variant, params: Array, tx_params: Dictionary):
	if _uses_native_confirmations() and _contract_invoke_requires_confirmation(method):
		if not _is_non_zero_address_value(address):
			return _failed("invalid_address")
		var normalized_tx_params_response = await _normalize_tx_params_for_confirmation(tx_params)
		if not normalized_tx_params_response.get("ok", false):
			return normalized_tx_params_response
		var normalized_tx_params = normalized_tx_params_response.get("value", {})
		var confirmation = await _confirm_wallet_request("contract_invoke", {
			"kind": "contract",
			"contract": address,
			"method": method,
			"params": params,
			"tx_params": normalized_tx_params,
		})
		if not confirmation.get("ok", false):
			return confirmation
		tx_params = normalized_tx_params
	return await _binding.contract_invoke(address, method, params, tx_params)

## Gets ABI-decoded events for a registered contract.
##
## Event can be an event name or an ABI entry dictionary. Topics can be an
## array of up to three topic values, or a dictionary keyed by indexed field
## names. Block tags follow validate_block_tag(tag).
func contract_get_events(address: String, event: Variant, topics: Variant, from: String = "0x0", to: String = "latest"):
	return await _binding.contract_get_events(address, event, topics, from, to)

## Decodes matching events from a transaction object returned by wait_for().
##
## If event is null, all decodable events are returned, with raw entries for
## logs that cannot be decoded with the current contract ABI.
func contract_get_tx_events(tx_obj: Dictionary, event: Variant = null):
	return _binding.contract_get_tx_events(tx_obj, event)

func _verify_recovered_address(address: String, recovered: Dictionary) -> Dictionary:
	if not recovered.get("ok", false):
		return recovered
	var expected = to_checksum_address(address)
	if not expected.get("ok", false):
		return expected
	var actual = to_checksum_address(String(recovered.get("value", "")))
	if not actual.get("ok", false):
		return actual
	return {"ok": true, "value": String(expected["value"]).to_lower() == String(actual["value"]).to_lower()}

func _signature_message_value(message: Variant) -> Variant:
	if message is PackedByteArray:
		return to_hex(message).get("value")
	if message is String:
		return message
	return null

func _uses_native_confirmations() -> bool:
	return _tx_confirm_modal != null and manages_wallet()

func _set_confirm_modal(modal: Object) -> Dictionary:
	if modal == null:
		_tx_confirm_modal = null
		return _success(null)
	if not manages_wallet():
		return _failed("not_supported")
	if not modal.has_method("confirm_request"):
		return _failed("invalid_modal")
	_tx_confirm_modal = modal
	return _success(null)

func _confirm_wallet_request(method: String, payload: Dictionary) -> Dictionary:
	if _tx_confirm_modal != null and not _tx_confirm_modal.has_method("confirm_request"):
		return _failed("invalid_modal")
	if _tx_confirm_modal == null:
		push_warning("It is recommended to use a TXConfirmModal instance to confirm user transactions!")
		return _success(null)
	var approved = await _tx_confirm_modal.confirm_request(method, payload)
	if not bool(approved):
		return _failed("user_rejected")
	return _success(null)

func _confirmation_payload_for_request(method: String, params: Array) -> Dictionary:
	if method == "eth_sign":
		if params.size() < 2:
			return _failed("invalid_params")
		var eth_sign_account := str(params[0])
		if not (await _is_known_account_value(eth_sign_account)):
			return _failed("unknown_account")
		var eth_sign_message = _signature_message_value(params[1])
		if eth_sign_message == null:
			return _failed("invalid_message")
		return _success({
			"kind": "sign",
			"account": eth_sign_account,
			"message": eth_sign_message,
			"params": [eth_sign_account, eth_sign_message],
		})

	if method == "personal_sign":
		if params.size() < 2:
			return _failed("invalid_params")
		var account_index := 1
		var message_index := 0
		if (await _is_known_account_value(params[0])):
			account_index = 0
			message_index = 1
		var personal_account := str(params[account_index])
		if not (await _is_known_account_value(personal_account)):
			return _failed("unknown_account")
		var personal_message = _signature_message_value(params[message_index])
		if personal_message == null:
			return _failed("invalid_message")
		return _success({
			"kind": "sign",
			"account": personal_account,
			"message": personal_message,
			"params": [personal_message, personal_account],
		})

	if _is_typed_data_method(method):
		if params.size() < 2:
			return _failed("invalid_params")
		var typed_data = params[1]
		if typed_data is String:
			var parsed = JSON.parse_string(typed_data)
			if parsed == null:
				return _failed("invalid_typed_data")
			typed_data = parsed
		if not (typed_data is Dictionary):
			return _failed("invalid_typed_data")
		var typed_account := str(params[0])
		if not (await _is_known_account_value(typed_account)):
			return _failed("unknown_account")
		return _success({
			"kind": "typed",
			"account": typed_account,
			"typed_data": typed_data,
			"params": [typed_account, typed_data],
		})

	if method == "eth_signTransaction" or method == "eth_sendTransaction":
		if params.size() < 1 or not (params[0] is Dictionary):
			return _failed("invalid_params")
		var request_tx = params[0]
		var normalized_tx_response = await _normalize_transaction_for_confirmation(request_tx)
		if not normalized_tx_response.get("ok", false):
			return normalized_tx_response
		var tx = normalized_tx_response.get("value", {})
		return _success({
			"kind": "transaction",
			"transaction": tx,
			"params": [tx],
		})

	return _success(null)

func _is_typed_data_method(method: String) -> bool:
	return method == "eth_signTypedData" or method == "eth_signTypedData_v3" or method == "eth_signTypedData_v4"

func _contract_invoke_requires_confirmation(method: Variant) -> bool:
	if method is Dictionary:
		var state := str(method.get("stateMutability", "")).to_lower()
		return state != "view" and state != "pure"
	return true

func _first_account() -> Dictionary:
	var accounts = await get_accounts()
	if not accounts.get("ok", false):
		return accounts
	var values = accounts.get("value", [])
	if not (values is Array) or values.is_empty():
		return _failed("no_valid_accounts")
	return _success(str(values[0]))

func _normalize_transaction_for_confirmation(tx_config: Dictionary) -> Dictionary:
	var tx := tx_config.duplicate(true)
	if not tx.has("from"):
		var account_response = await _first_account()
		if not account_response.get("ok", false):
			return account_response
		tx["from"] = account_response.get("value", "")
	if not _is_non_zero_address_value(str(tx.get("from", ""))):
		return _failed("invalid_from")
	if not (await _is_known_account_value(tx.get("from", ""))):
		return _failed("unknown_account")
	if not tx.has("to") or not _is_non_zero_address_value(str(tx.get("to", ""))):
		return _failed("invalid_to")
	var tx_type_response = _transaction_type_code(tx)
	if not tx_type_response.get("ok", false):
		return tx_type_response
	var tx_type := int(tx_type_response.get("value", 0))
	if tx_type == 1 or tx.has("accessList"):
		return _failed("unsupported_transaction_type")
	if tx_type == 2 and not tx.has("maxFeePerGas"):
		return _failed("missing_maxFeePerGas")

	for key in ["value", "gas", "gasLimit", "gasPrice", "maxFeePerGas", "maxPriorityFeePerGas", "nonce", "chainId", "chain_id"]:
		if tx.has(key):
			var normalized = await _normalize_uint_quantity(tx[key])
			if not normalized.get("ok", false):
				return _failed("invalid_%s" % key)
			tx[key] = normalized.get("value", "0x0")

	if tx.has("data") and not _is_even_hex(str(tx["data"])):
		return _failed("invalid_data")
	if tx.has("accessList") and not (tx["accessList"] is Array):
		return _failed("invalid_access_list")

	return _success(tx)

func _normalize_tx_params_for_confirmation(tx_params: Dictionary) -> Dictionary:
	var normalized_tx_params := tx_params.duplicate(true)
	var tx_type_response = _transaction_type_code(normalized_tx_params)
	if not tx_type_response.get("ok", false):
		return tx_type_response
	var tx_type := int(tx_type_response.get("value", 0))
	if tx_type == 1 or normalized_tx_params.has("accessList"):
		return _failed("unsupported_transaction_type")
	if tx_type == 2 and not normalized_tx_params.has("maxFeePerGas"):
		return _failed("missing_maxFeePerGas")
	for key in ["value", "gas", "gasLimit", "gasPrice", "maxFeePerGas", "maxPriorityFeePerGas", "nonce", "chainId", "chain_id"]:
		if normalized_tx_params.has(key):
			var normalized = await _normalize_uint_quantity(normalized_tx_params[key])
			if not normalized.get("ok", false):
				return _failed("invalid_%s" % key)
			normalized_tx_params[key] = normalized.get("value", "0x0")
	if normalized_tx_params.has("from") and not _is_non_zero_address_value(str(normalized_tx_params["from"])):
		return _failed("invalid_from")
	if normalized_tx_params.has("from") and not (await _is_known_account_value(normalized_tx_params["from"])):
		return _failed("unknown_account")
	return _success(normalized_tx_params)

func _transaction_type_code(tx: Dictionary) -> Dictionary:
	if tx.has("type"):
		var raw_type = tx["type"]
		if raw_type is int:
			if int(raw_type) < 0 or int(raw_type) > 2:
				return _failed("invalid_transaction_type")
			return _success(int(raw_type))
		if raw_type is String:
			var type_text := str(raw_type).to_lower()
			if type_text == "legacy":
				return _success(0)
			if type_text == "0" or type_text == "0x0":
				return _success(0)
			if type_text == "1" or type_text == "0x1":
				return _success(1)
			if type_text == "2" or type_text == "0x2":
				return _success(2)
		return _failed("invalid_transaction_type")
	if tx.has("maxFeePerGas") or tx.has("maxPriorityFeePerGas"):
		return _success(2)
	if tx.has("accessList"):
		return _success(1)
	return _success(0)

func _normalize_uint_quantity(value: Variant) -> Dictionary:
	if value is int:
		if int(value) < 0:
			return _failed("invalid_value")
		return await decimal_to_hex(str(value))
	if value is float:
		if float(value) < 0.0 or float(value) != floor(float(value)):
			return _failed("invalid_value")
		return await decimal_to_hex(str(int(value)))
	if not (value is String):
		return _failed("invalid_value")
	var text := String(value)
	if text.begins_with("0x"):
		if not _is_prefixed_hex_quantity(text):
			return _failed("invalid_value")
		return _success(text)
	if not _is_decimal_uint_value(text):
		return _failed("invalid_value")
	return await decimal_to_hex(text)

func _is_known_account_value(value: Variant) -> bool:
	var account := str(value).to_lower()
	var accounts = await get_accounts()
	if not accounts.get("ok", false):
		return false
	var values = accounts.get("value", [])
	if not (values is Array):
		return false
	for candidate in values:
		if str(candidate).to_lower() == account:
			return true
	return false

func _is_decimal_uint_value(value: String) -> bool:
	if value.is_empty():
		return false
	for i in range(value.length()):
		var code = value.unicode_at(i)
		if code < 48 or code > 57:
			return false
	return true

func _is_non_zero_address_value(address: String) -> bool:
	var stripped = _strip_optional_0x(address)
	if stripped.length() != 40:
		return false
	var non_zero := false
	for i in range(stripped.length()):
		var code = stripped.unicode_at(i)
		if not _is_hex_code(code):
			return false
		if code != 48:
			non_zero = true
	return non_zero
