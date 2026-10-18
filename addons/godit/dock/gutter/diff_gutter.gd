## Changed-line flags in the script editor's gutter, next to Bookmarks, computed from the editor's (possibly unsaved) text against HEAD. Clicking a flag opens an inline preview of the old lines (change_preview.gd); its "Show in Changes" button emits change_clicked, which plugin.gd routes to the Changes panel.
extends Node

signal change_clicked(rel_path: String, line: int)
## A text file tab (.md, .json...) got its flags; plugin.gd hands it to script_menu.gd, whose menu items those tabs don't ask for.
signal text_tab_refreshed(editor: Control, code_edit: CodeEdit)

const GitCliRepo := preload("res://addons/godit/util/git_cli_repo.gd")
const DiffHunks := preload("res://addons/godit/util/diff_hunks.gd")
const GitIcons := preload("res://addons/godit/util/git_icons.gd")
const ChangePreview := preload("res://addons/godit/dock/gutter/change_preview.gd")
const PollTimer := preload("res://addons/godit/util/poll_timer.gd")
const EditorOpen := preload("res://addons/godit/util/editor_open.gd")
const DiffViewScript := preload("res://addons/godit/dock/widgets/diff_view.gd")
const GutterPainter := preload("res://addons/godit/dock/gutter/gutter_painter.gd")

const GUTTER_NAME := "godit_diff"
const GUTTER_WIDTH := 14
const REFRESH_INTERVAL := 2.0
## Pause after typing before the flags and changed characters are recomputed.
const EDIT_DELAY := 0.3

const META_FLAGS := GutterPainter.META_FLAGS
## DiffHunks.parse_regions() of HEAD -> the editor's text.
const META_REGIONS := "godit_diff_regions"
const META_REL_PATH := "godit_rel_path"
const META_RES_PATH := "godit_res_path"
## Path, text hash and HEAD the flags were computed from, so unchanged tabs skip git.
const META_SIGNATURE := "godit_diff_signature"
const META_INLINE := GutterPainter.META_INLINE
const META_INLINE_RECTS := GutterPainter.META_INLINE_RECTS
const META_INLINE_VIEW := GutterPainter.META_INLINE_VIEW
## [background_color, "normal" stylebox override or null] from before _move_background().
const META_BACKGROUND := "godit_original_background"

var _script_editor: ScriptEditor
var _refresh_timer: PollTimer
## [CodeEdit, gutter_clicked Callable, text_changed Callable, draw Callable], so disable() can disconnect them (the CodeEdits outlive a plugin reload).
var _connections: Array = []
var _preview: Control
var _edit_timer: Timer
## CodeEdits edited since the last _edit_timer timeout.
var _edited: Array[CodeEdit] = []


func enable(_plugin: EditorPlugin) -> void:
	_script_editor = EditorInterface.get_script_editor()

	_refresh_timer = PollTimer.new(REFRESH_INTERVAL)
	_refresh_timer.poll.connect(_refresh_current)
	add_child(_refresh_timer)
	_refresh_timer.active = true

	_edit_timer = Timer.new()
	_edit_timer.one_shot = true
	_edit_timer.wait_time = EDIT_DELAY
	_edit_timer.timeout.connect(_refresh_edited)
	add_child(_edit_timer)


func disable() -> void:
	close_preview()
	if _refresh_timer:
		_refresh_timer.queue_free()
	for connection in _connections:
		var code_edit: CodeEdit = connection[0]
		if not is_instance_valid(code_edit):
			continue
		if code_edit.gutter_clicked.is_connected(connection[1]):
			code_edit.gutter_clicked.disconnect(connection[1])
		if code_edit.text_changed.is_connected(connection[2]):
			code_edit.text_changed.disconnect(connection[2])
		if code_edit.draw.is_connected(connection[3]):
			code_edit.draw.disconnect(connection[3])
		for meta in [META_SIGNATURE, META_INLINE, META_INLINE_RECTS, META_INLINE_VIEW]:
			code_edit.remove_meta(meta)
		_restore_background(code_edit)
		code_edit.queue_redraw()
	_connections.clear()
	_edited.clear()


## The script editor's current CodeEdit, or null.
func current_code_edit() -> CodeEdit:
	if _script_editor == null:
		return null
	var editor_base := _script_editor.get_current_editor()
	return editor_base.get_base_editor() as CodeEdit if editor_base != null else null


func _refresh_current() -> void:
	if _script_editor == null:
		return
	var code_edit := current_code_edit()
	var res_path := EditorOpen.current_tab_path()
	if code_edit == null or not res_path.begins_with("res://"):
		return
	refresh_code_edit(code_edit, res_path)
	var editor := _script_editor.get_current_editor()
	if editor.get_class() == "TextEditor" and code_edit.has_meta(META_REL_PATH):
		text_tab_refreshed.emit(editor, code_edit)


