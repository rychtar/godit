@tool
extends Control

const GitStatusFlags := preload("res://addons/git_tree/util/git_status_flags.gd")
const GitIcons := preload("res://addons/git_tree/util/git_icons.gd")
const EditorOpen := preload("res://addons/git_tree/util/editor_open.gd")

@onready var _tree: Tree = %ChangesTree
@onready var _status_label: Label = %StatusLabel
@onready var _error_dialog: AcceptDialog = %ErrorDialog

## Set by git_tree_dock.gd; a git_cli_repo.gd instance.
var _repo: RefCounted


func set_repo(repo: RefCounted) -> void:
	_repo = repo
	refresh()


func refresh() -> void:
	if _repo == null:
		return
	var entries: Array = _repo.get_status()

	_tree.clear()
	var root := _tree.create_item()
	for entry in entries:
		var path: String = entry["path"]
		var status: int = entry["status"]
		var item := _tree.create_item(root)
		item.set_text(0, "%s  %s" % [GitIcons.status_letter(status), path])
		item.set_custom_color(0, GitIcons.status_color(status))
		item.set_metadata(0, { "path": path, "status": status })
		item.set_tooltip_text(0, "%s — %s\nDouble-click to open." % [path, GitStatusFlags.short_label(status)])

	_status_label.text = "No changes." if entries.is_empty() else "%d changed file%s" % [entries.size(), "" if entries.size() == 1 else "s"]


func _on_changes_tree_item_activated() -> void:
	var item := _tree.get_selected()
	if item == null:
		return
	var meta: Dictionary = item.get_metadata(0)
	if meta.is_empty() or not meta.has("path"):
		return
	var error := EditorOpen.open_file(_repo.get_repo_root(), meta["path"])
	if not error.is_empty():
		_show_error("Can't open file", error)


func _show_error(title: String, message: String) -> void:
	_error_dialog.title = title
	_error_dialog.dialog_text = message
	_error_dialog.popup_centered()
