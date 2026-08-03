extends AlephVault__EVM.UI.Modal


## Emitted when the user approves or rejects the pending wallet operation.
signal decided(approved: bool)

const TXConfirmModalStep = preload("./modal_step.gd")

const DEFAULT_TEXTS = {
	"button.approve": "Approve",
	"button.reject": "Reject",
	"field.access_list": "Access list",
	"field.account": "Account",
	"field.chain_id": "Chain ID",
	"field.contract": "Contract",
	"field.data": "Data",
	"field.from": "From",
	"field.gas": "Gas",
	"field.gas_limit": "Gas limit",
	"field.gas_price": "Gas price",
	"field.max_fee_per_gas": "Max fee per gas",
	"field.max_priority_fee_per_gas": "Max priority fee per gas",
	"field.method": "Method",
	"field.nonce": "Nonce",
	"field.params": "Params",
	"field.to": "To",
	"field.transaction_type": "Transaction type",
	"field.value": "Value",
	"status.review": "Review this native wallet request before continuing.",
	"text.contract_transaction": "Approve this contract transaction.",
	"text.sign_data": "Approve signing this data.",
	"text.sign_typed_data": "Approve signing this typed data.",
	"text.sign_transaction": "Approve signing this transaction.",
	"text.send_transaction": "Approve sending this transaction.",
	"title.contract_invoke": "Contract transaction",
	"title.eth_sendTransaction": "Send transaction",
	"title.eth_sign": "Sign data",
	"title.eth_signTransaction": "Sign transaction",
	"title.eth_signTypedData": "Sign typed data",
	"title.eth_signTypedData_v3": "Sign typed data",
	"title.eth_signTypedData_v4": "Sign typed data",
	"title.personal_sign": "Personal sign",
	"value.legacy": "Legacy",
	"value.type_0": "Legacy",
	"value.type_1": "EIP-2930",
	"value.type_2": "EIP-1559",
	"value.unknown": "Unknown",
}

## Text overrides keyed like DEFAULT_TEXTS. Values pass through tr().
@export var text_overrides: Dictionary = {}

var _pending_method := ""
var _pending_payload: Dictionary = {}
var _waiting := false
var _approved := false


func _init() -> void:
	visible = false


class ReviewStep:
	extends TXConfirmModalStep

	func _on_show() -> void:
		clear_content()
		var modal = get_parent()
		lt_button_visible = false
		rt_button_visible = false
		primary_button_visible = true
		primary_button_text = modal._text("button.approve")
		secondary_button_visible = true
		secondary_button_text = modal._text("button.reject")
		status = modal._text("status.review")

		_add_title(modal._title_for_method(modal._pending_method))
		_add_text(modal._description_for_method(modal._pending_method))
		var kind := str(modal._pending_payload.get("kind", ""))
		if kind == "sign":
			_add_field(modal._text("field.account"), str(modal._pending_payload.get("account", "")))
			_add_field(modal._text("field.data"), str(modal._pending_payload.get("message", "")))
		elif kind == "typed":
			_add_field(modal._text("field.account"), str(modal._pending_payload.get("account", "")))
			_add_value(modal._pending_payload.get("typed_data"))
		elif kind == "transaction":
			_add_transaction(modal._pending_payload.get("transaction", {}))
		elif kind == "contract":
			_add_field(modal._text("field.contract"), str(modal._pending_payload.get("contract", "")))
			_add_field(modal._text("field.method"), str(modal._pending_payload.get("method", "")))
			_add_value({"params": modal._pending_payload.get("params", []), "tx_params": modal._pending_payload.get("tx_params", {})})
		else:
			_add_value(modal._pending_payload)

	func _buttonc1_pressed():
		get_parent()._resolve(true)

	func _buttonc2_pressed():
		get_parent()._resolve(false)

	func _add_title(text: String) -> Label:
		var label := Label.new()
		label.text = text
		label.theme_type_variation = "TXConfirmTitle"
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		get_content_container().add_child(label)
		return label

	func _add_text(text: String) -> Label:
		var label := Label.new()
		label.text = text
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		get_content_container().add_child(label)
		return label

	func _add_field(label_text: String, value: String) -> void:
		var group := VBoxContainer.new()
		group.theme_type_variation = "TXConfirmField"
		group.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		get_content_container().add_child(group)

		var label := Label.new()
		label.text = label_text
		label.theme_type_variation = "TXConfirmFieldLabel"
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		group.add_child(label)

		var edit := LineEdit.new()
		edit.text = value
		edit.editable = false
		edit.theme_type_variation = "TXConfirmFieldValue"
		edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		group.add_child(edit)

	func _add_transaction(tx_value: Variant) -> void:
		var modal = get_parent()
		if not (tx_value is Dictionary):
			_add_value(tx_value)
			return
		var tx = tx_value
		_add_field(modal._text("field.transaction_type"), modal._transaction_type_label(tx))
		for key in ["from", "to", "value", "chainId", "chain_id", "nonce", "gas", "gasLimit", "gasPrice", "maxFeePerGas", "maxPriorityFeePerGas", "data", "accessList"]:
			if tx.has(key):
				_add_field(modal._label_for_tx_key(key), str(tx[key]))

	func _add_value(value: Variant, depth: int = 0) -> void:
		var indent := ""
		for _i in range(depth):
			indent += "  "
		if value is Dictionary:
			for key in value.keys():
				var child = value[key]
				if child is Dictionary or child is Array:
					_add_text("%s%s:" % [indent, str(key)])
					_add_value(child, depth + 1)
				else:
					_add_text("%s%s: %s" % [indent, str(key), str(child)])
		elif value is Array:
			var index := 0
			for child in value:
				if child is Dictionary or child is Array:
					_add_text("%s[%d]:" % [indent, index])
					_add_value(child, depth + 1)
				else:
					_add_text("%s[%d]: %s" % [indent, index, str(child)])
				index += 1
		else:
			_add_text("%s%s" % [indent, str(value)])


