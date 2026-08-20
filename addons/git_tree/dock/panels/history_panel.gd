@tool
extends Control

const EditorOpen := preload("res://addons/git_tree/util/editor_open.gd")

## How many of the newest commits the log shows.
const LOG_LIMIT := 300

enum {
	ID_COPY_HASH = 1, ID_COPY_MESSAGE, ID_CREATE_BRANCH, ID_CHECKOUT_COMMIT,
}

@onready var _graph_scroll: ScrollContainer = %GraphScroll
@onready var _graph: Control = %CommitGraph
@onready var _context_menu: PopupMenu = %ContextMenu
@onready var _error_dialog: AcceptDialog = %ErrorDialog
@onready var _checkout_confirm_dialog: ConfirmationDialog = %CheckoutConfirmDialog
@onready var _new_branch_dialog: ConfirmationDialog = %NewBranchDialog
@onready var _new_branch_name_edit: LineEdit = %NewBranchNameEdit
@onready var _new_branch_checkout_check: CheckBox = %NewBranchCheckoutCheck

## Set by git_tree_dock.gd; a git_cli_repo.gd instance.
var _repo: RefCounted
var _all_commits: Array = []
var _commits_by_oid: Dictionary = {}

## The commit the context menu was last opened for, for the dialogs'
## confirmed handlers (same pattern as changes_panel.gd's _context_target).
var _context_oid := ""
## Every commit the context menu acts on (multi-selection), newest first.
var _context_oids := PackedStringArray()


func _ready() -> void:
	_graph_scroll.get_v_scroll_bar().value_changed.connect(func(_v: float) -> void: _graph.queue_redraw())


func set_repo(repo: RefCounted) -> void:
	_repo = repo
	refresh()


func refresh() -> void:
	if _repo == null:
		return

	_all_commits = _repo.get_commit_graph(LOG_LIMIT)
	_commits_by_oid.clear()
	for c in _all_commits:
		_commits_by_oid[c["oid"]] = c
	_graph.set_commits(_all_commits, _repo.get_head_oid())


func _on_refresh_button_pressed() -> void:
	refresh()


func _on_commit_graph_commit_context_requested(oid: String, screen_position: Vector2) -> void:
	_context_oid = oid
	_context_oids = _graph.get_selected_oids()
	if not _context_oids.has(oid):
		_context_oids = PackedStringArray([oid])
	var many := _context_oids.size() > 1

	var m := _context_menu
	m.clear()
	m.add_item("Copy Commit Hash%s" % ("es" if many else ""), ID_COPY_HASH)
	m.add_item("Copy Commit Message", ID_COPY_MESSAGE)
	m.add_separator()
	if not many:
		m.add_item("Create Branch from Here...", ID_CREATE_BRANCH)
		m.add_item("Checkout This Commit...", ID_CHECKOUT_COMMIT)

	m.position = screen_position
	m.reset_size()
	m.popup()


func _on_context_menu_id_pressed(id: int) -> void:
	match id:
		ID_COPY_HASH:
			DisplayServer.clipboard_set("\n".join(_context_oids) if _context_oids.size() > 1 else _context_oid)
		ID_COPY_MESSAGE:
			if _commits_by_oid.has(_context_oid):
				var c: Dictionary = _commits_by_oid[_context_oid]
				DisplayServer.clipboard_set(String(c["message"]).strip_edges())
		ID_CREATE_BRANCH:
			_new_branch_name_edit.text = ""
			_new_branch_checkout_check.button_pressed = false
			_new_branch_dialog.popup_centered()
			_new_branch_name_edit.grab_focus()
		ID_CHECKOUT_COMMIT:
			_checkout_confirm_dialog.dialog_text = "Checkout commit %s?\nThis leaves HEAD detached (not on a branch)." % _context_oid.substr(0, 7)
			_checkout_confirm_dialog.popup_centered()


func _on_new_branch_dialog_confirmed() -> void:
	var name := _new_branch_name_edit.text.strip_edges()
	if name.is_empty():
		_show_error("Invalid name", "Branch name can't be empty.")
		return
	var result: Dictionary = _repo.create_branch(name, _context_oid, _new_branch_checkout_check.button_pressed)
	if not result["ok"]:
		_show_error("Couldn't create branch", result["error"])
		return
	if _new_branch_checkout_check.button_pressed:
		EditorOpen.refresh_all_external_changes()
	refresh()


func _on_checkout_confirm_dialog_confirmed() -> void:
	var result: Dictionary = _repo.checkout_commit(_context_oid)
	if not result["ok"]:
		_show_error("Checkout failed", result["error"])
		return
	EditorOpen.refresh_all_external_changes()
	refresh()


func _show_error(title: String, message: String) -> void:
	_error_dialog.title = title
	_error_dialog.dialog_text = message
	_error_dialog.popup_centered()
