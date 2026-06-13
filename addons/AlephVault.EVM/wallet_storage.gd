extends RefCounted
class_name AlephVault__EVM_WalletStorage
## Native-only encrypted wallet storage for imported EVM private keys.
##
## Rationale:
## - This class deliberately stores only imported private keys. No seed phrase
##   or deterministic account derivation is involved.
## - The storage file lives under user://AlephVault.EVM, which is scoped by
##   Godot to the current game's user data directory on every platform. That
##   keeps wallet files from different games separated by the engine's storage
##   model, and the addon subdirectory avoids collisions with other game data.
## - Only one storage object should be used per game process. singleton()
##   enforces that convention for consumers that want a shared instance.
## - Names are plaintext metadata. Private keys are encrypted account by
##   account. Addresses are derived in memory for duplicate detection and are
##   not persisted. The sentinel is encrypted with the same password-derived
##   key so an empty wallet can still validate a password.
## - The password is never stored. Unlock derives a temporary encryption/MAC
##   key pair and keeps it in memory until lock() is called.

const STORAGE_DIR := "user://AlephVault.EVM"
const STORAGE_PATH := "user://AlephVault.EVM/wallet_storage.json"
const STORAGE_TMP_PATH := "user://AlephVault.EVM/wallet_storage.tmp"
const STORAGE_BAK_PATH := "user://AlephVault.EVM/wallet_storage.bak"
const VERSION := 1
const KDF_ITERATIONS := 50000
const KDF_NAME := "pbkdf2-hmac-sha256"
const SENTINEL_TEXT := "AlephVault.EVM.wallet_storage.v1"

static var _singleton = null

var _unlocked := false
var _enc_key := PackedByteArray()
var _mac_key := PackedByteArray()
var _accounts: Array = []
var _validator: Object = null

static func singleton():
	if _singleton == null:
		_singleton = AlephVault__EVM_WalletStorage.new()
	return _singleton

static func _success(value: Variant) -> Dictionary:
	return {"ok": true, "value": value}

static func _failed(error: String) -> Dictionary:
	return {"ok": false, "error": error}

func _init():
	# Rationale: validating imported private keys should be available before
	# the main native wallet binding is initialized. The Rust extension exposes
	# validate_private_key without requiring wallet readiness, so storage can use
	# a tiny private validator instance only for address derivation.
	if not OS.has_feature("web") and ClassDB.class_exists("AlephVaultEvmNativeWallet"):
		_validator = ClassDB.instantiate("AlephVaultEvmNativeWallet")

func is_supported() -> bool:
	return not OS.has_feature("web") and _validator != null

func exists() -> bool:
	return FileAccess.file_exists(STORAGE_PATH) or FileAccess.file_exists(STORAGE_BAK_PATH)

func is_unlocked() -> bool:
	return _unlocked

## Creates the encrypted storage file for a new imported-key wallet.
##
## The password is never persisted. It derives temporary keys used only to
## encrypt a sentinel, which later allows unlock() to detect wrong passwords
## even when no accounts have been imported. Empty passwords are rejected.
func create(password: String) -> Dictionary:
	var supported_response := _require_supported()
	if not supported_response.get("ok", false):
		return supported_response
	if exists():
		return _failed("already_created")
	if password.is_empty():
		return _failed("empty_password")

	var salt := _random_bytes(16)
	if salt.is_empty():
		return _failed("crypto_error")
	var keys := _derive_keys(password, salt)
	if not _keys_valid(keys):
		return _failed("crypto_error")
	var sentinel := _encrypt_json(SENTINEL_TEXT, keys["enc_key"], keys["mac_key"], "sentinel")
	if sentinel.is_empty():
		_clear_key_material(keys["enc_key"], keys["mac_key"])
		return _failed("crypto_error")

	var contents := {
		"version": VERSION,
		"kdf": {
			"name": KDF_NAME,
			"iterations": KDF_ITERATIONS,
			"salt": _to_hex(salt),
		},
		"sentinel": sentinel,
		"accounts": [],
	}

	var save_response := _save_contents(contents)
	_clear_key_material(keys["enc_key"], keys["mac_key"])
	if not save_response.get("ok", false):
		return save_response
	return _success(null)

