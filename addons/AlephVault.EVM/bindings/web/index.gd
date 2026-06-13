extends RefCounted

const Async = AlephVault__EVM.Utils.Async
const AsyncRequest = preload("./utils/async_request.gd")

## Emitted when the browser wallet reports an account list change.
signal accounts_changed(accounts: Array)

## Emitted when the browser wallet reports a chain change.
signal chain_changed(chain_id: int)

var _ready := false
var _accounts: Array = []
var _chain_id: int = 0
var _accounts_changed_callback = null
var _chain_changed_callback = null

func _init():
	if not OS.has_feature("web"):
		return

	_accounts_changed_callback = JavaScriptBridge.create_callback(_on_accounts_changed)
	_chain_changed_callback = JavaScriptBridge.create_callback(_on_chain_changed)
	JavaScriptBridge.eval("""
		(function () {
			if (!window.ethereum || window.__alephVaultEvmEventsAttached) return;
			window.__alephVaultEvmEventsAttached = true;
			window.ethereum.on('accountsChanged', function (accounts) {
				if (window.__alephVaultEvmAccountsChanged) {
					window.__alephVaultEvmAccountsChanged(JSON.stringify(accounts || []));
				}
			});
			window.ethereum.on('chainChanged', function (chainId) {
				if (window.__alephVaultEvmChainChanged) {
					window.__alephVaultEvmChainChanged(String(chainId));
				}
			});
		}());
	""", true)
	var window = JavaScriptBridge.get_interface("window")
	window.__alephVaultEvmAccountsChanged = _accounts_changed_callback
	window.__alephVaultEvmChainChanged = _chain_changed_callback

## Requests account access from the EIP-1193 provider and marks the binding ready.
##
## Returns {"ok": true, "value": null} on success, or a standard failure
## dictionary. Accounts are cached internally and exposed through get_accounts().
func initialize():
	var response = await _request("eth_requestAccounts", [])
	if not response.get("ok", false):
		var error = response.get("error")
		if error is Dictionary and int(error.get("code", 0)) == 4001:
			return Async.failed("user_rejected")
		return response

	var value = response.get("value", [])
	if not (value is Array) or value.is_empty():
		return Async.failed("no_valid_accounts")

	_ready = true
	_accounts = value
	var chain_response = await get_chain_id()
	if chain_response.get("ok", false):
		_chain_id = int(chain_response["value"])
	return Async.success(null)

## Gets the currently selected chain id from the provider.
##
## The successful value is an int decoded from the provider's hex chain id.
func get_chain_id():
	if not _ready:
		return Async.failed("not_ready")

	var response = await _request("eth_chainId", [])
	if not response.get("ok", false):
		return response

	_chain_id = _hex_quantity_to_int(String(response.get("value", "0x0")))
	return Async.success(_chain_id)

## Returns true because browser wallets can be asked to switch chains.
func can_set_chain_id() -> bool:
	return true

## Requests a wallet chain switch to chain_id.
##
## The chain id must be positive. The web binding calls
## wallet_switchEthereumChain with a canonical 0x-prefixed hex quantity.
func set_chain_id(chain_id: int):
	if not _ready:
		return Async.failed("not_ready")
	if chain_id <= 0:
		return Async.failed("invalid_chain")

	var response = await _request("wallet_switchEthereumChain", [{"chainId": _int_to_hex_quantity(chain_id)}])
	if not response.get("ok", false):
		return Async.failed("invalid_chain")

	_chain_id = chain_id
	return Async.success(null)

## Gets the currently exposed wallet accounts.
##
## This does not request new permissions; initialize() is responsible for that.
func get_accounts():
	if not _ready:
		return Async.failed("not_ready")

	var response = await _request("eth_accounts", [])
	if not response.get("ok", false):
		return response

	_accounts = response.get("value", [])
	return Async.success(_accounts)

## Gets the balance for a valid non-zero EVM address.
##
## The successful value is a decimal numeric string denominated in wei.
func get_balance(address: String):
	if not _ready:
		return Async.failed("not_ready")
	return await _promise("window.alephVaultEvmWeb3.getBalance(%s)" % _json(address))

