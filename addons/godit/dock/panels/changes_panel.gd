@tool
extends Control

const GitStatusFlags := preload("res://addons/godit/util/git_status_flags.gd")
const UiScale := preload("res://addons/godit/util/ui_scale.gd")
const PollTimer := preload("res://addons/godit/util/poll_timer.gd")
const GitIcons := preload("res://addons/godit/util/git_icons.gd")
const TreeFolders := preload("res://addons/godit/util/tree_folders.gd")
const EditorOpen := preload("res://addons/godit/util/editor_open.gd")
const ChangelistStore := preload("res://addons/godit/util/changelist_store.gd")
const Settings := preload("res://addons/godit/util/settings.gd")
const RemoteActions := preload("res://addons/godit/dock/widgets/remote_actions.gd")
const Dialogs := preload("res://addons/godit/dock/widgets/dialogs.gd")
const GitErrors := preload("res://addons/godit/util/git_errors.gd")
const ConflictResolver := preload("res://addons/godit/dock/widgets/conflict_resolver.gd")

const DIFF_VISIBLE_SETTING_KEY := "diff_preview_visible"
const SyncBar := preload("res://addons/godit/dock/widgets/sync_bar.gd")
const LIST_PANE_RATIO := 0.4

const MENU_MOVE_TO_SUBMENU := "MoveToMenu"
const ID_OPEN := 1
const ID_ADD_TO_VCS := 2
const ID_ADD_ALL_TO_VCS := 3
const ID_SET_ACTIVE := 4
const ID_RENAME := 5
const ID_DELETE := 6
const ID_NEW_CHANGELIST := 7
const ID_TOGGLE_STAGE := 8
const ID_MOVE_TO_NEW := 1000 # MoveToMenu: indices 0..N-1 are existing changelists, this is "New Changelist..."
const ID_REVERT := 9
const ID_IGNORE := 10
const ID_REMOVE := 11
const ID_ACCEPT_OURS := 12
const ID_ACCEPT_THEIRS := 13
const ID_MARK_RESOLVED := 14
const ID_REVERT_ALL := 15
const ID_SHOW_HISTORY := 16
const ID_STASH_GROUP := 17
const ID_COPY_PATH := 18
const ID_RESOLVE := 19
const ID_ADD_FOLDER_TO_VCS := 20
const ID_IGNORE_FOLDER := 21

## "Show History" on a file — godit_dock.gd forwards it to the Git Log panel.
signal file_history_requested(path: String)

const AUTO_REFRESH_INTERVAL := 3.0

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
@onready var _changelist_option: OptionButton = %ChangelistOption
@onready var _amend_check: CheckBox = %AmendCheck
@onready var _commit_message: TextEdit = %CommitMessage
@onready var _commit_button: Button = %CommitButton
@onready var _commit_push_button: Button = %CommitPushButton
@onready var _status_label: Label = %StatusLabel
@onready var _error_dialog: AcceptDialog = %ErrorDialog
@onready var _context_menu: PopupMenu = %ContextMenu
@onready var _move_to_menu: PopupMenu = %MoveToMenu
@onready var _name_dialog: ConfirmationDialog = %NameDialog
@onready var _name_edit: LineEdit = %NameEdit
@onready var _create_branch_check: CheckBox = %CreateBranchCheck
@onready var _revert_confirm_dialog: ConfirmationDialog = %RevertConfirmDialog

## Set by godit_dock.gd; a git_cli_repo.gd instance.
var _repo: RefCounted

## {"names": Array[String], "assignments": Dictionary[path, name], "active": String}.
## Pure local bookkeeping (git has no concept of changelists) — see
## util/changelist_store.gd.
var _changelist_state: Dictionary = {}

## Rebuilding the tree in refresh() re-checks/unchecks items programmatically,
## which would otherwise re-trigger item_edited and loop back into refresh().
var _suppress_item_edited := false

## What a right-click landed on, stashed for the context menu's id_pressed
## handler: {"kind": "file"|"untracked_file"|"changelist_group", "path": ...}
## or {"kind": "changelist_group", "name": ...}.
var _context_target: Dictionary = {}

## Which dialog action _name_dialog is currently being used for: "new" or "rename".
var _name_dialog_mode := ""
var _name_dialog_rename_target := ""

## Which action _revert_confirm_dialog is currently being used for: "revert" or "remove".
var _confirm_dialog_action := "revert"

## Pauses while the panel is hidden or the editor is in the background.
var _auto_refresh_timer: PollTimer
var _operation_bar: HBoxContainer

## Merge/rebase/cherry-pick/revert-in-progress strip above the toolbar (see _update_operation_banner()).
var _op_banner: PanelContainer
var _op_label: Label
var _op_continue_button: Button
var _op_skip_button: Button
## Branch switcher + Fetch/Pull/Push header (shared widget, also on the Branches tab).
var _sync_bar: VBoxContainer
## Last branch seen by refresh(), to notice checkouts made anywhere (sync bar, Branches, Git Log, terminal).
var _last_branch := ""
var _branch_seen := false

## Which diff ("unstaged"/"staged") was last viewed per path, for files that have both.
var _diff_side_by_path := {}
## Which side the diff view is showing right now ("unstaged"/"staged"), so Revert knows where the hunk lives.
var _diff_side := "unstaged"

## Signature of the last-seen `git status` (see _status_signature()) — lets
## the auto-refresh timer skip rebuilding the tree when nothing changed,
## which would otherwise reset scroll position and selection every tick.
var _last_status_signature := ""
## Changed files' mtimes at the last check: a re-saved file keeps its status, so only this reveals that its diff is stale.
var _last_content_signature := ""


