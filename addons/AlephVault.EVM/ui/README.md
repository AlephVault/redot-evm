# AlephVault EVM UI Modals

This directory provides two modal building blocks:

- `modal.gd`: a wizard-style container that shows one modal step at a time.
- `modal_step.gd`: a single responsive step with top buttons, scrollable content, status text, and bottom buttons.
- `wallet_modal.gd`: a native-wallet account management modal built on top of `modal.gd` and `modal_step.gd`.

The namespace entry point is:

```gdscript
const Modal = AlephVault__EVM.UI.Modal
const ModalStep = AlephVault__EVM.UI.ModalStep
const WalletModal = AlephVault__EVM.UI.WalletModal
```

## Creating A Modal

Create a script that extends `modal.gd`. Add child nodes that inherit from `modal_step.gd`. Each step is selected by its node name.

```gdscript
@tool
extends "res://addons/AlephVault.EVM/ui/modal.gd"


class ConnectStep:
	extends ModalStep

	func _ready() -> void:
		super()
		lt_button_visible = false
		rt_button_visible = false
		primary_button_text = "Continue"
		secondary_button_visible = false
		status = "Connect a wallet to continue."

		var label := Label.new()
		label.text = "Choose a wallet and approve the connection."
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		get_content_container().add_child(label)

	func _buttonc1_pressed():
		get_parent().current_step = "Confirm"


class ConfirmStep:
	extends ModalStep

	func _ready() -> void:
		super()
		lt_button_text = "Back"
		rt_button_visible = false
		primary_button_text = "Confirm"
		secondary_button_text = "Cancel"
		status = "Review the transaction."

	func _buttonlt_pressed():
		get_parent().current_step = "Connect"


func _enter_tree() -> void:
	if get_child_count() > 0:
		return

	var connect := ConnectStep.new()
	connect.name = "Connect"
	add_child(connect)

	var confirm := ConfirmStep.new()
	confirm.name = "Confirm"
	add_child(confirm)
```

Then attach the modal script to a `Control` node, or instantiate it from code:

```gdscript
var modal := preload("res://path/to/my_modal.gd").new()
add_child(modal)
modal.current_step = "Connect"
```

`current_step` is exported, so it can also be configured in the inspector. If it is empty or does not match a valid step name, the modal selects the first child that inherits from `ModalStep`.

## ModalStep Layout

Each `ModalStep` creates this internal layout:

1. A top `HBoxContainer` with a left-top button and a right-top button.
2. A vertically scrollable content area.
3. A status `Label`.
4. A bottom `HBoxContainer` with primary and secondary buttons.

Each step anchors itself to full rect inside the `Modal`. The `Modal` applies its exported `Initial Margin` as the outer inset around the whole modal. The default is `16`.

Use `get_content_container()` to add arbitrary content to the scrollable area:

```gdscript
var form := VBoxContainer.new()
get_content_container().add_child(form)
```

Button state can be configured initially through exported fields:

```gdscript
_left_top_button_visible
_left_top_button_text
_right_top_button_visible
_right_top_button_text
_primary_button_visible
_primary_button_text
_secondary_button_visible
_secondary_button_text
```

At runtime, use the public proxy properties. These read and write the actual internal buttons:

```gdscript
lt_button_visible = false
rt_button_text = "Close"
primary_button_text = "Continue"
secondary_button_visible = false
status = "Waiting for confirmation..."
```

Override button hooks in each step:

```gdscript
func _buttonlt_pressed():
	pass

func _buttonrt_pressed():
	pass

func _buttonc1_pressed():
	pass

func _buttonc2_pressed():
	pass
```

## Theme Configuration

Assign a Godot `Theme` to the `Modal` node or to a parent `Control`. Theme values propagate to child controls unless a child has its own theme or override.

The modal step internals use `theme_type_variation` names so a single theme can target different parts of the modal separately:

| Variation | Node |
| --- | --- |
| `ModalLayout` | Root `VBoxContainer` inside a step |
| `ModalTopButtons` | Top `HBoxContainer` |
| `ModalTopButton` | Both top buttons |
| `ModalContentScroll` | `ScrollContainer` around step content |
| `ModalContentCenter` | Centering wrapper inside the scroll area |
| `ModalContent` | Scrollable content `VBoxContainer` |
| `ModalStatusLabel` | Status `Label` |
| `ModalBottomButtons` | Bottom `HBoxContainer` |
| `ModalPrimaryButton` | Primary bottom button |
| `ModalSecondaryButton` | Secondary bottom button |

If a variation does not define an item, Godot falls back to the base type. For example, `ModalPrimaryButton` falls back to `Button`.