## Transfers wei to a valid non-zero EVM address.
##
## amount is a decimal numeric string denominated in wei. tx_config is a
## JSON-serializable EVM transaction configuration dictionary. Common keys are
## "from", "value", "gas", "gasLimit", "gasPrice", "maxFeePerGas",
## "maxPriorityFeePerGas", "nonce", "chainId", "chain_id", and "data".
## Numeric fields accept decimal strings, 0x-prefixed hex quantities, or JSON
## integers; use strings for large values. The web binding sets "to" and
## "value" from address and amount, so callers should not rely on conflicting
## tx_config values for those keys.
func transfer(address: String, amount: String, tx_config: Dictionary):
	if not _ready:
		return Async.failed("not_ready")
	return await _promise("window.alephVaultEvmWeb3.transfer(%s, %s, %s)" % [_json(address), _json(amount), _json(tx_config)])

## Waits until a transaction receipt exists.
##
## The successful value is the provider's transaction receipt dictionary. If
## the receipt status is failed, the receipt itself is returned as the error.
func wait_for(tx_hash: String):
	if not _ready:
		return Async.failed("not_ready")
	return await _promise("window.alephVaultEvmWeb3.waitFor(%s)" % _json(tx_hash))

## Performs an arbitrary EIP-1193 provider request.
##
## The request is forwarded as {method, params}. Only eth_requestAccounts is
## allowed before the binding is ready.
func request(method: String, params: Array):
	if not _ready and method != "eth_requestAccounts":
		return Async.failed("not_ready")
	return await _request(method, params)

## Stores an ABI in the JavaScript-side ABI cache.
##
## The key must be an alphanumeric/underscore identifier. Contract helpers use
## this cache to create and reuse web3.eth.Contract instances.
func set_abi(key: String, abi: Array[Dictionary]):
	return _eval_response("window.alephVaultEvmWeb3.setAbi(%s, %s)" % [_json(key), _json(abi)])

## Gets an ABI from the JavaScript-side ABI cache.
func get_abi(key: String):
	return _eval_response("window.alephVaultEvmWeb3.getAbi(%s)" % _json(key))

## ABI-encodes arguments using standard Solidity ABI encoding.
##
## Each element can be a plain value or {"type": String, "value": Variant}.
## Plain byte integer arrays infer as bytes; Solidity arrays require an
## explicit array type.
func abi_encode(args: Array):
	return _bytes_response(_eval_response("window.alephVaultEvmWeb3.abiEncode(%s)" % _json(args)))

## ABI-encodes arguments using packed Solidity ABI encoding.
##
## Each element follows the same format as abi_encode(args).
func abi_encode_packed(args: Array):
	return _bytes_response(_eval_response("window.alephVaultEvmWeb3.abiEncodePacked(%s)" % _json(args)))

## ABI-decodes bytes according to a type specification array.
##
## Each spec element can be an EVM type string or an ABI type dictionary.
func abi_decode(args: PackedByteArray, spec: Array):
	return _eval_response("window.alephVaultEvmWeb3.abiDecode(%s, %s)" % [_json(_to_hex_value(args)), _json(spec)])

## Computes Keccak-256 over bytes.
##
## The successful value is exactly 32 bytes.
func keccak256(b: PackedByteArray):
	return _bytes_response(_eval_response("window.alephVaultEvmWeb3.keccak256(%s)" % _json(_to_hex_value(b))))

## Converts a wei-denominated decimal numeric string into unit.
func from_wei(amount: String, unit: String):
	return _eval_response("window.alephVaultEvmWeb3.fromWei(%s, %s)" % [_json(amount), _json(unit)])

## Converts a decimal numeric string from unit into wei.
func to_wei(amount: String, unit: String):
	return _eval_response("window.alephVaultEvmWeb3.toWei(%s, %s)" % [_json(amount), _json(unit)])

## Decodes an even-sized hex string into bytes.
##
## The 0x prefix is optional. Empty strings and "0x" succeed with empty bytes.
func from_hex(hex: String):
	if not _is_even_hex(hex):
		return Async.failed("invalid_hex")
	return Async.success(_from_hex_value(hex))

## Converts an address into its EIP-55 checksum representation.
func to_checksum_address(address: String):
	return _eval_response("window.alephVaultEvmWeb3.toChecksumAddress(%s)" % _json(address))

