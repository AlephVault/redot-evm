extends Control

const WalletModal = AlephVault__EVM.UI.WalletModal
const Web3Client = AlephVault__EVM.Web3Client

# Replace these with the values from your Hardhat deployment README.
const HARDHAT_RPC_URL := "http://127.0.0.1:8545"
const DEV_ACCOUNT_ADDRESS := "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
const DEV_ACCOUNT_PRIVATE_KEY := "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
const SMPL_CONTRACT_ADDRESS := "0x0000000000000000000000000000000000000000"
const SMPL_ABI_KEY := "SMPL"
const SMPL_ABI: Array[Dictionary] = [
	{
		"type": "function",
		"name": "balanceOf",
		"stateMutability": "view",
		"inputs": [{"name": "account", "type": "address"}],
		"outputs": [{"name": "", "type": "uint256"}],
	},
	{
		"type": "function",
		"name": "transfer",
		"stateMutability": "nonpayable",
		"inputs": [{"name": "to", "type": "address"}, {"name": "amount", "type": "uint256"}],
		"outputs": [{"name": "", "type": "bool"}],
	},
	{
		"type": "event",
		"name": "Transfer",
		"anonymous": false,
		"inputs": [
			{"name": "from", "type": "address", "indexed": true},
			{"name": "to", "type": "address", "indexed": true},
			{"name": "value", "type": "uint256", "indexed": false},
		],
	},
]

var _client := Web3Client.new()
var _wallet_modal = null
var _native_lock: Callable
var _account := ""
var _chain_id := 0
var _last_event_block := 0

var _app_root: VBoxContainer
var _status_label: Label
var _account_label: Label
var _eth_balance_label: Label
var _smpl_balance_label: Label
var _eth_to_edit: LineEdit
var _eth_amount_edit: LineEdit
var _smpl_to_edit: LineEdit
var _smpl_amount_edit: LineEdit
var _balance_address_edit: LineEdit
var _message_edit: TextEdit
var _signature_edit: TextEdit
var _signature_valid_label: Label
var _typed_signature_edit: TextEdit
var _typed_signature_valid_label: Label
var _tx_events_log: TextEdit
var _background_events_log: TextEdit
var _debug_log: TextEdit
var _poll_timer: Timer
var _lock_button: Button


func _ready() -> void:
	_build_ui()
	_app_root.visible = false
	_status("Starting sample...")
	if _client.manages_wallet():
		await _start_native()
	else:
		await _start_web()


func _start_web() -> void:
	_status("Requesting browser wallet access...")
	var response = await _client.initialize()
	if not response.get("ok", false):
		_status("Web wallet initialization failed: %s" % str(response.get("error", "unknown_error")))
		return
	await _show_app()


func _start_native() -> void:
	_status("Configuring native Hardhat RPC...")
	var chain_response = await _client.set_chain(HARDHAT_RPC_URL)
	if not chain_response.get("ok", false):
		_status("Native chain setup failed: %s" % str(chain_response.get("error", "unknown_error")))
		_log("Start Hardhat on %s, then run the sample again." % HARDHAT_RPC_URL)
		return

	_wallet_modal = WalletModal.new()
	_wallet_modal.client = _client
	_wallet_modal.started.connect(_on_native_wallet_started)
	add_child(_wallet_modal)
	_status("Unlock or import the native wallet.")
	_log("For the Hardhat dev account, restore a text file containing this private key: %s" % DEV_ACCOUNT_PRIVATE_KEY)
	_wallet_modal.show_from_scratch()


func _on_native_wallet_started(lock: Callable) -> void:
	_native_lock = lock
	if _wallet_modal != null:
		_wallet_modal.hide()
	_status("Wallet initialized. Loading Hardhat sample...")
	await _show_app()


