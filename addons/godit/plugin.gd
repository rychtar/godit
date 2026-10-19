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
const FilesystemColorsScript := preload("res://addons/godit/dock/filesystem/filesystem_colors.gd")
const FilesystemMenuScript := preload("res://addons/godit/dock/filesystem/filesystem_menu.gd")
const CombinedDockScript := preload("res://addons/godit/dock/godit_combined_dock.gd")
const RepoWatcherScript := preload("res://addons/godit/util/repo_watcher.gd")
const GitCliRepo := preload("res://addons/godit/util/git_cli_repo.gd")
const GoditScreenScript := preload("res://addons/godit/dock/godit_screen.gd")
const DiffViewScript := preload("res://addons/godit/dock/widgets/diff_view.gd")
const RepoSetup := preload("res://addons/godit/util/repo_setup.gd")
const HeadInspectorScript := preload("res://addons/godit/dock/inspector/head_inspector.gd")
const SceneDockColorsScript := preload("res://addons/godit/dock/inspector/scene_dock_colors.gd")
const Dialogs := preload("res://addons/godit/dock/widgets/dialogs.gd")
const EditorCommands := preload("res://addons/godit/util/editor_commands.gd")
const EditorOpen := preload("res://addons/godit/util/editor_open.gd")
const SettingsWindowScript := preload("res://addons/godit/dock/widgets/settings_window.gd")
const BranchToolbarScript := preload("res://addons/godit/dock/widgets/branch_toolbar.gd")
const RepoOpener := preload("res://addons/godit/util/repo_opener.gd")
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
## The Godit tab next to 2D/3D/Script showing a diff full size, or null when turned off.
var main_screen: Control
## Where "Back to the panel" returns to.
var _last_main_screen := "Script"
## "Last commit" rows under changed properties in the Inspector.
var head_inspector: EditorInspectorPlugin
## Changed nodes colored in the Scene dock.
var scene_dock_colors: Node
## Command Palette entries and their shortcuts.
var commands: RefCounted
## Godit Settings, created the first time it's opened.
var _settings_window: SettingsWindowScript
## The current branch in the editor's main toolbar, or null outside a repository.
var branch_toolbar: BranchToolbarScript

const AUTO_RELOAD_SETTING_KEY := "auto_reload_external_changes"
const AUTO_RELOAD_EDITOR_SETTING := "text_editor/behavior/files/auto_reload_scripts_on_external_change"

const AUTO_SAVE_SETTING_KEY := "auto_save_scripts"
const AUTO_SAVE_EDITOR_SETTING := "text_editor/behavior/files/autosave_interval_secs"
const AUTO_SAVE_INTERVAL_SECS := 3
const AUTO_SAVE_SECONDS_KEY := "auto_save_seconds"
## The user's own autosave interval, kept while Godit's auto-save is on so turning it off puts it back.
const AUTO_SAVE_ORIGINAL_KEY := "auto_save_original_interval"

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
const LAYOUT_ORDER := [LAYOUT_COMBINED, LAYOUT_SEPARATE, LAYOUT_BOTTOM]
## Shorter than the Tools menu's, for the menus inside the docks and the command palette.
const LAYOUT_TITLES := {LAYOUT_COMBINED: "Combined Dock", LAYOUT_SEPARATE: "Git Dock and Git Log", LAYOUT_BOTTOM: "Both in the Bottom Panel"}
const LAYOUT_TOOLTIPS := {
	LAYOUT_COMBINED: "Everything in one SourceTree-like dock: the views and branches in a sidebar. On Godot 4.6+ it can float, e.g. on a second monitor.",
	LAYOUT_SEPARATE: "Changes and Branches in a side dock, Git Log and Console in the bottom panel",
	LAYOUT_BOTTOM: "Changes and Branches as tabs in the bottom panel, next to Git Log",
}

const ID_AUTO_FETCH := 3

## Same floor the Shader Editor uses, so the bottom panels can't be dragged down to an unusable sliver (they can still be hidden entirely).
const BOTTOM_PANEL_MIN_HEIGHT := 300

const BLAME_SETTING_KEY := "show_blame"
const ID_BLAME := 4

const MAIN_SCREEN_SETTING_KEY := "diff_main_screen"
const MAIN_SCREEN_NAME := "Godit"

