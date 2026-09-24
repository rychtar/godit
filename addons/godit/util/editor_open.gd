## Opens a repo-relative path in whichever editor Godot normally uses for
## it — same as double-clicking it in the FileSystem dock. Shared by
## changes_panel.gd and history_panel.gd. No class_name: internal helper,
## addressed via preload (see git_status_flags.gd for why).
extends RefCounted


## The repo root isn't necessarily the Godot project root, so this resolves
## through an absolute path rather than assuming path is already
## res://-relative. Returns an error message to show, or "" on success.
static func open_file(repo_root: String, path: String) -> String:
	var abs_path := repo_root.path_join(path)
	var res_path := ProjectSettings.localize_path(abs_path)
	if not res_path.begins_with("res://"):
		return "This file is outside the current Godot project:\n%s" % abs_path

	if res_path.get_extension() in ["tscn", "scn"]:
		EditorInterface.open_scene_from_path(res_path)
		return ""

	if not ResourceLoader.exists(res_path):
		return "No editor is registered for this file type:\n%s" % res_path

	var resource := load(res_path)
	if resource == null:
		return "Failed to load:\n%s" % res_path

	EditorInterface.edit_resource(resource)
	return ""


## Like open_file(), but for scripts/text also jumps to line (1-based).
static func open_file_at_line(repo_root: String, path: String, line: int) -> String:
	var res_path := ProjectSettings.localize_path(repo_root.path_join(path))
	if res_path.begins_with("res://") and ResourceLoader.exists(res_path):
		var resource := load(res_path)
		if resource is Script or resource is Shader or resource.get_class() == "TextFile":
			EditorInterface.edit_script(resource, maxi(1, line), 0)
			EditorInterface.set_main_screen_editor("Script")
			return ""
	return open_file(repo_root, path)


## Reloads a file the editor doesn't know changed on disk (after revert,
## checkout, ...) — otherwise an open scene/script tab keeps showing stale
## content until the user clicks away and back.
static func refresh_external_change(repo_root: String, path: String) -> void:
	var abs_path := repo_root.path_join(path)
	var res_path := ProjectSettings.localize_path(abs_path)
	if not res_path.begins_with("res://"):
		return

	# Also covers a file revert_file() just deleted outright.
	EditorInterface.get_resource_filesystem().scan()

	if res_path.get_extension() in ["tscn", "scn"]:
		if res_path in EditorInterface.get_open_scenes():
			EditorInterface.reload_scene_from_path(res_path)
		return

	# CACHE_MODE_REPLACE forces a re-read from disk if it's already loaded
	# (open script tab, resource referenced by an open scene, ...).
	if ResourceLoader.exists(res_path):
		ResourceLoader.load(res_path, "", ResourceLoader.CACHE_MODE_REPLACE)
	sync_open_scripts()


## Same as refresh_external_change(), but for an operation that can touch
## the whole working tree (checkout_commit, reset_branch_to, ...) rather
## than one known path.
static func refresh_all_external_changes() -> void:
	EditorInterface.get_resource_filesystem().scan()
	for scene_path in EditorInterface.get_open_scenes():
		# Unsaved new scenes have no path, and a checkout may have deleted the file.
		if not scene_path.is_empty() and FileAccess.file_exists(scene_path):
			EditorInterface.reload_scene_from_path(scene_path)
	sync_open_scripts()


## Script tabs keep their own text buffer, so reloading the resource doesn't change what's shown; this rewrites each open, unmodified tab whose file changed on disk (one undoable edit, caret and scroll kept, tab stays "saved").
static func sync_open_scripts() -> void:
	var script_editor := EditorInterface.get_script_editor()
	if script_editor == null:
		return
	# get_open_scripts() lists only the ScriptTextEditor tabs, in tab order — pair it with those editors.
	var scripts: Array = script_editor.get_open_scripts()
	var editors: Array = script_editor.get_open_script_editors().filter(func(e: Node) -> bool: return e.get_class() == "ScriptTextEditor")
	for i in mini(scripts.size(), editors.size()):
		var script: Script = scripts[i]
		var code_edit := (editors[i] as ScriptEditorBase).get_base_editor() as CodeEdit
		if script == null or code_edit == null or script.resource_path.is_empty() or not FileAccess.file_exists(script.resource_path):
			continue
		if code_edit.get_version() != code_edit.get_saved_version():
			continue # unsaved edits in the tab: leave them, Godot asks on its own
		var disk := FileAccess.get_file_as_string(script.resource_path)
		if code_edit.text == disk:
			continue
		_replace_text_keeping_view(code_edit, disk)
		script.source_code = disk


static func _replace_text_keeping_view(code_edit: CodeEdit, text: String) -> void:
	var caret_line := code_edit.get_caret_line()
	var caret_column := code_edit.get_caret_column()
	var scroll := code_edit.scroll_vertical
	code_edit.begin_complex_operation()
	var last := code_edit.get_line_count() - 1
	code_edit.remove_text(0, 0, last, code_edit.get_line(last).length())
	code_edit.insert_text(text, 0, 0)
	code_edit.end_complex_operation()
	code_edit.tag_saved_version()
	code_edit.set_caret_line(mini(caret_line, code_edit.get_line_count() - 1))
	code_edit.set_caret_column(caret_column)
	code_edit.scroll_vertical = scroll
