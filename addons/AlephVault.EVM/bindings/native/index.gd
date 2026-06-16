extends RefCounted

const Async = AlephVault__EVM.Utils.Async

## Emitted when the native wallet reports an account list change.
signal accounts_changed(accounts: Array)

## Present for compatibility with the common binding surface. The native wallet
## is initialized with one fixed chain, so this signal is never emitted.
signal chain_changed(chain_id: int)

var _wallet: Object = null
var _ready := false
var _config := {}
var _accounts: Array = []
var _chain_id: int = 0

func _init():
	if ClassDB.class_exists("AlephVaultEvmNativeWallet"):
		_wallet = ClassDB.instantiate("AlephVaultEvmNativeWallet")

## Initializes the native wallet from Rust-owned unlocked account and chain
## state. Success returns {"ok": true, "value": null}; address and chain data
## are cached internally and exposed through get_accounts() and get_chain_id().
##
## Transaction config dictionaries use the same names in both bindings:
## "from", "value", "gas", "gasLimit", "gasPrice", "maxFeePerGas",
## "maxPriorityFeePerGas", "nonce", "chainId", "chain_id", and "data".
## Numeric fields accept decimal strings, 0x-prefixed hex quantities, or JSON
## integers; use strings for large values. Contract view calls may also pass
## "block" or "blockTag".
func initialize():
	if _wallet == null:
		return Async.failed("incomplete_binding")

	var response = _wallet.initialize()
	if not response.get("ok", false):
		return response

	var value = response.get("value", {})
	if not (value is Dictionary):
		return Async.failed("invalid_config")
	_config = value
	_ready = true
	_accounts = _config.get("accounts", [])
	_chain_id = int(_config.get("chain_id", _config.get("chainId", 0)))
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return Async.failed("incomplete_binding")
	await tree.process_frame
	return Async.success(null)

func get_chain_id():
	if _wallet == null:
		return Async.failed("incomplete_binding")
	var response = _wallet.get_chain_id()
	if response.get("ok", false):
		_chain_id = int(response.get("value", 0))
	return response

## Returns false because native wallets are initialized with one fixed chain.
func can_set_chain_id() -> bool:
	return false

func set_chain_id(_chain_id: int):
	if _wallet == null:
		return Async.failed("incomplete_binding")
	return Async.failed("not_supported")

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
	return _wallet.request(method, JSON.stringify(params))

func verify_personal_sign(address: String, message: Variant, signature: String):
	if _wallet == null:
		return Async.failed("incomplete_binding")
	if not (message is String):
		return Async.failed("invalid_message")
	return _wallet.verify_personal_sign(address, message, signature)

func recover_personal_sign(message: Variant, signature: String):
	if _wallet == null:
		return Async.failed("incomplete_binding")
	if not (message is String):
		return Async.failed("invalid_message")
	return _wallet.recover_personal_sign(message, signature)

func verify_eth_sign_typed_data(address: String, typed_data: Variant, signature: String):
	if _wallet == null:
		return Async.failed("incomplete_binding")
	return _wallet.verify_eth_sign_typed_data(address, JSON.stringify(typed_data), signature)

func recover_eth_sign_typed_data(typed_data: Variant, signature: String):
	if _wallet == null:
		return Async.failed("incomplete_binding")
	return _wallet.recover_eth_sign_typed_data(JSON.stringify(typed_data), signature)

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

## Returns true because native bindings manage local wallet/account material.
func manages_wallet() -> bool:
	return true

func account_exists():
	if _wallet == null:
		return Async.failed("incomplete_binding")
	return _wallet.account_exists()

func account_create(password: String):
	if _wallet == null:
		return Async.failed("incomplete_binding")
	return await _await_wallet_job(_wallet.account_create_async(password))

func account_destroy():
	if _wallet == null:
		return Async.failed("incomplete_binding")
	var response = _wallet.account_destroy()
	if response.get("ok", false):
		_clear_ready_state()
	return response

func account_backup(target_path: String):
	if _wallet == null:
		return Async.failed("incomplete_binding")
	return await _await_wallet_job(_wallet.account_backup_async(target_path))

