@tool
extends Control

const GitStatusFlags := preload("res://addons/git_tree/util/git_status_flags.gd")
const GitIcons := preload("res://addons/git_tree/util/git_icons.gd")
const EditorOpen := preload("res://addons/git_tree/util/editor_open.gd")

const ID_OPEN := 1
const ID_ADD_TO_VCS := 2
const ID_ADD_ALL_TO_VCS := 3
const ID_TOGGLE_STAGE := 4

## ChangesTree has two columns: the checkbox needs its own narrow column,
## since Godot toggles a CELL_MODE_CHECK cell on any click anywhere inside
## it, and a single wide column meant clicking the filename also toggled
## staged state.
const TEXT_COLUMN := 0
const CHECKBOX_COLUMN := 1
const CHECKBOX_COLUMN_WIDTH := 28

@onready var _tree: Tree = %ChangesTree
@onready var _commit_message: TextEdit = %CommitMessage
@onready var _commit_button: Button = %CommitButton
@onready var _status_label: Label = %StatusLabel
@onready var _error_dialog: AcceptDialog = %ErrorDialog
@onready var _context_menu: PopupMenu = %ContextMenu

## Set by git_tree_dock.gd; a git_cli_repo.gd instance.
var _repo: RefCounted

## Rebuilding the tree in refresh() re-checks/unchecks items programmatically,
## which would otherwise re-trigger item_edited and loop back into refresh().
var _suppress_item_edited := false

## What a right-click landed on, stashed for the context menu's id_pressed
## handler: {"kind": "file"|"untracked_file", "path": ...}.
var _context_target: Dictionary = {}


func _ready() -> void:
	_tree.columns = 2
	_tree.set_column_expand(CHECKBOX_COLUMN, false)
	_tree.set_column_custom_minimum_width(CHECKBOX_COLUMN, CHECKBOX_COLUMN_WIDTH)
	_tree.set_column_expand(TEXT_COLUMN, true)
	# Without this, a right-click doesn't register as hitting an item, so
	# item_mouse_selected never fires and the context menu can't open.
	_tree.allow_rmb_select = true

	_commit_message.gui_input.connect(_on_commit_message_gui_input)
	_commit_message.tooltip_text = "Ctrl/Cmd+Enter to commit"


func set_repo(repo: RefCounted) -> void:
	_repo = repo
	refresh()


func refresh() -> void:
	if _repo == null:
		return
	var entries: Array = _repo.get_status()

	var selected_path := ""
	var selected_item := _tree.get_selected()
	if selected_item != null and selected_item.get_metadata(0) is Dictionary:
		selected_path = selected_item.get_metadata(0).get("path", "")
	var scroll_y := _tree.get_scroll().y

	_suppress_item_edited = true
	_tree.clear()
	var root := _tree.create_item()

	var any_staged := false
	var count := 0
	for entry in entries:
		var path: String = entry["path"]
		var status: int = entry["status"]
		var staged := GitStatusFlags.is_staged(status)
		any_staged = any_staged or staged
		count += 1
		_add_file_item(root, path, status, staged, not GitStatusFlags.is_untracked(status))
	_suppress_item_edited = false

	_reselect(root, selected_path, scroll_y)

	if count == 0:
		_status_label.text = "No changes."
	else:
		_status_label.text = ""

	_update_commit_buttons_enabled(any_staged)


## Re-selects the file that was selected before the tree was rebuilt, so a refresh doesn't lose your place.
func _reselect(root: TreeItem, path: String, scroll_y: float) -> void:
	if not path.is_empty():
		var found := _find_item_by_path(root, path)
		if found != null:
			found.select(TEXT_COLUMN)
	_restore_scroll.call_deferred(scroll_y)


## Tree keeps its scrollbars as internal children with no getter; restoring the scroll position after a rebuild needs the vertical one.
func _restore_scroll(scroll_y: float) -> void:
	for child in _tree.get_children(true):
		if child is VScrollBar:
			child.value = scroll_y


func _find_item_by_path(item: TreeItem, path: String) -> TreeItem:
	var child := item.get_first_child()
	while child:
		var meta: Variant = child.get_metadata(0)
		if meta is Dictionary and meta.get("path", "") == path:
			return child
		child = child.get_next()
	return null


## Stages previously-untracked files.
func _add_to_vcs(paths: Array) -> void:
	var result: Dictionary = _repo.stage_files(paths)
	if not result["ok"]:
		_show_error("Add to Git failed", result["error"])
		return
	_status_label.text = "Added %s to Git." % (paths[0].get_file() if paths.size() == 1 else "%d files" % paths.size())


func _add_file_item(root: TreeItem, path: String, status: int, staged: bool, tracked: bool) -> void:
	var item := _tree.create_item(root)
	# New files get a checkbox too: checking one adds it to Git (same gesture as staging).
	item.set_cell_mode(CHECKBOX_COLUMN, TreeItem.CELL_MODE_CHECK)
	item.set_editable(CHECKBOX_COLUMN, true)
	item.set_checked(CHECKBOX_COLUMN, staged)
	item.set_tooltip_text(CHECKBOX_COLUMN, "Stage/unstage" if tracked else "Add to Git")
	item.set_text(TEXT_COLUMN, "%s  %s" % [GitIcons.status_letter(status), path])
	item.set_custom_color(TEXT_COLUMN, GitIcons.status_color(status))
	var meta := { "kind": "file" if tracked else "untracked_file", "path": path, "status": status, "staged": staged }
	item.set_metadata(0, meta)
	var hint := "Check to stage, uncheck to unstage. Double-click to open." if tracked else "Check to add to Git. Double-click to open."
	item.set_tooltip_text(TEXT_COLUMN, "%s — %s\n%s" % [path, GitStatusFlags.short_label(status), hint])