func _show_app() -> void:
	var accounts = await _client.get_accounts()
	if not accounts.get("ok", false):
		_status("Account lookup failed: %s" % str(accounts.get("error", "unknown_error")))
		return
	var account_values: Array = accounts.get("value", [])
	if account_values.is_empty():
		_status("No account is available.")
		return
	_account = str(account_values[0])
	_balance_address_edit.text = _account

	var chain_response = await _client.get_chain_id()
	if chain_response.get("ok", false):
		_chain_id = int(chain_response.get("value", 0))

	_account_label.text = "Account: %s | Chain: %s" % [_account, str(_chain_id)]
	_lock_button.visible = _client.manages_wallet()
	_app_root.visible = true

	var abi_response = _client.set_abi(SMPL_ABI_KEY, SMPL_ABI)
	if not abi_response.get("ok", false):
		_status("ABI setup failed: %s" % str(abi_response.get("error", "unknown_error")))
		return
	var contract_response = _client.contract_create(SMPL_CONTRACT_ADDRESS, SMPL_ABI_KEY)
	if not contract_response.get("ok", false):
		_status("Contract setup failed: %s" % str(contract_response.get("error", "unknown_error")))
		_log("Set SMPL_CONTRACT_ADDRESS to your deployed contract address.")
		return

	_status("Ready.")
	await _refresh_balances()
	_start_event_polling()


func _lock_native_wallet() -> void:
	if not _client.manages_wallet() or not _native_lock.is_valid():
		return
	_stop_event_polling()
	_app_root.visible = false
	_account = ""
	_status("Wallet locked.")
	_native_lock.call()


func _refresh_balances() -> void:
	await _query_eth_balance()
	await _query_smpl_balance()


func _query_eth_balance() -> void:
	var address := _balance_address_edit.text.strip_edges()
	var response = await _client.get_balance(address)
	if response.get("ok", false):
		_eth_balance_label.text = "ETH wei: %s" % str(response.get("value", "0"))
	else:
		_eth_balance_label.text = "ETH balance error: %s" % str(response.get("error", "unknown_error"))


func _query_smpl_balance() -> void:
	var address := _balance_address_edit.text.strip_edges()
	var response = await _client.contract_invoke(SMPL_CONTRACT_ADDRESS, "balanceOf", [address], {})
	if response.get("ok", false):
		_smpl_balance_label.text = "SMPL units: %s" % str(response.get("value", "0"))
	else:
		_smpl_balance_label.text = "SMPL balance error: %s" % str(response.get("error", "unknown_error"))


func _transfer_eth() -> void:
	var to := _eth_to_edit.text.strip_edges()
	var amount := _eth_amount_edit.text.strip_edges()
	_status("Sending ETH...")
	var response = await _client.transfer(to, amount, {"from": _account})
	if not response.get("ok", false):
		_status("ETH transfer failed: %s" % str(response.get("error", "unknown_error")))
		return
	var tx_hash := str(response.get("value", ""))
	_log("ETH tx: %s" % tx_hash)
	await _wait_and_log_tx(tx_hash, null)
	await _refresh_balances()


func _transfer_smpl() -> void:
	var to := _smpl_to_edit.text.strip_edges()
	var amount := _smpl_amount_edit.text.strip_edges()
	_status("Sending SMPL...")
	var response = await _client.contract_invoke(
		SMPL_CONTRACT_ADDRESS,
		"transfer",
		[to, amount],
		{"from": _account}
	)
	if not response.get("ok", false):
		_status("SMPL transfer failed: %s" % str(response.get("error", "unknown_error")))
		return
	var tx_hash := str(response.get("value", ""))
	_log("SMPL tx: %s" % tx_hash)
	await _wait_and_log_tx(tx_hash, "Transfer")
	await _refresh_balances()


func _wait_and_log_tx(tx_hash: String, event: Variant) -> void:
	var receipt = await _client.wait_for(tx_hash)
	if not receipt.get("ok", false):
		_status("Transaction failed: %s" % str(receipt.get("error", "unknown_error")))
		return
	_status("Transaction mined: %s" % tx_hash)
	var events = _client.contract_get_tx_events(receipt.get("value", {}), event)
	if events.get("ok", false):
		_tx_events_log.text += JSON.stringify(events.get("value", []), "\t") + "\n"
	else:
		_tx_events_log.text += "Event decode failed: %s\n" % str(events.get("error", "unknown_error"))


func _sign_message() -> void:
	_status("Signing message...")
	var response = await _client.personal_sign(_message_edit.text, _account)
	if response.get("ok", false):
		_signature_edit.text = str(response.get("value", ""))
		_status("Message signed.")
	else:
		_status("Message signing failed: %s" % str(response.get("error", "unknown_error")))


