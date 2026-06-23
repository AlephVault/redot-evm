extends AlephVault__EVM.UI.Modal


## Emitted after the native wallet has been unlocked and initialized.
##
## The lock callable locks the wallet and reopens this modal from the Welcome
## step, allowing the application to return to the pre-initialized state.
signal started(lock: Callable)

const WalletModalStep = preload("./modal_step.gd")
const Web3Client = preload("../web3_client.gd")

const DEFAULT_TEXTS = {
	"button.back": "Back",
	"button.backup": "Backup",
	"button.change_password": "Change password",
	"button.confirm_deletion": "Confirm deletion",
	"button.create": "Create",
	"button.delete": "Delete",
	"button.lock": "Lock",
	"button.private_key": "Private key",
	"button.restore": "Restore",
	"button.reveal": "Reveal",
	"button.start": "Start",
	"button.unlock": "Unlock",
	"placeholder.confirm_new_password": "Confirm new password",
	"placeholder.confirmation_code": "Confirmation code",
	"placeholder.confirm_master_password": "Confirm master password",
	"placeholder.master_password": "Master password",
	"placeholder.new_master_password": "New master password",
	"placeholder.new_password": "New password",
	"placeholder.private_key_hidden": "Private key hidden",
	"text.account_creation_failed": "Account creation failed.",
	"text.changing_password_intro": "Choose a new master password for the unlocked wallet. After changing it, the wallet will be locked and you will return to Welcome so you can unlock again.",
	"text.changing_password_warning": "The old password cannot be used anymore. Previous backups still require the password that was active when each backup was created. Do not lose the new password; note it before submitting.",
	"text.create_or_restore": "No native wallet account exists. Create a new account with a master password, or restore an encrypted account backup.",
	"text.delete_confirmation_code": "To confirm deletion, type this 8-digit code exactly:",
	"text.delete_warning": "This will permanently delete the encrypted native wallet account from local storage. This action cannot be undone unless you have a valid backup.",
	"text.existing_wallet": "A native wallet account exists. Enter the master password to unlock it and continue. You can also create a backup of the encrypted account before unlocking.",
	"text.native_unavailable": "This wallet dialog is intended for native builds. HTML5 builds use the browser wallet directly.",
	"text.plain_imports": "Plain unencrypted imports are also accepted as a text file containing 0x..., or JSON containing private_key/privateKey. These imports create the encrypted wallet with password \"default\".",
	"text.private_key_warning": "Reveal the private key only when you need to migrate this account to another wallet. Anyone with this value can control the account.",
	"text.unlocked_account_address": "Unlocked account address:",
	"status.account_created": "Account created. Unlock it to continue.",
	"status.account_deleted": "Account deleted.",
	"status.account_restored": "Account restored or imported. Unlock it to continue.",
	"status.account_unlocked": "Account unlocked.",
	"status.backup_created": "Backup created.",
	"status.backup_destination": "Choose a backup destination.",
	"status.backup_failed": "Backup failed: %s",
	"status.chain_setup_failed": "Chain setup failed: %s",
	"status.change_password_failed": "Password change failed: %s",
	"status.change_password_prompt": "Enter a new password.",
	"status.changing_password": "Changing password...",
	"status.confirm_delete_prompt": "Type the confirmation code before deleting.",
	"status.create_password_prompt": "Enter a password for the new account.",
	"status.creating_account": "Creating account...",
	"status.creating_backup": "Creating backup...",
	"status.creation_failed": "Creation failed: %s",
	"status.deleting_account": "Deleting account...",
	"status.deletion_failed": "Deletion failed: %s",
	"status.import_invalid_private_key": "Import failed: invalid private key.",
	"status.initialization_failed": "Initialization failed: %s",
	"status.initializing_wallet": "Initializing wallet...",
	"status.inspect_failed": "Could not inspect wallet state: %s",
	"status.native_unavailable": "Native wallet management is not available in this environment.",
	"status.password_changed": "Password changed. Unlock with the new password.",
	"status.password_confirmation_mismatch": "Password confirmation does not match.",
	"status.private_key_hidden": "Private key hidden.",
	"status.private_key_retrieval_failed": "Private key retrieval failed: %s",
	"status.private_key_retrieved": "Private key revealed.",
	"status.restore_failed": "Restore failed: %s",
	"status.restore_source": "Choose a backup file to restore.",
	"status.restoring_account": "Restoring account...",
	"status.retrieving_private_key": "Retrieving private key...",
	"status.unlock_failed": "Unlock failed: %s",
	"status.unlocking_account": "Unlocking account...",
	"status.wallet_initialized": "Wallet initialized.",
}