func account_restore(source_path: String):
	if _wallet == null:
		return Async.failed("incomplete_binding")
	return await _await_wallet_job(_wallet.account_restore_async(source_path))

func account_unlock(password: String):
	if _wallet == null:
		return Async.failed("incomplete_binding")
	return await _await_wallet_job(_wallet.account_unlock_async(password))

func account_lock():
	if _wallet == null:
		return Async.failed("incomplete_binding")
	var response = _wallet.account_lock()
	if response.get("ok", false):
		_clear_ready_state()
	return response

func account_set_password(password: String):
	if _wallet == null:
		return Async.failed("incomplete_binding")
	return await _await_wallet_job(_wallet.account_set_password_async(password))

func account_private_key():
	if _wallet == null:
		return Async.failed("incomplete_binding")
	return _wallet.account_private_key()

func set_chain(rpc_url: String):
	if _wallet == null:
		return Async.failed("incomplete_binding")
	if not (rpc_url.begins_with("http://") or rpc_url.begins_with("https://")):
		return Async.failed("invalid_rpc_url")
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return Async.failed("incomplete_binding")

	var http := HTTPRequest.new()
	tree.root.add_child.call_deferred(http)
	await tree.process_frame
	await tree.process_frame
	var body := JSON.stringify({
		"jsonrpc": "2.0",
		"id": 1,
		"method": "eth_chainId",
		"params": [],
	})
	var request_error := http.request(
		rpc_url,
		PackedStringArray(["content-type: application/json"]),
		HTTPClient.METHOD_POST,
		body
	)
	if request_error != OK:
		http.queue_free()
		return Async.failed("invalid_chain")

	var result = await http.request_completed
	http.queue_free()
	if not (result is Array) or result.size() < 4:
		return Async.failed("invalid_chain")
	if int(result[0]) != HTTPRequest.RESULT_SUCCESS:
		return Async.failed("invalid_chain")
	var response_code := int(result[1])
	if response_code < 200 or response_code >= 300:
		return Async.failed("invalid_chain")
	var response_body: PackedByteArray = result[3]
	var parsed = JSON.parse_string(response_body.get_string_from_utf8())
	if not (parsed is Dictionary) or parsed.has("error"):
		return Async.failed("invalid_chain")
	var chain_id = _chain_id_from_value(parsed.get("result"))
	if chain_id <= 0:
		return Async.failed("invalid_chain")

	var response = _wallet.set_chain_config(rpc_url, chain_id)
	if not (response is Dictionary):
		return Async.failed("incomplete_binding")
	if not response.get("ok", false):
		return response
	var value = response.get("value", {})
	if value is Dictionary:
		_config = value
		_chain_id = int(_config.get("chain_id", 0))
		_accounts = _config.get("accounts", _accounts)
	return response

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

func _clear_ready_state():
	_ready = false
	_config = {}
	_accounts = []
	_chain_id = 0

func _await_wallet_job(start_response: Dictionary):
	if not start_response.get("ok", false):
		return start_response
	var job_id := int(start_response.get("value", 0))
	if job_id <= 0:
		return Async.failed("incomplete_binding")
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return Async.failed("incomplete_binding")
	while true:
		var poll_response = _wallet.poll_wallet_job(job_id)
		if not poll_response.get("ok", false):
			return poll_response
		if bool(poll_response.get("done", false)):
			var response = poll_response.get("response")
			if response is Dictionary:
				return response
			return Async.failed("incomplete_binding")
		await tree.process_frame

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

func _chain_id_from_value(value: Variant) -> int:
	if value is int:
		return int(value)
	if not (value is String):
		return 0
	var text := String(value)
	if text.begins_with("0x"):
		if not _is_prefixed_hex_quantity(text):
			return 0
		var parsed := 0
		for i in range(2, text.length()):
			parsed = parsed * 16 + _hex_code_to_int(text.unicode_at(i))
		return parsed
	if not _is_decimal_uint(text):
		return 0
	return int(text)
