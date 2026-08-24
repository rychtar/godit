@tool
extends Control

const GitIcons := preload("res://addons/git_tree/util/git_icons.gd")
const TreeFolders := preload("res://addons/git_tree/util/tree_folders.gd")
const EditorOpen := preload("res://addons/git_tree/util/editor_open.gd")
const Settings := preload("res://addons/git_tree/util/settings.gd")
const Dialogs := preload("res://addons/git_tree/dock/widgets/dialogs.gd")
const DiffViewScript := preload("res://addons/git_tree/dock/widgets/diff_view.gd")
const ChangesetDialog := preload("res://addons/git_tree/dock/widgets/changeset_dialog.gd")

const DETAILS_VISIBLE_SETTING_KEY := "history_details_visible"
const SHOW_REMOTES_SETTING_KEY := "history_show_remotes"
const SEARCH_LIMIT := 500

const DETAIL_PANE_RATIO := 1.0 / 3.0

## Commits loaded at first, and added each time the list is scrolled to its end.
const PAGE_SIZE := 300

enum {
	ID_COPY_HASH = 1, ID_COPY_MESSAGE, ID_CREATE_BRANCH, ID_CHECKOUT_COMMIT,
	ID_COMPARE_WORKTREE, ID_COMPARE_SELECTED, ID_SHOW_CHANGES,
}
enum { ID_FILE_OPEN = 100, ID_FILE_HISTORY, ID_FILE_RESTORE_THIS, ID_FILE_RESTORE_BEFORE, ID_FILE_COPY_PATH }

@onready var _search_edit: LineEdit = %SearchEdit
var _search_mode: OptionButton
## Whole-history matches after Enter in the search box, or null while only the loaded commits are filtered.
var _search_results: Variant = null
@onready var _split: HSplitContainer = %Split
@onready var _graph_split: VSplitContainer = %GraphSplit
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
var _limit := PAGE_SIZE

## The commit the context menu was last opened for, for the dialogs'
## confirmed handlers (same pattern as changes_panel.gd's _context_target).
var _context_oid := ""
## Every commit the context menu acts on (multi-selection), newest first.
var _context_oids := PackedStringArray()
## The commit whose files are listed in the detail pane.
var _detail_oid := ""
var _file_context_path := ""

var _branch_option: OptionButton
var _remotes_check: CheckBox
var _path_chip: HBoxContainer
var _path_label: Label
var _path_filter := ""
var _count_label: Label

var _file_diff_box: VBoxContainer
var _file_diff_label: Label
var _file_diff_view: Control
var _file_menu: PopupMenu


func _ready() -> void:
	_split.resized.connect(_update_split_offset)
	_update_split_offset()
	_files_tree.item_activated.connect(_on_files_tree_item_activated)
	_files_tree.item_selected.connect(_on_files_tree_item_selected)
	_files_tree.allow_rmb_select = true
	_files_tree.item_mouse_selected.connect(_on_files_tree_item_mouse_selected)
	_details_toggle.button_pressed = Settings.get_value(DETAILS_VISIBLE_SETTING_KEY, true)
	_build_toolbar()
	_build_file_diff()

	_file_menu = PopupMenu.new()
	_file_menu.id_pressed.connect(_on_file_menu_id_pressed)
	add_child(_file_menu)

	var v_bar := _graph_scroll.get_v_scroll_bar()
	v_bar.value_changed.connect(func(value: float) -> void:
		_graph.queue_redraw()
		# Scrolled to the end of a full page: there's probably more history, fetch the next page.
		if value + v_bar.page >= v_bar.max_value - 4.0 and _all_commits.size() >= _limit and _search_edit.text.is_empty():
			_limit += PAGE_SIZE
			refresh.call_deferred()
	)