## Opened repos by directory, so the 2 s poll doesn't spawn `git rev-parse` for every tick.
static var _repos := {}


## {"repo": GitCliRepo, "rel_path": String} for res_path, or {} if it's not inside a git repo. Shared with blame_gutter.gd.
static func resolve_repo(res_path: String) -> Dictionary:
	var abs_path := ProjectSettings.globalize_path(res_path)
	var dir := abs_path.get_base_dir()
	var repo: RefCounted = _repos.get(dir)
	if repo == null:
		repo = GitCliRepo.new()
		if not repo.open(dir):
			return {}
		_repos[dir] = repo
	var repo_root: String = repo.get_repo_root()
	if not abs_path.begins_with(repo_root):
		return {}
	return { "repo": repo, "rel_path": abs_path.substr(repo_root.length() + 1) }


## Recomputes code_edit's flags unless its text and HEAD are unchanged since last time (force skips that check).
func refresh_code_edit(code_edit: CodeEdit, res_path: String, force := false) -> void:
	var resolved := resolve_repo(res_path)
	if resolved.is_empty():
		return
	var repo: RefCounted = resolved["repo"]
	var text := _normalized(code_edit.text)
	var signature := "%s|%d|%s" % [resolved["rel_path"], text.hash(), repo.read_head_oid()]
	_install_gutter(code_edit)
	code_edit.set_meta(META_REL_PATH, resolved["rel_path"])
	code_edit.set_meta(META_RES_PATH, res_path)
	if not force and code_edit.get_meta(META_SIGNATURE, "") == signature:
		return
	code_edit.set_meta(META_SIGNATURE, signature)

	var head_text: Variant = repo.get_head_text(resolved["rel_path"])
	var regions: Array = [] if head_text == null else DiffHunks.parse_regions(repo.diff_texts(_normalized(head_text), text))
	code_edit.set_meta(META_REGIONS, regions)
	code_edit.set_meta(META_FLAGS, _flags_for(regions))
	code_edit.set_meta(META_INLINE, _inline_for(regions, text.split("\n")))
	code_edit.remove_meta(META_INLINE_RECTS)
	code_edit.queue_redraw()


## Stale character highlights go at once; everything is recomputed after a pause in typing.
func _on_text_changed(code_edit: CodeEdit) -> void:
	if code_edit.has_meta(META_INLINE):
		code_edit.remove_meta(META_INLINE)
		code_edit.remove_meta(META_INLINE_RECTS)
		code_edit.queue_redraw()
	if not _edited.has(code_edit):
		_edited.append(code_edit)
	_edit_timer.start()


func _refresh_edited() -> void:
	for code_edit in _edited:
		if is_instance_valid(code_edit) and code_edit.has_meta(META_RES_PATH):
			refresh_code_edit(code_edit, code_edit.get_meta(META_RES_PATH))
	_edited.clear()


## LF-only and newline-terminated, so CRLF checkouts and a missing final newline don't flag every/last line.
static func _normalized(text: String) -> String:
	var t := text.replace("\r\n", "\n")
	return t if t.ends_with("\n") or t.is_empty() else t + "\n"


static func _flags_for(regions: Array) -> Dictionary:
	var flags := {}
	for i in regions.size():
		var r: Dictionary = regions[i]
		match DiffHunks.region_type(r):
			"deleted":
				if r["new_start"] == 0:
					flags[1] = { "type": "deleted_before", "region": i }
				else:
					flags[r["new_start"]] = { "type": "deleted_after", "region": i }
			var type:
				for k in r["new_count"]:
					flags[r["new_start"] + k] = { "type": type, "region": i }
	return flags


## Changed characters of each modified line that pairs up with a HEAD line (see _pair_lines()): line (0-based) -> ranges.
static func _inline_for(regions: Array, lines: PackedStringArray) -> Dictionary:
	var inline := {}
	for r: Dictionary in regions:
		if DiffHunks.region_type(r) != "modified":
			continue
		var first: int = r["new_start"] - 1
		var current := lines.slice(first, mini(first + r["new_count"], lines.size()))
		for pair: Vector2i in _pair_lines(r["old_lines"], current):
			var ranges: Array = DiffViewScript._word_diff(r["old_lines"][pair.x], current[pair.y])[1]
			if not ranges.is_empty():
				inline[first + pair.y] = ranges
	return inline