## Permanently removes the wallet file.
##
## Destroying an unlocked wallet is rejected so callers do not accidentally
## delete persistent storage while decrypted private keys are still live in
## memory. UI should still ask for explicit destructive confirmation.
func destroy() -> Dictionary:
	var supported_response := _require_supported()
	if not supported_response.get("ok", false):
		return supported_response
	if not exists():
		return _failed("not_found")
	if _unlocked:
		return _failed("already_unlocked")

	var deleted_any := false
	if FileAccess.file_exists(STORAGE_PATH):
		var error := DirAccess.remove_absolute(STORAGE_PATH)
		if error != OK:
			return _failed("os_error")
		deleted_any = true
	if FileAccess.file_exists(STORAGE_BAK_PATH):
		var backup_error := DirAccess.remove_absolute(STORAGE_BAK_PATH)
		if backup_error != OK:
			return _failed("os_error")
		deleted_any = true
	if FileAccess.file_exists(STORAGE_TMP_PATH):
		DirAccess.remove_absolute(STORAGE_TMP_PATH)
	if not deleted_any:
		return _failed("os_error")
	return _success(null)

## Derives temporary keys from password, validates the encrypted sentinel, and
## decrypts each imported private key into process memory.
##
## The keys stay resident only until lock(), change_password() replacement, or
## process exit. Wrong passwords fail at the sentinel MAC/decryption step.
func unlock(password: String) -> Dictionary:
	var supported_response := _require_supported()
	if not supported_response.get("ok", false):
		return supported_response
	if _unlocked:
		return _failed("already_unlocked")
	if not exists():
		return _failed("not_found")

	var load_response := _load_contents()
	if not load_response.get("ok", false):
		return load_response
	var contents: Dictionary = load_response["value"]
	var kdf: Dictionary = contents.get("kdf", {})
	if String(kdf.get("name", "")) != KDF_NAME:
		return _failed("invalid_storage")
	var salt := _from_hex(String(kdf.get("salt", "")))
	if salt.is_empty():
		return _failed("invalid_storage")

	var keys := _derive_keys(password, salt, int(kdf.get("iterations", KDF_ITERATIONS)))
	if not _keys_valid(keys):
		return _failed("crypto_error")
	var sentinel = _decrypt_json(contents.get("sentinel", {}), keys["enc_key"], keys["mac_key"], "sentinel")
	if sentinel != SENTINEL_TEXT:
		_clear_key_material(keys["enc_key"], keys["mac_key"])
		return _failed("invalid_password")

	var unlocked_accounts: Array = []
	for entry in contents.get("accounts", []):
		if not (entry is Dictionary):
			_clear_key_material(keys["enc_key"], keys["mac_key"])
			return _failed("invalid_storage")
		var private_key = _decrypt_json(entry.get("key", {}), keys["enc_key"], keys["mac_key"], "account")
		if not (private_key is String):
			_clear_key_material(keys["enc_key"], keys["mac_key"])
			return _failed("invalid_password")
		var validation := _validate_private_key(private_key)
		if not validation.get("ok", false):
			_clear_key_material(keys["enc_key"], keys["mac_key"])
			return _failed("invalid_storage")
		unlocked_accounts.push_back({
			"private_key": private_key,
			"name": _string_or_empty(entry.get("name", "")),
			"address": String(validation["value"]),
		})

	_enc_key = keys["enc_key"]
	_mac_key = keys["mac_key"]
	_accounts = unlocked_accounts
	_unlocked = true
	return _success(null)