### Margins And Spacing

The modal inset is not a theme value. Configure it through the exported `Initial Margin` field on the `Modal`.

For spacing between vertically stacked groups, set the `separation` constant on `ModalLayout`, which is a `VBoxContainer` variation.

For spacing between top buttons or bottom buttons, set the `separation` constant on `ModalTopButtons` or `ModalBottomButtons`, both `HBoxContainer` variations.

In code:

```gdscript
var theme := Theme.new()
theme.set_constant("separation", "ModalLayout", 12)
theme.set_constant("separation", "ModalTopButtons", 8)
theme.set_constant("separation", "ModalBottomButtons", 8)
```

### Widths And Button Sizing

The top buttons keep their natural width and are separated by an expanding spacer, placing one at the left and one at the right.

The bottom buttons use `SIZE_EXPAND_FILL`, so visible buttons split the available width evenly. If only one bottom button is visible, it fills the full width.

Theme constants can change padding inside buttons by changing their styleboxes. Use larger content margins in the stylebox to create wider visual buttons:

```gdscript
var primary_normal := StyleBoxFlat.new()
primary_normal.content_margin_left = 16
primary_normal.content_margin_right = 16
primary_normal.content_margin_top = 8
primary_normal.content_margin_bottom = 8
theme.set_stylebox("normal", "ModalPrimaryButton", primary_normal)
```

### Fonts And Font Sizes

Set fonts globally with the base types, or target only modal controls with variations:

```gdscript
theme.set_font_size("font_size", "ModalTopButton", 14)
theme.set_font_size("font_size", "ModalPrimaryButton", 16)
theme.set_font_size("font_size", "ModalSecondaryButton", 16)
theme.set_font_size("font_size", "ModalStatusLabel", 13)
```

To use a custom font:

```gdscript
var font := preload("res://fonts/Inter-Regular.ttf")
theme.set_font("font", "ModalPrimaryButton", font)
theme.set_font("font", "ModalSecondaryButton", font)
theme.set_font("font", "ModalStatusLabel", font)
```

### Text Colors

Buttons and labels use different color item names.

For labels:

```gdscript
theme.set_color("font_color", "ModalStatusLabel", Color.WHITE)
theme.set_color("font_shadow_color", "ModalStatusLabel", Color.TRANSPARENT)
```

For buttons:

```gdscript
theme.set_color("font_color", "ModalPrimaryButton", Color.WHITE)
theme.set_color("font_hover_color", "ModalPrimaryButton", Color.WHITE)
theme.set_color("font_pressed_color", "ModalPrimaryButton", Color.WHITE)
theme.set_color("font_disabled_color", "ModalPrimaryButton", Color(1, 1, 1, 0.35))
```

### Backgrounds

`ModalStep` extends `PanelContainer`, so the step background is configured through the `PanelContainer/styles/panel` theme item. If all modal steps should share one background, define it for `PanelContainer` or assign a `theme_type_variation` to the step subclass.

```gdscript
var panel := StyleBoxFlat.new()
panel.bg_color = Color(0.08, 0.08, 0.1, 0.92)
panel.corner_radius_top_left = 6
panel.corner_radius_top_right = 6
panel.corner_radius_bottom_left = 6
panel.corner_radius_bottom_right = 6
theme.set_stylebox("panel", "PanelContainer", panel)
```

For button backgrounds, define the usual `Button` styleboxes for the modal button variations:

```gdscript
var normal := StyleBoxFlat.new()
normal.bg_color = Color(0.18, 0.2, 0.24)

var hover := normal.duplicate()
hover.bg_color = Color(0.24, 0.27, 0.32)

var pressed := normal.duplicate()
pressed.bg_color = Color(0.12, 0.14, 0.18)

theme.set_stylebox("normal", "ModalSecondaryButton", normal)
theme.set_stylebox("hover", "ModalSecondaryButton", hover)
theme.set_stylebox("pressed", "ModalSecondaryButton", pressed)
```

### Scroll Area

`ModalContentScroll` targets the scroll container. Use it for scrollbar styles and scroll-related theme values. `ModalContentCenter` targets the wrapper that vertically centers short content. `ModalContent` targets the inner `VBoxContainer`; use it for content spacing.

```gdscript
theme.set_constant("separation", "ModalContent", 10)
```

Content children added by a step can also receive their own theme variations if they need modal-specific styling.

### Complete Theme Example

