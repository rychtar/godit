@tool
extends Control

const GitStatusFlags := preload("res://addons/git_tree/util/git_status_flags.gd")
const GitIcons := preload("res://addons/git_tree/util/git_icons.gd")
const TreeFolders := preload("res://addons/git_tree/util/tree_folders.gd")
const EditorOpen := preload("res://addons/git_tree/util/editor_open.gd")
const Settings := preload("res://addons/git_tree/util/settings.gd")
const Dialogs := preload("res://addons/git_tree/dock/widgets/dialogs.gd")

const DIFF_VISIBLE_SETTING_KEY := "diff_preview_visible"
const LIST_PANE_RATIO := 0.4

const ID_OPEN := 1
const ID_ADD_TO_VCS := 2
const ID_ADD_ALL_TO_VCS := 3
const ID_TOGGLE_STAGE := 4
const ID_ADD_FOLDER_TO_VCS := 5

## ChangesTree has two columns: the checkbox needs its own narrow column,
## since Godot toggles a CELL_MODE_CHECK cell on any click anywhere inside
## it, and a single wide column meant clicking the filename also toggled
## staged state.
##
## Text is column 0, not the checkbox, because Godot only indents/draws
## fold-arrows for column 0 — with the checkbox there, nested folders
## lined up flush-left instead of stair-stepping.
const TEXT_COLUMN := 0
const CHECKBOX_COLUMN := 1
const CHECKBOX_COLUMN_WIDTH := 28

@onready var _tree: Tree = %ChangesTree
@onready var _diff_view: Control = %DiffView
@onready var _diff_toggle: CheckButton = %DiffToggle
@onready var _amend_check: CheckBox = %AmendCheck
@onready var _commit_message: TextEdit = %CommitMessage
@onready var _commit_button: Button = %CommitButton
@onready var _commit_push_button: Button = %CommitPushButton
@onready var _status_label: Label = %StatusLabel
@onready var _error_dialog: AcceptDialog = %ErrorDialog
@onready var _context_menu: PopupMenu = %ContextMenu

## Set by git_tree_dock.gd; a git_cli_repo.gd instance.
var _repo: RefCounted

## Rebuilding the tree in refresh() re-checks/unchecks items programmatically,
## which would otherwise re-trigger item_edited and loop back into refresh().
var _suppress_item_edited := false

## What a right-click landed on, stashed for the context menu's id_pressed
## handler: {"kind": "file"|"untracked_file"|"folder", "path": ...}.
var _context_target: Dictionary = {}

## Which diff ("unstaged"/"staged") was last viewed per path, for files that have both.
var _diff_side_by_path := {}


