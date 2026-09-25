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
const SaveGuard := preload("res://addons/godit/dock/widgets/save_guard.gd")
const FilesystemColorsScript := preload("res://addons/godit/dock/filesystem/filesystem_colors.gd")
const FilesystemMenuScript := preload("res://addons/godit/dock/filesystem/filesystem_menu.gd")
const CombinedDockScript := preload("res://addons/godit/dock/godit_combined_dock.gd")
const RepoWatcherScript := preload("res://addons/godit/util/repo_watcher.gd")
const GitCliRepo := preload("res://addons/godit/util/git_cli_repo.gd")
##
## Changes + Branches: left dock, alongside FileSystem/Import.
var dock_instance: Control
## History (commit graph): bottom panel by default, like Output/Debugger
## reads better full-width than squeezed into a side dock. Just the
## starting position; the user can drag it anywhere.
var history_dock_instance: Control
## Non-null only while Changes+Branches are detached into the bottom panel; see _apply_dock_layout().
var bottom_dock_container: TabContainer
## Non-null only in the combined layout, holding every panel; see _apply_dock_layout().
var combined_dock: Control
## The EditorDock (4.6+) combined_dock is registered in, or null when it went to the bottom panel directly (older versions).
var _combined_editor_dock: Node
## The layout the panels are arranged in right now (one of LAYOUT_*).
var _layout := LAYOUT_SEPARATE
## Changed-line flags in the script editor's gutter, next to Bookmarks.
var diff_gutter: Node
## Author/age column in the script editor, toggled from the Tools menu.
var blame_gutter: Node
## "Git" submenu in the script editor's right-click menu.
var script_menu: EditorContextMenuPlugin
## Git status colors in the FileSystem dock.
var filesystem_colors: Node
## "Git" items in the FileSystem dock's right-click menu.
var filesystem_menu: EditorContextMenuPlugin
## Polls the repo for every panel; created before them, since they subscribe as they get their repo.
var watcher: Node
## Project > Tools > Godit submenu, holding the auto-reload toggle.
var tools_menu: PopupMenu

const AUTO_RELOAD_SETTING_KEY := "auto_reload_external_changes"
const AUTO_RELOAD_EDITOR_SETTING := "text_editor/behavior/files/auto_reload_scripts_on_external_change"
const ID_AUTO_RELOAD := 0

const AUTO_SAVE_SETTING_KEY := "auto_save_scripts"
const AUTO_SAVE_EDITOR_SETTING := "text_editor/behavior/files/autosave_interval_secs"
const AUTO_SAVE_INTERVAL_SECS := 3
const ID_AUTO_SAVE := 1

## Replaced by DOCK_LAYOUT_SETTING_KEY; still read as the default for users who had it on.
const CHANGES_BOTTOM_DOCK_SETTING_KEY := "changes_panel_bottom_dock"
const DOCK_LAYOUT_SETTING_KEY := "dock_layout"
const LAYOUT_SEPARATE := "separate"
const LAYOUT_BOTTOM := "bottom"
const LAYOUT_COMBINED := "combined"
const ID_LAYOUT_BOTTOM := 2
const ID_LAYOUT_SEPARATE := 7
const ID_LAYOUT_COMBINED := 8
const LAYOUT_IDS := {ID_LAYOUT_SEPARATE: LAYOUT_SEPARATE, ID_LAYOUT_BOTTOM: LAYOUT_BOTTOM, ID_LAYOUT_COMBINED: LAYOUT_COMBINED}

const ID_AUTO_FETCH := 3

## Same floor the Shader Editor uses, so the bottom panels can't be dragged down to an unusable sliver (they can still be hidden entirely).
const BOTTOM_PANEL_MIN_HEIGHT := 300

const BLAME_SETTING_KEY := "show_blame"
const ID_BLAME := 4

const ID_CONFIRM_SHORTCUT_COMMIT := 5
const ID_SAVE_BEFORE_GIT := 6
const ID_FAST_STATUS := 9


