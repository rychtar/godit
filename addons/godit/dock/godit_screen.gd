@tool
extends VBoxContainer

## The Godit tab next to 2D/3D/Script: borrows a panel's DiffView at full editor size and gives it back when the tab is left.

const UiScale := preload("res://addons/godit/util/ui_scale.gd")
const DiffView := preload("res://addons/godit/dock/widgets/diff_view.gd")

## The placeholder's "Bring Back" button.
signal back_requested

## Returns the DiffView to show when the tab opens with none (the Changes one), or null.
var default_view: Callable
var _view: Control
## Stands in for _view in its panel meanwhile.
var _placeholder: Control
var _empty: Label


func _init() -> void:
	name = "GoditScreen"
	auto_translate_mode = AUTO_TRANSLATE_MODE_DISABLED # English throughout, see godit_dock.gd
	size_flags_horizontal = SIZE_EXPAND_FILL
	size_flags_vertical = SIZE_EXPAND_FILL
	visible = false
	_empty = Label.new()
	_empty.text = DiffView.EXPANDED_EMPTY_TEXT
	_empty.modulate.a = 0.6
	_empty.size_flags_vertical = SIZE_EXPAND_FILL
	_empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	add_child(_empty)


## The view shown here right now, or null.
func current_view() -> Control:
	return _view if is_instance_valid(_view) else null


## Called when the tab is shown: keeps what's there, else borrows the default view.
func open() -> void:
	if current_view() == null and default_view.is_valid():
		var view: Control = default_view.call()
		if view != null:
			adopt(view)


## Moves view here, leaving a placeholder in its panel; a view already here goes back first.
func adopt(view: Control) -> void:
	if view == current_view():
		return
	release()
	var parent := view.get_parent()
	_placeholder = _make_placeholder(view)
	parent.add_child(_placeholder)
	parent.move_child(_placeholder, view.get_index())
	parent.remove_child(view)
	add_child(view)
	_view = view
	view.visible = true
	_empty.visible = false
	view.call("set_expanded", true)


## Puts the borrowed view back where the placeholder is.
func release() -> void:
	var view := current_view()
	_view = null
	_empty.visible = true
	if view == null or not is_instance_valid(_placeholder):
		return
	var parent := _placeholder.get_parent()
	remove_child(view)
	parent.add_child(view)
	parent.move_child(view, _placeholder.get_index())
	parent.remove_child(_placeholder)
	_placeholder.free()
	view.call("set_expanded", false)


func _make_placeholder(view: Control) -> Control:
	var box := VBoxContainer.new()
	box.name = "GoditScreenPlaceholder"
	box.size_flags_horizontal = view.size_flags_horizontal
	box.size_flags_vertical = view.size_flags_vertical
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	var label := Label.new()
	label.text = "The diff is in the Godit tab."
	label.modulate.a = 0.6
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.custom_minimum_size.x = UiScale.px(80)
	box.add_child(label)
	var back := Button.new()
	back.text = "Bring Back"
	back.size_flags_horizontal = SIZE_SHRINK_CENTER
	back.pressed.connect(back_requested.emit)
	box.add_child(back)
	return box
