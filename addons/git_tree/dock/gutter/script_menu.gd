## "Git: …" items in the script editor's right-click menu: preview/rollback the change at the caret, the commit behind the caret's line, file history, and the blame toggle. Plain items rather than a submenu: a PopupMenu handed to add_context_submenu_item() gets parented into the editor's menu, and freeing it on plugin reload left the editor with a dangling submenu that crashed on the next right-click.
extends EditorContextMenuPlugin

## Set by plugin.gd.
var diff_gutter: Node
var blame_gutter: Node
## Called with an oid / a repo-relative path; plugin.gd points them at the Git Log.
var show_commit: Callable
var show_file_history: Callable


func _popup_menu(paths: PackedStringArray) -> void:
	var code_edit := _code_edit_from(paths)
	if code_edit == null or not code_edit.has_meta(diff_gutter.META_REL_PATH):
		return # not a script inside the repo

	if diff_gutter.region_at_line(code_edit, code_edit.get_caret_line()) != -1:
		add_context_menu_item("Git: Preview Change", _on_preview)
		add_context_menu_item("Git: Rollback Change", _on_rollback)
		add_context_menu_item("Git: Show Change in Changes Panel", _on_show_in_changes)
	add_context_menu_item("Git: Show Commit for This Line", _on_line_commit)
	add_context_menu_item("Git: Show History of This File", _on_file_history)
	add_context_menu_item("Git: Hide Blame" if blame_gutter.is_enabled() else "Git: Show Blame", _on_toggle_blame)


## The callback gets the CodeEdit itself; _popup_menu() gets its node path.
static func _code_edit_from(target: Variant) -> CodeEdit:
	if target is CodeEdit:
		return target
	if (target is PackedStringArray or target is Array) and not target.is_empty():
		return Engine.get_main_loop().root.get_node_or_null(NodePath(str(target[0]))) as CodeEdit
	return null


func _on_preview(target: Variant) -> void:
	var code_edit := _code_edit_from(target)
	if code_edit != null:
		diff_gutter.show_preview(code_edit, diff_gutter.region_at_line(code_edit, code_edit.get_caret_line()))


func _on_rollback(target: Variant) -> void:
	var code_edit := _code_edit_from(target)
	if code_edit != null:
		diff_gutter.rollback(code_edit, diff_gutter.region_at_line(code_edit, code_edit.get_caret_line()))


func _on_show_in_changes(target: Variant) -> void:
	var code_edit := _code_edit_from(target)
	if code_edit != null:
		diff_gutter.change_clicked.emit(code_edit.get_meta(diff_gutter.META_REL_PATH, ""), code_edit.get_caret_line() + 1)


func _on_line_commit(target: Variant) -> void:
	var code_edit := _code_edit_from(target)
	if code_edit == null:
		return
	var oid: String = await blame_gutter.commit_at(code_edit.get_meta(diff_gutter.META_RES_PATH, ""), code_edit, code_edit.get_caret_line())
	if oid.is_empty():
		EditorInterface.get_editor_toaster().push_toast("Git: this line isn't committed yet.")
	else:
		show_commit.call(oid)


func _on_file_history(target: Variant) -> void:
	var code_edit := _code_edit_from(target)
	if code_edit != null:
		show_file_history.call(code_edit.get_meta(diff_gutter.META_REL_PATH, ""))


func _on_toggle_blame(_target: Variant) -> void:
	blame_gutter.toggle_requested.emit(not blame_gutter.is_enabled())
