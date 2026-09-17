@tool
extends EditorPlugin

const GitTreeDockScene := preload("res://addons/git_tree/dock/git_tree_dock.tscn")
const GitTreeHistoryDockScene := preload("res://addons/git_tree/dock/git_tree_history_dock.tscn")
const DiffGutterScript := preload("res://addons/git_tree/dock/gutter/diff_gutter.gd")
const BlameGutterScript := preload("res://addons/git_tree/dock/gutter/blame_gutter.gd")
const ScriptMenuScript := preload("res://addons/git_tree/dock/gutter/script_menu.gd")
const Settings := preload("res://addons/git_tree/util/settings.gd")
const GitCli := preload("res://addons/git_tree/util/git_cli.gd")
const GitTreeDockScript := preload("res://addons/git_tree/dock/git_tree_dock.gd")

## Changes + Branches: left dock, alongside FileSystem/Import.
var dock_instance: Control
## History (commit graph): bottom panel by default, like Output/Debugger
## reads better full-width than squeezed into a side dock. Just the
## starting position; the user can drag it anywhere.
var history_dock_instance: Control
## Changed-line flags in the script editor's gutter, next to Bookmarks.
var diff_gutter: Node
## Author/age column in the script editor, toggled from the Tools menu.
var blame_gutter: Node
## "Git" submenu in the script editor's right-click menu.
var script_menu: EditorContextMenuPlugin
## Project > Tools > Git Tree submenu.
var tools_menu: PopupMenu

const ID_AUTO_FETCH := 3

## Same floor the Shader Editor uses, so the bottom panels can't be dragged down to an unusable sliver (they can still be hidden entirely).
const BOTTOM_PANEL_MIN_HEIGHT := 300

const BLAME_SETTING_KEY := "show_blame"
const ID_BLAME := 4


func _enter_tree() -> void:
	GitCli.prepare_environment()

	tools_menu = PopupMenu.new()
	tools_menu.add_check_item("Fetch remotes in the background every %d min" % int(GitTreeDockScript.AUTO_FETCH_INTERVAL_SECS / 60), ID_AUTO_FETCH)
	tools_menu.set_item_checked(tools_menu.get_item_index(ID_AUTO_FETCH), Settings.get_value(GitTreeDockScript.AUTO_FETCH_SETTING_KEY, false))
	tools_menu.add_check_item("Show blame in the script editor", ID_BLAME)
	tools_menu.set_item_checked(tools_menu.get_item_index(ID_BLAME), Settings.get_value(BLAME_SETTING_KEY, false))
	tools_menu.id_pressed.connect(_on_tools_menu_id_pressed)
	add_tool_submenu_item("Git Tree", tools_menu)

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

	blame_gutter = BlameGutterScript.new()
	add_child(blame_gutter)
	blame_gutter.set_enabled(Settings.get_value(BLAME_SETTING_KEY, false))
	blame_gutter.commit_clicked.connect(_show_commit)
	blame_gutter.toggle_requested.connect(_set_blame_enabled)

	script_menu = ScriptMenuScript.new()
	script_menu.diff_gutter = diff_gutter
	script_menu.blame_gutter = blame_gutter
	script_menu.show_commit = _show_commit
	script_menu.show_file_history = _show_file_history
	add_context_menu_plugin(EditorContextMenuPlugin.CONTEXT_SLOT_SCRIPT_EDITOR_CODE, script_menu)
	dock_instance.file_history_requested.connect(_show_file_history)


func _exit_tree() -> void:
	remove_tool_menu_item("Git Tree")

	remove_control_from_docks(dock_instance)
	dock_instance.free()

	remove_control_from_bottom_panel(history_dock_instance)
	history_dock_instance.free()

	diff_gutter.disable()
	diff_gutter.free()
	remove_context_menu_plugin(script_menu)
	script_menu = null
	blame_gutter.disable()
	blame_gutter.free()

	GitCli.restore_environment()


func _show_commit(oid: String) -> void:
	_reveal_history_dock()
	history_dock_instance.show_commit(oid)


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


## Shared by the Tools menu and the script editor's context menu, keeping both in sync.
func _set_blame_enabled(enabled: bool) -> void:
	Settings.set_value(BLAME_SETTING_KEY, enabled)
	tools_menu.set_item_checked(tools_menu.get_item_index(ID_BLAME), enabled)
	blame_gutter.set_enabled(enabled)


func _on_gutter_change_clicked(rel_path: String, line: int) -> void:
	dock_instance.reveal_change(rel_path, line)


func _on_tools_menu_id_pressed(id: int) -> void:
	var index := tools_menu.get_item_index(id)
	var checked := not tools_menu.is_item_checked(index)
	tools_menu.set_item_checked(index, checked)
	match id:
		ID_BLAME:
			_set_blame_enabled(checked)
		ID_AUTO_FETCH:
			Settings.set_value(GitTreeDockScript.AUTO_FETCH_SETTING_KEY, checked)
			dock_instance.apply_auto_fetch_setting()