## Web3 client controlled by this wallet modal.
##
## If left null, the modal creates a new Web3Client in _ready(). Assign an
## existing client before _ready() when the application owns the client
## instance and wants the modal to perform the native pre-initialize flow for it.
@export var text_overrides: Dictionary = {}
var client = null
var chain_rpc_url := ""
var _pending_password := ""
var _address := ""
var _backup_dialog: FileDialog = null
var _restore_dialog: FileDialog = null
var _file_dialog_step: Control = null


class WelcomeStep:
	extends WalletModalStep

	var _password_edit: LineEdit = null
	var _create_password_edit: LineEdit = null
	var _create_confirm_edit: LineEdit = null

	## Rebuilds the Welcome UI according to native wallet availability.
	##
	## Existing wallets show unlock, backup, and delete actions. Missing wallets
	## show create and restore actions.
	func _on_show() -> void:
		clear_content()
		_password_edit = null
		_create_password_edit = null
		_create_confirm_edit = null
		lt_button_visible = false
		rt_button_visible = false
		secondary_button_visible = true
		status = ""

		var modal = get_parent()
		if not modal._has_native_wallet():
			primary_button_visible = false
			secondary_button_visible = false
			status = modal._text("status.native_unavailable")
			_add_text(modal._text("text.native_unavailable"))
			return

		var exists_response = modal.client.account_exists()
		if not exists_response.get("ok", false):
			primary_button_visible = false
			secondary_button_visible = false
			status = modal._text("status.inspect_failed", [str(exists_response.get("error", "unknown_error"))])
			return

		if bool(exists_response.get("value", false)):
			if await modal._redirect_to_main_if_unlocked():
				return
			_show_existing_wallet()
		else:
			_show_missing_wallet()

	func _show_existing_wallet() -> void:
		var modal = get_parent()
		rt_button_visible = true
		rt_button_text = modal._text("button.delete")
		primary_button_visible = true
		primary_button_text = modal._text("button.unlock")
		secondary_button_visible = true
		secondary_button_text = modal._text("button.backup")

		_add_text(modal._text("text.existing_wallet"))
		_password_edit = _add_password_edit(modal._text("placeholder.master_password"))

	func _show_missing_wallet() -> void:
		var modal = get_parent()
		rt_button_visible = false
		primary_button_visible = true
		primary_button_text = modal._text("button.create")
		secondary_button_visible = true
		secondary_button_text = modal._text("button.restore")

		_add_text(modal._text("text.create_or_restore"))
		_add_text(modal._text("text.plain_imports"))
		_create_password_edit = _add_password_edit(modal._text("placeholder.new_master_password"))
		_create_confirm_edit = _add_password_edit(modal._text("placeholder.confirm_master_password"))

	func _buttonrt_pressed():
		get_parent().current_step = "Deleting"

	func _buttonc1_pressed():
		var modal = get_parent()
		if _password_edit != null:
			if await modal._redirect_to_main_if_unlocked():
				return
			status = modal._text("status.unlocking_account")
			var response = await modal.client.account_unlock(_password_edit.text)
			if not response.get("ok", false):
				if str(response.get("error", "")) == "invalid_state" and await modal._redirect_to_main_if_unlocked():
					return
				status = modal._text("status.unlock_failed", [str(response.get("error", "unknown_error"))])
				return
			modal._address = str(response.get("value", ""))
			status = modal._text("status.account_unlocked")
			modal.current_step = "Main"
			return

		if _create_password_edit.text.is_empty():
			status = modal._text("status.create_password_prompt")
			return
		if _create_password_edit.text != _create_confirm_edit.text:
			status = modal._text("status.password_confirmation_mismatch")
			return

		modal._pending_password = _create_password_edit.text
		modal.current_step = "Creating"

	func _buttonc2_pressed():
		var modal = get_parent()
		if _password_edit != null:
			status = modal._text("status.backup_destination")
			modal._request_backup(self)
		else:
			status = modal._text("status.restore_source")
			modal._request_restore(self)

	func _add_text(text: String) -> Label:
		var label := Label.new()
		label.text = text
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		get_content_container().add_child(label)
		return label

	func _add_password_edit(placeholder: String) -> LineEdit:
		var edit := LineEdit.new()
		edit.placeholder_text = placeholder
		edit.secret = true
		edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		get_content_container().add_child(edit)
		return edit