const INSPECTOR_SETTING_KEY := "inspector_changes"
const ID_INSPECTOR := 11
const ID_SETTINGS := 12
const TOOLBAR_BRANCH_SETTING_KEY := "toolbar_branch"
## The Tools menu's toggles, by item id; the rest are in Godit Settings.
const TOOLS_TOGGLES := {ID_BLAME: [BLAME_SETTING_KEY, false], ID_AUTO_FETCH: [GoditDockScript.AUTO_FETCH_SETTING_KEY, false], ID_INSPECTOR: [INSPECTOR_SETTING_KEY, true]}


func _enter_tree() -> void:
	GitCli.prepare_environment()
	watcher = RepoWatcherScript.new()
	add_child(watcher)

	tools_menu = PopupMenu.new()
	tools_menu.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED # it goes into the editor's Tools menu, which would translate it (see godit_dock.gd)
	tools_menu.add_item("Settings…", ID_SETTINGS)
	tools_menu.add_separator()
	tools_menu.add_check_item("Show blame in the script editor", ID_BLAME)
	tools_menu.add_check_item("Fetch remotes in the background", ID_AUTO_FETCH)
	tools_menu.add_check_item("Show changes since the last commit in the Inspector and Scene dock", ID_INSPECTOR)
	tools_menu.add_separator("Layout")
	tools_menu.add_radio_check_item("Combined dock, SourceTree-like (default; can float on a second monitor)", ID_LAYOUT_COMBINED)
	tools_menu.add_radio_check_item("Git dock + Git Log at bottom", ID_LAYOUT_SEPARATE)
	tools_menu.add_radio_check_item("Changes/Branches and Git Log at bottom", ID_LAYOUT_BOTTOM)
	_update_layout_items()
	# Godit Settings, the script editor's menu and the palette change these too, so they're read on every open.
	tools_menu.about_to_popup.connect(func() -> void:
		for id: int in TOOLS_TOGGLES:
			tools_menu.set_item_checked(tools_menu.get_item_index(id), Settings.get_value(TOOLS_TOGGLES[id][0], TOOLS_TOGGLES[id][1]))
		tools_menu.set_item_text(tools_menu.get_item_index(ID_AUTO_FETCH), "Fetch remotes in the background every %d min" % int(Settings.get_value(GoditDockScript.AUTO_FETCH_MINUTES_KEY, GoditDockScript.AUTO_FETCH_DEFAULT_MINUTES)))
	)
	tools_menu.id_pressed.connect(_on_tools_menu_id_pressed)
	Settings.notifier().changed.connect(_on_setting_changed)
	add_tool_submenu_item("Godit", tools_menu)
	_apply_auto_reload_setting()
	_apply_auto_save_setting()
	_add_commands()

	dock_instance = GoditDockScene.instantiate()
	dock_instance.plugin = self
	dock_instance.name = "Git" # dock tab label; scene root is named GoditDock in code
	add_control_to_dock(EditorPlugin.DOCK_SLOT_LEFT_UR, dock_instance, commands.shortcut("toggle_dock"))

	history_dock_instance = GoditHistoryDockScene.instantiate()
	history_dock_instance.custom_minimum_size.y = UiScale.px(BOTTOM_PANEL_MIN_HEIGHT)
	add_control_to_bottom_panel(history_dock_instance, "Git Log")
	dock_instance.set_tab_menu(_layout_menu(PopupMenu.new()))
	history_dock_instance.set_tab_menu(_layout_menu(PopupMenu.new()))
	_apply_dock_layout()
	var toolbar_repo: RefCounted = RepoOpener.open_current_project_repo()["repo"] # its own, like the panels': watcher.repo is set only once the plugin is ready
	if toolbar_repo != null:
		branch_toolbar = BranchToolbarScript.new()
		branch_toolbar.visible = Settings.get_value(TOOLBAR_BRANCH_SETTING_KEY, true)
		add_control_to_container(CONTAINER_TOOLBAR, branch_toolbar)
		branch_toolbar.set_repo(toolbar_repo)

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
	diff_gutter.text_tab_refreshed.connect(script_menu.hook_text_editor)
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
	if _has_main_screen():
		main_screen = GoditScreenScript.new()
		main_screen.default_view = func() -> Control: return dock_instance.changes_diff_view() if dock_instance.has_repo() else null
		main_screen.back_requested.connect(_leave_main_screen)
		EditorInterface.get_editor_main_screen().add_child(main_screen)
		DiffViewScript.expander = _expand_diff
		DiffViewScript.collapser = _leave_main_screen
		DiffViewScript.follower = _follow_diff
	main_screen_changed.connect(_on_main_screen_changed)
	Dialogs.show_console = _show_console
	head_inspector = HeadInspectorScript.new()
	head_inspector.enabled = Settings.get_value(INSPECTOR_SETTING_KEY, true)
	add_inspector_plugin(head_inspector)
	scene_dock_colors = SceneDockColorsScript.new()
	scene_dock_colors.enabled = head_inspector.enabled
	add_child(scene_dock_colors)
	scene_saved.connect(func(_path: String) -> void: scene_dock_colors.refresh.call_deferred())
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
	Settings.notifier().changed.disconnect(_on_setting_changed)
	if _settings_window != null:
		_settings_window.free()
	if branch_toolbar != null:
		remove_control_from_container(CONTAINER_TOOLBAR, branch_toolbar)
		branch_toolbar.free()
	remove_tool_menu_item("Godit")
	commands.clear()
	EditorInterface.get_resource_filesystem().filesystem_changed.disconnect(_queue_poll)
	DiffViewScript.expander = Callable()
	DiffViewScript.collapser = Callable()
	DiffViewScript.follower = Callable()
	Dialogs.show_console = Callable()
	remove_inspector_plugin(head_inspector)
	scene_dock_colors.free() # restores the dock's own colors
	if main_screen != null:
		main_screen.release() # back into its panel before the panels go
		main_screen.free()
		main_screen = null

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

	if diff_gutter.has_method("disable"): # not while its script is being edited and doesn't compile
		diff_gutter.disable()
	diff_gutter.free()
	script_menu.unhook_text_editors()
	remove_context_menu_plugin(script_menu)
	script_menu = null
	remove_context_menu_plugin(filesystem_menu)
	filesystem_menu = null
	filesystem_colors.free() # restores the dock's own colors on the way out
	if blame_gutter.has_method("disable"):
		blame_gutter.disable()
	blame_gutter.free()
	watcher.free() # after the panels, which are subscribed to it

	GitCli.restore_environment()