## Which HEAD line each changed line came from, in order: the k-th with the k-th when the counts match, else the most alike (sharing a start and an end), so an inserted line doesn't shift every pair after it. Vector2i(old index, new index).
static func _pair_lines(old_lines: PackedStringArray, new_lines: PackedStringArray) -> Array:
	var pairs: Array = []
	if old_lines.size() == new_lines.size() or old_lines.size() * new_lines.size() > 10000:
		for k in mini(old_lines.size(), new_lines.size()):
			pairs.append(Vector2i(k, k))
		return pairs
	var columns := new_lines.size() + 1
	var best := PackedFloat32Array()
	best.resize((old_lines.size() + 1) * columns)
	for i in range(old_lines.size() - 1, -1, -1):
		for j in range(new_lines.size() - 1, -1, -1):
			var similarity := _similarity(old_lines[i], new_lines[j])
			var paired := best[(i + 1) * columns + j + 1] + similarity if similarity >= 0.5 else 0.0
			best[i * columns + j] = maxf(paired, maxf(best[(i + 1) * columns + j], best[i * columns + j + 1]))
	var i := 0
	var j := 0
	while i < old_lines.size() and j < new_lines.size():
		var similarity := _similarity(old_lines[i], new_lines[j])
		if similarity >= 0.5 and is_equal_approx(best[i * columns + j], best[(i + 1) * columns + j + 1] + similarity):
			pairs.append(Vector2i(i, j))
			i += 1
			j += 1
		elif best[(i + 1) * columns + j] >= best[i * columns + j + 1]:
			i += 1
		else:
			j += 1
	return pairs


## Share of two lines that their common start and end make up, 0 to 1.
static func _similarity(a: String, b: String) -> float:
	var shorter := mini(a.length(), b.length())
	var prefix := 0
	while prefix < shorter and a[prefix] == b[prefix]:
		prefix += 1
	var suffix := 0
	while suffix < shorter - prefix and a[a.length() - 1 - suffix] == b[b.length() - 1 - suffix]:
		suffix += 1
	return 1.0 if maxi(a.length(), b.length()) == 0 else float(prefix + suffix) / maxi(a.length(), b.length())


## Index into META_REGIONS of the change on 0-based line, or -1.
static func region_at_line(code_edit: CodeEdit, line: int) -> int:
	var flags: Dictionary = code_edit.get_meta(META_FLAGS, {})
	return flags[line + 1]["region"] if flags.has(line + 1) else -1


## Inserts the gutter column once per CodeEdit (each open tab has its own), just left of Bookmarks, or at the left edge if that gutter isn't present.
func _install_gutter(code_edit: CodeEdit) -> void:
	var insert_at := gutter_index(code_edit, GUTTER_NAME)
	if insert_at == -1:
		insert_at = 0
		for i in code_edit.get_gutter_count():
			if code_edit.get_gutter_name(i).to_lower().contains("bookmark"):
				insert_at = i
				break

		code_edit.add_gutter(insert_at)
		code_edit.set_gutter_name(insert_at, GUTTER_NAME)
		code_edit.set_gutter_type(insert_at, TextEdit.GUTTER_TYPE_CUSTOM)
		code_edit.set_meta(META_FLAGS, {})
	code_edit.set_gutter_width(insert_at, int(GUTTER_WIDTH * EditorInterface.get_editor_scale()))

	_move_background(code_edit)
	# Re-bound on every refresh, not just on first install — the gutter lives on the engine-owned CodeEdit and survives a plugin reload, but a reload replaces this whole Node, which would otherwise leave the callback pointing at a freed instance for any tab left open across it.
	code_edit.set_gutter_custom_draw(insert_at, GutterPainter.draw_diff.bind(code_edit))
	code_edit.set_gutter_clickable(insert_at, true)
	if not _connections.any(func(connection: Array) -> bool: return connection[0] == code_edit):
		var on_click := _on_gutter_clicked.bind(code_edit)
		code_edit.gutter_clicked.connect(on_click)
		var on_edit := _on_text_changed.bind(code_edit)
		code_edit.text_changed.connect(on_edit)
		var on_draw := GutterPainter.capture_inline.bind(code_edit)
		code_edit.draw.connect(on_draw)
		_connections.append([code_edit, on_click, on_edit, on_draw])


## The editor paints background_color over everything drawn in gutters; moved into the "normal" stylebox, the character highlights show behind the text. Re-done on every refresh, since editor settings changes set the color again.
static func _move_background(code_edit: CodeEdit) -> void:
	var color := code_edit.get_theme_color(&"background_color")
	var style := code_edit.get_theme_stylebox(&"normal") as StyleBoxFlat
	if color.a == 0.0 or style == null:
		return
	if not code_edit.has_meta(META_BACKGROUND):
		code_edit.set_meta(META_BACKGROUND, [color, style if code_edit.has_theme_stylebox_override(&"normal") else null])
	style = style.duplicate()
	style.bg_color = color
	code_edit.add_theme_stylebox_override(&"normal", style)
	code_edit.add_theme_color_override(&"background_color", Color.TRANSPARENT)