func _build_toolbar() -> void:
	var toolbar: HBoxContainer = $Layout/Toolbar

	_branch_option = OptionButton.new()
	_branch_option.tooltip_text = "Which branches to show"
	_branch_option.fit_to_longest_item = false
	_branch_option.custom_minimum_size.x = 150
	_branch_option.clip_text = true
	_branch_option.item_selected.connect(func(_i: int) -> void: refresh())
	toolbar.add_child(_branch_option)
	toolbar.move_child(_branch_option, 1)

	_remotes_check = CheckBox.new()
	_remotes_check.text = "Remotes"
	_remotes_check.tooltip_text = "Also show commits that are only on remote-tracking branches (e.g. fetched but not pulled)"
	_remotes_check.button_pressed = Settings.get_value(SHOW_REMOTES_SETTING_KEY, true)
	_remotes_check.toggled.connect(func(on: bool) -> void:
		Settings.set_value(SHOW_REMOTES_SETTING_KEY, on)
		refresh()
	)
	toolbar.add_child(_remotes_check)
	toolbar.move_child(_remotes_check, 2)

	_path_chip = HBoxContainer.new()
	_path_chip.visible = false
	_path_label = Label.new()
	_path_label.modulate = Color(0.95, 0.85, 0.55)
	_path_label.clip_text = true
	_path_label.custom_minimum_size.x = 60
	_path_label.size_flags_horizontal = SIZE_SHRINK_BEGIN
	_path_chip.add_child(_path_label)
	var clear := Button.new()
	clear.text = "✕"
	clear.flat = true
	clear.tooltip_text = "Show all files again"
	clear.pressed.connect(func() -> void: set_path_filter(""))
	_path_chip.add_child(clear)
	toolbar.add_child(_path_chip)
	toolbar.move_child(_path_chip, 3)

	_search_mode = OptionButton.new()
	_search_mode.add_item("Message", 0)
	_search_mode.add_item("Author", 1)
	_search_mode.add_item("Code", 2)
	_search_mode.tooltip_text = "What the search box matches. Typing filters the loaded commits; Enter searches the whole history (Code: commits that added or removed the text)."
	_search_mode.item_selected.connect(func(_i: int) -> void:
		_update_search_placeholder()
		_on_search_edit_text_changed(_search_edit.text)
	)
	toolbar.add_child(_search_mode)
	toolbar.move_child(_search_mode, _search_edit.get_index() + 1)
	_search_edit.text_submitted.connect(func(_t: String) -> void: _run_full_search())
	_update_search_placeholder()

	_count_label = Label.new()
	_count_label.modulate.a = 0.6
	toolbar.add_child(_count_label)
	toolbar.move_child(_count_label, toolbar.get_child_count() - 2)


func _build_file_diff() -> void:
	_file_diff_box = VBoxContainer.new()
	_file_diff_box.visible = false
	_file_diff_box.custom_minimum_size.y = 120
	_file_diff_box.size_flags_vertical = SIZE_EXPAND_FILL # shares the height with the graph instead of a thin strip
	var header := HBoxContainer.new()
	_file_diff_label = Label.new()
	_file_diff_label.size_flags_horizontal = SIZE_EXPAND_FILL
	_file_diff_label.clip_text = true
	_file_diff_label.modulate.a = 0.75
	header.add_child(_file_diff_label)
	var close := Button.new()
	close.text = "✕"
	close.flat = true
	close.tooltip_text = "Close the file diff"
	close.pressed.connect(func() -> void:
		_file_diff_box.visible = false
		_files_tree.deselect_all()
	)
	header.add_child(close)
	_file_diff_box.add_child(header)

	_file_diff_view = DiffViewScript.new()
	_file_diff_view.options_changed.connect(_on_files_tree_item_selected)
	_file_diff_view.open_location_requested.connect(func(path: String, line: int) -> void:
		EditorOpen.open_file_at_line(_repo.get_repo_root(), path, line)
	)
	_file_diff_box.add_child(_file_diff_view)
	_graph_split.add_child(_file_diff_box)


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
	_update_branch_option()
	refresh()


## Limits the log to commits touching path ("" = no filter) — the Changes panel's "Show History".
func set_path_filter(path: String) -> void:
	_path_filter = path
	_path_chip.visible = not path.is_empty()
	_path_label.text = "File: " + path.get_file()
	_path_label.tooltip_text = path
	_limit = PAGE_SIZE
	refresh()


func _log_options() -> Dictionary:
	var ref := ""
	if _branch_option.selected > 0:
		ref = _branch_option.get_item_text(_branch_option.selected)
	return { "remotes": _remotes_check.button_pressed, "ref": ref, "path": _path_filter }


func _update_branch_option() -> void:
	var current := _branch_option.get_item_text(_branch_option.selected) if _branch_option.selected >= 0 else ""
	_branch_option.clear()
	_branch_option.add_item("All branches")
	for b in _repo.list_branches(false):
		_branch_option.add_item(b["name"])
		if b["name"] == current:
			_branch_option.select(_branch_option.item_count - 1)
	if _branch_option.selected < 0:
		_branch_option.select(0)


func refresh() -> void:
	if _repo == null:
		return

	_all_commits = _repo.get_commit_graph(_limit, _log_options())
	_commits_by_oid.clear()
	for c in _all_commits + (_search_results if _search_results != null else []):
		_commits_by_oid[c["oid"]] = c
	if _search_results == null:
		_count_label.text = "%d%s commits" % [_all_commits.size(), "+" if _all_commits.size() >= _limit else ""]

	_apply_filter()
	# Keep the detail pane if its commit is still listed (refresh after an unrelated change).
	if not _commits_by_oid.has(_detail_oid):
		_detail_oid = ""
		_files_tree.clear()
		_detail_label.text = ""
		_detail_separator.visible = false
		_file_diff_box.visible = false


func _on_refresh_button_pressed() -> void:
	_update_branch_option()
	refresh()


func _on_search_edit_text_changed(_new_text: String) -> void:
	_search_results = null
	_repo.cancel_search()
	_apply_filter()


func _search_mode_key() -> String:
	return ["message", "author", "code"][_search_mode.selected]


func _update_search_placeholder() -> void:
	_search_edit.placeholder_text = {
		"message": "Search message or hash (Enter: whole history)",
		"author": "Search author (Enter: whole history)",
		"code": "Text added/removed by a commit, then Enter",
	}[_search_mode_key()]