## Clears decrypted keys and password-derived key material from this instance.
##
## GDScript cannot guarantee secure memory wiping across VM copies, but the
## method overwrites the byte arrays and removes references held by storage.
func lock() -> Dictionary:
	var supported_response := _require_supported()
	if not supported_response.get("ok", false):
		return supported_response
	if not exists():
		return _failed("not_found")
	if not _unlocked:
		return _failed("not_unlocked")

	_lock_in_memory()
	return _success(null)

## Re-encrypts the sentinel and all imported private keys with a new password.
##
## The wallet must be unlocked because the plaintext private keys are required
## for re-encryption. Empty passwords are rejected just like create().
func change_password(password: String) -> Dictionary:
	var ready_response := _require_unlocked()
	if not ready_response.get("ok", false):
		return ready_response
	if password.is_empty():
		return _failed("empty_password")

	var salt := _random_bytes(16)
	if salt.is_empty():
		return _failed("crypto_error")
	var keys := _derive_keys(password, salt)
	if not _keys_valid(keys):
		return _failed("crypto_error")
	var save_response := _write_unlocked_accounts(keys["enc_key"], keys["mac_key"], salt)
	if not save_response.get("ok", false):
		_clear_key_material(keys["enc_key"], keys["mac_key"])
		return save_response

	_clear_key_material(_enc_key, _mac_key)
	_enc_key = keys["enc_key"]
	_mac_key = keys["mac_key"]
	return _success(null)

## Imports a new private key and immediately rewrites encrypted storage.
##
## Address derivation is delegated to the native extension validator so account
## identity is based on the EVM address, not exact private-key string spelling.
func add_account(private_key: String, name: Variant = "") -> Dictionary:
	var ready_response := _require_unlocked()
	if not ready_response.get("ok", false):
		return ready_response
	var validation := _validate_private_key(private_key)
	if not validation.get("ok", false):
		return _failed("invalid_private_key")

	var address := String(validation["value"])
	if _account_index(address) != -1:
		return _failed("already_added")

	_accounts.push_back({
		"private_key": private_key,
		"name": _string_or_empty(name),
		"address": address,
	})
	var save_response := _persist_current_accounts()
	if not save_response.get("ok", false):
		_accounts.pop_back()
	return save_response

## Updates plaintext metadata for an existing imported account.
##
## The private key identifies the account through its derived address. The key
## itself is not replaced; this operation changes only the account name.
func update_account(private_key: String, name: Variant = "") -> Dictionary:
	var ready_response := _require_unlocked()
	if not ready_response.get("ok", false):
		return ready_response
	var validation := _validate_private_key(private_key)
	if not validation.get("ok", false):
		return _failed("invalid_private_key")

	var index := _account_index(String(validation["value"]))
	if index == -1:
		return _failed("account_not_found")

	var previous_name = _accounts[index]["name"]
	_accounts[index]["name"] = _string_or_empty(name)
	var save_response := _persist_current_accounts()
	if not save_response.get("ok", false):
		_accounts[index]["name"] = previous_name
	return save_response

## Removes an imported account by derived address and rewrites storage.
func remove_account(private_key: String) -> Dictionary:
	var ready_response := _require_unlocked()
	if not ready_response.get("ok", false):
		return ready_response
	var validation := _validate_private_key(private_key)
	if not validation.get("ok", false):
		return _failed("invalid_private_key")

	var index := _account_index(String(validation["value"]))
	if index == -1:
		return _failed("account_not_found")

	var removed_account: Dictionary = _accounts[index].duplicate(true)
	_accounts.remove_at(index)
	var save_response := _persist_current_accounts()
	if not save_response.get("ok", false):
		_accounts.insert(index, removed_account)
	return save_response

## Returns decrypted imported accounts as {private_key, name} dictionaries.
##
## This intentionally requires an unlocked wallet because private keys are
## decrypted on demand from the in-memory key material.
func list_accounts() -> Dictionary:
	var ready_response := _require_unlocked()
	if not ready_response.get("ok", false):
		return ready_response

	var output: Array = []
	for account in _accounts:
		output.push_back({
			"private_key": account["private_key"],
			"name": account["name"],
		})
	return _success(output)

