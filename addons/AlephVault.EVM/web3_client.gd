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
#      Other possible options are "no_valid_chains" if no native chain
#      is configured, or "no_valid_accounts" if no accounts are
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
# 8. (asynchronous) transfer(address: String, amount: String, tx_config: Dictionary) returning:
#    - {"ok": true, "value": String}
#      Where value is the tx. hash.
#    - {"ok": false, "error": String}
#      Where error is an error code. Many errors can occur here, like
#      "not_ready" if the client is not ready yet, "invalid_address"
#      if the address is not valid or "0x000...000" or "invalid_amount"
#      if the amount is not a numeric string.
#    tx_config is a JSON-serializable EVM transaction configuration
#    dictionary. Standard keys include "from", "gas", "gasPrice",
#    "maxFeePerGas", "maxPriorityFeePerGas", "nonce", and "chainId".
#    Bindings may accept extra provider/native-specific keys. transfer()
#    sets "to" and "value" from address and amount, so callers should not
#    rely on conflicting tx_config values for those keys.
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
#
# 13. abi_encode(args: Array) returning:
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
# 14. abi_encode_packed(args: Array) returning:
#     - {"ok": true, "value": PackedByteArray}
#       Where value is the packed ABI encoding of the provided
#       arguments.
#     - {"ok": false, "error": String}
#       Where error can be "incomplete_binding", "invalid_args",
#       "invalid_type", or "invalid_value". They're the same ones that
#       were described for `abi_encode`.
#
# 15. abi_decode(args: PackedByteArray, spec: Array) returning:
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
#      ABI type for this value.
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
# 16. keccak256(b: PackedByteArray) returning:
#     - {"ok": true, "value": PackedByteArray}
#       Where value is exactly 32 bytes.
#     - {"ok": false, "error": String}
#       Where error can be "incomplete_binding" if the binding is not
#       complete enough to compute Keccak-256.
#
# 17. from_wei(amount: String, unit: String) returning:
#     - {"ok": true, "value": String}
#       Where value is the amount converted from wei into unit.
#     - {"ok": false, "error": String}
#       Where error can be "invalid_amount" if amount is not a valid
#       numeric string, "invalid_unit" if unit is not supported, or
#       "incomplete_binding" if the binding is not complete enough to
#       perform bigint unit conversions.
#
# 18. to_wei(amount: String, unit: String) returning:
#     - {"ok": true, "value": String}
#       Where value is the amount converted from unit into wei.
#     - {"ok": false, "error": String}
#       Where error can be "invalid_amount" if amount is not a valid
#       numeric string, "invalid_unit" if unit is not supported, or
#       "incomplete_binding" if the binding is not complete enough to
#       perform bigint unit conversions.
#
# 19. from_hex(hex: String) returning:
#     - {"ok": true, "value": PackedByteArray}
#       Where value is the decoded byte array. "" and "0x" decode
#       successfully into an empty PackedByteArray.
#     - {"ok": false, "error": String}
#       Where error can be "invalid_hex" if hex contains non-hex
#       characters, a misplaced 0x prefix, an odd number of hex digits,
#       or another invalid hex representation.
#
# 20. to_checksum_address(address: String) returning:
#     - {"ok": true, "value": String}
#       Where value is the EIP-55 checksummed address.
#     - {"ok": false, "error": String}
#       Where error can be "invalid_address" if address is not in the
#       0x-prefixed 40-hex-digit address format, or "incomplete_binding"
#       if the binding is not complete enough to compute the checksum.
#
# 21. to_hex(value: PackedByteArray) returning:
#     - {"ok": true, "value": String}
#       Where value is a 0x-prefixed hex string.
#
# 22. decimal_to_hex(decimal: String) returning:
#     - {"ok": true, "value": String}
#       Where value is a 0x-prefixed hex string.
#     - {"ok": false, "error": String}
#       Where error can be "invalid_value" or "incomplete_binding" if the
#       binding is not complete enough to perform bigint conversions.
#
# 23. hex_to_decimal(hex: String) returning:
#     - {"ok": true, "value": String}
#       Where value is a decimal numeric string.
#     - {"ok": false, "error": String}
#       Where error can be "invalid_value" or "incomplete_binding" if the
#       binding is not complete enough to perform bigint conversions.
#
# 24. validate_block_tag(tag: String) returning:
#     - {"ok": true, "value": null}
#     - {"ok": false, "error": String}
#       Where error can be "invalid_value". Valid block tags are
#       "earliest", "latest", "pending", "safe", "finalized", or a
#       canonical 0x-prefixed hex quantity without leading zeroes
#       except for "0x0".
#
# 25. validate_uint(value: String, size: int) returning:
#     - {"ok": true, "value": null}
#     - {"ok": false, "error": String}
#       Where error can be "invalid_value" if value is not a valid uint
#       for the requested size, or "invalid_size" if size is not one of
#       8, 16, ..., 256, or "incomplete_binding" if the binding is not
#       complete enough to validate bigint ranges.
#
# 26. validate_int(value: String, size: int) returning:
#     - {"ok": true, "value": null}
#     - {"ok": false, "error": String}
#       Where error can be "invalid_value" if value is not a valid int
#       for the requested size, or "invalid_size" if size is not one of
#       8, 16, ..., 256, or "incomplete_binding" if the binding is not
#       complete enough to validate bigint ranges.
#
# 27. validate_bytes(value: String | PackedByteArray, size: int = 0) returning:
#     - {"ok": true, "value": null}
#     - {"ok": false, "error": String}
#       Where error can be "invalid_value" if value is not valid for
#       bytes or bytesX, or "invalid_size" if size is not in 0..32.
#       If value is a String, it must be hex with an optional 0x prefix.
#       When size is 0, the hex digit count must be even. When size is
#       1..32, the hex digit count must be exactly size * 2.
#
# 28. validate_address(value: String, checksum: bool = false) returning:
#     - {"ok": true, "value": null}
#     - {"ok": false, "error": String}
#       Where error can be "invalid_value". A valid address is a string
#       matching (0x)?[0-9a-fA-F]{40}. When checksum is true, the address
#       must also satisfy the checksum rules. "incomplete_binding" can be
#       returned if checksum validation is requested but the binding is
#       not complete enough to compute/verify the checksum.
#
# 28a. can_manage_private_keys() returning bool:
#      Returns true when the binding can validate/import local private keys.
#
# 28b. validate_private_key(private_key: String) returning:
#     - {"ok": true, "value": String}
#       Where value is the EIP-55 checksum address derived from the key.
#     - {"ok": false, "error": String}
#       Where error can be "invalid_value", "not_supported", or
#       "incomplete_binding".
#
# --------- Contract-related methods ---------
#
# 29. contract_create(address: String, abi_key: String) returning:
#     - {"ok": true, "value": null}
#       Where the binding creates and stores a contract reference for the
#       address and ABI, such as window.web3.Contract(...) in web builds.
#     - {"ok": false, "error": String}
#       Where error can be "incomplete_binding" if the binding is not
#       available, "invalid_address" if address is not a valid non-zero
#       address, or "not_found" if abi_key does not match a registered ABI.
#     This method is synchronous and only performs setup.
#
# 30. (asynchronous) contract_invoke(
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
#     configuration dictionary syntax as transfer()'s tx_config. Standard
#     keys include "from", "gas", "gasPrice", "maxFeePerGas",
#     "maxPriorityFeePerGas", "nonce", "chainId", and "value".
#
# 31. (asynchronous) contract_get_events(
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
# 32. contract_get_tx_events(
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
##
## Native callback contract:
## - The callback may return the config dictionary directly, or a standard
##   {"ok": true, "value": Dictionary} / {"ok": false, "error": Variant}
##   response.
## - The config must include one fixed native chain: "chain_id" or "chainId"
##   as an integer, decimal string, or 0x-prefixed hex quantity, plus
##   "rpc_url" or "rpcUrl".
## - Accounts are read from "accounts", an array of dictionaries shaped as
##   {"privateKey": "0x...", "name": "My Key"}. "name" may be empty, null,
##   or absent; it is currently metadata only. Every exposed native account is
##   derived from a valid privateKey and can sign locally.
## - Transaction config dictionaries use JSON-RPC/web3 names: "from", "gas",
##   "gasPrice", "maxFeePerGas", "maxPriorityFeePerGas", "nonce", "chainId",
##   and "value". "gasLimit" and "chain_id" are also accepted natively as
##   aliases. Contract view calls may also pass "block" or "blockTag".
func initialize(callback: Callable):
	return _binding.initialize(callback)