class MainStep:
	extends WalletModalStep

	## Shows the unlocked address and wallet startup actions.
	func _on_show() -> void:
		clear_content()
		lt_button_visible = true
		var modal = get_parent()
		lt_button_text = modal._text("button.lock")
		rt_button_visible = true
		rt_button_text = modal._text("button.private_key")
		primary_button_visible = true
		primary_button_text = modal._text("button.start")
		secondary_button_visible = true
		secondary_button_text = modal._text("button.change_password")
		status = ""

		var address: String = modal._get_current_address()
		_add_text(modal._text("text.unlocked_account_address"))
		_add_address(address)

	func _buttonlt_pressed():
		var modal = get_parent()
		modal.client.account_lock()
		modal._address = ""
		modal.current_step = "Welcome"

	func _buttonrt_pressed():
		get_parent().current_step = "PrivateKey"

	func _buttonc1_pressed():
		var modal = get_parent()
		status = modal._text("status.initializing_wallet")
		if not modal.chain_rpc_url.is_empty():
			var chain_response = await modal.client.set_chain(modal.chain_rpc_url)
			if not chain_response.get("ok", false):
				status = modal._text("status.chain_setup_failed", [str(chain_response.get("error", "unknown_error"))])
				return
		var response = await modal.client.initialize()
		if not response.get("ok", false):
			status = modal._text("status.initialization_failed", [str(response.get("error", "unknown_error"))])
			return
		status = modal._text("status.wallet_initialized")
		modal.started.emit(Callable(modal, "_lock_and_restart"))

	func _buttonc2_pressed():
		get_parent().current_step = "ChangingPassword"

	func _add_text(text: String) -> Label:
		var label := Label.new()
		label.text = text
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		get_content_container().add_child(label)
		return label

	func _add_address(address: String) -> LineEdit:
		var edit := LineEdit.new()
		edit.text = address
		edit.editable = false
		edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		get_content_container().add_child(edit)
		return edit


class PrivateKeyStep:
	extends WalletModalStep

	var _private_key_edit: LineEdit = null

	## Lets an unlocked-wallet user explicitly reveal the private key for
	## migration to another wallet.
	func _on_show() -> void:
		clear_content()
		_private_key_edit = null
		var modal = get_parent()
		lt_button_visible = true
		lt_button_text = modal._text("button.back")
		rt_button_visible = false
		primary_button_visible = true
		primary_button_text = modal._text("button.reveal")
		secondary_button_visible = false
		status = modal._text("status.private_key_hidden")

		_add_text(modal._text("text.private_key_warning"))
		_private_key_edit = LineEdit.new()
		_private_key_edit.text = ""
		_private_key_edit.placeholder_text = modal._text("placeholder.private_key_hidden")
		_private_key_edit.editable = false
		_private_key_edit.secret = true
		_private_key_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		get_content_container().add_child(_private_key_edit)

	func _buttonlt_pressed():
		get_parent().current_step = "Main"

	func _buttonc1_pressed():
		if _private_key_edit == null:
			return
		var modal = get_parent()
		status = modal._text("status.retrieving_private_key")
		var response = modal.client.account_private_key()
		if not response.get("ok", false):
			status = modal._text("status.private_key_retrieval_failed", [str(response.get("error", "unknown_error"))])
			return
		_private_key_edit.secret = false
		_private_key_edit.text = str(response.get("value", ""))
		primary_button_visible = false
		status = modal._text("status.private_key_retrieved")

	func _add_text(text: String) -> Label:
		var label := Label.new()
		label.text = text
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		get_content_container().add_child(label)
		return label


class CreatingStep:
	extends WalletModalStep

	## Attempts account creation using the password collected in Welcome.
	##
	## On success, the modal returns to Welcome so the user can unlock the new
	## account. On failure, this step shows an error and a Back button.
	func _on_show() -> void:
		clear_content()
		lt_button_visible = false
		rt_button_visible = false
		primary_button_visible = false
		secondary_button_visible = false
		var modal = get_parent()
		status = modal._text("status.creating_account")
		_add_text(modal._text("status.creating_account"))
		_create_account()

	func _create_account() -> void:
		var modal = get_parent()
		var response = await modal.client.account_create(modal._pending_password)
		modal._pending_password = ""
		if not response.get("ok", false):
			clear_content()
			_add_text(modal._text("text.account_creation_failed"))
			status = modal._text("status.creation_failed", [str(response.get("error", "unknown_error"))])
			primary_button_visible = true
			primary_button_text = modal._text("button.back")
			return
		status = modal._text("status.account_created")
		modal.current_step = "Welcome"

	func _buttonc1_pressed():
		get_parent().current_step = "Welcome"

	func _add_text(text: String) -> Label:
		var label := Label.new()
		label.text = text
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		get_content_container().add_child(label)
		return label