func _ready() -> void:
	_tree.columns = 2
	_tree.set_column_expand(CHECKBOX_COLUMN, false)
	_tree.set_column_custom_minimum_width(CHECKBOX_COLUMN, CHECKBOX_COLUMN_WIDTH)
	_tree.set_column_expand(TEXT_COLUMN, true)
	# Without this, a right-click doesn't register as hitting an item, so
	# item_mouse_selected never fires and the context menu can't open.
	_tree.allow_rmb_select = true

	_diff_toggle.button_pressed = Settings.get_value(DIFF_VISIBLE_SETTING_KEY, true)

	# File list + commit box take ~40% of the width, the diff the rest; re-applied on resize since split_offset is in pixels from the middle.
	%Split.resized.connect(func() -> void: %Split.split_offset = int(%Split.size.x * (LIST_PANE_RATIO - 0.5)))

	_diff_view.options_changed.connect(_show_selected_diff)
	_diff_view.tab_selected.connect(_on_diff_tab_selected)
	_diff_view.open_location_requested.connect(func(path: String, line: int) -> void:
		var error := EditorOpen.open_file_at_line(_repo.get_repo_root(), path, line)
		if not error.is_empty():
			Dialogs.error(self, "Can't open file", error)
	)
	_commit_message.gui_input.connect(_on_commit_message_gui_input)
	_commit_message.tooltip_text = "Ctrl/Cmd+Enter to commit, Ctrl/Cmd+Shift+Enter to commit and push"


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

	var changes_group := _tree.create_item(root)
	changes_group.set_selectable(CHECKBOX_COLUMN, false)
	changes_group.set_selectable(TEXT_COLUMN, false)
	changes_group.set_metadata(0, { "kind": "changes_group" })
	# Checkable like a folder — toggling the group header cascades to
	# every file under it (see _aggregate_files() and
	# _on_changes_tree_item_edited()).
	changes_group.set_cell_mode(CHECKBOX_COLUMN, TreeItem.CELL_MODE_CHECK)
	changes_group.set_editable(CHECKBOX_COLUMN, true)
	changes_group.set_custom_color(TEXT_COLUMN, Color(0.68, 0.85, 1.0))
	var changes_folders: Dictionary = {}

	# Blank spacer row so "New Files" reads as separate from the
	# tracked changes above it.
	var spacer := _tree.create_item(root)
	spacer.set_selectable(CHECKBOX_COLUMN, false)
	spacer.set_selectable(TEXT_COLUMN, false)
	spacer.set_custom_minimum_height(6)

	var untracked_group := _tree.create_item(root)
	untracked_group.set_selectable(CHECKBOX_COLUMN, false)
	untracked_group.set_selectable(TEXT_COLUMN, false)
	untracked_group.set_metadata(0, { "kind": "untracked_group" })
	untracked_group.set_cell_mode(CHECKBOX_COLUMN, TreeItem.CELL_MODE_CHECK)
	untracked_group.set_editable(CHECKBOX_COLUMN, true)
	untracked_group.set_tooltip_text(CHECKBOX_COLUMN, "Add all new files to Git")
	untracked_group.set_custom_color(TEXT_COLUMN, Color(0.55, 0.55, 0.58))
	untracked_group.set_custom_bg_color(TEXT_COLUMN, Color(1, 1, 1, 0.03), true)
	var untracked_folders: Dictionary = {}

	var any_staged := false

	for entry in entries:
		var path: String = entry["path"]
		var status: int = entry["status"]
		var staged := GitStatusFlags.is_staged(status)
		any_staged = any_staged or staged
		if GitStatusFlags.is_untracked(status):
			_add_file_item(untracked_group, untracked_folders, path, status, staged, false)
		else:
			_add_file_item(changes_group, changes_folders, path, status, staged, true)

	var agg := _aggregate_files(changes_group)
	var tracked_count: int = agg["count"]
	changes_group.set_text(TEXT_COLUMN, "Changes  %d %s" % [tracked_count, "file" if tracked_count == 1 else "files"])
	changes_group.set_checked(CHECKBOX_COLUMN, tracked_count > 0 and agg["staged"] == tracked_count)
	changes_group.set_indeterminate(CHECKBOX_COLUMN, tracked_count > 0 and agg["staged"] > 0 and agg["staged"] < tracked_count)

	var untracked_agg := _aggregate_files(untracked_group)
	var untracked_count: int = untracked_agg["count"]
	untracked_group.set_text(TEXT_COLUMN, "New Files  %d — not in Git yet, check to add" % untracked_count)
	untracked_group.collapsed = untracked_count == 0
	untracked_group.set_visible(untracked_count > 0)
	spacer.set_visible(untracked_count > 0)
	_suppress_item_edited = false

	_reselect(root, selected_path, scroll_y)

	if untracked_count == 0 and tracked_count == 0:
		_status_label.text = "No changes."
	else:
		_status_label.text = ""

	_update_commit_buttons_enabled(any_staged)


## Re-selects the file that was selected before the tree was rebuilt (so refreshes and hunk actions don't lose your place), or clears the diff if it's gone.
func _reselect(root: TreeItem, path: String, scroll_y: float) -> void:
	var found: TreeItem = null
	if not path.is_empty():
		found = _find_item_by_path(root, path)
	if found != null:
		found.select(TEXT_COLUMN) # emits item_selected -> _show_selected_diff()
	else:
		_diff_view.clear_diff()
	var bar: VScrollBar = TreeFolders.v_scroll_bar(_tree)
	if bar != null:
		bar.set_deferred("value", scroll_y)


func _find_item_by_path(item: TreeItem, path: String) -> TreeItem:
	var child := item.get_first_child()
	while child:
		var meta: Variant = child.get_metadata(0)
		if meta is Dictionary and meta.get("path", "") == path and child.is_visible_in_tree():
			return child
		var nested := _find_item_by_path(child, path)
		if nested != null:
			return nested
		child = child.get_next()
	return null


