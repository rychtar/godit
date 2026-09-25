@tool
extends EditorPlugin

const GoditDockScene := preload("res://addons/godit/dock/godit_dock.tscn")
const UiScale := preload("res://addons/godit/util/ui_scale.gd")
const GoditHistoryDockScene := preload("res://addons/godit/dock/godit_history_dock.tscn")
const DiffGutterScript := preload("res://addons/godit/dock/gutter/diff_gutter.gd")
const BlameGutterScript := preload("res://addons/godit/dock/gutter/blame_gutter.gd")
const ScriptMenuScript := preload("res://addons/godit/dock/gutter/script_menu.gd")
const Settings := preload("res://addons/godit/util/settings.gd")
const GitCli := preload("res://addons/godit/util/git_cli.gd")
const GoditDockScript := preload("res://addons/godit/dock/godit_dock.gd")
const ChangesPanelScript := preload("res://addons/godit/dock/panels/changes_panel.gd")
##
## Changes + Branches: left dock, alongside FileSystem/Import.
var dock_instance: Control
## History (commit graph): bottom panel by default, like Output/Debugger
## reads better full-width than squeezed into a side dock. Just the
## starting position; the user can drag it anywhere.
var history_dock_instance: Control
## Non-null only while Changes+Branches are detached into the bottom panel; see _apply_dock_placement().
var bottom_dock_container: TabContainer
## Changed-line flags in the script editor's gutter, next to Bookmarks.
var diff_gutter: Node
## Author/age column in the script editor, toggled from the Tools menu.
var blame_gutter: Node
## "Git" submenu in the script editor's right-click menu.
var script_menu: EditorContextMenuPlugin
## Project > Tools > Godit submenu, holding the auto-reload toggle.
var tools_menu: PopupMenu

const AUTO_RELOAD_SETTING_KEY := "auto_reload_external_changes"
const AUTO_RELOAD_EDITOR_SETTING := "text_editor/behavior/files/auto_reload_scripts_on_external_change"
const ID_AUTO_RELOAD := 0

const AUTO_SAVE_SETTING_KEY := "auto_save_scripts"
const AUTO_SAVE_EDITOR_SETTING := "text_editor/behavior/files/autosave_interval_secs"
const AUTO_SAVE_INTERVAL_SECS := 3
const ID_AUTO_SAVE := 1

const CHANGES_BOTTOM_DOCK_SETTING_KEY := "changes_panel_bottom_dock"
const ID_CHANGES_BOTTOM_DOCK := 2

const ID_AUTO_FETCH := 3

## Same floor the Shader Editor uses, so the bottom panels can't be dragged down to an unusable sliver (they can still be hidden entirely).
const BOTTOM_PANEL_MIN_HEIGHT := 300

const BLAME_SETTING_KEY := "show_blame"
const ID_BLAME := 4

const ID_CONFIRM_SHORTCUT_COMMIT := 5


func _enter_tree() -> void:
	GitCli.prepare_environment()

	tools_menu = PopupMenu.new()
	tools_menu.add_check_item("Auto-reload files changed externally (no confirmation)", ID_AUTO_RELOAD)
	tools_menu.set_item_checked(tools_menu.get_item_index(ID_AUTO_RELOAD), Settings.get_value(AUTO_RELOAD_SETTING_KEY, true))
	tools_menu.add_check_item("Auto-save scripts every %ds" % AUTO_SAVE_INTERVAL_SECS, ID_AUTO_SAVE)
	tools_menu.set_item_checked(tools_menu.get_item_index(ID_AUTO_SAVE), Settings.get_value(AUTO_SAVE_SETTING_KEY, false))
	tools_menu.add_check_item("Dock Changes/Branches at bottom", ID_CHANGES_BOTTOM_DOCK)
	tools_menu.set_item_checked(tools_menu.get_item_index(ID_CHANGES_BOTTOM_DOCK), Settings.get_value(CHANGES_BOTTOM_DOCK_SETTING_KEY, false))
	tools_menu.add_check_item("Fetch remotes in the background every %d min" % int(GoditDockScript.AUTO_FETCH_INTERVAL_SECS / 60), ID_AUTO_FETCH)
	tools_menu.set_item_checked(tools_menu.get_item_index(ID_AUTO_FETCH), Settings.get_value(GoditDockScript.AUTO_FETCH_SETTING_KEY, false))
	tools_menu.add_check_item("Show blame in the script editor", ID_BLAME)
	tools_menu.set_item_checked(tools_menu.get_item_index(ID_BLAME), Settings.get_value(BLAME_SETTING_KEY, false))
	tools_menu.add_check_item("Confirm Ctrl/Cmd+Enter commits", ID_CONFIRM_SHORTCUT_COMMIT)
	# The confirmation dialog's "Don't ask again" changes this setting too, so re-read it on every open.
	tools_menu.about_to_popup.connect(func() -> void:
		tools_menu.set_item_checked(tools_menu.get_item_index(ID_CONFIRM_SHORTCUT_COMMIT), Settings.get_value(ChangesPanelScript.CONFIRM_SHORTCUT_COMMIT_SETTING_KEY, true))
	)
	tools_menu.id_pressed.connect(_on_tools_menu_id_pressed)
	add_tool_submenu_item("Godit", tools_menu)
	_apply_auto_reload_setting()
	_apply_auto_save_setting()

	dock_instance = GoditDockScene.instantiate()
	dock_instance.plugin = self
	dock_instance.name = "Git" # dock tab label; scene root is named GoditDock in code
	add_control_to_dock(EditorPlugin.DOCK_SLOT_LEFT_UR, dock_instance)
	_apply_dock_placement()

	history_dock_instance = GoditHistoryDockScene.instantiate()
	history_dock_instance.custom_minimum_size.y = UiScale.px(BOTTOM_PANEL_MIN_HEIGHT)
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
	history_dock_instance.changes_requested.connect(_show_changes)


