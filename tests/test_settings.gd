extends "res://tests/assertions.gd"

# Every file goes to a temp folder: a test must not write into the project's user:// settings, the editor's config folder or project.godot.

const Settings = preload("res://addons/godit/util/settings.gd")
const SettingsWindow = preload("res://addons/godit/dock/widgets/settings_window.gd")
const MASKS_SETTING := "godit/changes/auto_add_ignore_masks"

var _dir := ""
## The runner's paths, put back by _restore().
var _runner_paths: Array = []

func _isolate() -> void:
	_runner_paths = [Settings.local_path_override, Settings.global_path_override, Settings.project_file_override]
	_dir = make_temp_dir()
	Settings.local_path_override = _dir.path_join("project_a.cfg")
	Settings.global_path_override = _dir.path_join("config/godit_settings.cfg")
	Settings.project_file_override = _dir.path_join("project.godot")

func _restore() -> void:
	Settings.local_path_override = _runner_paths[0]
	Settings.global_path_override = _runner_paths[1]
	Settings.project_file_override = _runner_paths[2]
	ProjectSettings.set_setting(MASKS_SETTING, null)

func _write_local(key: String, value: Variant) -> void:
	var cfg := ConfigFile.new()
	cfg.load(Settings.local_path_override)
	cfg.set_value(Settings.SECTION, key, value)
	cfg.save(Settings.local_path_override)

func test_preferences_follow_to_every_project() -> void:
	_isolate()
	Settings.set_value("diff_side_by_side", true)
	Settings.local_path_override = _dir.path_join("project_b.cfg")
	check("another project sees it", Settings.get_value("diff_side_by_side", false), true)
	check("kept in the config folder", FileAccess.file_exists(Settings.global_path_override), true)
	_restore()

func test_view_state_stays_per_project() -> void:
	_isolate()
	Settings.set_value("combined_view", "history")
	check("this project", Settings.get_value("combined_view", "changes"), "history")
	Settings.local_path_override = _dir.path_join("project_b.cfg")
	check("not another one", Settings.get_value("combined_view", "changes"), "changes")
	check("nothing in the config folder", FileAccess.file_exists(Settings.global_path_override), false)
	_restore()

func test_older_per_project_values_count_until_set_again() -> void:
	_isolate()
	_write_local("show_blame", true)
	check("the old value", Settings.get_value("show_blame", false), true)
	check("is set", Settings.is_set("show_blame"), true)
	Settings.set_value("show_blame", false)
	check("the new value", Settings.get_value("show_blame", true), false)
	var local := ConfigFile.new()
	local.load(Settings.local_path_override)
	check("the old one is gone", local.has_section_key(Settings.SECTION, "show_blame"), false)
	_restore()

func test_team_settings_go_to_project_godot() -> void:
	_isolate()
	_write_local("auto_add_ignore_masks", ["*.old"])
	check("an old per-project list still counts", Settings.get_value("auto_add_ignore_masks", []), ["*.old"])
	Settings.set_value("auto_add_ignore_masks", ["*.psd", "build/"])
	check("a project setting", ProjectSettings.get_setting(MASKS_SETTING), ["*.psd", "build/"])
	check("read back", Settings.get_value("auto_add_ignore_masks", []), ["*.psd", "build/"])
	check_contains("saved with the project", read_file(Settings.project_file_override), MASKS_SETTING.get_slice("/", 2))
	Settings.reset("auto_add_ignore_masks")
	check("reset removes it", ProjectSettings.has_setting(MASKS_SETTING), false)
	check("and the default applies", Settings.get_value("auto_add_ignore_masks", ["*.tmp"]), ["*.tmp"])
	_restore()

func test_changes_are_announced() -> void:
	_isolate()
	var keys: Array = []
	var listener := func(key: String) -> void: keys.append(key)
	Settings.notifier().changed.connect(listener)
	Settings.set_value("diff_context", 10)
	Settings.reset("diff_context")
	Settings.notifier().changed.disconnect(listener)
	check("set and reset", keys, ["diff_context", "diff_context"])
	check("back to the default", Settings.get_value("diff_context", 3), 3)
	_restore()

func _window(layout: Array) -> SettingsWindow:
	var window: SettingsWindow = track(SettingsWindow.new())
	window.layouts = [["combined", "Combined Dock"], ["separate", "Git Dock and Git Log"]]
	window.default_layout = "combined"
	window.get_layout = func() -> String: return layout[0]
	window.set_layout = func(value: String) -> void: layout[0] = value
	window.get_fast_status = func() -> Dictionary: return {"on": false, "available": false}
	window.set_fast_status = func(_on: bool) -> void: pass
	tree.root.add_child(window)
	return window

func _row(window: SettingsWindow, key: String) -> Dictionary:
	for entry: Dictionary in window._built:
		if entry["key"] == key:
			return entry
	return {}

func test_window_edits_and_resets_settings() -> void:
	_isolate()
	var layout := ["separate"]
	var window := _window(layout)
	var side_by_side: CheckBox = _row(window, "diff_side_by_side")["control"]
	check("shows the stored value", side_by_side.button_pressed, false)
	side_by_side.button_pressed = true
	check("a click stores it", Settings.get_value("diff_side_by_side", false), true)
	Settings.set_value("diff_syntax", false)
	check("follows a change made elsewhere", (_row(window, "diff_syntax")["control"] as CheckBox).button_pressed, false)
	var layout_option: OptionButton = _row(window, "dock_layout")["control"]
	check("the current layout", layout_option.selected, 1)
	window.reset_section("Diff")
	check("reset", Settings.get_value("diff_side_by_side", false), false)
	check("unchecked again", side_by_side.button_pressed, false)
	check("other sections stay", layout[0], "separate")
	window.reset_section("Layout")
	check("the default layout", layout[0], "combined")
	_restore()

func test_window_shows_one_section_at_a_time() -> void:
	_isolate()
	var window := _window(["combined"])
	check("every section on the left", window.listed_sections(), Array(SettingsWindow.SECTIONS))
	check("the first one open", (window._sections["Layout"]["box"] as Control).visible, true)
	window.show_section("Diff")
	check("Diff open", (window._sections["Diff"]["box"] as Control).visible, true)
	check("Layout closed", (window._sections["Layout"]["box"] as Control).visible, false)
	check("selected on the left", window._sidebar.get_selected().get_metadata(0), "Diff")
	_restore()

func test_window_filter_narrows_sections_and_rows() -> void:
	_isolate()
	var window := _window(["combined"])
	window.show_section("Diff")
	window._filter.text = "blame"
	window._apply_filter()
	check("only the section with a match", window.listed_sections(), ["Editor"])
	check("and it's open", (window._sections["Editor"]["box"] as Control).visible, true)
	check("the matching row", (_row(window, "show_blame")["row"] as Control).visible, true)
	check("not its neighbor", (_row(window, "inspector_changes")["row"] as Control).visible, false)
	window._filter.text = "no such setting"
	window._apply_filter()
	check("nothing listed", window.listed_sections(), [])
	check("says so", window._no_match.visible, true)
	window._filter.text = ""
	window._apply_filter()
	check("all back", window.listed_sections(), Array(SettingsWindow.SECTIONS))
	check("the open section stays", (window._sections["Editor"]["box"] as Control).visible, true)
	check("rows back", (_row(window, "inspector_changes")["row"] as Control).visible, true)
	_restore()