func _ready() -> void:
	if UiScale.is_in_edited_scene(self):
		return # opened in the scene editor, not running in a dock
	UiScale.scale_scene(self)
	_tree.columns = 2
	_tree.set_column_expand(CHECKBOX_COLUMN, false)
	_tree.set_column_custom_minimum_width(CHECKBOX_COLUMN, CHECKBOX_COLUMN_WIDTH)
	_tree.set_column_expand(TEXT_COLUMN, true)
	# Without this, a right-click doesn't register as hitting an item, so
	# item_mouse_selected never fires and the context menu can't open.
	_tree.allow_rmb_select = true

	_diff_toggle.button_pressed = Settings.get_value(DIFF_VISIBLE_SETTING_KEY, true)

	_sync_bar = SyncBar.new()
	$Layout.add_child(_sync_bar)
	$Layout.move_child(_sync_bar, 0)
	_sync_bar.changed.connect(refresh)
	_operation_bar = _sync_bar.operation_bar
	_build_operation_banner()

	var stash_button := Button.new()
	stash_button.text = "Stash…"
	stash_button.flat = true
	stash_button.tooltip_text = "Stash uncommitted changes (put them aside and clean the working tree)"
	stash_button.pressed.connect(_on_stash_button_pressed)
	%DeleteChangelistButton.add_sibling(stash_button)

	# Changelists + commit box take ~40% of the width, the diff the rest; re-applied on resize since split_offset is in pixels from the middle.
	%Split.resized.connect(func() -> void: %Split.split_offset = int(%Split.size.x * (LIST_PANE_RATIO - 0.5)))

	_diff_view.hunk_action_requested.connect(_on_hunk_action_requested)
	_diff_view.options_changed.connect(_show_selected_diff)
	_diff_view.tab_selected.connect(_on_diff_tab_selected)
	_diff_view.open_location_requested.connect(func(path: String, line: int) -> void:
		var error := EditorOpen.open_file_at_line(_repo.get_repo_root(), path, line)
		if not error.is_empty():
			Dialogs.error(self, "Can't open file", error)
	)
	_commit_message.gui_input.connect(_on_commit_message_gui_input)
	_commit_message.tooltip_text = "Ctrl/Cmd+Enter to commit, Ctrl/Cmd+Shift+Enter to commit and push"

	_auto_refresh_timer = PollTimer.new(AUTO_REFRESH_INTERVAL)
	_auto_refresh_timer.poll.connect(_maybe_refresh)
	add_child(_auto_refresh_timer)


func set_repo(repo: RefCounted) -> void:
	_repo = repo
	_sync_bar.set_repo(repo)
	_changelist_state = ChangelistStore.load_state(_repo.get_repo_root())
	_sync_staging_to_active_changelist()
	refresh()
	if _auto_refresh_timer != null:
		_auto_refresh_timer.active = true


## Re-fetches status and only calls refresh() — which rebuilds the tree from
## scratch — if something actually changed since the last check.
func _maybe_refresh() -> void:
	if _repo == null:
		return
	if _repo.is_busy():
		return # a pull/push is rewriting things right now — catch up once it's done
	var entries: Array = _repo.get_status()
	if _status_signature(entries) != _last_status_signature:
		refresh(entries)
		return
	var content := _content_signature(entries)
	if content != _last_content_signature:
		_last_content_signature = content
		_show_selected_diff()


func _content_signature(entries: Array) -> String:
	var root: String = _repo.get_repo_root()
	var parts: Array = []
	for entry in entries:
		var abs_path := root.path_join(entry["path"])
		parts.append(FileAccess.get_modified_time(abs_path) if FileAccess.file_exists(abs_path) else 0)
	return ",".join(parts)


func _status_signature(entries: Array) -> String:
	# Branch, ahead/behind (status header) and HEAD too, so the sync bar updates after a commit/push/fetch even when no file changed.
	var parts: Array = [_repo.get_operation_state()["kind"], _repo.status_header, _repo.read_head_oid()]
	for entry in entries:
		parts.append("%s:%d" % [entry["path"], entry["status"]])
	return "|".join(parts)


