@tool
extends PanelContainer


@export var _initial_margin := 16.0
@export var _left_top_button_visible := true
@export var _left_top_button_text := ""
@export var _right_top_button_visible := true
@export var _right_top_button_text := ""
@export var _primary_button_visible := true
@export var _primary_button_text := ""
@export var _secondary_button_visible := true
@export var _secondary_button_text := ""

var _root: VBoxContainer = null
var _top_buttons: HBoxContainer = null
var _scroll: ScrollContainer = null
var _content_center: VBoxContainer = null
var _content: VBoxContainer = null
var _status_label: Label = null
var _bottom_buttons: HBoxContainer = null
var _lt_button: Button = null
var _rt_button: Button = null
var _primary_button: Button = null
var _secondary_button: Button = null


var lt_button_visible: bool:
	get:
		_ensure_structure()
		return _lt_button.visible
	set(value):
		_ensure_structure()
		_lt_button.visible = value


var rt_button_visible: bool:
	get:
		_ensure_structure()
		return _rt_button.visible
	set(value):
		_ensure_structure()
		_rt_button.visible = value


var lt_button_text: String:
	get:
		_ensure_structure()
		return _lt_button.text
	set(value):
		_ensure_structure()
		_lt_button.text = value


var rt_button_text: String:
	get:
		_ensure_structure()
		return _rt_button.text
	set(value):
		_ensure_structure()
		_rt_button.text = value


var primary_button_visible: bool:
	get:
		_ensure_structure()
		return _primary_button.visible
	set(value):
		_ensure_structure()
		_primary_button.visible = value


var primary_button_text: String:
	get:
		_ensure_structure()
		return _primary_button.text
	set(value):
		_ensure_structure()
		_primary_button.text = value


var secondary_button_visible: bool:
	get:
		_ensure_structure()
		return _secondary_button.visible
	set(value):
		_ensure_structure()
		_secondary_button.visible = value


var secondary_button_text: String:
	get:
		_ensure_structure()
		return _secondary_button.text
	set(value):
		_ensure_structure()
		_secondary_button.text = value


var status: String:
	get:
		_ensure_structure()
		return _status_label.text
	set(value):
		_ensure_structure()
		_status_label.text = value


func _ready() -> void:
	_apply_default_layout()
	_ensure_structure()


func _apply_default_layout() -> void:
	anchor_left = 0.0
	anchor_top = 0.0
	anchor_right = 1.0
	anchor_bottom = 1.0
	offset_left = _initial_margin
	offset_top = _initial_margin
	offset_right = -_initial_margin
	offset_bottom = -_initial_margin


func get_content_container() -> VBoxContainer:
	_ensure_structure()
	return _content


func clear_content() -> void:
	_ensure_structure()
	for child in _content.get_children():
		_content.remove_child(child)
		child.queue_free()


## Override this one to refresh dynamic step contents each time it is shown.
func _on_show() -> void:
	pass


func _ensure_structure() -> void:
	if _root != null:
		return

	_root = VBoxContainer.new()
	_root.name = "Layout"
	_root.theme_type_variation = "ModalLayout"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(_root)

	_top_buttons = HBoxContainer.new()
	_top_buttons.name = "TopButtons"
	_top_buttons.theme_type_variation = "ModalTopButtons"
	_top_buttons.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_root.add_child(_top_buttons)

	_lt_button = Button.new()
	_lt_button.name = "LeftTopButton"
	_lt_button.theme_type_variation = "ModalTopButton"
	_lt_button.pressed.connect(_buttonlt_pressed)
	_top_buttons.add_child(_lt_button)

	var top_spacer := Control.new()
	top_spacer.name = "TopButtonSpacer"
	top_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_top_buttons.add_child(top_spacer)

	_rt_button = Button.new()
	_rt_button.name = "RightTopButton"
	_rt_button.theme_type_variation = "ModalTopButton"
	_rt_button.pressed.connect(_buttonrt_pressed)
	_top_buttons.add_child(_rt_button)

	_scroll = ScrollContainer.new()
	_scroll.name = "ContentScroll"
	_scroll.theme_type_variation = "ModalContentScroll"
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.resized.connect(_update_content_center_size)
	_root.add_child(_scroll)

	_content_center = VBoxContainer.new()
	_content_center.name = "ContentCenter"
	_content_center.theme_type_variation = "ModalContentCenter"
	_content_center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content_center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_content_center)

	var top_content_spacer := Control.new()
	top_content_spacer.name = "TopContentSpacer"
	top_content_spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_content_center.add_child(top_content_spacer)

	_content = VBoxContainer.new()
	_content.name = "Content"
	_content.theme_type_variation = "ModalContent"
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content_center.add_child(_content)

	var bottom_content_spacer := Control.new()
	bottom_content_spacer.name = "BottomContentSpacer"
	bottom_content_spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_content_center.add_child(bottom_content_spacer)

	_status_label = Label.new()
	_status_label.name = "StatusLabel"
	_status_label.theme_type_variation = "ModalStatusLabel"
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.clip_text = false
	_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_root.add_child(_status_label)

	_bottom_buttons = HBoxContainer.new()
	_bottom_buttons.name = "BottomButtons"
	_bottom_buttons.theme_type_variation = "ModalBottomButtons"
	_bottom_buttons.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_root.add_child(_bottom_buttons)

	_primary_button = Button.new()
	_primary_button.name = "PrimaryButton"
	_primary_button.theme_type_variation = "ModalPrimaryButton"
	_primary_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_primary_button.pressed.connect(_buttonc1_pressed)
	_bottom_buttons.add_child(_primary_button)

	_secondary_button = Button.new()
	_secondary_button.name = "SecondaryButton"
	_secondary_button.theme_type_variation = "ModalSecondaryButton"
	_secondary_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_secondary_button.pressed.connect(_button_c2_pressed)
	_bottom_buttons.add_child(_secondary_button)

	_apply_initial_button_values()
	_update_content_center_size()


func _update_content_center_size() -> void:
	if _content_center == null or _scroll == null:
		return

	_content_center.custom_minimum_size = Vector2(0.0, _scroll.size.y)


func _apply_initial_button_values() -> void:
	_lt_button.visible = _left_top_button_visible
	_lt_button.text = _left_top_button_text
	_rt_button.visible = _right_top_button_visible
	_rt_button.text = _right_top_button_text
	_primary_button.visible = _primary_button_visible
	_primary_button.text = _primary_button_text
	_secondary_button.visible = _secondary_button_visible
	_secondary_button.text = _secondary_button_text


## Override this one to attend when the left-top button is pressed.
func _buttonlt_pressed():
	pass

## Override this one to attend when the right-top button is pressed.
func _buttonrt_pressed():
	pass

## Override this one to attend when the first main button is pressed.
func _buttonc1_pressed():
	pass

## Override this one to attend when the second main button is pressed.
func _button_c2_pressed():
	_buttonc2_pressed()

## Deprecated compatibility hook. Override _button_c2_pressed instead.
func _buttonc2_pressed():
	pass