func _enter_tree() -> void:
	if _has_steps():
		return
	var review := ReviewStep.new()
	review.name = "Review"
	add_child(review)


func _ready() -> void:
	hide()
	super()


## Shows the confirmation modal and resolves true only when the user approves.
func confirm_request(method: String, payload: Dictionary) -> bool:
	if not is_inside_tree():
		return false
	_pending_method = method
	_pending_payload = payload.duplicate(true)
	_waiting = true
	_approved = false
	show()
	current_step = "Review"
	await decided
	_waiting = false
	hide()
	return _approved


func _resolve(approved: bool) -> void:
	if not _waiting:
		return
	_approved = approved
	decided.emit(approved)


func _has_steps() -> bool:
	for child in get_children():
		if child is TXConfirmModalStep:
			return true
	return false


func _text(key: String, values: Array = []) -> String:
	var template := str(text_overrides.get(key, DEFAULT_TEXTS.get(key, key)))
	template = tr(template)
	if values.is_empty():
		return template
	return template % values


func _title_for_method(method: String) -> String:
	return _text("title.%s" % method)


func _description_for_method(method: String) -> String:
	if method == "personal_sign" or method == "eth_sign":
		return _text("text.sign_data")
	if method.begins_with("eth_signTypedData"):
		return _text("text.sign_typed_data")
	if method == "eth_signTransaction":
		return _text("text.sign_transaction")
	if method == "eth_sendTransaction":
		return _text("text.send_transaction")
	if method == "contract_invoke":
		return _text("text.contract_transaction")
	return _text("status.review")


func _label_for_tx_key(key: String) -> String:
	var labels := {
		"chainId": "field.chain_id",
		"chain_id": "field.chain_id",
		"gas": "field.gas",
		"gasLimit": "field.gas_limit",
		"gasPrice": "field.gas_price",
		"maxFeePerGas": "field.max_fee_per_gas",
		"maxPriorityFeePerGas": "field.max_priority_fee_per_gas",
		"accessList": "field.access_list",
	}
	return _text(str(labels.get(key, "field.%s" % key)))


func _transaction_type_label(tx: Dictionary) -> String:
	var raw_type = tx.get("type", null)
	if raw_type == null:
		if tx.has("maxFeePerGas") or tx.has("maxPriorityFeePerGas"):
			return _text("value.type_2")
		if tx.has("accessList"):
			return _text("value.type_1")
		return _text("value.legacy")
	var type_text := str(raw_type).to_lower()
	if type_text == "0" or type_text == "0x0" or type_text == "legacy":
		return _text("value.type_0")
	if type_text == "1" or type_text == "0x1":
		return _text("value.type_1")
	if type_text == "2" or type_text == "0x2":
		return _text("value.type_2")
	return "%s (%s)" % [_text("value.unknown"), str(raw_type)]