## status_entries lets callers that already fetched `git status` (e.g.
## _maybe_refresh()) pass it along instead of fetching it twice.
func refresh(status_entries: Variant = null) -> void:
	if _repo == null:
		return
	var entries: Array = status_entries if status_entries != null else _repo.get_status()
	_last_status_signature = _status_signature(entries)
	_last_content_signature = _content_signature(entries)
	_follow_branch_switch()

	var selected_path := ""
	var selected_item := _tree.get_selected()
	if selected_item != null and selected_item.get_metadata(0) is Dictionary:
		selected_path = selected_item.get_metadata(0).get("path", "")
	var scroll_y := _tree.get_scroll().y
	var op := _update_operation_banner()
	_sync_bar.refresh()

	_suppress_item_edited = true
	_tree.clear()
	var root := _tree.create_item()

	var conflict_group := _tree.create_item(root)
	conflict_group.set_selectable(TEXT_COLUMN, false)
	conflict_group.set_selectable(CHECKBOX_COLUMN, false)
	conflict_group.set_metadata(0, { "kind": "conflict_group" })
	conflict_group.set_custom_color(TEXT_COLUMN, GitIcons.COLOR_DELETED)
	var conflict_folders: Dictionary = {}
	var conflict_count := 0

	var changelist_groups: Dictionary = {} # name -> TreeItem
	var changelist_folders: Dictionary = {} # name -> {dir_path: TreeItem}
	for name in _changelist_state["names"]:
		var group := _tree.create_item(root)
		group.set_selectable(CHECKBOX_COLUMN, false)
		group.set_selectable(TEXT_COLUMN, false)
		group.set_metadata(0, { "kind": "changelist_group", "name": name })
		# Checkable like a folder — toggling the group header cascades to
		# every file under it (see _aggregate_files() and
		# _on_changes_tree_item_edited()).
		group.set_cell_mode(CHECKBOX_COLUMN, TreeItem.CELL_MODE_CHECK)
		group.set_editable(CHECKBOX_COLUMN, true)
		changelist_groups[name] = group
		changelist_folders[name] = {}

	# Blank spacer row so "New Files" reads as separate from the
	# real changelists above it.
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
	_prune_assignments(entries)
	var current_branch: String = _repo.get_current_branch()

	for entry in entries:
		var path: String = entry["path"]
		var status: int = entry["status"]
		if status & GitStatusFlags.CONFLICTED:
			conflict_count += 1
			_add_conflict_item(conflict_group, conflict_folders, path)
			continue
		var staged := GitStatusFlags.is_staged(status)
		any_staged = any_staged or staged

		# A file assigned to a changelist stays shown there even if it's
		# currently untracked — unstaging a brand-new file makes git see
		# it as untracked again, but it shouldn't vanish into New Files.
		var assignments: Dictionary = _changelist_state["assignments"]
		var is_new: bool = GitStatusFlags.is_untracked(status) and not assignments.has(path)
		if is_new:
			_add_file_item(untracked_group, untracked_folders, path, status, staged, false)
		else:
			var list_name := _changelist_for_path(path)
			_add_file_item(changelist_groups[list_name], changelist_folders[list_name], path, status, staged, true)

	var tracked_count := 0
	var counts := {}
	for name in _changelist_state["names"]:
		var is_active: bool = name == _changelist_state["active"]
		var group: TreeItem = changelist_groups[name]
		var agg := _aggregate_files(group)
		var count: int = agg["count"]
		tracked_count += count
		counts[name] = count
		group.set_text(TEXT_COLUMN, "%s %s%s  %d %s" % ["●" if is_active else "○", name, "  ⎇" if name == current_branch else "", count, "file" if count == 1 else "files"])
		group.set_custom_color(TEXT_COLUMN, Color(0.68, 0.85, 1.0) if is_active else Color(0.75, 0.75, 0.78))
		group.set_checked(CHECKBOX_COLUMN, count > 0 and agg["staged"] == count)
		group.set_indeterminate(CHECKBOX_COLUMN, count > 0 and agg["staged"] > 0 and agg["staged"] < count)
		group.collapsed = count == 0
		# Hide empty inactive changelists (still reachable via "Move to
		# Changelist"); keep the active one visible even when empty.
		group.set_visible(count > 0 or is_active)

	conflict_group.set_text(TEXT_COLUMN, "⚠ Conflicts  %d %s — resolve, then Continue" % [conflict_count, "file" if conflict_count == 1 else "files"])
	conflict_group.set_visible(conflict_count > 0)

	var untracked_agg := _aggregate_files(untracked_group)
	var untracked_count: int = untracked_agg["count"]
	untracked_group.set_text(TEXT_COLUMN, "New Files  %d — not in Git yet, check to add to \"%s\"" % [untracked_count, _changelist_state["active"]])
	untracked_group.collapsed = untracked_count == 0
	untracked_group.set_visible(untracked_count > 0)
	spacer.set_visible(untracked_count > 0)
	_suppress_item_edited = false

	_update_changelist_option(counts)
	_reselect(root, selected_path, scroll_y)
	if op["kind"] == "merge" and _commit_message.text.strip_edges().is_empty() and not op["detail"].is_empty():
		_commit_message.text = _repo.get_merge_message()

	if untracked_count == 0 and tracked_count == 0:
		_status_label.text = "No changes."
	else:
		_status_label.text = ""

	_update_commit_buttons_enabled(any_staged)


## Re-selects the file that was selected before the tree was rebuilt (so auto-refresh and hunk actions don't lose your place), or clears the diff if it's gone.
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


## Selects path's row (showing its unstaged diff when it has one) and scrolls the diff to line.
func reveal(path: String, line: int) -> void:
	refresh()
	var item := _find_item_by_path(_tree.get_root(), path)
	if item == null:
		return
	_diff_side_by_path[path] = "unstaged"
	var parent := item.get_parent()
	while parent != null:
		parent.collapsed = false
		parent = parent.get_parent()
	item.select(TEXT_COLUMN)
	_tree.scroll_to_item(item)
	_diff_view.scroll_to_line.call_deferred(line)


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


func _add_conflict_item(group: TreeItem, folder_cache: Dictionary, path: String) -> void:
	var parent := TreeFolders.get_or_create_folder(_tree, group, folder_cache, path.get_base_dir(), TEXT_COLUMN)
	var item := _tree.create_item(parent)
	item.set_selectable(CHECKBOX_COLUMN, false)
	item.set_text(TEXT_COLUMN, "!  %s" % path.get_file())
	item.set_custom_color(TEXT_COLUMN, GitIcons.COLOR_DELETED)
	item.set_metadata(0, { "kind": "conflict_file", "path": path, "staged": false, "status": GitStatusFlags.CONFLICTED })
	item.set_tooltip_text(TEXT_COLUMN, "%s — conflicted\nDouble-click to resolve side by side. Right-click: Accept Ours / Theirs, or Mark Resolved after editing it yourself." % path)


