@tool
extends AlephVault__EVM.UI.Modal


class IntroStep:
	extends ModalStep

	func _ready() -> void:
		super()
		lt_button_visible = false
		rt_button_visible = false
		primary_button_text = "Next"
		secondary_button_visible = false
		status = "Intro step"

		var label := Label.new()
		label.text = "This is the first modal step."
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		get_content_container().add_child(label)

	func _buttonc1_pressed():
		_move_to_next_step()

	func _move_to_next_step() -> void:
		var modal := get_parent()
		var step_count := modal.get_child_count()
		for offset in range(1, step_count + 1):
			var child := modal.get_child((get_index() + offset) % step_count)
			if child is ModalStep:
				modal.current_step = str(child.name)
				return


class ConfirmStep:
	extends ModalStep

	func _ready() -> void:
		super()
		lt_button_text = "Back"
		rt_button_visible = false
		primary_button_text = "Finish"
		secondary_button_text = "Cancel"
		status = "Confirm step"

		var label := Label.new()
		label.text = "This is the second modal step."
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		get_content_container().add_child(label)

	func _buttonlt_pressed():
		_move_to_next_step()

	func _buttonc1_pressed():
		_move_to_next_step()

	func _buttonc2_pressed():
		_move_to_next_step()

	func _move_to_next_step() -> void:
		var modal := get_parent()
		var step_count := modal.get_child_count()
		for offset in range(1, step_count + 1):
			var child := modal.get_child((get_index() + offset) % step_count)
			if child is ModalStep:
				modal.current_step = str(child.name)
				return


func _enter_tree() -> void:
	if get_child_count() > 0:
		return

	var intro := IntroStep.new()
	intro.name = "Intro"
	add_child(intro)

	var confirm := ConfirmStep.new()
	confirm.name = "Confirm"
	add_child(confirm)
