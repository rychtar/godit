## Godit's preferences, each kept at one of three levels: all projects (a file in the editor's config folder), this project just for me (user://), or the whole team (project.godot). No class_name: internal helper, addressed via preload (see git_status_flags.gd for why).
extends RefCounted

const SCOPE_GLOBAL := "global"
const SCOPE_PROJECT := "project"
const SCOPE_TEAM := "team"

## The per-project file, and where every key lived before there were levels: a value still there is used until the key is set again.
const CONFIG_PATH := "user://godit_settings.cfg"
const GLOBAL_FILE_NAME := "godit_settings.cfg"
const SECTION := "godit"

## Preferences that follow the user to every project; any other key (open view, dividers, toolbar filters) stays per project.
const GLOBAL_KEYS := [
	"dock_layout", "diff_main_screen", "show_blame", "inspector_changes",
	"diff_side_by_side", "diff_ignore_whitespace", "diff_syntax", "diff_hide_noise", "diff_context", "diff_scene_view", "diff_image_mode",
	"history_visible_columns", "history_absolute_dates", "history_hash_col_width", "history_author_col_width", "history_date_col_width",
	"auto_stage_changes", "auto_add_new_files", "confirm_shortcut_commit", "save_before_git",
	"auto_fetch", "auto_fetch_minutes", "auto_save_scripts", "auto_save_seconds", "auto_save_original_interval", "auto_reload_external_changes",
]
## Team conventions, key -> its project setting (saved in project.godot, so they're committed with the project).
const TEAM_KEYS := { "auto_add_ignore_masks": "godit/changes/auto_add_ignore_masks" }

## Tests point these elsewhere; "" means the real places.
static var local_path_override := ""
static var global_path_override := ""
static var project_file_override := ""
static var _notifier: Notifier


class Notifier:
	extends RefCounted
	signal changed(key: String)


## Emits changed(key) after every set_value() and reset(), so open panels, menus and the settings window follow a change made anywhere. Created on first use: the editor doesn't run static initializers of scripts that aren't @tool.
static func notifier() -> Notifier:
	if _notifier == null:
		_notifier = Notifier.new()
	return _notifier


static func scope_of(key: String) -> String:
	if TEAM_KEYS.has(key):
		return SCOPE_TEAM
	return SCOPE_GLOBAL if GLOBAL_KEYS.has(key) else SCOPE_PROJECT


static func get_value(key: String, default: Variant) -> Variant:
	match scope_of(key):
		SCOPE_TEAM:
			var setting: String = TEAM_KEYS[key]
			if ProjectSettings.has_setting(setting):
				return ProjectSettings.get_setting(setting)
		SCOPE_GLOBAL:
			var global := _load(_global_path())
			if global.has_section_key(SECTION, key):
				return global.get_value(SECTION, key)
	var local := _load(_local_path())
	# ConfigFile.get_value() logs an error for a missing key when default is null.
	return local.get_value(SECTION, key) if local.has_section_key(SECTION, key) else default


static func set_value(key: String, value: Variant) -> void:
	_store(key, value)
	notifier().changed.emit(key)


## Back to the default: removed from wherever it's kept, including the per-project value older versions left.
static func reset(key: String) -> void:
	_store(key, null)
	notifier().changed.emit(key)


## Whether the key has a value of its own (not the default) at its level or left over per project.
static func is_set(key: String) -> bool:
	match scope_of(key):
		SCOPE_TEAM:
			if ProjectSettings.has_setting(TEAM_KEYS[key]):
				return true
		SCOPE_GLOBAL:
			if _load(_global_path()).has_section_key(SECTION, key):
				return true
	return _load(_local_path()).has_section_key(SECTION, key)


static func _store(key: String, value: Variant) -> void:
	var scope := scope_of(key)
	var local := _load(_local_path())
	if scope != SCOPE_PROJECT or value == null:
		# A level above per project takes over: the old per-project value goes, or it would shadow the key in the next version.
		if local.has_section_key(SECTION, key):
			local.erase_section_key(SECTION, key)
			_save(local, _local_path())
	match scope:
		SCOPE_TEAM:
			var setting: String = TEAM_KEYS[key]
			if not ProjectSettings.has_setting(setting) and value == null:
				return # nothing to remove, and project.godot isn't rewritten for nothing
			ProjectSettings.set_setting(setting, value) # null removes it
			if project_file_override.is_empty():
				ProjectSettings.save()
			else:
				ProjectSettings.save_custom(project_file_override)
		SCOPE_GLOBAL:
			var global := _load(_global_path())
			if value == null:
				if global.has_section_key(SECTION, key):
					global.erase_section_key(SECTION, key)
			else:
				global.set_value(SECTION, key, value)
			_save(global, _global_path())
		_:
			if value != null:
				local.set_value(SECTION, key, value)
				_save(local, _local_path())


static func _local_path() -> String:
	return local_path_override if not local_path_override.is_empty() else CONFIG_PATH


## The editor's config folder (next to editor_settings-4.x.tres); user:// where there's no editor (tests run with --script).
static func _global_path() -> String:
	if not global_path_override.is_empty():
		return global_path_override
	if Engine.is_editor_hint():
		return EditorInterface.get_editor_paths().get_config_dir().path_join(GLOBAL_FILE_NAME)
	return "user://godit_global_settings.cfg"


static func _load(path: String) -> ConfigFile:
	var cfg := ConfigFile.new()
	cfg.load(path) # a missing file is fine: no keys
	return cfg


static func _save(cfg: ConfigFile, path: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	cfg.save(path)