func _shortcut_input(event: InputEvent) -> void:
	if commands != null and commands.handle(event):
		get_viewport().set_input_as_handled()


## Command Palette entries (Ctrl/Cmd+Shift+P, "Godit: …"), with shortcuts in Editor Settings > Shortcuts > Godit.
func _add_commands() -> void:
	commands = EditorCommands.new()
	commands.add("toggle_dock", "Toggle Godit Dock", Callable(), [EditorCommands.alt_key(KEY_G)])
	commands.add("show_changes", "Show File Status", _show_changes.bind(""), [EditorCommands.command_digit(KEY_1)])
	commands.add("show_history", "Show History", _reveal_history, [EditorCommands.command_digit(KEY_2)])
	commands.add("show_branches", "Show Branches", _reveal_branches, [EditorCommands.command_digit(KEY_3)])
	commands.add("show_console", "Show Console", _show_console, [EditorCommands.command_digit(KEY_4)])
	commands.add("commit", "Commit…", _show_changes.bind("commit"))
	commands.add("fetch", "Fetch", func() -> void: dock_instance.press_sync("fetch"))
	commands.add("pull", "Pull", func() -> void: dock_instance.press_sync("pull"))
	commands.add("push", "Push", func() -> void: dock_instance.press_sync("push"))
	commands.add("file_history", "History of the Open Scene or Script", _show_open_file_history)
	commands.add("toggle_blame", "Toggle Blame", func() -> void: _set_blame_enabled(not Settings.get_value(BLAME_SETTING_KEY, false)))
	commands.add("settings", "Settings…", open_settings)
	commands.add("switch_branch", "Switch Branch…", func() -> void:
		if branch_toolbar != null:
			branch_toolbar.open_switcher()
	)
	commands.add("toggle_sidebar", "Toggle Sidebar", func() -> void:
		if combined_dock != null:
			combined_dock.toggle_sidebar()
	)
	for layout: String in LAYOUT_ORDER:
		commands.add("layout_" + layout, "Layout: " + LAYOUT_TITLES[layout], set_layout.bind(layout))