func _require_unlocked() -> Dictionary:
	var supported_response := _require_supported()
	if not supported_response.get("ok", false):
		return supported_response
	if not exists():
		return _failed("not_found")
	if not _unlocked:
		return _failed("not_unlocked")
	return _success(null)

func _require_supported() -> Dictionary:
	if not is_supported():
		return _failed("incomplete_binding")
	return _success(null)

func _persist_current_accounts() -> Dictionary:
	return _write_unlocked_accounts(_enc_key, _mac_key, _current_salt())

func _write_unlocked_accounts(enc_key: PackedByteArray, mac_key: PackedByteArray, salt: PackedByteArray) -> Dictionary:
	if salt.is_empty():
		return _failed("invalid_storage")

	var encrypted_accounts: Array = []
	for account in _accounts:
		var encrypted_key := _encrypt_json(String(account["private_key"]), enc_key, mac_key, "account")
		if encrypted_key.is_empty():
			return _failed("crypto_error")
		encrypted_accounts.push_back({
			"name": account["name"],
			"key": encrypted_key,
		})

	var sentinel := _encrypt_json(SENTINEL_TEXT, enc_key, mac_key, "sentinel")
	if sentinel.is_empty():
		return _failed("crypto_error")

	return _save_contents({
		"version": VERSION,
		"kdf": {
			"name": KDF_NAME,
			"iterations": KDF_ITERATIONS,
			"salt": _to_hex(salt),
		},
		"sentinel": sentinel,
		"accounts": encrypted_accounts,
	})

func _current_salt() -> PackedByteArray:
	var load_response := _load_contents()
	if not load_response.get("ok", false):
		return PackedByteArray()
	var kdf: Dictionary = load_response["value"].get("kdf", {})
	return _from_hex(String(kdf.get("salt", "")))

func _load_contents() -> Dictionary:
	var path := STORAGE_PATH
	if not FileAccess.file_exists(path) and FileAccess.file_exists(STORAGE_BAK_PATH):
		path = STORAGE_BAK_PATH
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return _failed("os_error")
	var parsed = JSON.parse_string(file.get_as_text())
	if not (parsed is Dictionary):
		return _failed("invalid_storage")
	if int(parsed.get("version", 0)) != VERSION:
		return _failed("invalid_storage")
	return _success(parsed)

func _save_contents(contents: Dictionary) -> Dictionary:
	var dir_error := DirAccess.make_dir_recursive_absolute(STORAGE_DIR)
	if dir_error != OK:
		return _failed("os_error")

	var file := FileAccess.open(STORAGE_TMP_PATH, FileAccess.WRITE)
	if file == null:
		return _failed("os_error")
	file.store_string(JSON.stringify(contents))
	file.close()

	if FileAccess.file_exists(STORAGE_BAK_PATH):
		var remove_backup_error := DirAccess.remove_absolute(STORAGE_BAK_PATH)
		if remove_backup_error != OK:
			DirAccess.remove_absolute(STORAGE_TMP_PATH)
			return _failed("os_error")
	if FileAccess.file_exists(STORAGE_PATH):
		var backup_error := DirAccess.rename_absolute(STORAGE_PATH, STORAGE_BAK_PATH)
		if backup_error != OK:
			DirAccess.remove_absolute(STORAGE_TMP_PATH)
			return _failed("os_error")
	var rename_error := DirAccess.rename_absolute(STORAGE_TMP_PATH, STORAGE_PATH)
	if rename_error != OK:
		DirAccess.remove_absolute(STORAGE_TMP_PATH)
		if FileAccess.file_exists(STORAGE_BAK_PATH):
			DirAccess.rename_absolute(STORAGE_BAK_PATH, STORAGE_PATH)
		return _failed("os_error")
	if FileAccess.file_exists(STORAGE_BAK_PATH):
		DirAccess.remove_absolute(STORAGE_BAK_PATH)
	return _success(null)