func _build_operation_banner() -> void:
	_op_banner = PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.85, 0.55, 0.2, 0.18)
	style.border_color = Color(0.95, 0.65, 0.25, 0.6)
	style.border_width_left = 3
	style.content_margin_left = 8
	style.content_margin_right = 4
	style.content_margin_top = 3
	style.content_margin_bottom = 3
	_op_banner.add_theme_stylebox_override("panel", style)
	_op_banner.visible = false

	var row := HBoxContainer.new()
	_op_label = Label.new()
	_op_label.size_flags_horizontal = SIZE_EXPAND_FILL
	_op_label.clip_text = true
	_op_label.mouse_filter = Control.MOUSE_FILTER_PASS
	row.add_child(_op_label)

	_op_continue_button = Button.new()
	_op_continue_button.text = "Continue"
	_op_continue_button.pressed.connect(_on_op_continue_pressed)
	row.add_child(_op_continue_button)

	_op_skip_button = Button.new()
	_op_skip_button.text = "Skip"
	_op_skip_button.tooltip_text = "Drop the commit being applied and move on to the next one"
	_op_skip_button.pressed.connect(_on_op_skip_pressed)
	row.add_child(_op_skip_button)

	var abort := Button.new()
	abort.text = "Abort"
	abort.tooltip_text = "Undo the whole operation and go back to how things were before it started"
	abort.pressed.connect(_on_op_abort_pressed)
	row.add_child(abort)

	_op_banner.add_child(row)
	$Layout.add_child(_op_banner)
	$Layout.move_child(_op_banner, 1)


## Shows/hides the in-progress banner; returns the operation state it used.
func _update_operation_banner() -> Dictionary:
	var op: Dictionary = _repo.get_operation_state()
	var kind: String = op["kind"]
	_op_banner.visible = not kind.is_empty()
	if kind.is_empty():
		return op
	var verb: String = { "merge": "Merging", "rebase": "Rebasing", "cherry-pick": "Cherry-picking", "revert": "Reverting" }.get(kind, kind)
	var conflicts: int = op["conflicts"]
	var detail: String = op["detail"]
	_op_label.text = "%s%s — %s" % [verb, " " + detail if not detail.is_empty() else "", "%d conflict%s left" % [conflicts, "" if conflicts == 1 else "s"] if conflicts > 0 else "no conflicts left"]
	_op_label.tooltip_text = _op_label.text
	_op_continue_button.disabled = conflicts > 0
	_op_continue_button.tooltip_text = "Resolve every conflict first" if conflicts > 0 else "Commit the resolution and carry on"
	_op_skip_button.visible = kind != "merge"
	return op


func _on_op_continue_pressed() -> void:
	var result: Dictionary = _repo.continue_operation()
	await _after_operation_step(result, "Continue")


func _on_op_skip_pressed() -> void:
	if await Dialogs.confirm(self, "Skip Commit", "Drop the commit currently being applied (its changes are discarded) and continue with the next one?", "Skip"):
		await _after_operation_step(_repo.skip_operation(), "Skip")


func _on_op_abort_pressed() -> void:
	if await Dialogs.confirm(self, "Abort", "Abort the %s and return to the state before it started?\nAny conflict resolutions made so far are lost." % _repo.get_operation_state()["kind"], "Abort"):
		await _after_operation_step(_repo.abort_operation(), "Abort")


func _after_operation_step(result: Dictionary, title: String) -> void:
	EditorOpen.refresh_all_external_changes()
	if result.get("conflicts", false):
		_operation_bar.done("Stopped on the next conflicts — resolve them, then Continue.", true)
	elif not result["ok"]:
		var error: String = result["error"]
		if error.contains("nothing to commit") or error.contains("is now empty"):
			error += "\n\nThe commit being applied ended up empty — use Skip to drop it."
		await Dialogs.error(self, "%s failed" % title, GitErrors.explain(error))
	else:
		_operation_bar.done("%s done." % title)
		_commit_message.text = ""
	refresh()


func _changelist_for_path(path: String) -> String:
	var name: String = _changelist_state["assignments"].get(path, ChangelistStore.DEFAULT_NAME)
	return name if _changelist_state["names"].has(name) else ChangelistStore.DEFAULT_NAME


## Forgets assignments of files that are no longer changed (committed, reverted, stashed — a stash remembers them itself), so a file edited again later starts in the active changelist instead of a stale one.
func _prune_assignments(entries: Array) -> void:
	var present := {}
	for entry in entries:
		present[entry["path"]] = true
	var assignments: Dictionary = _changelist_state["assignments"]
	var stale := assignments.keys().filter(func(path: String) -> bool: return not present.has(path))
	for path in stale:
		assignments.erase(path)
	if not stale.is_empty():
		_save_changelist_state()


## A changelist named like the branch just checked out becomes active — changelists double as per-branch work buckets.
func _follow_branch_switch() -> void:
	var branch: String = _repo.get_current_branch()
	if branch == _last_branch:
		return
	var first_time := _last_branch.is_empty() and not _branch_seen
	_last_branch = branch
	_branch_seen = true
	if not first_time and _changelist_state["names"].has(branch) and _changelist_state["active"] != branch:
		_set_active_changelist(branch)
		_operation_bar.done("Switched to branch %s — its changelist is now active." % branch)


func _save_changelist_state() -> void:
	ChangelistStore.save_state(_repo.get_repo_root(), _changelist_state)


## Appends path to the repo's top-level .gitignore, creating it if needed; no-op if already listed.
func _ignore_path(path: String) -> void:
	var gitignore_path: String = _repo.get_repo_root().path_join(".gitignore")
	var existing := ""
	if FileAccess.file_exists(gitignore_path):
		var read_file := FileAccess.open(gitignore_path, FileAccess.READ)
		existing = read_file.get_as_text()
		read_file.close()
	if Array(existing.split("\n")).has(path):
		return

	var new_content := existing
	if not new_content.is_empty() and not new_content.ends_with("\n"):
		new_content += "\n"
	new_content += path + "\n"

	var write_file := FileAccess.open(gitignore_path, FileAccess.WRITE)
	write_file.store_string(new_content)
	write_file.close()
	refresh()


