## Colors the nodes of the edited scene in the Scene dock that were added (green) or changed (yellow) since the last commit, comparing the saved scene with HEAD.
@tool
extends Node

const SceneText := preload("res://addons/godit/util/scene_text.gd")
const DiffGutter := preload("res://addons/godit/dock/gutter/diff_gutter.gd")
const GitIcons := preload("res://addons/godit/util/git_icons.gd")
const RepoWatcher := preload("res://addons/godit/util/repo_watcher.gd")
const META_ORIGINAL := &"godit_original_color"

## Turned off in Godit Settings > Editor, with the Inspector rows.
var enabled := true:
	set(value):
		enabled = value
		_signature = ""
		refresh()
var _tree: Tree
## Node path as SceneText writes it ("Root/Child") -> "added" | "changed".
var _status := {}
## Scene, HEAD and file time _status was computed for.
var _signature := ""
## The edited scene's root at the last paint: another one means the colors are recomputed (Godot 4.4 sends scene_changed before switching).
var _painted_root: Node
var _paint_queued := false


func _ready() -> void:
	var docks := EditorInterface.get_base_control().find_children("*", "SceneTreeDock", true, false)
	if docks.is_empty():
		return
	var trees := docks[0].find_children("*", "Tree", true, false)
	if trees.is_empty():
		return
	_tree = trees[0]
	_tree.draw.connect(_queue_paint)
	RepoWatcher.watch(self, func(_snapshot: Dictionary) -> void: refresh())
	refresh()


func _exit_tree() -> void:
	_status = {}
	if is_instance_valid(_tree):
		_tree.draw.disconnect(_queue_paint)
		_paint()


## Recomputes the colors when the edited scene, HEAD or the saved file changed.
func refresh() -> void:
	var root := EditorInterface.get_edited_scene_root()
	var path := root.scene_file_path if enabled and root != null else ""
	var resolved := DiffGutter.resolve_repo(path) if path.begins_with("res://") else {}
	var signature := "" if resolved.is_empty() else "%s|%s|%d" % [path, resolved["repo"].read_head_oid(), FileAccess.get_modified_time(path)]
	if signature == _signature:
		return
	_signature = signature
	_status = {}
	if not resolved.is_empty():
		var head: PackedByteArray = resolved["repo"].get_file_bytes("HEAD", resolved["rel_path"])
		if not head.is_empty(): # a scene that's new altogether is marked in the FileSystem dock already
			_status = changed_nodes(head.get_string_from_utf8(), FileAccess.get_file_as_string(path))
	_queue_paint()


## "Root/Child" -> "added" | "changed" between two versions of a scene.
static func changed_nodes(old_text: String, new_text: String) -> Dictionary:
	var status := {}
	for node: Dictionary in SceneText.diff(old_text, new_text)["nodes"]:
		if node["status"] != "removed":
			status[node["path"]] = node["status"]
	return status


## The dock rebuilds and recolors its rows on its own, so every redraw checks them again.
func _queue_paint() -> void:
	if _paint_queued:
		return
	_paint_queued = true
	(func() -> void:
		_paint_queued = false
		_paint()
	).call_deferred()


func _paint() -> void:
	if not is_instance_valid(_tree) or _tree.get_root() == null:
		return
	var root := EditorInterface.get_edited_scene_root()
	if root != _painted_root:
		_painted_root = root
		refresh()
	var stack: Array[TreeItem] = [_tree.get_root()]
	while not stack.is_empty():
		var item: TreeItem = stack.pop_back()
		var meta: Variant = item.get_metadata(0)
		var node: Node = root.get_node_or_null(meta) if root != null and meta is NodePath else null
		var kind: String = ""
		if node != null and not _status.is_empty():
			kind = _status.get(String(root.name) if node == root else "%s/%s" % [root.name, root.get_path_to(node)], "")
		if not kind.is_empty():
			var color := GitIcons.COLOR_ADDED if kind == "added" else GitIcons.COLOR_MODIFIED
			if not item.has_meta(META_ORIGINAL):
				item.set_meta(META_ORIGINAL, item.get_custom_color(0))
			if item.get_custom_color(0) != color:
				item.set_custom_color(0, color)
		elif item.has_meta(META_ORIGINAL):
			var original: Color = item.get_meta(META_ORIGINAL)
			if original == Color(): # the getter's value for "no custom color"
				item.clear_custom_color(0)
			else:
				item.set_custom_color(0, original)
			item.remove_meta(META_ORIGINAL)
		for child in item.get_children():
			stack.append(child)
