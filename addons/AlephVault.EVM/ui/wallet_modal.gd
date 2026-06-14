@tool
extends "res://addons/AlephVault.EVM/ui/modal.gd"


## Emitted after the native wallet has been unlocked and initialized.
##
## The lock callable locks the wallet and reopens this modal from the Welcome
## step, allowing the application to return to the pre-initialized state.
signal started(lock: Callable)

const WalletModalStep = preload("./modal_step.gd")
const Web3Client = preload("../web3_client.gd")

## Web3 client controlled by this wallet modal.
##
## If left null, the modal creates a new Web3Client in _ready(). Assign an
## existing client before _ready() when the application owns the client
## instance and wants the modal to perform the native pre-initialize flow for it.
var client = null
var _pending_password := ""
var _address := ""
var _backup_dialog: FileDialog = null
var _restore_dialog: FileDialog = null
var _file_dialog_step = null


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
			status = "Native wallet management is not available in this environment."
			_add_text("This wallet dialog is intended for native builds. HTML5 builds use the browser wallet directly.")
			return

		var exists_response = modal.client.account_exists()
		if not exists_response.get("ok", false):
			primary_button_visible = false
			secondary_button_visible = false
			status = "Could not inspect wallet state: %s" % str(exists_response.get("error", "unknown_error"))
			return

		if bool(exists_response.get("value", false)):
			_show_existing_wallet()
		else:
			_show_missing_wallet()

	func _show_existing_wallet() -> void:
		rt_button_visible = true
		rt_button_text = "Delete"
		primary_button_visible = true
		primary_button_text = "Unlock"
		secondary_button_visible = true
		secondary_button_text = "Backup"

		_add_text("A native wallet account exists. Enter the master password to unlock it and continue. You can also create a backup of the encrypted account before unlocking.")
		_password_edit = _add_password_edit("Master password")

	func _show_missing_wallet() -> void:
		rt_button_visible = false
		primary_button_visible = true
		primary_button_text = "Create"
		secondary_button_visible = true
		secondary_button_text = "Restore"

		_add_text("No native wallet account exists. Create a new account with a master password, or restore an encrypted account backup.")
		_create_password_edit = _add_password_edit("New master password")
		_create_confirm_edit = _add_password_edit("Confirm master password")

	func _buttonrt_pressed():
		get_parent().current_step = "Deleting"

	func _buttonc1_pressed():
		var modal = get_parent()
		if _password_edit != null:
			status = "Unlocking account..."
			var response = modal.client.account_unlock(_password_edit.text)
			if not response.get("ok", false):
				status = "Unlock failed: %s" % str(response.get("error", "unknown_error"))
				return
			modal._address = str(response.get("value", ""))
			status = "Account unlocked."
			modal.current_step = "Main"
			return

		if _create_password_edit.text.is_empty():
			status = "Enter a password for the new account."
			return
		if _create_password_edit.text != _create_confirm_edit.text:
			status = "Password confirmation does not match."
			return

		modal._pending_password = _create_password_edit.text
		modal.current_step = "Creating"

	func _buttonc2_pressed():
		var modal = get_parent()
		if _password_edit != null:
			status = "Choose a backup destination."
			modal._request_backup(self)
		else:
			status = "Choose a backup file to restore."
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
	##
	## This step never displays or exposes a private key.
	func _on_show() -> void:
		clear_content()
		lt_button_visible = true
		lt_button_text = "Lock"
		rt_button_visible = false
		primary_button_visible = true
		primary_button_text = "Start"
		secondary_button_visible = true
		secondary_button_text = "Change password"
		status = ""

		var modal = get_parent()
		var address := modal._get_current_address()
		_add_text("Unlocked account address:")
		_add_address(address)

	func _buttonlt_pressed():
		var modal = get_parent()
		modal.client.account_lock()
		modal._address = ""
		modal.current_step = "Welcome"

	func _buttonc1_pressed():
		var modal = get_parent()
		status = "Initializing wallet..."
		var response = await modal.client.initialize()
		if not response.get("ok", false):
			status = "Initialization failed: %s" % str(response.get("error", "unknown_error"))
			return
		status = "Wallet initialized."
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
		status = "Creating account..."
		_add_text("Creating account...")
		_create_account()

	func _create_account() -> void:
		var modal = get_parent()
		var response = modal.client.account_create(modal._pending_password)
		modal._pending_password = ""
		if not response.get("ok", false):
			clear_content()
			_add_text("Account creation failed.")
			status = "Creation failed: %s" % str(response.get("error", "unknown_error"))
			primary_button_visible = true
			primary_button_text = "Back"
			return
		status = "Account created. Unlock it to continue."
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
		lt_button_visible = true
		lt_button_text = "Back"
		rt_button_visible = false
		primary_button_visible = true
		primary_button_text = "Confirm deletion"
		secondary_button_visible = false
		status = ""

		_confirmation = _generate_confirmation()
		_add_text("This will permanently delete the encrypted native wallet account from local storage. This action cannot be undone unless you have a valid backup.")
		_add_text("To confirm deletion, type this 8-digit code exactly:")
		_add_code(_confirmation)
		_confirmation_edit = LineEdit.new()
		_confirmation_edit.placeholder_text = "Confirmation code"
		_confirmation_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_confirmation_edit.text_changed.connect(_on_confirmation_changed)
		get_content_container().add_child(_confirmation_edit)
		_set_delete_enabled(false)

	func _buttonlt_pressed():
		get_parent().current_step = "Welcome"

	func _buttonc1_pressed():
		if _confirmation_edit == null or _confirmation_edit.text != _confirmation:
			status = "Type the confirmation code before deleting."
			return
		status = "Deleting account..."
		var modal = get_parent()
		var response = modal.client.account_destroy()
		if not response.get("ok", false):
			status = "Deletion failed: %s" % str(response.get("error", "unknown_error"))
			return
		status = "Account deleted."
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
		lt_button_visible = true
		lt_button_text = "Back"
		rt_button_visible = false
		primary_button_visible = true
		primary_button_text = "Change password"
		secondary_button_visible = false
		status = ""

		_add_text("Choose a new master password for the unlocked wallet. After changing it, the wallet will be locked and you will return to Welcome so you can unlock again.")
		_add_text("The old password cannot be used anymore. Previous backups still require the password that was active when each backup was created. Do not lose the new password; note it before submitting.")
		_password_edit = _add_password_edit("New password")
		_confirm_edit = _add_password_edit("Confirm new password")

	func _buttonlt_pressed():
		get_parent().current_step = "Main"

	func _buttonc1_pressed():
		if _password_edit.text.is_empty():
			status = "Enter a new password."
			return
		if _password_edit.text != _confirm_edit.text:
			status = "Password confirmation does not match."
			return

		status = "Changing password..."
		var modal = get_parent()
		var response = modal.client.account_set_password(_password_edit.text)
		if not response.get("ok", false):
			status = "Password change failed: %s" % str(response.get("error", "unknown_error"))
			return
		modal.client.account_lock()
		modal._address = ""
		status = "Password changed. Unlock with the new password."
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
	step.status = "Creating backup..."
	var response = client.account_backup(path)
	if response.get("ok", false):
		step.status = "Backup created."
	else:
		step.status = "Backup failed: %s" % str(response.get("error", "unknown_error"))


func _on_restore_file_selected(path: String) -> void:
	var step := _file_dialog_step
	_file_dialog_step = null
	if step == null:
		return
	step.status = "Restoring account..."
	var response = client.account_restore(path)
	if response.get("ok", false):
		step.status = "Account restored. Unlock it to continue."
		current_step = "Welcome"
	else:
		step.status = "Restore failed: %s" % str(response.get("error", "unknown_error"))