func _run_full_search() -> void:
	var query := _search_edit.text.strip_edges()
	if query.is_empty() or _repo == null:
		return
	_count_label.text = "searching…"
	var results: Variant = await _repo.search_commits(query, _search_mode_key(), SEARCH_LIMIT, _log_options())
	if results == null or _search_edit.text.strip_edges() != query:
		return # superseded by further typing or another search
	_search_results = results
	for c in results:
		_commits_by_oid[c["oid"]] = c
	_count_label.text = "%d%s matches" % [results.size(), "+" if results.size() >= SEARCH_LIMIT else ""]
	_apply_filter()


func _on_details_toggle_toggled(pressed: bool) -> void:
	_detail_margin.visible = pressed
	Settings.set_value(DETAILS_VISIBLE_SETTING_KEY, pressed)


## Whole-history search results if there are any, else a case-insensitive filter of the loaded commits by the search mode.
func _apply_filter() -> void:
	var query := _search_edit.text.strip_edges().to_lower()
	var head: String = _repo.get_head_oid()
	if _search_results != null:
		_graph.set_commits(_search_results, head)
		return
	# Code search needs git (Enter); there's nothing to match locally.
	if query.is_empty() or _search_mode_key() == "code":
		_graph.set_commits(_all_commits, head)
		return

	var by_author := _search_mode_key() == "author"
	var filtered: Array = []
	for c in _all_commits:
		var hit := (String(c["author_name"]).to_lower().contains(query) or String(c["author_email"]).to_lower().contains(query)) if by_author \
				else (String(c["oid"]).to_lower().begins_with(query) or String(c["summary"]).to_lower().contains(query) or String(c["message"]).to_lower().contains(query))
		if hit:
			filtered.append(c)
	_graph.set_commits(filtered, head)


func _on_commit_graph_commit_selected(oid: String) -> void:
	if not _commits_by_oid.has(oid):
		return
	var c: Dictionary = _commits_by_oid[oid]
	var same_commit := oid == _detail_oid
	_detail_oid = oid

	if not same_commit:
		_build_files_tree(oid)
		_file_diff_box.visible = false
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
		item.set_tooltip_text(0, "%s\nClick for its diff, double-click to open, right-click for more" % path)
		if not _path_filter.is_empty() and path == _path_filter:
			item.select(0)

	if files.is_empty():
		var empty_item := _files_tree.create_item(root)
		empty_item.set_text(0, "(no file changes)")
		empty_item.set_selectable(0, false)


func _on_files_tree_item_selected() -> void:
	var item := _files_tree.get_selected()
	if item == null or _detail_oid.is_empty():
		return
	var meta: Variant = item.get_metadata(0)
	if not meta is Dictionary or not meta.has("path"):
		return
	var path: String = meta["path"]
	_file_diff_label.text = "%s  @ %s" % [path, _detail_oid.substr(0, 8)]
	_file_diff_box.visible = true
	_file_diff_view.show_diff(_repo.get_commit_file_diff(_detail_oid, path, _file_diff_view.get_options()), { "path": path })


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
	_file_menu.add_item("Show History of This File", ID_FILE_HISTORY)
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
		ID_FILE_HISTORY:
			set_path_filter(path)
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
		m.add_item("Show Changes…", ID_SHOW_CHANGES)
		m.add_item("Compare with Working Tree…", ID_COMPARE_WORKTREE)
	if _context_oids.size() == 2:
		m.add_item("Compare the Two Selected Commits…", ID_COMPARE_SELECTED)
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
		ID_SHOW_CHANGES:
			_open_changeset("%s  %s" % [_context_oid.substr(0, 8), _summary(_context_oid)],
					_repo.parent_or_empty_tree(_context_oid), _context_oid)
		ID_COMPARE_WORKTREE:
			_open_changeset("%s ↔ working tree" % _context_oid.substr(0, 8), _context_oid, "")
		ID_COMPARE_SELECTED:
			# Older one as the base, so additions read as additions.
			_open_changeset("%s ↔ %s" % [_context_oids[1].substr(0, 8), _context_oids[0].substr(0, 8)], _context_oids[1], _context_oids[0])
		ID_CREATE_BRANCH:
			_new_branch_name_edit.text = ""
			_new_branch_checkout_check.button_pressed = false
			_new_branch_dialog.popup_centered()
			_new_branch_name_edit.grab_focus()
		ID_CHECKOUT_COMMIT:
			_checkout_confirm_dialog.dialog_text = "Checkout commit %s?\nThis leaves HEAD detached (not on a branch)." % _context_oid.substr(0, 7)
			_checkout_confirm_dialog.popup_centered()


func _summary(oid: String) -> String:
	return String(_commits_by_oid.get(oid, {}).get("summary", ""))


func _open_changeset(title: String, base: String, target: String) -> void:
	var dialog := ChangesetDialog.new()
	add_child(dialog)
	dialog.open(_repo, title, base, target)


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
	_update_branch_option()
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