## The layout choice inside the docks: the combined dock's toolbar menu and the tab bar menus of the Git dock, Git Log and the bottom tabs.
func _layout_menu(menu: PopupMenu) -> PopupMenu:
	menu.add_separator("Layout")
	for layout: String in LAYOUT_ORDER:
		var id: int = LAYOUT_IDS.find_key(layout)
		menu.add_radio_check_item(LAYOUT_TITLES[layout], id)
		menu.set_item_tooltip(menu.get_item_index(id), LAYOUT_TOOLTIPS[layout])
	menu.add_separator()
	menu.add_item("Settings…", ID_SETTINGS)
	menu.about_to_popup.connect(func() -> void:
		for id: int in LAYOUT_IDS:
			menu.set_item_checked(menu.get_item_index(id), LAYOUT_IDS[id] == _layout)
	)
	# Deferred: switching frees the dock the menu is in.
	menu.id_pressed.connect(func(id: int) -> void:
		if id == ID_SETTINGS:
			open_settings()
		else:
			set_layout.call_deferred(LAYOUT_IDS[id])
	)
	return menu


## Switches the layout (Tools menu, the docks' layout menus, command palette) and shows where the panels went.
func set_layout(layout: String) -> void:
	Settings.set_value(DOCK_LAYOUT_SETTING_KEY, layout)
	_update_layout_items()
	_apply_dock_layout()
	if combined_dock != null:
		_reveal(combined_dock)
	elif bottom_dock_container != null:
		_reveal(bottom_dock_container)
	else:
		_reveal(dock_instance)


## The current scene's history, or the current script's while the Script screen is open.
func _show_open_file_history() -> void:
	var path := ""
	if _last_main_screen == "Script":
		path = EditorOpen.current_tab_path()
	elif EditorInterface.get_edited_scene_root() != null:
		path = EditorInterface.get_edited_scene_root().scene_file_path
	var repo: RefCounted = watcher.repo
	if path.is_empty() or repo == null:
		return
	var abs_path := ProjectSettings.globalize_path(path)
	var root: String = repo.get_repo_root() + "/"
	if abs_path.begins_with(root):
		_show_file_history(abs_path.trim_prefix(root))


func _has_main_screen() -> bool:
	return Settings.get_value(MAIN_SCREEN_SETTING_KEY, false)


func _get_plugin_name() -> String:
	return MAIN_SCREEN_NAME


func _get_plugin_icon() -> Texture2D:
	var theme := EditorInterface.get_editor_theme()
	return theme.get_icon(&"VcsBranches", &"EditorIcons") if theme.has_icon(&"VcsBranches", &"EditorIcons") else null


func _make_visible(visible: bool) -> void:
	if not is_instance_valid(main_screen):
		return
	main_screen.visible = visible
	if visible:
		main_screen.open()
	else:
		main_screen.release()


func _expand_diff(view: Control) -> void:
	main_screen.adopt(view)
	EditorInterface.set_main_screen_editor(MAIN_SCREEN_NAME)


## A file picked in Changes or Git Log while the Godit tab is open: its diff goes there, the previous one back to its panel.
func _follow_diff(view: Control) -> void:
	if is_instance_valid(main_screen) and main_screen.visible and main_screen.current_view() != view:
		main_screen.adopt(view)


func _leave_main_screen() -> void:
	EditorInterface.set_main_screen_editor(_last_main_screen)


func _on_main_screen_changed(screen_name: String) -> void:
	if screen_name != MAIN_SCREEN_NAME:
		_last_main_screen = screen_name


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


## Brings the Console (Git Log's tab, or the combined dock's view) to front.
func _show_console() -> void:
	if combined_dock != null:
		_reveal(combined_dock)
		combined_dock.show_view("console")
	else:
		_reveal(history_dock_instance)
		history_dock_instance.show_console()


## Brings Branches (the combined dock's sidebar or view, or its tab) to front.
func _reveal_branches() -> void:
	if combined_dock != null:
		_reveal(combined_dock)
		combined_dock.show_view("branches")
	elif bottom_dock_container != null:
		_reveal(bottom_dock_container)
		bottom_dock_container.current_tab = bottom_dock_container.get_node("Branches").get_index()
	else:
		_reveal(dock_instance)
		dock_instance.show_branches()


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


## The script editor's context menu and the palette; _on_setting_changed() turns the gutter on or off.
func _set_blame_enabled(enabled: bool) -> void:
	Settings.set_value(BLAME_SETTING_KEY, enabled)


## Brings Changes to front and runs action there (see changes_panel.gd's run_action()).
func _show_changes(action: String) -> void:
	_reveal_changes()
	dock_instance.show_changes(action)