## Converts a decimal numeric string into a 0x-prefixed hex quantity.
func decimal_to_hex(decimal: String):
	return _eval_response("window.alephVaultEvmWeb3.decimalToHex(%s)" % _json(decimal))

## Converts a 0x-prefixed hex quantity into a decimal numeric string.
func hex_to_decimal(hex: String):
	return _eval_response("window.alephVaultEvmWeb3.hexToDecimal(%s)" % _json(hex))

## Validates value as a uint<size> decimal numeric string.
##
## size must be 8, 16, ..., 256.
func validate_uint(value: String, size: int):
	return _eval_response("window.alephVaultEvmWeb3.validateUint(%s, %d)" % [_json(value), size])

## Validates value as an int<size> decimal numeric string.
##
## size must be 8, 16, ..., 256.
func validate_int(value: String, size: int):
	return _eval_response("window.alephVaultEvmWeb3.validateInt(%s, %d)" % [_json(value), size])

## Validates dynamic bytes or fixed bytes<size>.
##
## PackedByteArray values are checked by byte length. String values must be
## even-sized hexadecimal with an optional 0x prefix. size 0 means dynamic
## bytes; size 1..32 means bytes<size>.
func validate_bytes(value: Variant, size: int = 0):
	if size < 0 or size > 32:
		return Async.failed("invalid_size")
	if value is PackedByteArray:
		var bytes_value: PackedByteArray = value
		if size != 0 and bytes_value.size() != size:
			return Async.failed("invalid_value")
		return Async.success(null)
	if not (value is String):
		return Async.failed("invalid_value")
	var string_value: String = value
	if not _is_even_hex(string_value):
		return Async.failed("invalid_value")
	var stripped = _strip_optional_0x(string_value)
	if size != 0 and stripped.length() != size * 2:
		return Async.failed("invalid_value")
	return Async.success(null)

## Validates an EVM address string.
##
## Valid values match (0x)?[0-9a-fA-F]{40}. When checksum is true, the value
## must also satisfy EIP-55 checksum rules.
func validate_address(value: String, checksum: bool = false):
	return _eval_response("window.alephVaultEvmWeb3.validateAddress(%s, %s)" % [_json(value), _json(checksum)])

## Returns false because browser wallets keep wallet/account material outside
## this binding.
func manages_wallet() -> bool:
	return false

## Encodes bytes as a 0x-prefixed lowercase hex string.
func to_hex(value: PackedByteArray):
	return Async.success(_to_hex_value(value))

## Validates an EVM JSON-RPC block tag.
##
## Valid values are "earliest", "latest", "pending", "safe", "finalized", or
## a canonical 0x-prefixed hex quantity without leading zeroes except "0x0".
func validate_block_tag(tag: String):
	if _is_named_block_tag(tag) or _is_prefixed_hex_quantity(tag):
		return Async.success(null)
	return Async.failed("invalid_value")

## Creates and caches a web3.eth.Contract instance in JavaScript.
##
## The address must be valid and non-zero. abi_key must refer to a registered
## ABI in the JavaScript-side ABI cache.
func contract_create(address: String, abi_key: String):
	return _eval_response("window.alephVaultEvmWeb3.contractCreate(%s, %s)" % [_json(address), _json(abi_key)])

## Invokes a method on a cached contract.
##
## method can be a function name or a function ABI entry dictionary. params are
## passed to the Web3 method builder. tx_params uses the same JSON-serializable
## EVM transaction configuration dictionary syntax as transfer()'s tx_config.
## Contract view/pure calls may also pass "block" or "blockTag".
func contract_invoke(address: String, method: Variant, params: Array, tx_params: Dictionary):
	if not _ready:
		return Async.failed("not_ready")
	return await _promise("window.alephVaultEvmWeb3.contractInvoke(%s, %s, %s, %s)" % [_json(address), _json(method), _json(params), _json(tx_params)])

