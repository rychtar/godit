@tool
## Marks what changed since the last commit in the Inspector: a "Last commit" row with the old value and Revert under each changed property of a node of the edited scene or a .tres, and a note on nodes that are new.
extends EditorInspectorPlugin

const SceneText := preload("res://addons/godit/util/scene_text.gd")
const DiffGutter := preload("res://addons/godit/dock/gutter/diff_gutter.gd")
const GitIcons := preload("res://addons/godit/util/git_icons.gd")
const HeadValueProperty := preload("res://addons/godit/dock/inspector/head_value_property.gd")

## Turned off from Tools > Godit.
var enabled := true
## "rel_path|HEAD oid" -> SceneText.parse() of the file at HEAD, or {} when it isn't there.
var _head_cache := {}
## What _parse_begin() found for the object being inspected (see _head_state()).
var _state := {}


func _can_handle(object: Object) -> bool:
	return enabled and not _head_state(object).is_empty()


func _parse_begin(object: Object) -> void:
	_state = _head_state(object)
	if _state.get("is_new", false):
		var note := Label.new()
		note.text = "New since the last commit"
		note.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED # the Inspector would translate it (see godit_dock.gd)
		note.add_theme_color_override("font_color", GitIcons.COLOR_ADDED)
		note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		add_custom_control(note)


func _parse_property(object: Object, _type: Variant.Type, name: String, _hint: PropertyHint, _hint_string: String, usage: int, _wide: bool) -> bool:
	if _state.is_empty() or _state["is_new"] or not usage & PROPERTY_USAGE_STORAGE:
		return false
	var props: Dictionary = _state["props"]
	var head: Dictionary = head_value(props.get(name, null), object, name, _state)
	if head.is_empty():
		return false
	# Properties set at HEAD get a row that shows up whenever they differ; others only when they already do.
	if not props.has(name) and HeadValueProperty.same(object.get(name), head):
		return false
	add_property_editor(name, HeadValueProperty.new(head), true, HeadValueProperty.LABEL)
	return false


## {"value", "text" shown, "path" of an ExtResource} of a property at HEAD from its text there (null: not stored, i.e. the default); {} when it can't be compared. state: _head_state()'s.
static func head_value(text: Variant, object: Object, name: String, state: Dictionary) -> Dictionary:
	if text == null:
		if state["instance"]:
			return {} # the default comes from the instanced scene
		var default: Variant = null
		var script: Script = object.get_script()
		if state["script_props"].has(name):
			default = script.get_property_default_value(name)
		elif state["class_props"].has(name):
			default = ClassDB.class_get_property_default_value(object.get_class(), name)
		else:
			return {}
		return { "value": default, "text": "default (%s)" % var_to_str(default).left(60) }
	var value: String = text
	if value.begins_with("ExtResource(\"") and value.ends_with("\")"):
		var path := value.trim_prefix("ExtResource(\"").trim_suffix("\")")
		return { "path": path, "text": path }
	if "SubResource(" in value or "ExtResource(" in value or value.begins_with("Object("):
		return {}
	return { "value": str_to_var(value), "text": value.left(80) }


## {"props": {name: text at HEAD}, "is_new", "instance", "script_props", "class_props": names with a known default} for a node of the edited scene (not inside an instanced one) or a .tres file at HEAD; {} when not in git or not at HEAD.
func _head_state(object: Object) -> Dictionary:
	var file := ""
	var key := ""
	if object is Node:
		var root := EditorInterface.get_edited_scene_root()
		if root == null or not (object == root or (root.is_ancestor_of(object) and (object as Node).owner == root)):
			return {}
		file = root.scene_file_path
		key = String(root.name) if object == root else "%s/%s" % [root.name, root.get_path_to(object)]
	elif object is Resource and (object as Resource).resource_path.get_extension() == "tres":
		file = (object as Resource).resource_path
		key = "Resource"
	if not file.begins_with("res://"):
		return {}
	var head := _head_of(file)
	if head.is_empty():
		return {}
	var node: Variant = head["nodes"].get(key)
	if node == null:
		return { "props": {}, "is_new": true }
	var script_props := {}
	if object.get_script() != null:
		for p: Dictionary in (object.get_script() as Script).get_script_property_list():
			script_props[p["name"]] = true
	var class_props := {}
	for p: Dictionary in ClassDB.class_get_property_list(object.get_class()):
		class_props[p["name"]] = true
	return { "props": node["props"], "is_new": false, "instance": node["props"].has("(instance)"), "script_props": script_props, "class_props": class_props }


func _head_of(res_path: String) -> Dictionary:
	var resolved := DiffGutter.resolve_repo(res_path)
	if resolved.is_empty():
		return {}
	var repo: RefCounted = resolved["repo"]
	var cache_key := "%s|%s" % [resolved["rel_path"], repo.read_head_oid()]
	if not _head_cache.has(cache_key):
		var bytes: PackedByteArray = repo.get_file_bytes("HEAD", resolved["rel_path"])
		_head_cache[cache_key] = {} if bytes.is_empty() else SceneText.parse(bytes.get_string_from_utf8())
	return _head_cache[cache_key]