func _verify_message_signature() -> void:
	var response = _client.verify_personal_sign(_account, _message_edit.text, _signature_edit.text.strip_edges())
	if response.get("ok", false):
		_signature_valid_label.text = "Valid: %s" % str(response.get("value", false))
	else:
		_signature_valid_label.text = "Verify error: %s" % str(response.get("error", "unknown_error"))


func _sign_typed_data() -> void:
	_status("Signing typed data...")
	var response = await _client.eth_sign_typed_data(_typed_data(), _account)
	if response.get("ok", false):
		_typed_signature_edit.text = str(response.get("value", ""))
		_status("Typed data signed.")
	else:
		_status("Typed data signing failed: %s" % str(response.get("error", "unknown_error")))


func _verify_typed_data_signature() -> void:
	var response = _client.verify_eth_sign_typed_data(_account, _typed_data(), _typed_signature_edit.text.strip_edges())
	if response.get("ok", false):
		_typed_signature_valid_label.text = "Valid: %s" % str(response.get("value", false))
	else:
		_typed_signature_valid_label.text = "Verify error: %s" % str(response.get("error", "unknown_error"))


func _typed_data() -> Dictionary:
	return {
		"types": {
			"EIP712Domain": [
				{"name": "name", "type": "string"},
				{"name": "version", "type": "string"},
				{"name": "chainId", "type": "uint256"},
				{"name": "verifyingContract", "type": "address"},
			],
			"SampleAction": [
				{"name": "account", "type": "address"},
				{"name": "message", "type": "string"},
				{"name": "nonce", "type": "uint256"},
			],
		},
		"primaryType": "SampleAction",
		"domain": {
			"name": "SMPL",
			"version": "1",
			"chainId": _chain_id,
			"verifyingContract": SMPL_CONTRACT_ADDRESS,
		},
		"message": {
			"account": _account,
			"message": _message_edit.text,
			"nonce": "1",
		},
	}


func _start_event_polling() -> void:
	_stop_event_polling()
	_last_event_block = 0
	_poll_timer.start()
	_poll_events()


func _stop_event_polling() -> void:
	if _poll_timer != null:
		_poll_timer.stop()


func _poll_events() -> void:
	if _account.is_empty():
		return
	var latest_response = await _client.request("eth_blockNumber", [])
	if not latest_response.get("ok", false):
		_log("Event poll block lookup failed: %s" % str(latest_response.get("error", "unknown_error")))
		return
	var latest_hex := str(latest_response.get("value", "0x0"))
	var latest_decimal = _client.hex_to_decimal(latest_hex)
	if not latest_decimal.get("ok", false):
		return
	var latest := int(str(latest_decimal.get("value", "0")))
	var from_block := _last_event_block
	if from_block > latest:
		return
	var from_hex = _client.decimal_to_hex(str(from_block))
	if not from_hex.get("ok", false):
		return
	var events = await _client.contract_get_events(SMPL_CONTRACT_ADDRESS, "Transfer", [], str(from_hex.get("value", "0x0")), latest_hex)
	if events.get("ok", false):
		var values: Array = events.get("value", [])
		for event in values:
			_background_events_log.text += JSON.stringify(event, "\t") + "\n"
		_last_event_block = latest + 1
	else:
		_log("Event poll failed: %s" % str(events.get("error", "unknown_error")))


func _build_ui() -> void:
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_KEEP_SIZE, 12)
	root.add_theme_constant_override("separation", 8)
	add_child(root)

	var header := HBoxContainer.new()
	header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(header)

	var title := Label.new()
	title.text = "Hardhat SMPL Example"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)

	_lock_button = Button.new()
	_lock_button.text = "Lock wallet"
	_lock_button.visible = false
	_lock_button.pressed.connect(_lock_native_wallet)
	header.add_child(_lock_button)

	_status_label = Label.new()
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(_status_label)

	_app_root = VBoxContainer.new()
	_app_root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(_app_root)

	_account_label = Label.new()
	_app_root.add_child(_account_label)

	var tabs := TabContainer.new()
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_app_root.add_child(tabs)

	_add_balances_tab(tabs)
	_add_transfers_tab(tabs)
	_add_signatures_tab(tabs)
	_add_tx_events_tab(tabs)
	_add_event_feed_tab(tabs)
	_add_logs_tab(tabs)

	_poll_timer = Timer.new()
	_poll_timer.wait_time = 5.0
	_poll_timer.timeout.connect(_poll_events)
	add_child(_poll_timer)


