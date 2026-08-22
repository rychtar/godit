@tool
extends Control

const GitIcons := preload("res://addons/git_tree/util/git_icons.gd")
const TreeFolders := preload("res://addons/git_tree/util/tree_folders.gd")
const EditorOpen := preload("res://addons/git_tree/util/editor_open.gd")
const Settings := preload("res://addons/git_tree/util/settings.gd")
const Dialogs := preload("res://addons/git_tree/dock/widgets/dialogs.gd")

const DETAILS_VISIBLE_SETTING_KEY := "history_details_visible"

const DETAIL_PANE_RATIO := 1.0 / 3.0

## How many of the newest commits the log shows.
const LOG_LIMIT := 300

enum {
	ID_COPY_HASH = 1, ID_COPY_MESSAGE, ID_CREATE_BRANCH, ID_CHECKOUT_COMMIT,
}
enum { ID_FILE_OPEN = 100, ID_FILE_RESTORE_THIS, ID_FILE_RESTORE_BEFORE, ID_FILE_COPY_PATH }

@onready var _split: HSplitContainer = %Split
@onready var _graph_scroll: ScrollContainer = %GraphScroll
@onready var _graph: Control = %CommitGraph
@onready var _detail_margin: Control = %DetailMargin
@onready var _details_toggle: CheckButton = %DetailsToggle
@onready var _files_tree: Tree = %FilesTree
@onready var _detail_separator: Control = %DetailSeparator
@onready var _detail_label: RichTextLabel = %DetailLabel
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
## The commit whose files are listed in the detail pane.
var _detail_oid := ""
var _file_context_path := ""
var _file_menu: PopupMenu


func _ready() -> void:
	_split.resized.connect(_update_split_offset)
	_update_split_offset()
	_files_tree.item_activated.connect(_on_files_tree_item_activated)
	_files_tree.allow_rmb_select = true
	_files_tree.item_mouse_selected.connect(_on_files_tree_item_mouse_selected)
	_details_toggle.button_pressed = Settings.get_value(DETAILS_VISIBLE_SETTING_KEY, true)

	_file_menu = PopupMenu.new()
	_file_menu.id_pressed.connect(_on_file_menu_id_pressed)
	add_child(_file_menu)

	_graph_scroll.get_v_scroll_bar().value_changed.connect(func(_v: float) -> void: _graph.queue_redraw())


## split_offset is a pixel offset from the container's midpoint, not a
## fraction, so it's recomputed on every resize to keep the detail pane at
## a constant ~1/3 width.
func _update_split_offset() -> void:
	var total := _split.size.x
	if total <= 0.0:
		return
	_split.split_offset = int(total * (0.5 - DETAIL_PANE_RATIO))


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
	# Keep the detail pane if its commit is still listed (refresh after an unrelated change).
	if not _commits_by_oid.has(_detail_oid):
		_detail_oid = ""
		_files_tree.clear()
		_detail_label.text = ""
		_detail_separator.visible = false


func _on_refresh_button_pressed() -> void:
	refresh()


func _on_details_toggle_toggled(pressed: bool) -> void:
	_detail_margin.visible = pressed
	Settings.set_value(DETAILS_VISIBLE_SETTING_KEY, pressed)


func _on_commit_graph_commit_selected(oid: String) -> void:
	if not _commits_by_oid.has(oid):
		return
	var c: Dictionary = _commits_by_oid[oid]
	var same_commit := oid == _detail_oid
	_detail_oid = oid

	if not same_commit:
		_build_files_tree(oid)
	_detail_separator.visible = true

	var when := Time.get_datetime_string_from_unix_time(int(c["time"]), true)
	var summary_line := "[b]%s[/b]" % _escape(String(c["summary"]).strip_edges())
	var byline := "%s %s [color=#8cbff2]<%s>[/color] on %s" % [
		String(c["oid"]).substr(0, 8), _escape(c["author_name"]), _escape(c["author_email"]), when,
	]

	var refs: PackedStringArray = c["refs"]
	var tags: PackedStringArray = c.get("tags", PackedStringArray())
	var badges: Array = []
	for r in refs:
		badges.append("[bgcolor=#3a3a3f] %s [/bgcolor]" % r)
	for t in tags:
		badges.append("[bgcolor=#3a3a3f] tag: %s [/bgcolor]" % t)
	var badges_line := ("\n" + "  ".join(badges)) if not badges.is_empty() else ""

	var branches: PackedStringArray = _repo.branches_containing(oid)
	var branches_line := ""
	if not branches.is_empty():
		branches_line = "\n\nIn %d branch%s: %s" % [
			branches.size(), "" if branches.size() == 1 else "es", ", ".join(Array(branches)),
		]

	var parents: PackedStringArray = c["parents"]
	var parents_line := ""
	if parents.size() > 1:
		parents_line = "\nMerge of " + " + ".join(Array(parents).map(func(p: String) -> String: return p.substr(0, 8)))

	# message is the full raw commit message (subject + body) — drop the
	# subject line since it's already shown above as the heading.
	var message_lines := String(c["message"]).strip_edges().split("\n")
	var body := "\n".join(Array(message_lines.slice(1))).strip_edges() if message_lines.size() > 1 else ""
	var body_line := ("\n\n" + _escape(body)) if not body.is_empty() else ""

	_detail_label.text = "%s\n\n%s%s%s%s%s" % [summary_line, byline, parents_line, badges_line, body_line, branches_line]


