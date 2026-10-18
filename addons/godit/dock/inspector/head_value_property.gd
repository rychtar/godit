@tool
## The "Last commit" row head_inspector.gd adds under a property: the value at HEAD and Revert, shown only while the property differs from it.
extends EditorProperty

const GitIcons := preload("res://addons/godit/util/git_icons.gd")
const LABEL := "Last commit"

## {"value"} or {"path"} (an ExtResource), and "text": see head_inspector.gd's head_value().
var _head: Dictionary


func _init(head: Dictionary) -> void:
	_head = head
	label = LABEL
	add_theme_color_override(&"property_color", GitIcons.COLOR_MODIFIED)
	var row := HBoxContainer.new()
	var value := Label.new()
	value.text = head["text"]
	value.tooltip_text = head["text"]
	value.mouse_filter = Control.MOUSE_FILTER_PASS
	value.clip_text = true
	value.size_flags_horizontal = SIZE_EXPAND_FILL
	value.add_theme_color_override(&"font_color", GitIcons.COLOR_MODIFIED)
	row.add_child(value)
	var revert := Button.new()
	revert.text = "Revert"
	revert.flat = true
	revert.tooltip_text = "Set it back to the value in the last commit"
	revert.pressed.connect(func() -> void:
		emit_changed(get_edited_property(), load(_head["path"]) if _head.has("path") else _head["value"])
	)
	row.add_child(revert)
	add_child(row)
	set_bottom_editor(row) # full width under the label, a narrow Inspector would clip the value


func _update_property() -> void:
	visible = not same(get_edited_object().get(get_edited_property()), _head)
	read_only = true # no revert-to-default arrow on this row, Revert is the one that counts


## Whether current matches a HEAD value from head_value(): floats and vectors approximately, resources by file.
static func same(current: Variant, head: Dictionary) -> bool:
	if head.has("path"):
		return current is Resource and (current as Resource).resource_path == head["path"]
	var old: Variant = head["value"]
	if typeof(current) in [TYPE_INT, TYPE_FLOAT] and typeof(old) in [TYPE_INT, TYPE_FLOAT]:
		return is_equal_approx(float(current), float(old))
	if typeof(current) != typeof(old):
		return false
	if typeof(current) in [TYPE_VECTOR2, TYPE_VECTOR3, TYPE_VECTOR4, TYPE_COLOR, TYPE_RECT2, TYPE_TRANSFORM2D, TYPE_TRANSFORM3D, TYPE_QUATERNION, TYPE_BASIS, TYPE_PLANE, TYPE_AABB]:
		return current.is_equal_approx(old)
	if typeof(current) == TYPE_OBJECT:
		return current == old or (current is Resource and old is Resource and not (current as Resource).resource_path.is_empty() and (current as Resource).resource_path == (old as Resource).resource_path)
	return current == old
