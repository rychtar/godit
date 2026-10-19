extends "res://tests/assertions.gd"

# The fingerprint of Godit's own files that tells a git operation changed the running plugin; the restart offer itself needs the editor.

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
