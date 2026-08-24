@tool
extends Control

const EditorOpen := preload("res://addons/git_tree/util/editor_open.gd")
const TreeFolders := preload("res://addons/git_tree/util/tree_folders.gd")
const Dialogs := preload("res://addons/git_tree/dock/widgets/dialogs.gd")

enum {
	ID_CHECKOUT, ID_NEW_BRANCH_FROM, ID_RENAME, ID_DELETE, ID_COPY_NAME, ID_COMPARE,
}

## Opens the changeset dialog, wired up by git_tree_dock.gd: (title, base_ref, target_ref). target "" means the working tree.
signal compare_requested(title: String, base: String, target: String)

@onready var _tree: Tree = %BranchesTree
@onready var _filter_edit: LineEdit = %FilterEdit
@onready var _context_menu: PopupMenu = %ContextMenu

## Set by git_tree_dock.gd; a git_cli_repo.gd instance.
var _repo: RefCounted
## Below this width the tree drops to a single column (side-dock mode).
const WIDE_MIN_WIDTH := 520.0
var _wide := true

## {"kind": "local"|"remote_branch"|"remote"|"section", ...} for whatever the context menu was opened on.
var _context: Dictionary = {}

## Section headers' collapsed state, kept across refreshes (keyed by section title).
var _collapsed_sections := {}


func _ready() -> void:
	_tree.resized.connect(func() -> void:
		if (_tree.size.x >= WIDE_MIN_WIDTH) != _wide and _repo != null:
			refresh()
	)

	_tree.item_collapsed.connect(func(item: TreeItem) -> void:
		var meta: Variant = item.get_metadata(0)
		if meta is Dictionary and meta.get("kind", "") == "section":
			_collapsed_sections[meta["title"]] = item.collapsed
	)
	_tree.empty_clicked.connect(func(pos: Vector2, button: int) -> void:
		if button == MOUSE_BUTTON_RIGHT:
			_show_context_menu({ "kind": "section", "title": "Local" }, _tree.get_screen_position() + pos)
	)


func set_repo(repo: RefCounted) -> void:
	_repo = repo
	refresh()


func refresh() -> void:
	if _repo == null:
		return

	var scroll := _tree.get_scroll()
	_tree.clear()
	_setup_columns()
	var root := _tree.create_item()
	var filter := _filter_edit.text.strip_edges().to_lower()
	var current: String = _repo.get_current_branch()

	var branches: Array = _repo.list_branches(false)
	var local_section := _section(root, "Local")
	var local_count := 0
	for b in branches:
		if b["is_remote"] or not _matches(filter, b["name"]):
			continue
		local_count += 1
		var item := _tree.create_item(local_section)
		var tracking := ""
		if not b["upstream"].is_empty():
			tracking = "%s%s" % [b["upstream"], "  (gone)" if b["gone"] else ""]
		_fill_row(item, ("● " if b["is_head"] else "") + b["name"], tracking, b)
		item.set_metadata(0, { "kind": "local", "name": b["name"], "upstream": b["upstream"], "is_head": b["is_head"] })
		item.set_tooltip_text(0, "%s — %s %s (%s)\nDouble-click to checkout, right-click for more" % [b["name"], b["oid"], b["summary"], b["date"]])
		if b["is_head"]:
			for col in _tree.columns:
				item.set_custom_color(col, get_theme_color(&"success_color", &"Editor"))
	_finish_section(local_section, local_count)

	var remote_section := _section(root, "Remote")
	var remote_folders := {}
	var remote_count := 0
	for b in branches:
		if not b["is_remote"] or not _matches(filter, b["name"]):
			continue
		var remote_name: String = b["name"].get_slice("/", 0)
		if not remote_folders.has(remote_name):
			var folder := _tree.create_item(remote_section)
			folder.set_text(0, remote_name)
			folder.set_icon(0, _icon(&"Folder"))
			folder.set_selectable(0, false)
			folder.set_metadata(0, { "kind": "remote", "name": remote_name })
			remote_folders[remote_name] = folder
		remote_count += 1
		var item := _tree.create_item(remote_folders[remote_name])
		_fill_row(item, b["name"].substr(remote_name.length() + 1), "", b)
		item.set_metadata(0, { "kind": "remote_branch", "name": b["name"], "remote": remote_name })
		item.set_tooltip_text(0, "%s — %s %s (%s)\nDouble-click to check out as a local tracking branch" % [b["name"], b["oid"], b["summary"], b["date"]])
		item.set_custom_color(0, Color(0.72, 0.78, 0.9))
	_finish_section(remote_section, remote_count)

	_restore_scroll.call_deferred(scroll)


