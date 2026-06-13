extends RefCounted

const Async = AlephVault__EVM.Utils.Async

## Emitted when the native wallet reports an account list change.
signal accounts_changed(accounts: Array)

## Emitted when the browser wallet reports a chain change.
signal chain_changed(chain_id: int)

var _wallet: Object = null
var _ready := false
var _config := {}
var _accounts: Array = []
var _chain_id: int = 0

func _init():
	if ClassDB.class_exists("AlephVaultEvmNativeWallet"):
		_wallet = ClassDB.instantiate("AlephVaultEvmNativeWallet")

## Initializes the native wallet from callback-provided config.
##
## The callback may return either the config dictionary directly or a standard
## {"ok": true, "value": Dictionary} response. Required config:
## - "chains": non-empty Array of chain dictionaries. Each chain needs an id
##   in "id", "chain_id", or "chainId", plus "rpc_url" or "rpcUrl".
## - Optional top-level "chain_id" or "chainId" selects the initial chain.
## - "accounts" is an Array of dictionaries shaped as
##   {"privateKey": "0x...", "name": "My Key"}. "name" may be empty, null, or
##   absent; it is metadata only. Accounts without valid privateKey values are
##   ignored because every native account must support local signing.
func initialize(callback: Callable):
	if _wallet == null:
		return Async.failed("incomplete_binding")
	if not callback.is_valid():
		return Async.failed("invalid_config")

	var config_response = await callback.call()
	if config_response is Dictionary and config_response.has("ok"):
		if not config_response.get("ok", false):
			return config_response
		_config = config_response.get("value", {})
	elif config_response is Dictionary:
		_config = config_response
	else:
		return Async.failed("invalid_config")

	var response = _wallet.initialize(JSON.stringify(_config))
	if not response.get("ok", false):
		return response

	_ready = true
	_accounts = response.get("value", [])
	var chain_response = _wallet.get_chain_id()
	if chain_response.get("ok", false):
		_chain_id = int(chain_response.get("value", 0))
	return Async.success(_accounts)

func get_chain_id():
	if _wallet == null:
		return Async.failed("incomplete_binding")
	var response = _wallet.get_chain_id()
	if response.get("ok", false):
		_chain_id = int(response.get("value", 0))
	return response

func set_chain_id(chain_id: int):
	if _wallet == null:
		return Async.failed("incomplete_binding")
	var response = _wallet.set_chain_id(chain_id, JSON.stringify(_config))
	if response.get("ok", false):
		_chain_id = chain_id
		chain_changed.emit(_chain_id)
	return response

func get_accounts():
	if _wallet == null:
		return Async.failed("incomplete_binding")
	var response = _wallet.get_accounts()
	if response.get("ok", false):
		_accounts = response.get("value", [])
	return response

func get_balance(address: String):
	if not _ready:
		return Async.failed("not_ready")
	if not _is_non_zero_address(address):
		return Async.failed("invalid_address")
	var response = await request("eth_getBalance", [address, "latest"])
	if not response.get("ok", false):
		return response
	var decimal_response = hex_to_decimal(String(response.get("value", "0x0")))
	if not decimal_response.get("ok", false):
		return Async.failed("invalid_response")
	return decimal_response

func transfer(address: String, amount: String, tx_config: Dictionary):
	if not _ready:
		return Async.failed("not_ready")
	if not _is_non_zero_address(address):
		return Async.failed("invalid_address")
	if not _is_decimal_uint(amount):
		return Async.failed("invalid_amount")

	var tx := tx_config.duplicate(true)
	tx["to"] = address
	tx["value"] = (await decimal_to_hex(amount)).get("value", "0x0")
	if not tx.has("from"):
		if _accounts.is_empty():
			return Async.failed("no_valid_accounts")
		tx["from"] = _accounts[0]
	return request("eth_sendTransaction", [tx])

func wait_for(tx_hash: String):
	if not _ready:
		return Async.failed("not_ready")
	if not _is_tx_hash(tx_hash):
		return Async.failed("invalid_tx_hash")

	for _i in range(120):
		var response = await request("eth_getTransactionReceipt", [tx_hash])
		if not response.get("ok", false):
			return response
		var receipt = response.get("value")
		if receipt != null:
			if receipt is Dictionary and String(receipt.get("status", "0x1")) == "0x0":
				return Async.failed(receipt)
			return Async.success(receipt)
		var tree := Engine.get_main_loop() as SceneTree
		if tree == null:
			return Async.failed("incomplete_binding")
		await tree.create_timer(1.0).timeout
	return Async.failed("timeout")

func request(method: String, params: Array):
	if _wallet == null:
		return Async.failed("incomplete_binding")
	if not _ready and method != "eth_accounts" and method != "eth_requestAccounts":
		return Async.failed("not_ready")
	var response = _wallet.request(method, JSON.stringify(params))
	if response.get("ok", false) and method == "wallet_switchEthereumChain":
		var chain_response = _wallet.get_chain_id()
		if chain_response.get("ok", false):
			_chain_id = int(chain_response.get("value", 0))
			chain_changed.emit(_chain_id)
	return response