## Stages a previously-untracked file and assigns it to the active
## changelist. Right-click-only, deliberate action — also what keeps the
## file under its changelist instead of bouncing back to New Files
## if it's later unstaged (see refresh()'s is_new check).
func _add_to_vcs(paths: Array) -> void:
	var result: Dictionary = _repo.stage_files(paths)
	if not result["ok"]:
		Dialogs.error(self, "Add to Git failed", result["error"])
		return
	for path in paths:
		_changelist_state["assignments"][path] = _changelist_state["active"]
	_save_changelist_state()
	_operation_bar.done("Added %s to \"%s\"." % [paths[0].get_file() if paths.size() == 1 else "%d files" % paths.size(), _changelist_state["active"]])


## Stages files in the active changelist, unstages tracked files outside
## it. Called whenever the active changelist changes, so Commit defaults
## to exactly that group unless the user hand-adjusts checkboxes after.
func _sync_staging_to_active_changelist() -> void:
	if _repo == null:
		return
	var active: String = _changelist_state["active"]
	for entry in _repo.get_status():
		var path: String = entry["path"]
		var status: int = entry["status"]
		# Staging a conflicted file would silently mark it resolved.
		if GitStatusFlags.is_untracked(status) or status & GitStatusFlags.CONFLICTED:
			continue
		var belongs := _changelist_for_path(path) == active
		var staged := GitStatusFlags.is_staged(status)
		if belongs and not staged:
			_repo.stage_file(path)
		elif not belongs and staged:
			_repo.unstage_file(path)


func _update_changelist_option(counts: Dictionary = {}) -> void:
	_changelist_option.clear()
	var names: Array = _changelist_state["names"]
	for i in names.size():
		var count: int = counts.get(names[i], 0)
		_changelist_option.add_item("Changelist: %s%s" % [names[i], "  (%d)" % count if count > 0 else ""])
		if names[i] == _changelist_state["active"]:
			_changelist_option.select(i)


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


func _add_file_item(group_root: TreeItem, folder_cache: Dictionary, path: String, status: int, staged: bool, in_changelist: bool) -> void:
	var parent := TreeFolders.get_or_create_folder(_tree, group_root, folder_cache, path.get_base_dir(), TEXT_COLUMN, CHECKBOX_COLUMN)

	var item := _tree.create_item(parent)
	# New files get a checkbox too: checking one adds it to Git in the active changelist (same gesture as staging).
	item.set_cell_mode(CHECKBOX_COLUMN, TreeItem.CELL_MODE_CHECK)
	item.set_editable(CHECKBOX_COLUMN, true)
	item.set_checked(CHECKBOX_COLUMN, staged)
	item.set_tooltip_text(CHECKBOX_COLUMN, "Stage/unstage" if in_changelist else "Add to Git")
	item.set_text(TEXT_COLUMN, "%s  %s" % [GitIcons.status_letter(status), path.get_file()])
	item.set_custom_color(TEXT_COLUMN, GitIcons.status_color(status))
	var meta := { "kind": "file" if in_changelist else "untracked_file", "path": path, "status": status, "staged": staged }
	item.set_metadata(0, meta)
	var hint := "Check to stage, uncheck to unstage. Double-click to open." if in_changelist else "Check to add to Git. Right-click to ignore. Double-click to open."
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
		# "folder" or "changelist_group": cascade the new checked state to
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


## Diff for whichever file is selected. Tracked files with both staged and unstaged changes get Unstaged/Staged tabs; hunk buttons follow the side shown.
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
	if meta["kind"] == "conflict_file":
		_diff_view.set_tabs([])
		_diff_view.show_diff(_repo.get_conflict_diff(path), { "path": path, "note": "conflict markers vs. ours" })
		return
	if GitStatusFlags.is_untracked(status):
		_diff_view.set_tabs([])
		_diff_view.show_diff(_repo.get_diff(path, false, options), { "path": path, "repo": _repo, "old_rev": ":", "new_rev": "", "note": "new file" })
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

	_diff_side = side
	if side == "staged":
		_diff_view.show_diff(_repo.get_diff(path, true, options), {
			"path": path, "repo": _repo, "old_rev": "HEAD", "new_rev": ":", "actions": ["unstage", "revert"], "note": "staged",
		})
	else:
		_diff_view.show_diff(_repo.get_diff(path, false, options), {
			"path": path, "repo": _repo, "old_rev": ":", "new_rev": "", "actions": ["stage", "revert"],
			"note": "unstaged" if has_staged else "",
		})


func _on_diff_tab_selected(index: int) -> void:
	var item := _tree.get_selected()
	if item == null or not item.get_metadata(0) is Dictionary:
		return
	_diff_side_by_path[item.get_metadata(0).get("path", "")] = "unstaged" if index == 0 else "staged"
	_show_selected_diff()


func _on_hunk_action_requested(action: String, patch: String) -> void:
	var item := _tree.get_selected()
	var path: String = item.get_metadata(0).get("path", "") if item != null and item.get_metadata(0) is Dictionary else ""
	var result: Dictionary
	match action:
		"stage":
			result = _repo.apply_patch(patch, true, false)
		"unstage":
			result = _repo.apply_patch(patch, true, true)
		"revert":
			if not await Dialogs.confirm(self, "Revert Changes", "Discard these changes from the working tree? This can't be undone.", "Revert"):
				return
			# A staged hunk is also in the working tree: discard it from both.
			result = _repo.discard_staged_patch(patch) if _diff_side == "staged" else _repo.apply_patch(patch, false, true)
			EditorOpen.refresh_external_change(_repo.get_repo_root(), path)
	if not result["ok"]:
		await Dialogs.error(self, "Couldn't %s" % action, result["error"])
	refresh()


func _on_changes_tree_item_activated() -> void:
	var item := _tree.get_selected()
	if item == null:
		return
	var meta: Dictionary = item.get_metadata(0)
	if meta.is_empty() or not meta.has("path"):
		return

	if meta.get("kind", "") == "conflict_file" and _repo.has_conflict_markers(meta["path"]):
		_open_conflict_resolver(meta["path"])
		return
	var error := EditorOpen.open_file(_repo.get_repo_root(), meta["path"])
	if not error.is_empty():
		_show_error("Can't open file", error)


