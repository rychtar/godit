extends "res://tests/assertions.gd"

const HeadInspector = preload("res://addons/godit/dock/inspector/head_inspector.gd")
const HeadValueProperty = preload("res://addons/godit/dock/inspector/head_value_property.gd")

func _state(node: Node, instance := false) -> Dictionary:
	var class_props := {}
	for p: Dictionary in ClassDB.class_get_property_list(node.get_class()):
		class_props[p["name"]] = true
	return { "instance": instance, "script_props": {}, "class_props": class_props }

func test_head_values() -> void:
	var node: Node2D = track(Node2D.new())
	var state := _state(node)
	check("a stored value", HeadInspector.head_value("Vector2(5, 5)", node, "position", state).get("value"), Vector2(5, 5))
	check("a file", HeadInspector.head_value("ExtResource(\"res://art/tree.png\")", node, "texture", state), { "path": "res://art/tree.png", "text": "res://art/tree.png" })
	check("an embedded resource can't be compared", HeadInspector.head_value("SubResource(\"Gradient_1\")", node, "texture", state), {})
	check("not stored: the class default", HeadInspector.head_value(null, node, "rotation", state), { "value": 0.0, "text": "default (0.0)" })
	check("not stored in an instanced scene: unknown", HeadInspector.head_value(null, node, "rotation", _state(node, true)), {})
	check("not a known property", HeadInspector.head_value(null, node, "metadata/note", state), {})

func test_same_as_head() -> void:
	check("floats approximately", HeadValueProperty.same(0.1 + 0.2, { "value": 0.3 }), true)
	check("int and float", HeadValueProperty.same(1, { "value": 1.0 }), true)
	check("vectors approximately", HeadValueProperty.same(Vector2(0.1 + 0.2, 1), { "value": Vector2(0.3, 1) }), true)
	check("a changed vector", HeadValueProperty.same(Vector2(50, 5), { "value": Vector2(5, 5) }), false)
	check("other types", HeadValueProperty.same("1", { "value": 1 }), false)
	var texture := PlaceholderTexture2D.new()
	texture.resource_path = "res://art/tree.png"
	check("a resource by file", HeadValueProperty.same(texture, { "path": "res://art/tree.png" }), true)
	check("none where HEAD had a file", HeadValueProperty.same(null, { "path": "res://art/tree.png" }), false)
	check("none as before", HeadValueProperty.same(null, { "value": null }), true)
