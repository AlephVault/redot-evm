@tool
extends Control


const ModalStep = preload("./modal_step.gd")


var _current_step := ""


@export var current_step := "":
	get:
		return _current_step
	set(value):
		_current_step = value
		_apply_current_step()


func _ready() -> void:
	_apply_default_layout()
	_select_initial_step()


func _apply_default_layout() -> void:
	anchor_left = 0.0
	anchor_top = 0.0
	anchor_right = 1.0
	anchor_bottom = 1.0
	offset_left = 0.0
	offset_top = 0.0
	offset_right = 0.0
	offset_bottom = 0.0


func _select_initial_step() -> void:
	if _find_step(current_step) == null:
		var first_step := _get_first_step()
		current_step = "" if first_step == null else str(first_step.name)
	else:
		_apply_current_step()


func _apply_current_step() -> void:
	if not is_inside_tree():
		return

	var selected_step := _find_step(current_step)
	if selected_step == null:
		selected_step = _get_first_step()
		_current_step = "" if selected_step == null else str(selected_step.name)

	for child in get_children():
		if _is_modal_step(child):
			child.visible = child == selected_step


func _find_step(step_name: String) -> Control:
	for child in get_children():
		if _is_modal_step(child) and child.name == step_name:
			return child
	return null


func _get_first_step() -> Control:
	for child in get_children():
		if _is_modal_step(child):
			return child
	return null


func _is_modal_step(node: Node) -> bool:
	var script := node.get_script()
	while script != null:
		if script == ModalStep:
			return true
		script = script.get_base_script()
	return false