## Branch | Tracking | Last commit when there's room (bottom panel), a single column in a narrow side dock.
func _setup_columns() -> void:
	_wide = _tree.size.x >= WIDE_MIN_WIDTH
	_tree.columns = 3 if _wide else 1
	_tree.column_titles_visible = _wide
	if not _wide:
		return
	_tree.set_column_title(0, "Name")
	_tree.set_column_title(1, "Tracking")
	_tree.set_column_title(2, "Last commit")
	for col in 3:
		_tree.set_column_title_alignment(col, HORIZONTAL_ALIGNMENT_LEFT)
		_tree.set_column_clip_content(col, true)
	_tree.set_column_expand_ratio(0, 3)
	_tree.set_column_expand_ratio(1, 3)
	_tree.set_column_expand_ratio(2, 5)


## Fills a row's columns; in single-column mode the tracking info is appended to the name instead.
func _fill_row(item: TreeItem, name: String, tracking: String, info: Dictionary) -> void:
	if not _wide:
		item.set_text(0, name + ("   → " + tracking if not tracking.is_empty() and info.has("upstream") else ""))
		return
	item.set_text(0, name)
	item.set_text(1, tracking)
	item.set_custom_color(1, Color(0.75, 0.78, 0.85))
	var commit := ""
	if not String(info.get("oid", "")).is_empty():
		commit = "%s  %s" % [info["oid"], info.get("summary", "")]
	if not String(info.get("date", "")).is_empty():
		commit += ("   · " if not commit.is_empty() else "") + info["date"]
	item.set_text(2, commit)
	item.set_custom_color(2, Color(0.62, 0.62, 0.66))
	for col in range(1, 3):
		item.set_selectable(col, item.is_selectable(0))


func _restore_scroll(scroll: Vector2) -> void:
	var bar: VScrollBar = TreeFolders.v_scroll_bar(_tree)
	if bar != null:
		bar.value = scroll.y


func _section(root: TreeItem, title: String) -> TreeItem:
	var item := _tree.create_item(root)
	item.set_metadata(0, { "kind": "section", "title": title })
	for col in _tree.columns:
		item.set_selectable(col, false)
	item.set_custom_color(0, Color(0.68, 0.85, 1.0))
	item.collapsed = _collapsed_sections.get(title, false)
	return item


func _finish_section(section: TreeItem, count: int) -> void:
	var meta: Dictionary = section.get_metadata(0)
	section.set_text(0, "%s  %d" % [meta["title"], count])


func _matches(filter: String, name: String) -> bool:
	return filter.is_empty() or name.to_lower().contains(filter)


func _icon(name: StringName) -> Texture2D:
	return get_theme_icon(name, &"EditorIcons") if has_theme_icon(name, &"EditorIcons") else null


# --- toolbar ---------------------------------------------------------------


func _on_filter_edit_text_changed(_text: String) -> void:
	refresh()


func _on_new_branch_button_pressed() -> void:
	await _new_branch_from("HEAD")


func _new_branch_from(start_point: String) -> void:
	var answer: Variant = await Dialogs.form(self, "New Branch", [
		{ "key": "name", "label": "Name", "placeholder": "feature/my-branch" },
		{ "key": "start", "label": "Start point", "default": start_point },
		{ "key": "checkout", "label": "Switch to it (uncommitted changes come along)", "type": "check", "default": true },
	], "Create")
	if answer == null or String(answer["name"]).strip_edges().is_empty():
		return
	_after(_repo.create_branch(String(answer["name"]).strip_edges(), String(answer["start"]).strip_edges(), answer["checkout"]), "Create branch failed", answer["checkout"])


# --- tree ------------------------------------------------------------------


func _on_branches_tree_item_activated() -> void:
	var item := _tree.get_selected()
	if item == null:
		return
	var meta: Variant = item.get_metadata(0)
	if not meta is Dictionary:
		return
	match meta.get("kind", ""):
		"local":
			if not meta["is_head"]:
				_checkout(meta["name"])
		"remote_branch":
			_after(_repo.checkout_remote_branch(meta["name"]), "Checkout failed", true)