func _open_conflict_resolver(path: String) -> void:
	var resolver := ConflictResolver.new()
	add_child(resolver)
	resolver.saved.connect(func(_p: String, _marked: bool) -> void: refresh())
	if not resolver.open(_repo, path):
		resolver.queue_free()
		Dialogs.error(self, "Nothing to resolve", "\"%s\" has no conflict markers — use Accept Ours / Theirs or Mark Resolved instead." % path)


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
	_move_to_menu.clear()

	match meta.get("kind", ""):
		"file":
			_context_menu.add_item("Open", ID_OPEN)
			_context_menu.add_item("Stage" if not meta["staged"] else "Unstage", ID_TOGGLE_STAGE)
			_context_menu.add_submenu_item("Move to Changelist", MENU_MOVE_TO_SUBMENU)
			var names: Array = _changelist_state["names"]
			for i in names.size():
				_move_to_menu.add_item(names[i], i)
				_move_to_menu.set_item_disabled(i, names[i] == _changelist_for_path(meta["path"]))
			_move_to_menu.add_separator()
			_move_to_menu.add_item("New Changelist...", ID_MOVE_TO_NEW)
			_context_menu.add_separator()
			_context_menu.add_item("Show History", ID_SHOW_HISTORY)
			_context_menu.add_item("Copy Path", ID_COPY_PATH)
			_context_menu.add_separator()
			_context_menu.add_item("Revert...", ID_REVERT)
			_context_menu.add_item("Remove...", ID_REMOVE)
		"folder":
			var folder_paths: Array = []
			_collect_file_paths(item, folder_paths)
			var new_paths: Array = []
			_collect_file_paths(item, new_paths, "untracked_file")
			if folder_paths.is_empty() and new_paths.is_empty():
				return
			var any_path: String = (folder_paths + new_paths)[0]
			var depth := 0
			var up := item.get_parent()
			while up != null and up.get_metadata(0) is Dictionary and up.get_metadata(0).get("kind", "") == "folder":
				depth += 1
				up = up.get_parent()
			# Repo-relative dir of this folder row: the first depth+1 segments of any file under it.
			var dir := "/".join(any_path.split("/").slice(0, depth + 1))
			_context_target = { "kind": "folder", "name": meta.get("name", ""), "paths": folder_paths, "new_paths": new_paths, "dir": dir }
			if not new_paths.is_empty():
				_context_menu.add_item("Add %d New File%s to Git" % [new_paths.size(), "" if new_paths.size() == 1 else "s"], ID_ADD_FOLDER_TO_VCS)
				_context_menu.add_item("Ignore Folder (%s/)" % dir, ID_IGNORE_FOLDER)
			if not folder_paths.is_empty():
				if not new_paths.is_empty():
					_context_menu.add_separator()
				_context_menu.add_item("Revert %d File%s..." % [folder_paths.size(), "" if folder_paths.size() == 1 else "s"], ID_REVERT_ALL)
				_context_menu.add_item("Stash %d File%s..." % [folder_paths.size(), "" if folder_paths.size() == 1 else "s"], ID_STASH_GROUP)
		"untracked_file":
			_context_menu.add_item("Add to Git", ID_ADD_TO_VCS)
			_context_menu.add_item("Open", ID_OPEN)
			_context_menu.add_separator()
			_context_menu.add_item("Ignore", ID_IGNORE)
			_context_menu.add_item("Revert...", ID_REVERT)
		"conflict_file":
			var op_kind: String = _repo.get_operation_state()["kind"]
			var ours := "upstream / branch being rebased onto" if op_kind == "rebase" else "current branch"
			var theirs := "your commit being replayed" if op_kind == "rebase" else ("incoming branch" if op_kind == "merge" else "commit being applied")
			_context_menu.add_item("Resolve Conflicts…", ID_RESOLVE)
			_context_menu.set_item_disabled(_context_menu.get_item_index(ID_RESOLVE), not _repo.has_conflict_markers(meta["path"]))
			_context_menu.add_item("Open", ID_OPEN)
			_context_menu.add_separator()
			_context_menu.add_item("Accept Ours (%s)" % ours, ID_ACCEPT_OURS)
			_context_menu.add_item("Accept Theirs (%s)" % theirs, ID_ACCEPT_THEIRS)
			_context_menu.add_item("Mark Resolved (as edited)", ID_MARK_RESOLVED)
			_context_menu.add_separator()
			_context_menu.add_item("Copy Path", ID_COPY_PATH)
		"untracked_group":
			_context_menu.add_item("Add All to Git", ID_ADD_ALL_TO_VCS)
		"changelist_group":
			var group_paths: Array = []
			_collect_file_paths(item, group_paths)
			_context_target = meta.duplicate()
			_context_target["paths"] = group_paths
			_context_menu.add_item("Set Active", ID_SET_ACTIVE)
			if meta["name"] != ChangelistStore.DEFAULT_NAME:
				_context_menu.add_item("Rename...", ID_RENAME)
				_context_menu.add_item("Delete", ID_DELETE)
			if not group_paths.is_empty():
				_context_menu.add_separator()
				_context_menu.add_item("Shelve (Stash) This Changelist...", ID_STASH_GROUP)
				_context_menu.add_item("Revert All %d File%s..." % [group_paths.size(), "" if group_paths.size() == 1 else "s"], ID_REVERT_ALL)
			_context_menu.add_separator()
			_context_menu.add_item("New Changelist...", ID_NEW_CHANGELIST)
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
				if GitStatusFlags.is_untracked(entry["status"]) and not _changelist_state["assignments"].has(entry["path"]):
					new_paths.append(entry["path"])
			_add_to_vcs(new_paths)
			refresh.call_deferred()
		ID_ADD_FOLDER_TO_VCS:
			_add_to_vcs(_context_target["new_paths"])
			refresh.call_deferred()
		ID_IGNORE_FOLDER:
			_ignore_path(_context_target["dir"] + "/")
		ID_SET_ACTIVE:
			_set_active_changelist(_context_target["name"])
		ID_RENAME:
			_name_dialog_mode = "rename"
			_name_dialog_rename_target = _context_target["name"]
			_name_edit.text = _context_target["name"]
			_create_branch_check.visible = false
			_name_dialog.title = "Rename Changelist"
			_name_dialog.popup_centered()
			_name_edit.grab_focus()
		ID_DELETE:
			_delete_changelist(_context_target["name"])
		ID_NEW_CHANGELIST:
			_open_new_changelist_dialog()
		ID_TOGGLE_STAGE:
			var path: String = _context_target["path"]
			if _context_target["staged"]:
				_repo.unstage_file(path)
			else:
				_repo.stage_file(path)
			refresh.call_deferred()
		ID_REVERT:
			var path: String = _context_target["path"]
			_confirm_dialog_action = "revert"
			_revert_confirm_dialog.title = "Revert"
			_revert_confirm_dialog.ok_button_text = "Revert"
			_revert_confirm_dialog.dialog_text = "Discard all changes to \"%s\"? This can't be undone." % path.get_file()
			_revert_confirm_dialog.popup_centered()
		ID_REMOVE:
			var path: String = _context_target["path"]
			_confirm_dialog_action = "remove"
			_revert_confirm_dialog.title = "Remove File"
			_revert_confirm_dialog.ok_button_text = "Remove"
			_revert_confirm_dialog.dialog_text = "Remove \"%s\" from Git and delete it from disk? This can't be undone." % path.get_file()
			_revert_confirm_dialog.popup_centered()
		ID_IGNORE:
			_ignore_path(_context_target["path"])
		ID_COPY_PATH:
			DisplayServer.clipboard_set(_context_target["path"])
		ID_RESOLVE:
			_open_conflict_resolver(_context_target["path"])
		ID_SHOW_HISTORY:
			file_history_requested.emit(_context_target["path"])
		ID_ACCEPT_OURS, ID_ACCEPT_THEIRS:
			var path: String = _context_target["path"]
			var result: Dictionary = _repo.resolve_conflict(path, "ours" if id == ID_ACCEPT_OURS else "theirs")
			if not result["ok"]:
				Dialogs.error(self, "Resolve failed", result["error"])
			EditorOpen.refresh_external_change(_repo.get_repo_root(), path)
			refresh()
		ID_MARK_RESOLVED:
			var path: String = _context_target["path"]
			if _repo.has_conflict_markers(path) and not await Dialogs.confirm(self, "Conflict Markers Left",
					"\"%s\" still contains <<<<<<< / >>>>>>> markers. Mark it resolved anyway?" % path, "Mark Resolved"):
				return
			var result: Dictionary = _repo.mark_resolved(path)
			if not result["ok"]:
				Dialogs.error(self, "Resolve failed", result["error"])
			refresh()
		ID_REVERT_ALL:
			var paths: Array = _context_target["paths"]
			if await Dialogs.confirm(self, "Revert Files", "Discard all changes to these %d files? This can't be undone.\n\n%s" % [paths.size(), _path_list(paths)], "Revert All"):
				var errors: Array = []
				for path in paths:
					var result: Dictionary = _repo.revert_file(path)
					if not result["ok"]:
						errors.append("%s: %s" % [path, result["error"]])
					_changelist_state["assignments"].erase(path)
				_save_changelist_state()
				EditorOpen.refresh_all_external_changes()
				if not errors.is_empty():
					Dialogs.error(self, "Some files couldn't be reverted", "\n".join(errors))
				refresh()
		ID_STASH_GROUP:
			var group_name: String = _context_target.get("name", "")
			await _stash_dialog(PackedStringArray(_context_target["paths"]), group_name)