func _on_gutter_change_clicked(rel_path: String, line: int) -> void:
	_reveal_changes()
	dock_instance.reveal_change(rel_path, line)


func _on_tools_menu_id_pressed(id: int) -> void:
	if LAYOUT_IDS.has(id):
		set_layout(LAYOUT_IDS[id])
	elif id == ID_SETTINGS:
		open_settings()
	elif TOOLS_TOGGLES.has(id):
		Settings.set_value(TOOLS_TOGGLES[id][0], not Settings.get_value(TOOLS_TOGGLES[id][0], TOOLS_TOGGLES[id][1]))


## Applies a setting changed anywhere: the Tools menu, Godit Settings, the palette, a dialog's "Don't ask again".
func _on_setting_changed(key: String) -> void:
	match key:
		AUTO_RELOAD_SETTING_KEY:
			_apply_auto_reload_setting()
		AUTO_SAVE_SETTING_KEY, AUTO_SAVE_SECONDS_KEY:
			_apply_auto_save_setting()
		BLAME_SETTING_KEY:
			blame_gutter.set_enabled(Settings.get_value(BLAME_SETTING_KEY, false))
		GoditDockScript.AUTO_FETCH_SETTING_KEY, GoditDockScript.AUTO_FETCH_MINUTES_KEY:
			dock_instance.apply_auto_fetch_setting()
		INSPECTOR_SETTING_KEY:
			head_inspector.enabled = Settings.get_value(INSPECTOR_SETTING_KEY, true)
			scene_dock_colors.enabled = head_inspector.enabled
			var inspected := EditorInterface.get_inspector().get_edited_object()
			if inspected != null:
				EditorInterface.inspect_object(inspected) # rebuilt with or without the rows
		MAIN_SCREEN_SETTING_KEY:
			if _has_main_screen() != (main_screen != null):
				RepoSetup.reload_plugin() # the editor asks for a plugin's main screen only when it's enabled
		DOCK_LAYOUT_SETTING_KEY:
			_update_layout_items()
		TOOLBAR_BRANCH_SETTING_KEY:
			if branch_toolbar != null:
				branch_toolbar.visible = Settings.get_value(TOOLBAR_BRANCH_SETTING_KEY, true)


## Godit Settings, from the Tools menu, the docks' ⋮ menus and the palette.
func open_settings() -> void:
	if _settings_window == null:
		_settings_window = SettingsWindowScript.new()
		_settings_window.layouts = LAYOUT_ORDER.map(func(l: String) -> Array: return [l, LAYOUT_TITLES[l]])
		_settings_window.default_layout = LAYOUT_COMBINED
		_settings_window.get_layout = _dock_layout
		_settings_window.set_layout = set_layout
		_settings_window.get_fast_status = _fast_status_state
		_settings_window.set_fast_status = _set_fast_status
		EditorInterface.get_base_control().add_child(_settings_window) # not in a dock: switching the layout frees those
	_settings_window.open()


## {"on", "available"} for this repository's git config (it can change outside Godit too).
func _fast_status_state() -> Dictionary:
	var repo: RefCounted = watcher.repo
	var on: bool = repo != null and repo.is_fast_status_on()
	return {"on": on, "available": repo != null and (on or GitCliRepo.fast_status_supported())}


func _set_fast_status(on: bool) -> void:
	if watcher.repo == null:
		return
	var result: Dictionary = watcher.repo.set_fast_status(on)
	if not result["ok"]:
		EditorInterface.get_editor_toaster().push_toast("Godit: " + result["error"], EditorToaster.SEVERITY_WARNING)
	if _settings_window != null:
		_settings_window.refresh()


## Mirrors our own per-user Godit preference onto Godot's own (editor-wide) auto-reload setting — unchecking it restores the normal "reload externally modified file?" confirmation.
func _apply_auto_reload_setting() -> void:
	EditorInterface.get_editor_settings().set_setting(AUTO_RELOAD_EDITOR_SETTING, Settings.get_value(AUTO_RELOAD_SETTING_KEY, true))