func _exit_tree() -> void:
	# Before freeing the UI: a fetch/push still running would otherwise outlive the plugin and resume coroutines on freed panels.
	GitCli.shutdown()
	remove_tool_menu_item("Godit")

	if bottom_dock_container != null:
		# dock_instance was already removed from the left docks when this was
		# set up; only bottom_dock_container needs unregistering here.
		remove_control_from_bottom_panel(bottom_dock_container)
		bottom_dock_container.free()
	else:
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


## Brings the Git dock's Changes tab to front wherever the dock lives (bottom panel or a side dock).
func _show_changes(action: String) -> void:
	if bottom_dock_container != null:
		make_bottom_panel_item_visible(bottom_dock_container)
		bottom_dock_container.current_tab = bottom_dock_container.get_node("Changes").get_index()
	else:
		var node: Node = dock_instance
		while node != null and not node.is_class("EditorDock"):
			node = node.get_parent()
		if node != null:
			node.call("open")
			node.call("make_visible")
	dock_instance.show_changes(action)


func _on_gutter_change_clicked(rel_path: String, line: int) -> void:
	if bottom_dock_container != null:
		make_bottom_panel_item_visible(bottom_dock_container)
		bottom_dock_container.current_tab = bottom_dock_container.get_node("Changes").get_index()
	dock_instance.reveal_change(rel_path, line)


func _on_tools_menu_id_pressed(id: int) -> void:
	var index := tools_menu.get_item_index(id)
	var checked := not tools_menu.is_item_checked(index)
	tools_menu.set_item_checked(index, checked)
	match id:
		ID_AUTO_RELOAD:
			Settings.set_value(AUTO_RELOAD_SETTING_KEY, checked)
			_apply_auto_reload_setting()
		ID_AUTO_SAVE:
			Settings.set_value(AUTO_SAVE_SETTING_KEY, checked)
			_apply_auto_save_setting()
		ID_CHANGES_BOTTOM_DOCK:
			Settings.set_value(CHANGES_BOTTOM_DOCK_SETTING_KEY, checked)
			_apply_dock_placement()
		ID_BLAME:
			_set_blame_enabled(checked)
		ID_CONFIRM_SHORTCUT_COMMIT:
			Settings.set_value(ChangesPanelScript.CONFIRM_SHORTCUT_COMMIT_SETTING_KEY, checked)
		ID_AUTO_FETCH:
			Settings.set_value(GoditDockScript.AUTO_FETCH_SETTING_KEY, checked)
			dock_instance.apply_auto_fetch_setting()


## Mirrors our own per-user Godit preference onto Godot's own (editor-wide) auto-reload setting — unchecking it restores the normal "reload externally modified file?" confirmation.
func _apply_auto_reload_setting() -> void:
	EditorInterface.get_editor_settings().set_setting(AUTO_RELOAD_EDITOR_SETTING, Settings.get_value(AUTO_RELOAD_SETTING_KEY, true))


## Mirrors our own per-user Godit preference onto Godot's own (editor-wide) autosave interval.
func _apply_auto_save_setting() -> void:
	var interval := AUTO_SAVE_INTERVAL_SECS if Settings.get_value(AUTO_SAVE_SETTING_KEY, false) else 0
	EditorInterface.get_editor_settings().set_setting(AUTO_SAVE_EDITOR_SETTING, interval)


## Side docks and the bottom panel are separate registrations in Godot's editor, so this reparents Changes+Branches live instead of just toggling visibility.
func _apply_dock_placement() -> void:
	var want_bottom: bool = Settings.get_value(CHANGES_BOTTOM_DOCK_SETTING_KEY, false)
	var is_bottom := bottom_dock_container != null
	if want_bottom == is_bottom:
		return

	if want_bottom:
		remove_control_from_docks(dock_instance)
		var panels: Dictionary = dock_instance.detach_panels()
		bottom_dock_container = TabContainer.new()
		bottom_dock_container.custom_minimum_size.y = UiScale.px(BOTTOM_PANEL_MIN_HEIGHT)
		bottom_dock_container.add_child(panels["changes"])
		bottom_dock_container.add_child(panels["branches"])
		add_control_to_bottom_panel(bottom_dock_container, "Git Changes")
	else:
		remove_control_from_bottom_panel(bottom_dock_container)
		var changes: Control = bottom_dock_container.get_node("Changes")
		var branches: Control = bottom_dock_container.get_node("Branches")
		bottom_dock_container.remove_child(changes)
		bottom_dock_container.remove_child(branches)
		dock_instance.reattach_panels({"changes": changes, "branches": branches})
		add_control_to_dock(EditorPlugin.DOCK_SLOT_LEFT_UR, dock_instance)
		bottom_dock_container.free()
		bottom_dock_container = null