## Reverts or removes the file, per _confirm_dialog_action (set by whichever menu item opened this dialog).
func _on_revert_confirm_dialog_confirmed() -> void:
	var path: String = _context_target["path"]
	var result: Dictionary = _repo.remove_file(path) if _confirm_dialog_action == "remove" else _repo.revert_file(path)
	if not result["ok"]:
		_show_error("Remove failed" if _confirm_dialog_action == "remove" else "Revert failed", result["error"])
		return
	_changelist_state["assignments"].erase(path)
	_save_changelist_state()
	EditorOpen.refresh_external_change(_repo.get_repo_root(), path)
	refresh()


static func _path_list(paths: Array) -> String:
	var shown := paths.slice(0, 12)
	var text := "\n".join(shown)
	if paths.size() > shown.size():
		text += "\n… and %d more" % (paths.size() - shown.size())
	return text


func _on_stash_button_pressed() -> void:
	await _stash_dialog(PackedStringArray(), "")


## paths empty = stash everything.
func _stash_dialog(paths: PackedStringArray, suggested_message: String) -> void:
	var fields: Array = [
		{ "key": "message", "label": "Message", "default": suggested_message, "placeholder": "WIP: what these changes are" },
		{ "key": "untracked", "label": "Include untracked (new) files", "type": "check", "default": paths.is_empty() },
	]
	if paths.is_empty():
		fields.append({ "key": "keep_index", "label": "Keep staged changes in the working tree too", "type": "check", "default": false })
	else:
		fields.push_front({ "type": "label", "label": "Stash %d file%s:\n%s" % [paths.size(), "" if paths.size() == 1 else "s", _path_list(Array(paths))] })
	var answer: Variant = await Dialogs.form(self, "Stash Changes", fields, "Stash")
	if answer == null:
		return
	var result: Dictionary = _repo.stash_push(String(answer["message"]).strip_edges(), answer["untracked"], paths, answer.get("keep_index", false))
	EditorOpen.refresh_all_external_changes()
	if not result["ok"]:
		await Dialogs.error(self, "Stash failed", result["error"])
	elif result["output"].contains("No local changes"):
		_operation_bar.done("Nothing to stash.")
	else:
		_operation_bar.done("Stashed. Restore it from Branches → Stashes.")
	refresh()