func _on_changes_tree_item_edited() -> void:
	if _suppress_item_edited:
		return

	var item := _tree.get_edited()
	if item == null:
		return
	var meta: Dictionary = item.get_metadata(0)
	if meta.is_empty():
		return

	var kind: String = meta.get("kind", "")
	if kind == "file":
		if item.is_checked(CHECKBOX_COLUMN):
			_repo.stage_file(meta["path"])
		else:
			_repo.unstage_file(meta["path"])
	elif kind == "untracked_file":
		if item.is_checked(CHECKBOX_COLUMN):
			_add_to_vcs([meta["path"]])
	refresh.call_deferred()


func _on_changes_tree_item_activated() -> void:
	var item := _tree.get_selected()
	if item == null:
		return
	var meta: Dictionary = item.get_metadata(0)
	if meta.is_empty() or not meta.has("path"):
		return
	var error := EditorOpen.open_file(_repo.get_repo_root(), meta["path"])
	if not error.is_empty():
		_show_error("Can't open file", error)


## Left click is checkbox-only (stage/unstage) and row selection; right
## click is the only way to reach the actions menu.
func _on_changes_tree_item_mouse_selected(mouse_position: Vector2, mouse_button_index: int) -> void:
	if mouse_button_index != MOUSE_BUTTON_RIGHT:
		return
	var item := _tree.get_item_at_position(mouse_position)
	if item == null:
		return
	# mouse_position is local to _tree, not this Control.
	_show_context_menu_for_item(item, _tree.get_screen_position() + mouse_position.round())


func _show_context_menu_for_item(item: TreeItem, screen_position: Vector2) -> void:
	var meta: Variant = item.get_metadata(0)
	if not meta is Dictionary or meta.is_empty():
		return

	_context_target = meta
	_context_menu.clear()

	match meta.get("kind", ""):
		"file":
			_context_menu.add_item("Open", ID_OPEN)
			_context_menu.add_item("Stage" if not meta["staged"] else "Unstage", ID_TOGGLE_STAGE)
		"untracked_file":
			_context_menu.add_item("Add to Git", ID_ADD_TO_VCS)
			_context_menu.add_item("Add All New Files to Git", ID_ADD_ALL_TO_VCS)
			_context_menu.add_item("Open", ID_OPEN)
		_:
			return

	_context_menu.position = screen_position
	_context_menu.reset_size()
	_context_menu.popup()


func _on_context_menu_id_pressed(id: int) -> void:
	match id:
		ID_OPEN:
			var error := EditorOpen.open_file(_repo.get_repo_root(), _context_target["path"])
			if not error.is_empty():
				_show_error("Can't open file", error)
		ID_ADD_TO_VCS:
			_add_to_vcs([_context_target["path"]])
			refresh.call_deferred()
		ID_ADD_ALL_TO_VCS:
			var new_paths: Array = []
			for entry in _repo.get_status():
				if GitStatusFlags.is_untracked(entry["status"]):
					new_paths.append(entry["path"])
			_add_to_vcs(new_paths)
			refresh.call_deferred()
		ID_TOGGLE_STAGE:
			var path: String = _context_target["path"]
			if _context_target["staged"]:
				_repo.unstage_file(path)
			else:
				_repo.stage_file(path)
			refresh.call_deferred()


func _on_commit_message_gui_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode in [KEY_ENTER, KEY_KP_ENTER] \
			and (event.ctrl_pressed or event.meta_pressed):
		_commit_message.accept_event()
		if not _commit_button.disabled:
			_do_commit()


func _on_commit_message_text_changed() -> void:
	_update_commit_buttons_enabled()


func _update_commit_buttons_enabled(any_staged: Variant = null) -> void:
	if _repo == null:
		return
	if any_staged == null:
		any_staged = false
		for entry in _repo.get_status():
			if GitStatusFlags.is_staged(entry["status"]):
				any_staged = true
				break

	var has_message := not _commit_message.text.strip_edges().is_empty()
	_commit_button.disabled = not (has_message and any_staged)


func _on_commit_button_pressed() -> void:
	_do_commit()


func _do_commit() -> void:
	var message := _commit_message.text.strip_edges()
	if message.is_empty():
		_show_error("Commit failed", "Commit message can't be empty.")
		return

	var result: Dictionary = _repo.commit(message)
	if not result["ok"]:
		_show_error("Commit failed", result["error"])
		return

	_commit_message.text = ""
	refresh()
	_status_label.text = "Committed %s" % String(result["oid"]).substr(0, 8)


func _show_error(title: String, message: String) -> void:
	_error_dialog.title = title
	_error_dialog.dialog_text = message
	_error_dialog.popup_centered()