## Mirrors our own per-user Godit preference onto Godot's own (editor-wide) autosave interval.
func _apply_auto_save_setting() -> void:
	var editor_settings := EditorInterface.get_editor_settings()
	var original: Variant = Settings.get_value(AUTO_SAVE_ORIGINAL_KEY, null)
	if Settings.get_value(AUTO_SAVE_SETTING_KEY, false):
		if original == null:
			var current: Variant = editor_settings.get_setting(AUTO_SAVE_EDITOR_SETTING)
			Settings.set_value(AUTO_SAVE_ORIGINAL_KEY, 0 if current == AUTO_SAVE_INTERVAL_SECS else current) # 3 here means an older version set it
		editor_settings.set_setting(AUTO_SAVE_EDITOR_SETTING, maxi(1, int(Settings.get_value(AUTO_SAVE_SECONDS_KEY, AUTO_SAVE_INTERVAL_SECS))))
	elif original != null:
		editor_settings.set_setting(AUTO_SAVE_EDITOR_SETTING, original)
		Settings.set_value(AUTO_SAVE_ORIGINAL_KEY, null)
	elif editor_settings.get_setting(AUTO_SAVE_EDITOR_SETTING) == AUTO_SAVE_INTERVAL_SECS:
		editor_settings.set_setting(AUTO_SAVE_EDITOR_SETTING, 0) # set by an older version that didn't remember the user's own interval


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
	if want == LAYOUT_BOTTOM and not dock_instance.has_repo():
		want = LAYOUT_SEPARATE # nothing to put in the bottom tabs, and the Git dock is where "Initialize Repository" shows
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
			add_control_to_dock(EditorPlugin.DOCK_SLOT_LEFT_UR, dock_instance, commands.shortcut("toggle_dock"))
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
			add_control_to_dock(EditorPlugin.DOCK_SLOT_LEFT_UR, dock_instance, commands.shortcut("toggle_dock"))
			add_control_to_bottom_panel(history_dock_instance, "Git Log")

	match want:
		LAYOUT_BOTTOM:
			remove_control_from_docks(dock_instance)
			var panels: Dictionary = dock_instance.detach_panels()
			bottom_dock_container = TabContainer.new()
			bottom_dock_container.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED # English throughout, see godit_dock.gd
			bottom_dock_container.custom_minimum_size.y = UiScale.px(BOTTOM_PANEL_MIN_HEIGHT)
			bottom_dock_container.add_child(panels["changes"])
			bottom_dock_container.add_child(panels["branches"])
			var menu := _layout_menu(PopupMenu.new())
			bottom_dock_container.add_child(menu, false, Node.INTERNAL_MODE_FRONT)
			bottom_dock_container.set_popup(menu)
			add_control_to_bottom_panel(bottom_dock_container, "Git Changes", commands.shortcut("toggle_dock"))
		LAYOUT_COMBINED:
			remove_control_from_docks(dock_instance)
			remove_control_from_bottom_panel(history_dock_instance)
			var panels := {}
			if dock_instance.has_repo():
				panels = dock_instance.detach_panels()
				panels.merge(history_dock_instance.detach_panels())
			combined_dock = CombinedDockScript.new(panels)
			combined_dock.custom_minimum_size.y = UiScale.px(BOTTOM_PANEL_MIN_HEIGHT) # it starts in the bottom panel, where it mustn't shrink to a clipped sliver
			if combined_dock.layout_menu() != null:
				_layout_menu(combined_dock.layout_menu())
			combined_dock.use_shortcuts(commands.shortcuts())
			_add_combined_dock()
	_layout = want


## Bottom panel by default. On 4.6+ as an EditorDock the user can move to a side dock or make floating, and the editor remembers where; older versions can only put it in the bottom panel.
func _add_combined_dock() -> void:
	if not ClassDB.class_exists("EditorDock"):
		add_control_to_bottom_panel(combined_dock, "Godit", commands.shortcut("toggle_dock"))
		return
	# Through ClassDB and call(): EditorDock, add_dock() and DOCK_SLOT_BOTTOM don't exist before 4.6, and naming them would break parsing there.
	_combined_editor_dock = ClassDB.instantiate("EditorDock")
	_combined_editor_dock.set("title", "Godit")
	_combined_editor_dock.set("layout_key", "GoditCombined") # not "Godit", which early builds saved as a side dock
	_combined_editor_dock.set("global", true) # listed in Editor > Editor Docks, so it can be reopened after closing
	_combined_editor_dock.set("default_slot", ClassDB.class_get_integer_constant("EditorDock", "DOCK_SLOT_BOTTOM"))
	_combined_editor_dock.set("available_layouts", ClassDB.class_get_integer_constant("EditorDock", "DOCK_LAYOUT_ALL"))
	_combined_editor_dock.set("dock_shortcut", commands.shortcut("toggle_dock"))
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