static func _restore_background(code_edit: CodeEdit) -> void:
	if not code_edit.has_meta(META_BACKGROUND):
		return
	var original: Array = code_edit.get_meta(META_BACKGROUND)
	code_edit.add_theme_color_override(&"background_color", original[0])
	if original[1] == null:
		code_edit.remove_theme_stylebox_override(&"normal")
	else:
		code_edit.add_theme_stylebox_override(&"normal", original[1])
	code_edit.remove_meta(META_BACKGROUND)


## Looked up by name every time: the blame gutter is inserted next to this one, which shifts indices.
static func gutter_index(code_edit: CodeEdit, gutter_name: String) -> int:
	for i in code_edit.get_gutter_count():
		if code_edit.get_gutter_name(i) == gutter_name:
			return i
	return -1


func _on_gutter_clicked(line: int, gutter: int, code_edit: CodeEdit) -> void:
	if gutter != gutter_index(code_edit, GUTTER_NAME):
		return
	var region := region_at_line(code_edit, line)
	if region != -1:
		show_preview(code_edit, region)


# --- inline preview ------------------------------------------------------------


## Opens the old-lines preview under region (an index into META_REGIONS), replacing any open one.
func show_preview(code_edit: CodeEdit, region: int) -> void:
	close_preview()
	var regions: Array = code_edit.get_meta(META_REGIONS, [])
	if region < 0 or region >= regions.size():
		return
	_preview = ChangePreview.new()
	_preview.navigate_requested.connect(func(delta: int) -> void:
		var target := region + delta
		if target >= 0 and target < regions.size():
			code_edit.set_caret_line(maxi(regions[target]["new_start"] - 1, 0))
			code_edit.center_viewport_to_caret()
			show_preview(code_edit, target)
	)
	_preview.rollback_requested.connect(func() -> void: rollback(code_edit, region))
	_preview.show_in_changes_requested.connect(func() -> void:
		change_clicked.emit(code_edit.get_meta(META_REL_PATH, ""), maxi(regions[region]["new_start"], 1))
		close_preview()
	)
	_preview.closed.connect(func() -> void: _preview = null)
	_preview.open(code_edit, regions, region, code_edit.get_meta(META_REL_PATH, ""))


func close_preview() -> void:
	if is_instance_valid(_preview):
		_preview.close()
	_preview = null


## Puts region's HEAD lines back in the editor buffer — one undoable edit, nothing written to disk.
func rollback(code_edit: CodeEdit, region_index: int) -> void:
	var regions: Array = code_edit.get_meta(META_REGIONS, [])
	if region_index < 0 or region_index >= regions.size():
		return
	close_preview()
	var r: Dictionary = regions[region_index]
	var old_text := "\n".join(r["old_lines"])
	var first: int = r["new_start"] - 1 # 0-based first changed line
	var count: int = r["new_count"]
	code_edit.begin_complex_operation()
	if count == 0:
		# Deletion after line new_start: re-insert below it (or at the very top).
		if r["new_start"] == 0:
			code_edit.insert_text(old_text + "\n", 0, 0)
		else:
			code_edit.insert_text("\n" + old_text, first, code_edit.get_line(first).length())
	elif r["old_count"] == 0:
		_remove_lines(code_edit, first, count)
	else:
		var last := first + count - 1
		code_edit.remove_text(first, 0, last, code_edit.get_line(last).length())
		code_edit.insert_text(old_text, first, 0)
	code_edit.end_complex_operation()
	code_edit.set_caret_line(clampi(first, 0, code_edit.get_line_count() - 1))
	refresh_code_edit(code_edit, code_edit.get_meta(META_RES_PATH, ""), true)


## Removes count whole lines starting at first, newlines included.
static func _remove_lines(code_edit: CodeEdit, first: int, count: int) -> void:
	var after := first + count
	if after < code_edit.get_line_count():
		code_edit.remove_text(first, 0, after, 0)
	elif first > 0:
		var last := code_edit.get_line_count() - 1
		code_edit.remove_text(first - 1, code_edit.get_line(first - 1).length(), last, code_edit.get_line(last).length())
	else:
		code_edit.remove_text(0, 0, code_edit.get_line_count() - 1, code_edit.get_line(code_edit.get_line_count() - 1).length())