class DeletingStep:
	extends WalletModalStep

	var _confirmation := ""
	var _confirmation_edit: LineEdit = null

	## Shows destructive account deletion confirmation.
	##
	## A random 8-digit code must be typed before the delete button is enabled.
	func _on_show() -> void:
		clear_content()
		_confirmation_edit = null
		var modal = get_parent()
		lt_button_visible = true
		lt_button_text = modal._text("button.back")
		rt_button_visible = false
		primary_button_visible = true
		primary_button_text = modal._text("button.confirm_deletion")
		secondary_button_visible = false
		status = ""

		_confirmation = _generate_confirmation()
		_add_text(modal._text("text.delete_warning"))
		_add_text(modal._text("text.delete_confirmation_code"))
		_add_code(_confirmation)
		_confirmation_edit = LineEdit.new()
		_confirmation_edit.placeholder_text = modal._text("placeholder.confirmation_code")
		_confirmation_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_confirmation_edit.text_changed.connect(_on_confirmation_changed)
		get_content_container().add_child(_confirmation_edit)
		_set_delete_enabled(false)

	func _buttonlt_pressed():
		get_parent().current_step = "Welcome"

	func _buttonc1_pressed():
		if _confirmation_edit == null or _confirmation_edit.text != _confirmation:
			status = get_parent()._text("status.confirm_delete_prompt")
			return
		var modal = get_parent()
		status = modal._text("status.deleting_account")
		var response = modal.client.account_destroy()
		if not response.get("ok", false):
			status = modal._text("status.deletion_failed", [str(response.get("error", "unknown_error"))])
			return
		status = modal._text("status.account_deleted")
		modal._address = ""
		modal.current_step = "Welcome"

	func _on_confirmation_changed(value: String) -> void:
		_set_delete_enabled(value == _confirmation)

	func _set_delete_enabled(enabled: bool) -> void:
		if _primary_button != null:
			_primary_button.disabled = not enabled

	func _generate_confirmation() -> String:
		var rng := RandomNumberGenerator.new()
		rng.randomize()
		var value := ""
		for _i in range(8):
			value += str(rng.randi_range(0, 9))
		return value

	func _add_text(text: String) -> Label:
		var label := Label.new()
		label.text = text
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		get_content_container().add_child(label)
		return label

	func _add_code(code: String) -> LineEdit:
		var edit := LineEdit.new()
		edit.text = code
		edit.editable = false
		edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		get_content_container().add_child(edit)
		return edit


class ChangingPasswordStep:
	extends WalletModalStep

	var _password_edit: LineEdit = null
	var _confirm_edit: LineEdit = null

	## Shows the password-change prompt for an unlocked native wallet.
	##
	## Successful changes lock the wallet and return to Welcome, where the new
	## password must be used to unlock again.
	func _on_show() -> void:
		clear_content()
		_password_edit = null
		_confirm_edit = null
		var modal = get_parent()
		lt_button_visible = true
		lt_button_text = modal._text("button.back")
		rt_button_visible = false
		primary_button_visible = true
		primary_button_text = modal._text("button.change_password")
		secondary_button_visible = false
		status = ""

		_add_text(modal._text("text.changing_password_intro"))
		_add_text(modal._text("text.changing_password_warning"))
		_password_edit = _add_password_edit(modal._text("placeholder.new_password"))
		_confirm_edit = _add_password_edit(modal._text("placeholder.confirm_new_password"))

	func _buttonlt_pressed():
		get_parent().current_step = "Main"

	func _buttonc1_pressed():
		var modal = get_parent()
		if _password_edit.text.is_empty():
			status = modal._text("status.change_password_prompt")
			return
		if _password_edit.text != _confirm_edit.text:
			status = modal._text("status.password_confirmation_mismatch")
			return

		status = modal._text("status.changing_password")
		var response = await modal.client.account_set_password(_password_edit.text)
		if not response.get("ok", false):
			status = modal._text("status.change_password_failed", [str(response.get("error", "unknown_error"))])
			return
		modal.client.account_lock()
		modal._address = ""
		status = modal._text("status.password_changed")
		modal.current_step = "Welcome"

	func _add_text(text: String) -> Label:
		var label := Label.new()
		label.text = text
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		get_content_container().add_child(label)
		return label

	func _add_password_edit(placeholder: String) -> LineEdit:
		var edit := LineEdit.new()
		edit.placeholder_text = placeholder
		edit.secret = true
		edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		get_content_container().add_child(edit)
		return edit