func _on_commit_message_gui_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode in [KEY_ENTER, KEY_KP_ENTER] \
			and (event.ctrl_pressed or event.meta_pressed):
		_commit_message.accept_event()
		if not _commit_button.disabled:
			_do_commit(event.shift_pressed)


func _on_move_to_menu_id_pressed(id: int) -> void:
	if id == ID_MOVE_TO_NEW:
		_open_new_changelist_dialog(true)
		return

	var names: Array = _changelist_state["names"]
	if id >= 0 and id < names.size():
		_move_file_to_changelist(_context_target["path"], names[id])


func _on_new_changelist_button_pressed() -> void:
	_open_new_changelist_dialog()


func _on_delete_changelist_button_pressed() -> void:
	var active: String = _changelist_state["active"]
	if active == ChangelistStore.DEFAULT_NAME:
		_show_error("Can't delete Default", "The Default changelist always exists and can't be deleted.")
		return
	_delete_changelist(active)


func _on_diff_toggle_toggled(pressed: bool) -> void:
	_diff_view.visible = pressed
	Settings.set_value(DIFF_VISIBLE_SETTING_KEY, pressed)


func _open_new_changelist_dialog(and_move_selected_file: bool = false) -> void:
	_name_dialog_mode = "new_and_move" if and_move_selected_file else "new"
	_name_edit.text = ""
	_create_branch_check.visible = true
	_create_branch_check.button_pressed = false
	_name_dialog.title = "New Changelist"
	_name_dialog.popup_centered()
	_name_edit.grab_focus()


func _on_name_dialog_confirmed() -> void:
	var name := _name_edit.text.strip_edges()
	if name.is_empty():
		_show_error("Invalid name", "Changelist name can't be empty.")
		return

	match _name_dialog_mode:
		"new":
			_create_changelist(name)
			_maybe_create_branch(name)
		"new_and_move":
			_create_changelist(name)
			_move_file_to_changelist(_context_target["path"], name)
			_maybe_create_branch(name)
		"rename":
			_rename_changelist(_name_dialog_rename_target, name)


func _maybe_create_branch(name: String) -> void:
	if not _create_branch_check.visible or not _create_branch_check.button_pressed:
		return
	# Switching right away (changes come along) is the point: the changelist and its branch start together.
	var result: Dictionary = _repo.create_branch(name, "HEAD", true)
	if not result["ok"]:
		_show_error("Couldn't create branch", result["error"])
		return
	_last_branch = name
	_operation_bar.done("Created and switched to branch %s." % name)
	refresh.call_deferred()


## A freshly created changelist becomes the active one — you create one
## because you're about to start working in it, so this also updates the
## dropdown and re-syncs staging to match (see _set_active_changelist()).
func _create_changelist(name: String) -> void:
	var names: Array = _changelist_state["names"]
	if names.has(name):
		_show_error("Changelist exists", "There's already a changelist named \"%s\"." % name)
		return
	names.append(name)
	_set_active_changelist(name)


func _rename_changelist(old_name: String, new_name: String) -> void:
	var names: Array = _changelist_state["names"]
	if old_name == ChangelistStore.DEFAULT_NAME:
		return
	if new_name != old_name and names.has(new_name):
		_show_error("Changelist exists", "There's already a changelist named \"%s\"." % new_name)
		return

	var idx := names.find(old_name)
	if idx != -1:
		names[idx] = new_name

	var assignments: Dictionary = _changelist_state["assignments"]
	for path in assignments.keys():
		if assignments[path] == old_name:
			assignments[path] = new_name

	if _changelist_state["active"] == old_name:
		_changelist_state["active"] = new_name

	_save_changelist_state()
	refresh.call_deferred()


func _delete_changelist(name: String) -> void:
	if name == ChangelistStore.DEFAULT_NAME:
		return

	var assignments: Dictionary = _changelist_state["assignments"]
	for path in assignments.keys():
		if assignments[path] == name:
			assignments.erase(path) # falls back to Default, see _changelist_for_path()

	_changelist_state["names"].erase(name)
	if _changelist_state["active"] == name:
		_set_active_changelist(ChangelistStore.DEFAULT_NAME)
		return # _set_active_changelist() already saves + refreshes

	_save_changelist_state()
	refresh.call_deferred()


func _set_active_changelist(name: String) -> void:
	_changelist_state["active"] = name
	_sync_staging_to_active_changelist()
	_save_changelist_state()
	refresh.call_deferred()


## Doesn't call _sync_staging_to_active_changelist(): moving a file between
## changelists shouldn't silently flip its staged checkbox. Only switching
## the active changelist resets staging to match it.
func _move_file_to_changelist(path: String, name: String) -> void:
	_changelist_state["assignments"][path] = name
	_save_changelist_state()
	refresh.call_deferred()


func _on_changelist_option_item_selected(index: int) -> void:
	var names: Array = _changelist_state["names"]
	if index >= 0 and index < names.size():
		_set_active_changelist(names[index])


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
	await RemoteActions.push(self, _repo, _operation_bar)
	refresh()


func _show_error(title: String, message: String) -> void:
	_error_dialog.title = title
	_error_dialog.dialog_text = message
	_error_dialog.popup_centered()