func _add_balances_tab(tabs: TabContainer) -> void:
	var tab := _tab("Balances")
	tabs.add_child(tab)
	_balance_address_edit = _line(tab, "Address", DEV_ACCOUNT_ADDRESS)
	_add_button(tab, "Query ETH balance", _query_eth_balance)
	_eth_balance_label = _label(tab, "ETH wei: -")
	_add_button(tab, "Query SMPL balance", _query_smpl_balance)
	_smpl_balance_label = _label(tab, "SMPL units: -")


func _add_transfers_tab(tabs: TabContainer) -> void:
	var tab := _tab("Transfers")
	tabs.add_child(tab)
	_eth_to_edit = _line(tab, "ETH recipient", DEV_ACCOUNT_ADDRESS)
	_eth_amount_edit = _line(tab, "ETH wei amount", "1000000000000000")
	_add_button(tab, "Transfer ETH", _transfer_eth)
	_smpl_to_edit = _line(tab, "SMPL recipient", DEV_ACCOUNT_ADDRESS)
	_smpl_amount_edit = _line(tab, "SMPL amount", "1000000000000000000")
	_add_button(tab, "Transfer SMPL", _transfer_smpl)


func _add_signatures_tab(tabs: TabContainer) -> void:
	var tab := _tab("Signatures")
	tabs.add_child(tab)
	_message_edit = TextEdit.new()
	_message_edit.text = "Sign in to the SMPL Hardhat example"
	_message_edit.custom_minimum_size = Vector2(0, 90)
	tab.add_child(_message_edit)
	_add_button(tab, "Sign message", _sign_message)
	_signature_edit = _text_log(tab, 80)
	_add_button(tab, "Verify message signature", _verify_message_signature)
	_signature_valid_label = _label(tab, "Valid: -")
	_add_button(tab, "Sign EIP-712 typed data", _sign_typed_data)
	_typed_signature_edit = _text_log(tab, 80)
	_add_button(tab, "Verify EIP-712 signature", _verify_typed_data_signature)
	_typed_signature_valid_label = _label(tab, "Valid: -")


func _add_tx_events_tab(tabs: TabContainer) -> void:
	var tab := _tab("Tx Events")
	tabs.add_child(tab)
	_label(tab, "Per-transaction decoded events")
	_tx_events_log = _text_log(tab, 150)


func _add_event_feed_tab(tabs: TabContainer) -> void:
	var tab := _tab("Event Feed")
	tabs.add_child(tab)
	_label(tab, "Background Transfer event list")
	_background_events_log = _text_log(tab, 220)


func _add_logs_tab(tabs: TabContainer) -> void:
	var tab := _tab("Logs")
	tabs.add_child(tab)
	_debug_log = _text_log(tab, 360)


func _tab(name: String) -> VBoxContainer:
	var tab := VBoxContainer.new()
	tab.name = name
	tab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tab.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tab.add_theme_constant_override("separation", 8)
	return tab


func _line(parent: VBoxContainer, placeholder: String, value: String = "") -> LineEdit:
	var edit := LineEdit.new()
	edit.placeholder_text = placeholder
	edit.text = value
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(edit)
	return edit


func _label(parent: VBoxContainer, text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(label)
	return label


func _add_button(parent: VBoxContainer, text: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.pressed.connect(callback)
	parent.add_child(button)
	return button


func _text_log(parent: VBoxContainer, height: int) -> TextEdit:
	var edit := TextEdit.new()
	edit.editable = false
	edit.custom_minimum_size = Vector2(0, height)
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(edit)
	return edit


func _status(message: String) -> void:
	if _status_label != null:
		_status_label.text = message
	_log(message)


func _log(message: String) -> void:
	if _debug_log != null:
		_debug_log.text += message + "\n"
