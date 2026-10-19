extends "res://tests/assertions.gd"

# The fingerprint of Godit's own files that tells a git operation changed the running plugin, and where Show in FileSystem lands; the restart offer and the dock itself need the editor.

const EditorOpen = preload("res://addons/godit/util/editor_open.gd")

func test_fingerprint_covers_scripts_and_scenes_in_subfolders() -> void:
	var dir := make_temp_dir() + "/"
	write_file(dir + "plugin.gd", "extends Node\n")
	write_file(dir + "dock/panel.tscn", "[gd_scene format=3]\n")
	write_file(dir + "notes.txt", "not code\n")
	var before := EditorOpen.hash_scripts(dir)
	check("scripts and scenes", before.keys().map(func(path: String) -> String: return path.trim_prefix(dir)), ["plugin.gd", "dock/panel.tscn"])
	write_file(dir + "notes.txt", "still not code\n")
	check("other files don't count", EditorOpen.hash_scripts(dir), before)
	write_file(dir + "dock/panel.tscn", "[gd_scene format=3 uid=\"uid://x\"]\n")
	check_true("a changed scene does", EditorOpen.hash_scripts(dir) != before)

func test_show_in_filesystem_lands_on_the_nearest_path_still_there() -> void:
	var project := ProjectSettings.globalize_path("res://")
	check("a file", EditorOpen.filesystem_target(project, "addons/godit/plugin.gd"), "res://addons/godit/plugin.gd")
	check("a folder", EditorOpen.filesystem_target(project, "addons/godit/"), "res://addons/godit")
	check("a deleted file: its folder", EditorOpen.filesystem_target(project, "addons/godit/gone/old.gd"), "res://addons/godit")
	check("the project", EditorOpen.filesystem_target(project, ""), "res://")
	check("outside the project", EditorOpen.filesystem_target(make_temp_dir(), "a.txt"), "")