```gdscript
func build_modal_theme() -> Theme:
	var theme := Theme.new()

	theme.set_constant("separation", "ModalLayout", 12)
	theme.set_constant("separation", "ModalContent", 10)
	theme.set_constant("separation", "ModalBottomButtons", 8)

	theme.set_font_size("font_size", "ModalStatusLabel", 13)
	theme.set_color("font_color", "ModalStatusLabel", Color(0.85, 0.88, 0.92))

	var primary := StyleBoxFlat.new()
	primary.bg_color = Color(0.12, 0.36, 0.72)
	primary.content_margin_left = 16
	primary.content_margin_right = 16
	primary.content_margin_top = 8
	primary.content_margin_bottom = 8
	primary.corner_radius_top_left = 4
	primary.corner_radius_top_right = 4
	primary.corner_radius_bottom_left = 4
	primary.corner_radius_bottom_right = 4
	theme.set_stylebox("normal", "ModalPrimaryButton", primary)
	theme.set_color("font_color", "ModalPrimaryButton", Color.WHITE)

	var secondary := primary.duplicate()
	secondary.bg_color = Color(0.2, 0.22, 0.26)
	theme.set_stylebox("normal", "ModalSecondaryButton", secondary)
	theme.set_color("font_color", "ModalSecondaryButton", Color.WHITE)

	return theme
```

Assign it to the modal:

```gdscript
modal.theme = build_modal_theme()
```

## WalletModal

`wallet_modal.gd` implements the native wallet/account-management flow. It is intended for native builds, where `AlephVault__EVM.Web3Client` manages encrypted local wallet material. HTML5 builds should use the browser/EIP-1193 wallet directly.

Instantiate it like any other `Control`:

```gdscript
var wallet_modal := AlephVault__EVM.UI.WalletModal.new()
add_child(wallet_modal)
wallet_modal.show_from_scratch()
```

By default it creates its own `AlephVault__EVM.Web3Client`. You can assign an existing client before `_ready()` if your application owns the client instance:

```gdscript
wallet_modal.client = my_web3_client
```

If the native wallet must be initialized against a specific RPC endpoint, assign it before showing the modal. The modal will call `await client.set_chain(chain_rpc_url)` immediately before `await client.initialize()`:

```gdscript
wallet_modal.chain_rpc_url = "http://127.0.0.1:8545"
```

All visible WalletModal copy is routed through `text_overrides`. Override only
the keys you need; missing keys keep the built-in English defaults. The selected
text is also passed through Godot's `tr()`, so values can be source strings in a
project translation catalog:

```gdscript
wallet_modal.text_overrides = {
	"button.unlock": "Desbloquear",
	"placeholder.master_password": "Contrasena maestra",
	"status.unlock_failed": "No se pudo desbloquear: %s",
}
```

The complete available text settings, and default values, are:

```json
{
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
	"status.wallet_initialized": "Wallet initialized."
}
```

When the user unlocks and starts the wallet successfully, the modal emits:

```gdscript
signal started(lock: Callable)
```

The `lock` callable locks the native wallet and opens the modal again at the Welcome step:

```gdscript
wallet_modal.started.connect(func(lock: Callable):
	# The wallet is initialized and ready for app use.
	# Store this callable if the app later needs to force a wallet lock.
	_current_wallet_lock = lock
)
```

The wallet modal contains these steps:

- `Welcome`: detects whether the encrypted account exists. Existing accounts can be unlocked, backed up, or deleted. Missing accounts can be created or restored.
- `Main`: shows the unlocked account address. It can lock, start wallet initialization, show the private-key reveal step, or move to password change.
- `PrivateKey`: requires an unlocked wallet and reveals the private key only after the user presses Reveal.
- `Creating`: creates the account using the password collected in Welcome, then returns to Welcome.
- `Deleting`: requires typing a random 8-digit confirmation code before deleting the account.
- `ChangingPassword`: changes the password, locks the wallet, and returns to Welcome.

The flow uses these `Web3Client` methods:

```gdscript
account_exists()
await account_create(password)
await account_restore(source_path)
await account_unlock(password)
await account_backup(target_path)
account_destroy()
account_lock()
await account_set_password(password)
account_private_key()
await initialize()
await get_accounts()
```

Backup and restore use Godot `FileDialog` controls. Backup uses save-file mode; restore uses open-file mode.

Restore accepts encrypted account backups. When the selected file is plain unencrypted text, it can also import a private key from exactly these formats: `0x...`, `{"private_key": "0x..."}`, or `{"privateKey": "0x..."}`. Plain imports validate the private key and create the encrypted wallet with password `default`.

The wallet modal inherits all theme behavior from `Modal` and `ModalStep`, so assigning a theme to the wallet modal also styles its steps and internal controls through the same theme variations listed above.