## Returns the chain id for this binding. Web bindings can observe wallet-side
## chain changes. Native bindings are initialized with one fixed chain.
func get_chain_id():
	return _binding.get_chain_id()

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
	return _binding.get_balance(address)

## Transfers wei to a valid non-zero EVM address.
##
## amount is a decimal numeric string denominated in wei. tx_config is a
## JSON-serializable EVM transaction configuration dictionary. Standard keys
## include "from", "gas", "gasPrice", "maxFeePerGas",
## "maxPriorityFeePerGas", "nonce", and "chainId"; bindings may accept extra
## provider/native-specific keys. transfer() sets "to" and "value" from
## address and amount, so callers should not rely on conflicting tx_config
## values for those keys.
func transfer(address: String, amount: String, tx_config: Dictionary):
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

## Encodes an ABI argument list using standard ABI encoding.
##
## Each argument can be a plain value, or a dictionary in the form
## {"type": String, "value": Variant} to force a specific EVM type.
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

## Returns whether this binding can validate and manage local private keys.
func can_manage_private_keys() -> bool:
	return _binding.can_manage_private_keys()

## Validates a native private key and returns its derived checksum address.
##
## Web bindings return {"ok": false, "error": "not_supported"}.
func validate_private_key(private_key: String):
	return _binding.validate_private_key(private_key)

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
## as transfer()'s tx_config. Standard keys include "from", "gas", "gasPrice",
## "maxFeePerGas", "maxPriorityFeePerGas", "nonce", "chainId", and "value".
func contract_invoke(address: String, method: Variant, params: Array, tx_params: Dictionary):
	return _binding.contract_invoke(address, method, params, tx_params)

## Gets ABI-decoded events for a registered contract.
##
## Event can be an event name or an ABI entry dictionary. Topics can be an
## array of up to three topic values, or a dictionary keyed by indexed field
## names. Block tags follow validate_block_tag(tag).
func contract_get_events(address: String, event: Variant, topics: Variant, from: String = "0x0", to: String = "latest"):
	return _binding.contract_get_events(address, event, topics, from, to)

## Decodes matching events from a transaction object returned by wait_for().
##
## If event is null, all decodable events are returned, with raw entries for
## logs that cannot be decoded with the current contract ABI.
func contract_get_tx_events(tx_obj: Dictionary, event: Variant = null):
	return _binding.contract_get_tx_events(tx_obj, event)