func _enter_tree() -> void:
	GitCli.prepare_environment()
	watcher = RepoWatcherScript.new()
	add_child(watcher)

	tools_menu = PopupMenu.new()
	tools_menu.add_check_item("Auto-reload files changed externally (no confirmation)", ID_AUTO_RELOAD)
	tools_menu.set_item_checked(tools_menu.get_item_index(ID_AUTO_RELOAD), Settings.get_value(AUTO_RELOAD_SETTING_KEY, true))
	tools_menu.add_check_item("Auto-save scripts every %ds" % AUTO_SAVE_INTERVAL_SECS, ID_AUTO_SAVE)
	tools_menu.set_item_checked(tools_menu.get_item_index(ID_AUTO_SAVE), Settings.get_value(AUTO_SAVE_SETTING_KEY, false))
	tools_menu.add_check_item("Fetch remotes in the background every %d min" % int(GoditDockScript.AUTO_FETCH_INTERVAL_SECS / 60), ID_AUTO_FETCH)
	tools_menu.set_item_checked(tools_menu.get_item_index(ID_AUTO_FETCH), Settings.get_value(GoditDockScript.AUTO_FETCH_SETTING_KEY, false))
	tools_menu.add_check_item("Show blame in the script editor", ID_BLAME)
	tools_menu.set_item_checked(tools_menu.get_item_index(ID_BLAME), Settings.get_value(BLAME_SETTING_KEY, false))
	tools_menu.add_check_item("Confirm Ctrl/Cmd+Enter commits", ID_CONFIRM_SHORTCUT_COMMIT)
	tools_menu.add_check_item("Save open files before git operations without asking", ID_SAVE_BEFORE_GIT)
	tools_menu.add_check_item("Faster git status for large projects (file system monitor)", ID_FAST_STATUS)
	tools_menu.set_item_tooltip(tools_menu.get_item_index(ID_FAST_STATUS), "Git's built-in fsmonitor daemon and untracked cache, set in this repo's config:\n`git status` asks what changed instead of scanning every file.")
	tools_menu.add_separator("Layout")
	tools_menu.add_radio_check_item("Combined dock, SourceTree-like (default; can float on a second monitor)", ID_LAYOUT_COMBINED)
	tools_menu.add_radio_check_item("Git dock + Git Log at bottom", ID_LAYOUT_SEPARATE)
	tools_menu.add_radio_check_item("Changes/Branches and Git Log at bottom", ID_LAYOUT_BOTTOM)
	_update_layout_items()
	# Dialog buttons ("Don't ask again", "Always Save First") change these settings too, so re-read them on every open.
	tools_menu.about_to_popup.connect(func() -> void:
		tools_menu.set_item_checked(tools_menu.get_item_index(ID_CONFIRM_SHORTCUT_COMMIT), Settings.get_value(ChangesPanelScript.CONFIRM_SHORTCUT_COMMIT_SETTING_KEY, true))
		tools_menu.set_item_checked(tools_menu.get_item_index(ID_SAVE_BEFORE_GIT), Settings.get_value(SaveGuard.ALWAYS_SAVE_SETTING_KEY, false))
		# Repo config, which can change outside Godit too.
		var fast_index := tools_menu.get_item_index(ID_FAST_STATUS)
		var repo: RefCounted = watcher.repo
		tools_menu.set_item_disabled(fast_index, repo == null or (not repo.is_fast_status_on() and not GitCliRepo.fast_status_supported()))
		tools_menu.set_item_checked(fast_index, repo != null and repo.is_fast_status_on())
	)
	tools_menu.id_pressed.connect(_on_tools_menu_id_pressed)
	add_tool_submenu_item("Godit", tools_menu)
	_apply_auto_reload_setting()
	_apply_auto_save_setting()

	dock_instance = GoditDockScene.instantiate()
	dock_instance.plugin = self
	dock_instance.name = "Git" # dock tab label; scene root is named GoditDock in code
	add_control_to_dock(EditorPlugin.DOCK_SLOT_LEFT_UR, dock_instance)

	history_dock_instance = GoditHistoryDockScene.instantiate()
	history_dock_instance.custom_minimum_size.y = UiScale.px(BOTTOM_PANEL_MIN_HEIGHT)
	add_control_to_bottom_panel(history_dock_instance, "Git Log")
	_apply_dock_layout()

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

	filesystem_colors = FilesystemColorsScript.new()
	add_child(filesystem_colors)
	filesystem_menu = FilesystemMenuScript.new()
	filesystem_menu.colors = filesystem_colors
	filesystem_menu.dock = dock_instance
	filesystem_menu.show_file_history = _show_file_history
	filesystem_menu.show_change = func(path: String) -> void:
		_show_changes("")
		dock_instance.reveal_change(path, 1)
	add_context_menu_plugin(EditorContextMenuPlugin.CONTEXT_SLOT_FILESYSTEM, filesystem_menu)
	history_dock_instance.changes_requested.connect(_show_changes)
	# Saves show up right away; the panels' polling still catches changes made outside the editor.
	resource_saved.connect(func(_r: Resource) -> void: _queue_poll())
	scene_saved.connect(func(_p: String) -> void: _queue_poll())
	EditorInterface.get_resource_filesystem().filesystem_changed.connect(_queue_poll)


var _poll_queued := false


## One poll per frame however many saves (Save All) or rescans triggered it.
func _queue_poll() -> void:
	if _poll_queued:
		return
	_poll_queued = true
	(func() -> void:
		_poll_queued = false
		if is_instance_valid(watcher):
			watcher.poll_now()
	).call_deferred()