## Stages previously-untracked files, which moves them from New Files into Changes.
func _add_to_vcs(paths: Array) -> void:
	var result: Dictionary = _repo.stage_files(paths)
	if not result["ok"]:
		Dialogs.error(self, "Add to Git failed", result["error"])
		return
	_status_label.text = "Added %s to Git." % (paths[0].get_file() if paths.size() == 1 else "%d files" % paths.size())


## Post-order walk that counts a group/folder's files (for the "N files"
## label) and rolls up checkable folders' checked state — indeterminate if
## some but not all descendants are staged. Runs as a second pass since
## folders are created lazily while files are added.
func _aggregate_files(item: TreeItem) -> Dictionary:
	var meta: Dictionary = item.get_metadata(0)
	var kind: String = meta.get("kind", "") if not meta.is_empty() else ""
	if kind == "file":
		return { "count": 1, "staged": 1 if item.is_checked(CHECKBOX_COLUMN) else 0 }
	if kind == "untracked_file":
		return { "count": 1, "staged": 0 }

	var total := 0
	var staged := 0
	var child := item.get_first_child()
	while child:
		var r := _aggregate_files(child)
		total += r["count"]
		staged += r["staged"]
		child = child.get_next()

	if kind == "folder":
		var base_name: String = meta.get("name", "")
		item.set_text(TEXT_COLUMN, "%s  %d %s" % [base_name, total, "file" if total == 1 else "files"])
		if item.get_cell_mode(CHECKBOX_COLUMN) == TreeItem.CELL_MODE_CHECK:
			item.set_checked(CHECKBOX_COLUMN, total > 0 and staged == total)
			item.set_indeterminate(CHECKBOX_COLUMN, total > 0 and staged > 0 and staged < total)

	return { "count": total, "staged": staged }


## Collects the repo paths of every "file"-kind descendant, for cascading a
## folder/group checkbox toggle down to actual stage/unstage calls.
func _collect_file_paths(item: TreeItem, out: Array, kind := "file") -> void:
	var child := item.get_first_child()
	while child:
		var meta: Dictionary = child.get_metadata(0)
		if not meta.is_empty() and meta.get("kind", "") == kind:
			out.append(meta["path"])
		_collect_file_paths(child, out, kind)
		child = child.get_next()


func _add_file_item(group_root: TreeItem, folder_cache: Dictionary, path: String, status: int, staged: bool, tracked: bool) -> void:
	var parent := TreeFolders.get_or_create_folder(_tree, group_root, folder_cache, path.get_base_dir(), TEXT_COLUMN, CHECKBOX_COLUMN)

	var item := _tree.create_item(parent)
	# New files get a checkbox too: checking one adds it to Git (same gesture as staging).
	item.set_cell_mode(CHECKBOX_COLUMN, TreeItem.CELL_MODE_CHECK)
	item.set_editable(CHECKBOX_COLUMN, true)
	item.set_checked(CHECKBOX_COLUMN, staged)
	item.set_tooltip_text(CHECKBOX_COLUMN, "Stage/unstage" if tracked else "Add to Git")
	item.set_text(TEXT_COLUMN, "%s  %s" % [GitIcons.status_letter(status), path.get_file()])
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
	else:
		# "folder" or a group: cascade the new checked state to
		# every file underneath. emit_signal off since we stage/unstage
		# ourselves via _collect_file_paths() instead.
		item.propagate_check(CHECKBOX_COLUMN, false)
		var checked := item.is_checked(CHECKBOX_COLUMN)
		var paths: Array = []
		_collect_file_paths(item, paths)
		for path in paths:
			if checked:
				_repo.stage_file(path)
			else:
				_repo.unstage_file(path)
		# Folders/group of new files: checking adds them all in one go; unchecking has nothing to undo.
		var new_paths: Array = []
		_collect_file_paths(item, new_paths, "untracked_file")
		if checked and not new_paths.is_empty():
			_add_to_vcs(new_paths)
	refresh.call_deferred()


func _on_changes_tree_item_selected() -> void:
	_show_selected_diff()