func set_abi(key: String, abi: Array[Dictionary]):
	if _wallet == null:
		return Async.failed("incomplete_binding")
	return _wallet.set_abi(key, JSON.stringify(abi))

func get_abi(key: String):
	if _wallet == null:
		return Async.failed("incomplete_binding")
	return _wallet.get_abi(key)

func abi_encode(args: Array):
	if _wallet == null:
		return Async.failed("incomplete_binding")
	return _wallet.abi_encode(JSON.stringify(args))

func abi_encode_packed(args: Array):
	if _wallet == null:
		return Async.failed("incomplete_binding")
	return _wallet.abi_encode_packed(JSON.stringify(args))

func abi_decode(args: PackedByteArray, spec: Array):
	if _wallet == null:
		return Async.failed("incomplete_binding")
	return _wallet.abi_decode(args, JSON.stringify(spec))

func keccak256(b: PackedByteArray):
	if _wallet == null:
		return Async.failed("incomplete_binding")
	return _wallet.keccak256(b)

func from_wei(amount: String, unit: String):
	if _wallet == null:
		return Async.failed("incomplete_binding")
	return _wallet.from_wei(amount, unit)

func to_wei(amount: String, unit: String):
	if _wallet == null:
		return Async.failed("incomplete_binding")
	return _wallet.to_wei(amount, unit)

func from_hex(hex: String):
	if not _is_even_hex(hex):
		return Async.failed("invalid_hex")
	return Async.success(_from_hex_value(hex))

func to_checksum_address(address: String):
	if _wallet == null:
		return Async.failed("incomplete_binding")
	return _wallet.to_checksum_address(address)

func decimal_to_hex(decimal: String):
	if _wallet == null:
		return Async.failed("incomplete_binding")
	return _wallet.decimal_to_hex(decimal)

func hex_to_decimal(hex: String):
	if _wallet == null:
		return Async.failed("incomplete_binding")
	return _wallet.hex_to_decimal(hex)

func validate_uint(value: String, size: int):
	if _wallet == null:
		return Async.failed("incomplete_binding")
	return _wallet.validate_uint(value, size)

func validate_int(value: String, size: int):
	if _wallet == null:
		return Async.failed("incomplete_binding")
	return _wallet.validate_int(value, size)

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

func validate_address(value: String, checksum: bool = false):
	if _wallet == null:
		return Async.failed("incomplete_binding")
	return _wallet.validate_address(value, checksum)

func to_hex(value: PackedByteArray):
	var hex := "0x"
	for byte in value:
		hex += "%02x" % byte
	return Async.success(hex)

func validate_block_tag(tag: String):
	if _is_named_block_tag(tag) or _is_prefixed_hex_quantity(tag):
		return Async.success(null)
	return Async.failed("invalid_value")

func contract_create(address: String, abi_key: String):
	if _wallet == null:
		return Async.failed("incomplete_binding")
	return _wallet.contract_create(address, abi_key)

func contract_invoke(address: String, method: Variant, params: Array, tx_params: Dictionary):
	if _wallet == null:
		return Async.failed("incomplete_binding")
	if not _ready:
		return Async.failed("not_ready")
	return _wallet.contract_invoke(address, JSON.stringify(method), JSON.stringify(params), JSON.stringify(tx_params))

func contract_get_events(address: String, event: Variant, topics: Variant, from: String = "0x0", to: String = "latest"):
	if _wallet == null:
		return Async.failed("incomplete_binding")
	if not _ready:
		return Async.failed("not_ready")
	if not (_is_named_block_tag(from) or _is_prefixed_hex_quantity(from)):
		return Async.failed("invalid_block_tag")
	if not (_is_named_block_tag(to) or _is_prefixed_hex_quantity(to)):
		return Async.failed("invalid_block_tag")
	return _wallet.contract_get_events(address, JSON.stringify(event), JSON.stringify(topics), from, to)

func contract_get_tx_events(tx_obj: Dictionary, event: Variant = null):
	if _wallet == null:
		return Async.failed("incomplete_binding")
	return _wallet.contract_get_tx_events(JSON.stringify(tx_obj), JSON.stringify(event))

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

func _from_hex_value(hex: String) -> PackedByteArray:
	var stripped = _strip_optional_0x(hex)
	var bytes = PackedByteArray()
	for i in range(0, stripped.length(), 2):
		bytes.append(_hex_code_to_int(stripped.unicode_at(i)) * 16 + _hex_code_to_int(stripped.unicode_at(i + 1)))
	return bytes

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

func _is_decimal_uint(value: String) -> bool:
	if value.is_empty():
		return false
	for i in range(value.length()):
		var code = value.unicode_at(i)
		if code < 48 or code > 57:
			return false
	return true

func _is_non_zero_address(address: String) -> bool:
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

func _is_tx_hash(tx_hash: String) -> bool:
	if not tx_hash.begins_with("0x") or tx_hash.length() != 66:
		return false
	for i in range(2, tx_hash.length()):
		if not _is_hex_code(tx_hash.unicode_at(i)):
			return false
	return true