func _validate_private_key(private_key: String) -> Dictionary:
	if _validator == null:
		return _failed("incomplete_binding")
	return _validator.validate_private_key(private_key)

func _account_index(address: String) -> int:
	for i in range(_accounts.size()):
		if String(_accounts[i].get("address", "")).to_lower() == address.to_lower():
			return i
	return -1

func _encrypt_json(value: Variant, enc_key: PackedByteArray, mac_key: PackedByteArray, aad: String) -> Dictionary:
	var plaintext := JSON.stringify(value).to_utf8_buffer()
	var nonce := _random_bytes(12)
	if nonce.is_empty():
		return {}
	var ciphertext := _crypt_ctr(plaintext, enc_key, nonce)
	if ciphertext.is_empty() and not plaintext.is_empty():
		return {}
	return {
		"nonce": _to_hex(nonce),
		"ciphertext": _to_hex(ciphertext),
		"mac": _to_hex(_mac(mac_key, aad, nonce, ciphertext)),
	}

func _decrypt_json(payload: Variant, enc_key: PackedByteArray, mac_key: PackedByteArray, aad: String) -> Variant:
	if not (payload is Dictionary):
		return null
	var nonce := _from_hex(String(payload.get("nonce", "")))
	var ciphertext := _from_hex(String(payload.get("ciphertext", "")))
	var expected_mac := _from_hex(String(payload.get("mac", "")))
	if nonce.size() != 12 or expected_mac.size() != 32:
		return null
	var actual_mac := _mac(mac_key, aad, nonce, ciphertext)
	if not _constant_time_equal(actual_mac, expected_mac):
		return null
	var plaintext := _crypt_ctr(ciphertext, enc_key, nonce)
	return JSON.parse_string(plaintext.get_string_from_utf8())

func _derive_keys(password: String, salt: PackedByteArray, iterations: int = KDF_ITERATIONS) -> Dictionary:
	var password_bytes := password.to_utf8_buffer()
	var material := _pbkdf2_hmac_sha256(password_bytes, salt, max(1, iterations), 32)
	if material.size() != 32:
		return {}
	return {
		"enc_key": _hmac_sha256(material, "enc".to_utf8_buffer()),
		"mac_key": _hmac_sha256(material, "mac".to_utf8_buffer()),
	}

func _crypt_ctr(input: PackedByteArray, key: PackedByteArray, nonce: PackedByteArray) -> PackedByteArray:
	if key.size() != 32 or nonce.size() != 12:
		return PackedByteArray()
	var output := PackedByteArray()
	output.resize(input.size())
	var counter := 0
	var offset := 0
	while offset < input.size():
		var stream := _aes_block(key, _counter_block(nonce, counter))
		if stream.size() != 16:
			return PackedByteArray()
		for i in range(min(16, input.size() - offset)):
			output[offset + i] = input[offset + i] ^ stream[i]
		counter += 1
		offset += 16
	return output

func _aes_block(key: PackedByteArray, block: PackedByteArray) -> PackedByteArray:
	var aes := AESContext.new()
	if aes.start(AESContext.MODE_ECB_ENCRYPT, key) != OK:
		return PackedByteArray()
	var output := aes.update(block)
	aes.finish()
	return output

func _counter_block(nonce: PackedByteArray, counter: int) -> PackedByteArray:
	var block := PackedByteArray()
	for i in range(12):
		block.append(nonce[i])
	block.append((counter >> 24) & 0xff)
	block.append((counter >> 16) & 0xff)
	block.append((counter >> 8) & 0xff)
	block.append(counter & 0xff)
	return block

func _mac(key: PackedByteArray, aad: String, nonce: PackedByteArray, ciphertext: PackedByteArray) -> PackedByteArray:
	return _hmac_sha256(key, _join_bytes([
		"mac:v1".to_utf8_buffer(),
		aad.to_utf8_buffer(),
		nonce,
		ciphertext,
	]))