func _checkout(name: String) -> void:
	_after(_repo.checkout_branch(name), "Checkout failed", true)


func _on_branches_tree_item_mouse_selected(mouse_position: Vector2, mouse_button_index: int) -> void:
	if mouse_button_index != MOUSE_BUTTON_RIGHT:
		return
	var item := _tree.get_item_at_position(mouse_position)
	if item == null:
		return
	var meta: Variant = item.get_metadata(0)
	if meta is Dictionary:
		_show_context_menu(meta, _tree.get_screen_position() + mouse_position.round())


func _show_context_menu(meta: Dictionary, screen_position: Vector2) -> void:
	_context = meta
	var m := _context_menu
	m.clear()
	var current: String = _repo.get_current_branch()
	var current_label := current if not current.is_empty() else "HEAD"

	match meta.get("kind", ""):
		"local":
			var name: String = meta["name"]
			if not meta["is_head"]:
				m.add_item("Checkout", ID_CHECKOUT)
			m.add_item("New Branch from Here…", ID_NEW_BRANCH_FROM)
			if not meta["is_head"]:
				m.add_separator()
				m.add_item("Compare with %s" % current_label, ID_COMPARE)
			m.add_separator()
			m.add_item("Rename…", ID_RENAME)
			m.add_item("Delete…", ID_DELETE)
			m.set_item_disabled(m.get_item_index(ID_DELETE), meta["is_head"])
			m.add_item("Copy Name", ID_COPY_NAME)
		"remote_branch":
			m.add_item("Checkout (as tracking branch)", ID_CHECKOUT)
			m.add_item("New Branch from Here…", ID_NEW_BRANCH_FROM)
			m.add_separator()
			m.add_item("Compare with %s" % current_label, ID_COMPARE)
			m.add_separator()
			m.add_item("Copy Name", ID_COPY_NAME)
		"section":
			if meta["title"] == "Local":
				m.add_item("New Branch…", ID_NEW_BRANCH_FROM)
			else:
				return
		_:
			return

	m.position = screen_position
	m.reset_size()
	m.popup()


func _on_context_menu_id_pressed(id: int) -> void:
	var kind: String = _context.get("kind", "")
	var name: String = _context.get("name", "")
	match id:
		ID_CHECKOUT:
			match kind:
				"local": _checkout(name)
				"remote_branch": _after(_repo.checkout_remote_branch(name), "Checkout failed", true)
		ID_NEW_BRANCH_FROM:
			await _new_branch_from(name if not name.is_empty() else "HEAD")
		ID_COMPARE:
			compare_requested.emit("%s ↔ %s" % [_current_label(), name], "HEAD", name)
		ID_RENAME:
			var new_name: Variant = await Dialogs.prompt(self, "Rename Branch", "New name for \"%s\"" % name, name, "Rename")
			if new_name != null and not new_name.is_empty() and new_name != name:
				_after(_repo.rename_branch(name, new_name), "Rename failed")
		ID_DELETE:
			await _delete_branch(name)
		ID_COPY_NAME:
			DisplayServer.clipboard_set(name)


func _current_label() -> String:
	var current: String = _repo.get_current_branch()
	return current if not current.is_empty() else "HEAD"


func _delete_branch(name: String) -> void:
	if not await Dialogs.confirm(self, "Delete Branch", "Delete local branch \"%s\"?" % name, "Delete"):
		return
	var result: Dictionary = _repo.delete_branch(name, false)
	if not result["ok"] and result["error"].contains("not fully merged"):
		if await Dialogs.confirm(self, "Branch Not Merged",
				"\"%s\" has commits that aren't merged anywhere else — deleting it loses them (they stay recoverable via reflog for a while).\n\nDelete anyway?" % name, "Force Delete"):
			result = _repo.delete_branch(name, true)
		else:
			return
	_after(result, "Delete branch failed")


## Shows result's error if it failed; reload_editor re-scans the project after anything that rewrote the working tree.
func _after(result: Dictionary, error_title: String, reload_editor: bool = false) -> void:
	if reload_editor:
		EditorOpen.refresh_all_external_changes()
	if not result["ok"]:
		Dialogs.error(self, error_title, result["error"])
	refresh()
