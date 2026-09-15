@tool
extends EditorPlugin

const GitTreeDockScene := preload("res://addons/git_tree/dock/git_tree_dock.tscn")
const GitTreeHistoryDockScene := preload("res://addons/git_tree/dock/git_tree_history_dock.tscn")
const DiffGutterScript := preload("res://addons/git_tree/dock/gutter/diff_gutter.gd")
const ScriptMenuScript := preload("res://addons/git_tree/dock/gutter/script_menu.gd")
const GitCli := preload("res://addons/git_tree/util/git_cli.gd")

## Changes + Branches: left dock, alongside FileSystem/Import.
var dock_instance: Control
## History (commit graph): bottom panel by default, like Output/Debugger
## reads better full-width than squeezed into a side dock. Just the
## starting position; the user can drag it anywhere.
var history_dock_instance: Control
## Changed-line flags in the script editor's gutter, next to Bookmarks.
var diff_gutter: Node
## "Git" submenu in the script editor's right-click menu.
var script_menu: EditorContextMenuPlugin

## Same floor the Shader Editor uses, so the bottom panels can't be dragged down to an unusable sliver (they can still be hidden entirely).
const BOTTOM_PANEL_MIN_HEIGHT := 300


func _enter_tree() -> void:
	GitCli.prepare_environment()

	dock_instance = GitTreeDockScene.instantiate()
	dock_instance.plugin = self
	dock_instance.name = "Git" # dock tab label; scene root is named GitTreeDock in code
	add_control_to_dock(EditorPlugin.DOCK_SLOT_LEFT_UR, dock_instance)

	history_dock_instance = GitTreeHistoryDockScene.instantiate()
	history_dock_instance.custom_minimum_size.y = BOTTOM_PANEL_MIN_HEIGHT
	add_control_to_bottom_panel(history_dock_instance, "Git Log")

	diff_gutter = DiffGutterScript.new()
	add_child(diff_gutter)
	diff_gutter.enable(self)

	diff_gutter.change_clicked.connect(_on_gutter_change_clicked)

	script_menu = ScriptMenuScript.new()
	script_menu.diff_gutter = diff_gutter
	script_menu.show_file_history = _show_file_history
	add_context_menu_plugin(EditorContextMenuPlugin.CONTEXT_SLOT_SCRIPT_EDITOR_CODE, script_menu)
	dock_instance.file_history_requested.connect(_show_file_history)


func _exit_tree() -> void:
	remove_control_from_docks(dock_instance)
	dock_instance.free()

	remove_control_from_bottom_panel(history_dock_instance)
	history_dock_instance.free()

	diff_gutter.disable()
	diff_gutter.free()
	remove_context_menu_plugin(script_menu)
	script_menu = null

	GitCli.restore_environment()


func _show_file_history(path: String) -> void:
	_reveal_history_dock()
	history_dock_instance.show_file_history(path)


## Brings Git Log to front wherever it lives — collapsed bottom panel, another bottom tab, or dragged into a side dock or closed (4.6+ wraps it in an EditorDock).
func _reveal_history_dock() -> void:
	var node: Node = history_dock_instance
	while node != null and not node.is_class("EditorDock"):
		node = node.get_parent()
	if node != null:
		node.call("open")
		node.call("make_visible")
	else:
		make_bottom_panel_item_visible(history_dock_instance)


func _on_gutter_change_clicked(rel_path: String, line: int) -> void:
	dock_instance.reveal_change(rel_path, line)
