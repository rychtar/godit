## Before a git operation works with the files on disk, offers to save the scenes and scripts that are still unsaved in the editor.
## No class_name: internal helper, addressed via preload.
extends RefCounted

const Dialogs := preload("res://addons/godit/dock/widgets/dialogs.gd")
const Settings := preload("res://addons/godit/util/settings.gd")
const EditorOpen := preload("res://addons/godit/util/editor_open.gd")

const ALWAYS_SAVE_SETTING_KEY := "save_before_git"


## res:// paths of open scenes and scripts with unsaved edits (untitled scenes excluded: there's no file to save them to).
static func unsaved_files() -> PackedStringArray:
	var paths := PackedStringArray()
	# Called by name: these exist from Godot 4.7, older versions can't list unsaved scenes (only scripts are offered there).
	var scenes: PackedStringArray = EditorInterface.call("get_unsaved_scenes") if EditorInterface.has_method("get_unsaved_scenes") else PackedStringArray()
	for path in scenes:
		if not path.is_empty():
			paths.append(path)
	var script_editor := EditorInterface.get_script_editor()
	if script_editor != null:
		var scripts: PackedStringArray = script_editor.call("get_unsaved_files") if script_editor.has_method("get_unsaved_files") else EditorOpen.unsaved_tab_paths(script_editor)
		for path in scripts:
			if not path.is_empty() and not paths.has(path):
				paths.append(path)
	return paths


static func save_all() -> void:
	var script_editor := EditorInterface.get_script_editor()
	if script_editor != null:
		if script_editor.has_method("save_all_scripts"):
			script_editor.call("save_all_scripts")
		else:
			EditorOpen.save_unsaved_tabs(script_editor)
	EditorInterface.save_all_scenes()


## Coroutine. verb names the operation ("Commit", "Checkout"...); for_commit says the risk is missing edits rather than overwritten ones. False = the user cancelled.
static func ensure_saved(parent: Node, verb: String, for_commit := false) -> bool:
	var proceed: bool = await _ensure_saved(parent, verb, for_commit)
	if proceed:
		EditorOpen.remember_scene_state() # what the open scenes look like on disk before the operation, to reload only those it changes
	return proceed


static func _ensure_saved(parent: Node, verb: String, for_commit: bool) -> bool:
	var unsaved := unsaved_files()
	if unsaved.is_empty():
		return true
	if Settings.get_value(ALWAYS_SAVE_SETTING_KEY, false):
		save_all()
		return true
	var shown := Array(unsaved.slice(0, 8)).map(func(p: String) -> String: return "  " + p.trim_prefix("res://"))
	if unsaved.size() > 8:
		shown.append("  … and %d more" % (unsaved.size() - 8))
	var risk := "The commit only takes what's saved on disk, so these edits would be left out." if for_commit \
			else "%s changes files on disk; unsaved edits could end up out of sync with them or overwrite the result later." % verb
	var answer: String = await Dialogs.error_with_actions(parent, "Unsaved Changes",
			"%d file%s ha%s unsaved changes:\n%s\n\n%s" % [unsaved.size(), "" if unsaved.size() == 1 else "s", "s" if unsaved.size() == 1 else "ve", "\n".join(shown), risk],
			{ "save": "Save and %s" % verb, "always": "Always Save First", "skip": "%s Without Saving" % verb })
	match answer:
		"save":
			save_all()
		"always":
			Settings.set_value(ALWAYS_SAVE_SETTING_KEY, true)
			save_all()
		"skip":
			pass
		_:
			return false
	return true