static func _escape(text: String) -> String:
	return text.replace("[", "[lb]")


func _build_files_tree(oid: String) -> void:
	_files_tree.clear()
	var root := _files_tree.create_item()
	var folder_cache: Dictionary = {}

	var files: Array = _repo.get_commit_files(oid)
	for f in files:
		var path: String = f["path"]
		var status: int = f["status"]

		var parent := TreeFolders.get_or_create_folder(_files_tree, root, folder_cache, path.get_base_dir())
		var item := _files_tree.create_item(parent)
		item.set_text(0, "%s  %s" % [GitIcons.delta_letter(status), path.get_file()])
		item.set_custom_color(0, GitIcons.delta_color(status))
		item.set_metadata(0, { "path": path, "status": status })
		item.set_tooltip_text(0, "%s\nDouble-click to open, right-click for more" % path)

	if files.is_empty():
		var empty_item := _files_tree.create_item(root)
		empty_item.set_text(0, "(no file changes)")
		empty_item.set_selectable(0, false)


func _on_files_tree_item_activated() -> void:
	var item := _files_tree.get_selected()
	if item == null:
		return
	var meta: Variant = item.get_metadata(0)
	if not meta is Dictionary or not meta.has("path"):
		return
	EditorOpen.open_file(_repo.get_repo_root(), meta["path"])


func _on_files_tree_item_mouse_selected(mouse_position: Vector2, mouse_button_index: int) -> void:
	if mouse_button_index != MOUSE_BUTTON_RIGHT:
		return
	var item := _files_tree.get_item_at_position(mouse_position)
	if item == null or not item.get_metadata(0) is Dictionary or not item.get_metadata(0).has("path"):
		return
	_file_context_path = item.get_metadata(0)["path"]
	_file_menu.clear()
	_file_menu.add_item("Open", ID_FILE_OPEN)
	_file_menu.add_item("Copy Path", ID_FILE_COPY_PATH)
	_file_menu.add_separator()
	_file_menu.add_item("Restore File to This Commit's Version…", ID_FILE_RESTORE_THIS)
	_file_menu.add_item("Restore File to Before This Commit…", ID_FILE_RESTORE_BEFORE)
	_file_menu.set_item_disabled(_file_menu.get_item_index(ID_FILE_RESTORE_BEFORE), not _repo.has_parent(_detail_oid))
	_file_menu.position = _files_tree.get_screen_position() + mouse_position.round()
	_file_menu.reset_size()
	_file_menu.popup()


func _on_file_menu_id_pressed(id: int) -> void:
	var path := _file_context_path
	match id:
		ID_FILE_OPEN:
			EditorOpen.open_file(_repo.get_repo_root(), path)
		ID_FILE_COPY_PATH:
			DisplayServer.clipboard_set(path)
		ID_FILE_RESTORE_THIS, ID_FILE_RESTORE_BEFORE:
			var rev := _detail_oid if id == ID_FILE_RESTORE_THIS else _detail_oid + "^"
			var label := "as of %s" % _detail_oid.substr(0, 7) if id == ID_FILE_RESTORE_THIS else "as it was before %s" % _detail_oid.substr(0, 7)
			if await Dialogs.confirm(self, "Restore File",
					"Replace \"%s\" in your working tree with its version %s?\n\nThe result shows up as an uncommitted change; your current edits to the file are lost." % [path, label], "Restore"):
				var result: Dictionary = _repo.restore_file_from(rev, path)
				if not result["ok"]:
					await Dialogs.error(self, "Restore failed", result["error"])
				EditorOpen.refresh_external_change(_repo.get_repo_root(), path)


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