func _ready() -> void:
	if client == null:
		client = Web3Client.new()
	_ensure_dialogs()
	super()


func _enter_tree() -> void:
	if _has_steps():
		return

	var welcome := WelcomeStep.new()
	welcome.name = "Welcome"
	add_child(welcome)

	var main := MainStep.new()
	main.name = "Main"
	add_child(main)

	var private_key := PrivateKeyStep.new()
	private_key.name = "PrivateKey"
	add_child(private_key)

	var creating := CreatingStep.new()
	creating.name = "Creating"
	add_child(creating)

	var deleting := DeletingStep.new()
	deleting.name = "Deleting"
	add_child(deleting)

	var changing_password := ChangingPasswordStep.new()
	changing_password.name = "ChangingPassword"
	add_child(changing_password)


## Shows the wallet modal from the Welcome step with transient state cleared.
##
## Use this before native client.initialize() when client.manages_wallet()
## returns true.
func show_from_scratch() -> void:
	_address = ""
	_pending_password = ""
	show()
	current_step = "Welcome"


func _lock_and_restart() -> void:
	if client != null:
		client.account_lock()
	show_from_scratch()


func _has_native_wallet() -> bool:
	return client != null and client.manages_wallet()


func _has_steps() -> bool:
	for child in get_children():
		if child is WalletModalStep:
			return true
	return false


func _get_current_address() -> String:
	if not _address.is_empty():
		return _address
	if client == null:
		return ""
	var response = client.get_accounts()
	if response.get("ok", false):
		var accounts: Array = response.get("value", [])
		if not accounts.is_empty():
			_address = str(accounts[0])
	return _address


func _redirect_to_main_if_unlocked() -> bool:
	var address := await _get_unlocked_wallet_address()
	if address.is_empty():
		return false
	_address = address
	current_step = "Main"
	return true


func _get_unlocked_wallet_address() -> String:
	if not _has_native_wallet():
		return ""

	var response = await client.request("eth_accounts", [])
	if not response.get("ok", false):
		return ""

	var accounts = response.get("value", [])
	if not (accounts is Array) or accounts.is_empty():
		return ""

	return str(accounts[0])


func _text(key: String, values: Array = []) -> String:
	var template := str(text_overrides.get(key, DEFAULT_TEXTS.get(key, key)))
	template = tr(template)
	if values.is_empty():
		return template
	return template % values


func _ensure_dialogs() -> void:
	if _backup_dialog == null:
		_backup_dialog = FileDialog.new()
		_backup_dialog.name = "BackupDialog"
		_backup_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
		_backup_dialog.access = FileDialog.ACCESS_FILESYSTEM
		_backup_dialog.file_selected.connect(_on_backup_file_selected)
		add_child(_backup_dialog)

	if _restore_dialog == null:
		_restore_dialog = FileDialog.new()
		_restore_dialog.name = "RestoreDialog"
		_restore_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		_restore_dialog.access = FileDialog.ACCESS_FILESYSTEM
		_restore_dialog.file_selected.connect(_on_restore_file_selected)
		add_child(_restore_dialog)


func _request_backup(step) -> void:
	_ensure_dialogs()
	_file_dialog_step = step
	_backup_dialog.popup_centered_ratio(0.75)


func _request_restore(step) -> void:
	_ensure_dialogs()
	_file_dialog_step = step
	_restore_dialog.popup_centered_ratio(0.75)


func _on_backup_file_selected(path: String) -> void:
	var step := _file_dialog_step
	_file_dialog_step = null
	if step == null:
		return
	step.status = _text("status.creating_backup")
	var response = await client.account_backup(path)
	if response.get("ok", false):
		step.status = _text("status.backup_created")
	else:
		step.status = _text("status.backup_failed", [str(response.get("error", "unknown_error"))])


func _on_restore_file_selected(path: String) -> void:
	var step := _file_dialog_step
	_file_dialog_step = null
	if step == null:
		return
	step.status = _text("status.restoring_account")
	var response = await client.account_restore(path)
	if response.get("ok", false):
		step.status = _text("status.account_restored")
		current_step = "Welcome"
	else:
		var error := str(response.get("error", "unknown_error"))
		if error == "invalid_private_key":
			step.status = _text("status.import_invalid_private_key")
		else:
			step.status = _text("status.restore_failed", [error])