## Gets ABI-decoded past events for a cached contract.
##
## event can be an event name or event ABI entry dictionary. topics can be an
## array of up to three 32-byte topic strings/nulls or a dictionary keyed by
## indexed field names. from and to must be valid block tags.
func contract_get_events(address: String, event: Variant, topics: Variant, from: String = "0x0", to: String = "latest"):
	if not _ready:
		return Async.failed("not_ready")
	if not (_is_named_block_tag(from) or _is_prefixed_hex_quantity(from)):
		return Async.failed("invalid_block_tag")
	if not (_is_named_block_tag(to) or _is_prefixed_hex_quantity(to)):
		return Async.failed("invalid_block_tag")
	return await _promise("window.alephVaultEvmWeb3.contractGetEvents(%s, %s, %s, %s, %s)" % [_json(address), _json(event), _json(topics), _json(from), _json(to)])

## Decodes matching logs from a transaction receipt returned by wait_for().
##
## If event is null, all decodable events are returned; logs that cannot be
## decoded with cached contract ABIs are returned as rawLog entries.
func contract_get_tx_events(tx_obj: Dictionary, event: Variant = null):
	return _eval_response("window.alephVaultEvmWeb3.contractGetTxEvents(%s, %s)" % [_json(tx_obj), _json(event)])

func _request(method: String, params: Array):
	return await _promise("window.web3.provider.request({method: %s, params: %s})" % [_json(method), _json(params)])

func _promise(expression: String):
	return await AsyncRequest.process(expression).wait()

func _eval_response(expression: String) -> Dictionary:
	var raw = JavaScriptBridge.eval(expression, true)
	if raw == null:
		return Async.failed("incomplete_binding")
	var parsed = JSON.parse_string(String(raw))
	if not (parsed is Dictionary):
		return Async.failed("invalid_response")
	return parsed

func _bytes_response(response: Dictionary) -> Dictionary:
	if not response.get("ok", false):
		return response
	if not (response.get("value") is String):
		return Async.failed("invalid_response")
	return from_hex(response["value"])

func _json(value: Variant) -> String:
	return JSON.stringify(value)

func _to_hex_value(value: PackedByteArray) -> String:
	var hex = "0x"
	for byte in value:
		hex += "%02x" % byte
	return hex

func _from_hex_value(hex: String) -> PackedByteArray:
	var stripped = _strip_optional_0x(hex)
	var bytes = PackedByteArray()
	for i in range(0, stripped.length(), 2):
		bytes.append(_hex_code_to_int(stripped.unicode_at(i)) * 16 + _hex_code_to_int(stripped.unicode_at(i + 1)))
	return bytes

func _strip_optional_0x(hex: String) -> String:
	if hex.begins_with("0x"):
		return hex.substr(2)
	return hex

func _has_misplaced_0x(hex: String) -> bool:
	return hex.find("0x", 1) != -1

func _is_hex_code(code: int) -> bool:
	return (code >= 48 and code <= 57) or (code >= 65 and code <= 70) or (code >= 97 and code <= 102)

func _hex_code_to_int(code: int) -> int:
	if code >= 48 and code <= 57:
		return code - 48
	if code >= 65 and code <= 70:
		return code - 55
	return code - 87

func _is_even_hex(hex: String) -> bool:
	if _has_misplaced_0x(hex):
		return false
	var stripped = _strip_optional_0x(hex)
	if stripped.length() % 2 != 0:
		return false
	for i in range(stripped.length()):
		if not _is_hex_code(stripped.unicode_at(i)):
			return false
	return true

func _is_prefixed_hex_quantity(hex: String) -> bool:
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

func _is_named_block_tag(tag: String) -> bool:
	return tag == "earliest" or tag == "latest" or tag == "pending" or tag == "safe" or tag == "finalized"

func _int_to_hex_quantity(value: int) -> String:
	return "0x%x" % value

func _hex_quantity_to_int(hex: String) -> int:
	var result = 0
	for i in range(2, hex.length()):
		result = result * 16 + _hex_code_to_int(hex.unicode_at(i))
	return result

func _on_accounts_changed(args: Array):
	if args.size() < 1 or not (args[0] is String):
		return
	var parsed = JSON.parse_string(args[0])
	if parsed is Array:
		_accounts = parsed
		accounts_changed.emit(_accounts)

func _on_chain_changed(args: Array):
	if args.size() < 1:
		return
	_chain_id = _hex_quantity_to_int(String(args[0]))
	chain_changed.emit(_chain_id)