func _exit_tree() -> void:
	# Before freeing the UI: a fetch/push still running would otherwise outlive the plugin and resume coroutines on freed panels.
	GitCli.shutdown()
	remove_tool_menu_item("Godit")
	EditorInterface.get_resource_filesystem().filesystem_changed.disconnect(_queue_poll)

	# Only what's registered right now needs unregistering: the other layouts took dock_instance/history_dock_instance out already.
	match _layout:
		LAYOUT_BOTTOM:
			remove_control_from_bottom_panel(bottom_dock_container)
			bottom_dock_container.free()
		LAYOUT_COMBINED:
			_remove_combined_dock()
			combined_dock.free()
		_:
			remove_control_from_docks(dock_instance)
	dock_instance.free()

	if _layout != LAYOUT_COMBINED:
		remove_control_from_bottom_panel(history_dock_instance)
	history_dock_instance.free()

	diff_gutter.disable()
	diff_gutter.free()
	remove_context_menu_plugin(script_menu)
	script_menu = null
	remove_context_menu_plugin(filesystem_menu)
	filesystem_menu = null
	filesystem_colors.free() # restores the dock's own colors on the way out
	blame_gutter.disable()
	blame_gutter.free()
	watcher.free() # after the panels, which are subscribed to it

	GitCli.restore_environment()


func _show_commit(oid: String) -> void:
	_reveal_history()
	history_dock_instance.show_commit(oid)


func _show_file_history(path: String) -> void:
	_reveal_history()
	history_dock_instance.show_file_history(path)


## The EditorDock Godot 4.6+ wraps a plugin's dock or bottom panel control in, or null (older versions).
func _editor_dock_of(control: Control) -> Node:
	var node: Node = control
	while node != null and not node.is_class("EditorDock"):
		node = node.get_parent()
	return node


## Brings one of our registered controls to front wherever it lives — collapsed bottom panel, another tab, dragged elsewhere, floating or closed.
func _reveal(control: Control) -> void:
	var dock := _editor_dock_of(control)
	if dock != null:
		dock.call("open")
		dock.call("make_visible")
	elif control == history_dock_instance or control == bottom_dock_container or control == combined_dock:
		make_bottom_panel_item_visible(control)
	elif control.get_parent() is TabContainer:
		(control.get_parent() as TabContainer).current_tab = control.get_index()


## Brings Git Log (or the combined dock's History view) to front.
func _reveal_history() -> void:
	if combined_dock != null:
		_reveal(combined_dock)
		combined_dock.show_view("history")
	else:
		_reveal(history_dock_instance)


## Brings Changes (in whichever layout) to front.
func _reveal_changes() -> void:
	if combined_dock != null:
		_reveal(combined_dock)
		combined_dock.show_view("changes")
	elif bottom_dock_container != null:
		_reveal(bottom_dock_container)
		bottom_dock_container.current_tab = bottom_dock_container.get_node("Changes").get_index()
	else:
		_reveal(dock_instance)


## Shared by the Tools menu and the script editor's context menu, keeping both in sync.
func _set_blame_enabled(enabled: bool) -> void:
	Settings.set_value(BLAME_SETTING_KEY, enabled)
	tools_menu.set_item_checked(tools_menu.get_item_index(ID_BLAME), enabled)
	blame_gutter.set_enabled(enabled)


## Brings Changes to front and runs action there (see changes_panel.gd's run_action()).
func _show_changes(action: String) -> void:
	_reveal_changes()
	dock_instance.show_changes(action)


func _on_gutter_change_clicked(rel_path: String, line: int) -> void:
	_reveal_changes()
	dock_instance.reveal_change(rel_path, line)


func _on_tools_menu_id_pressed(id: int) -> void:
	if LAYOUT_IDS.has(id):
		Settings.set_value(DOCK_LAYOUT_SETTING_KEY, LAYOUT_IDS[id])
		_update_layout_items()
		_apply_dock_layout()
		return
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
		ID_BLAME:
			_set_blame_enabled(checked)
		ID_CONFIRM_SHORTCUT_COMMIT:
			Settings.set_value(ChangesPanelScript.CONFIRM_SHORTCUT_COMMIT_SETTING_KEY, checked)
		ID_SAVE_BEFORE_GIT:
			Settings.set_value(SaveGuard.ALWAYS_SAVE_SETTING_KEY, checked)
		ID_FAST_STATUS:
			var result: Dictionary = watcher.repo.set_fast_status(checked)
			if not result["ok"]:
				tools_menu.set_item_checked(index, not checked)
				EditorInterface.get_editor_toaster().push_toast("Godit: " + result["error"], EditorToaster.SEVERITY_WARNING)
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