## Diff for whichever file is selected. Tracked files with both staged and unstaged changes get Unstaged/Staged tabs.
func _show_selected_diff() -> void:
	var item := _tree.get_selected()
	if item == null:
		return
	var meta: Variant = item.get_metadata(0)
	if not meta is Dictionary or not meta.has("path"):
		_diff_view.clear_diff()
		return

	var path: String = meta["path"]
	var status: int = meta["status"]
	var options: Dictionary = _diff_view.get_options()
	if GitStatusFlags.is_untracked(status):
		_diff_view.set_tabs([])
		_diff_view.show_diff(_repo.get_diff(path, false, options), { "path": path, "note": "new file" })
		return

	var has_staged := GitStatusFlags.is_staged(status)
	var has_unstaged := GitStatusFlags.is_unstaged(status)
	var side: String = _diff_side_by_path.get(path, "unstaged" if has_unstaged else "staged")
	if side == "unstaged" and not has_unstaged:
		side = "staged"
	elif side == "staged" and not has_staged:
		side = "unstaged"

	if has_staged and has_unstaged:
		_diff_view.set_tabs(["Unstaged", "Staged"], 0 if side == "unstaged" else 1)
	else:
		_diff_view.set_tabs([])

	if side == "staged":
		_diff_view.show_diff(_repo.get_diff(path, true, options), { "path": path, "note": "staged" })
	else:
		_diff_view.show_diff(_repo.get_diff(path, false, options), { "path": path, "note": "unstaged" if has_staged else "" })


func _on_diff_tab_selected(index: int) -> void:
	var item := _tree.get_selected()
	if item == null or not item.get_metadata(0) is Dictionary:
		return
	_diff_side_by_path[item.get_metadata(0).get("path", "")] = "unstaged" if index == 0 else "staged"
	_show_selected_diff()


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
		"folder":
			var new_paths: Array = []
			_collect_file_paths(item, new_paths, "untracked_file")
			if new_paths.is_empty():
				return
			_context_target = { "kind": "folder", "name": meta.get("name", ""), "new_paths": new_paths }
			_context_menu.add_item("Add %d New File%s to Git" % [new_paths.size(), "" if new_paths.size() == 1 else "s"], ID_ADD_FOLDER_TO_VCS)
		"untracked_file":
			_context_menu.add_item("Add to Git", ID_ADD_TO_VCS)
			_context_menu.add_item("Open", ID_OPEN)
		"untracked_group":
			_context_menu.add_item("Add All to Git", ID_ADD_ALL_TO_VCS)
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
		ID_ADD_FOLDER_TO_VCS:
			_add_to_vcs(_context_target["new_paths"])
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
			_do_commit(event.shift_pressed)


func _on_diff_toggle_toggled(pressed: bool) -> void:
	_diff_view.visible = pressed
	Settings.set_value(DIFF_VISIBLE_SETTING_KEY, pressed)


func _on_amend_check_toggled(pressed: bool) -> void:
	if pressed:
		var head: Dictionary = _repo.get_head_info()
		_commit_message.text = String(head.get("message", "")).strip_edges()
	else:
		_commit_message.text = ""
	_update_commit_buttons_enabled()


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
	var can_commit: bool = has_message and (any_staged or _amend_check.button_pressed)
	_commit_button.disabled = not can_commit
	_commit_push_button.disabled = not can_commit


func _on_commit_button_pressed() -> void:
	_do_commit(false)


func _on_commit_push_button_pressed() -> void:
	_do_commit(true)


func _do_commit(push_after: bool) -> void:
	var message := _commit_message.text.strip_edges()
	if message.is_empty():
		_show_error("Commit failed", "Commit message can't be empty.")
		return

	var result: Dictionary = _repo.commit(message, _amend_check.button_pressed)
	if not result["ok"]:
		_show_error("Commit failed", result["error"])
		return

	_commit_message.text = ""
	_amend_check.button_pressed = false
	refresh()
	_status_label.text = "Committed %s" % String(result["oid"]).substr(0, 8)

	if push_after:
		_do_push()


func _do_push() -> void:
	var result: Dictionary = _repo.push()
	if not result["ok"]:
		_show_error("Push failed", result["error"])
		return
	_status_label.text = "Pushed."


func _show_error(title: String, message: String) -> void:
	_error_dialog.title = title
	_error_dialog.dialog_text = message
	_error_dialog.popup_centered()
