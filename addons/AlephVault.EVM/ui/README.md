# AlephVault EVM UI Modals

This directory provides two modal building blocks:

- `modal.gd`: a wizard-style container that shows one modal step at a time.
- `modal_step.gd`: a single responsive step with top buttons, scrollable content, status text, and bottom buttons.

The namespace entry point is:

```gdscript
const Modal = AlephVault__EVM.UI.Modal
const ModalStep = AlephVault__EVM.UI.ModalStep
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

The step anchors itself to full rect and applies `_initial_margin` as the inset on every side. The default is `16`.

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

func _button_c2_pressed():
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
| `ModalContent` | Scrollable content `VBoxContainer` |
| `ModalStatusLabel` | Status `Label` |
| `ModalBottomButtons` | Bottom `HBoxContainer` |
| `ModalPrimaryButton` | Primary bottom button |
| `ModalSecondaryButton` | Secondary bottom button |

If a variation does not define an item, Godot falls back to the base type. For example, `ModalPrimaryButton` falls back to `Button`.

### Margins And Spacing

The outer inset of each step is not a theme value. Configure it through the exported `_initial_margin` field on the `ModalStep`.

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

`ModalContentScroll` targets the scroll container. Use it for scrollbar styles and scroll-related theme values. `ModalContent` targets the inner `VBoxContainer`; use it for content spacing.

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