## Combined on a fresh install; whoever toggled the old "at bottom" checkbox keeps what they had.
func _dock_layout() -> String:
	var old_bottom: Variant = Settings.get_value(CHANGES_BOTTOM_DOCK_SETTING_KEY, null)
	var fallback := LAYOUT_COMBINED if old_bottom == null else (LAYOUT_BOTTOM if old_bottom else LAYOUT_SEPARATE)
	return Settings.get_value(DOCK_LAYOUT_SETTING_KEY, fallback)


func _update_layout_items() -> void:
	for id: int in LAYOUT_IDS:
		tools_menu.set_item_checked(tools_menu.get_item_index(id), LAYOUT_IDS[id] == _dock_layout())


## Side docks and the bottom panel are separate registrations in Godot's editor, so switching layouts reparents the panels live: back into the Git dock and Git Log first, then into the wanted layout.
func _apply_dock_layout() -> void:
	var want := _dock_layout()
	if want == _layout:
		return

	match _layout:
		LAYOUT_BOTTOM:
			remove_control_from_bottom_panel(bottom_dock_container)
			var changes: Control = bottom_dock_container.get_node("Changes")
			var branches: Control = bottom_dock_container.get_node("Branches")
			bottom_dock_container.remove_child(changes)
			bottom_dock_container.remove_child(branches)
			dock_instance.reattach_panels({"changes": changes, "branches": branches})
			add_control_to_dock(EditorPlugin.DOCK_SLOT_LEFT_UR, dock_instance)
			bottom_dock_container.free()
			bottom_dock_container = null
		LAYOUT_COMBINED:
			_remove_combined_dock()
			var panels: Dictionary = combined_dock.detach_panels()
			if not panels.is_empty():
				dock_instance.reattach_panels(panels)
				history_dock_instance.reattach_panels()
			combined_dock.free()
			combined_dock = null
			add_control_to_dock(EditorPlugin.DOCK_SLOT_LEFT_UR, dock_instance)
			add_control_to_bottom_panel(history_dock_instance, "Git Log")

	match want:
		LAYOUT_BOTTOM:
			remove_control_from_docks(dock_instance)
			var panels: Dictionary = dock_instance.detach_panels()
			bottom_dock_container = TabContainer.new()
			bottom_dock_container.custom_minimum_size.y = UiScale.px(BOTTOM_PANEL_MIN_HEIGHT)
			bottom_dock_container.add_child(panels["changes"])
			bottom_dock_container.add_child(panels["branches"])
			add_control_to_bottom_panel(bottom_dock_container, "Git Changes")
		LAYOUT_COMBINED:
			remove_control_from_docks(dock_instance)
			remove_control_from_bottom_panel(history_dock_instance)
			var panels := {}
			if dock_instance.has_repo():
				panels = dock_instance.detach_panels()
				panels.merge(history_dock_instance.detach_panels())
			combined_dock = CombinedDockScript.new(panels)
			combined_dock.custom_minimum_size.y = UiScale.px(BOTTOM_PANEL_MIN_HEIGHT) # it starts in the bottom panel, where it mustn't shrink to a clipped sliver
			_add_combined_dock()
	_layout = want


## Bottom panel by default. On 4.6+ as an EditorDock the user can move to a side dock or make floating, and the editor remembers where; older versions can only put it in the bottom panel.
func _add_combined_dock() -> void:
	if not ClassDB.class_exists("EditorDock"):
		add_control_to_bottom_panel(combined_dock, "Godit")
		return
	# Through ClassDB and call(): EditorDock, add_dock() and DOCK_SLOT_BOTTOM don't exist before 4.6, and naming them would break parsing there.
	_combined_editor_dock = ClassDB.instantiate("EditorDock")
	_combined_editor_dock.set("title", "Godit")
	_combined_editor_dock.set("layout_key", "GoditCombined") # not "Godit", which early builds saved as a side dock
	_combined_editor_dock.set("global", true) # listed in Editor > Editor Docks, so it can be reopened after closing
	_combined_editor_dock.set("default_slot", ClassDB.class_get_integer_constant("EditorDock", "DOCK_SLOT_BOTTOM"))
	_combined_editor_dock.set("available_layouts", ClassDB.class_get_integer_constant("EditorDock", "DOCK_LAYOUT_ALL"))
	_combined_editor_dock.add_child(combined_dock)
	call("add_dock", _combined_editor_dock)


func _remove_combined_dock() -> void:
	if _combined_editor_dock == null:
		remove_control_from_bottom_panel(combined_dock)
		return
	call("remove_dock", _combined_editor_dock)
	_combined_editor_dock.remove_child(combined_dock)
	_combined_editor_dock.free()
	_combined_editor_dock = null