func _hmac_sha256(key: PackedByteArray, bytes: PackedByteArray) -> PackedByteArray:
	var context := HMACContext.new()
	if context.start(HashingContext.HASH_SHA256, key) != OK:
		return PackedByteArray()
	context.update(bytes)
	return context.finish()

func _pbkdf2_hmac_sha256(password: PackedByteArray, salt: PackedByteArray, iterations: int, output_size: int) -> PackedByteArray:
	var output := PackedByteArray()
	var block_index := 1
	while output.size() < output_size:
		var block_input := PackedByteArray()
		block_input.append_array(salt)
		block_input.append_array(_u32_be(block_index))
		var u := _hmac_sha256(password, block_input)
		if u.size() != 32:
			return PackedByteArray()
		var t := u.duplicate()
		for _i in range(1, iterations):
			u = _hmac_sha256(password, u)
			if u.size() != 32:
				return PackedByteArray()
			for j in range(t.size()):
				t[j] = t[j] ^ u[j]
		output.append_array(t)
		block_index += 1
	return _slice_bytes(output, 0, output_size)

func _keys_valid(keys: Dictionary) -> bool:
	return keys.has("enc_key") and keys.has("mac_key") and keys["enc_key"].size() == 32 and keys["mac_key"].size() == 32

func _u32_be(value: int) -> PackedByteArray:
	var output := PackedByteArray()
	output.append((value >> 24) & 0xff)
	output.append((value >> 16) & 0xff)
	output.append((value >> 8) & 0xff)
	output.append(value & 0xff)
	return output

func _slice_bytes(bytes: PackedByteArray, offset: int, size: int) -> PackedByteArray:
	var output := PackedByteArray()
	for i in range(size):
		output.append(bytes[offset + i])
	return output

func _sha256(bytes: PackedByteArray) -> PackedByteArray:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(bytes)
	return context.finish()

func _random_bytes(size: int) -> PackedByteArray:
	var crypto := Crypto.new()
	return crypto.generate_random_bytes(size)

func _join_bytes(parts: Array) -> PackedByteArray:
	var output := PackedByteArray()
	for part in parts:
		output.append_array(part)
	return output

func _constant_time_equal(a: PackedByteArray, b: PackedByteArray) -> bool:
	if a.size() != b.size():
		return false
	var diff := 0
	for i in range(a.size()):
		diff |= a[i] ^ b[i]
	return diff == 0

func _to_hex(bytes: PackedByteArray) -> String:
	var output := "0x"
	for byte in bytes:
		output += "%02x" % byte
	return output

func _from_hex(hex: String) -> PackedByteArray:
	var value := hex
	if value.begins_with("0x"):
		value = value.substr(2)
	if value.length() % 2 != 0:
		return PackedByteArray()
	var output := PackedByteArray()
	for i in range(0, value.length(), 2):
		var high := _hex_nibble(value.unicode_at(i))
		var low := _hex_nibble(value.unicode_at(i + 1))
		if high < 0 or low < 0:
			return PackedByteArray()
		output.append(high * 16 + low)
	return output

func _hex_nibble(code: int) -> int:
	if code >= 48 and code <= 57:
		return code - 48
	if code >= 65 and code <= 70:
		return code - 55
	if code >= 97 and code <= 102:
		return code - 87
	return -1

func _string_or_empty(value: Variant) -> String:
	if value == null:
		return ""
	return String(value)

func _lock_in_memory():
	_clear_key_material(_enc_key, _mac_key)
	for account in _accounts:
		account["private_key"] = ""
	_accounts.clear()
	_enc_key = PackedByteArray()
	_mac_key = PackedByteArray()
	_unlocked = false

func _clear_key_material(enc_key: PackedByteArray, mac_key: PackedByteArray):
	for i in range(enc_key.size()):
		enc_key[i] = 0
	for i in range(mac_key.size()):
		mac_key[i] = 0
