@tool
extends VBoxContainer

const HUNK_HEADER_PATTERN := "^@@ -(\\d+)(?:,(\\d+))? \\+(\\d+)(?:,(\\d+))? @@(.*)$"
const Settings := preload("res://addons/git_tree/util/settings.gd")

const OPT_IGNORE_WHITESPACE := 1
const OPT_CONTEXT_3 := 10
const OPT_CONTEXT_10 := 11
const OPT_CONTEXT_25 := 12
const OPT_CONTEXT_FULL := 13
const CONTEXT_BY_ID := { OPT_CONTEXT_3: 3, OPT_CONTEXT_10: 10, OPT_CONTEXT_25: 25, OPT_CONTEXT_FULL: -1 }

## A diff option changed (context lines, whitespace) — the owner should re-fetch the diff with get_options() and call show_diff() again.
signal options_changed
## Double-click on a line: open the file there (new_line is 1-based, in the new version).
signal open_location_requested(path: String, new_line: int)
## One of the tabs set with set_tabs() was clicked.
signal tab_selected(index: int)

var _tabs: TabBar
var _header_bar: PanelContainer
var _header_label: Label
var _stats_added: Label
var _stats_removed: Label
var _options_button: MenuButton
var _empty_label: Label
var _scroll: ScrollContainer
var _rows_view: Control

var _diff_text := ""
var _context: Dictionary = {}


func _init() -> void:
	size_flags_horizontal = SIZE_EXPAND_FILL
	size_flags_vertical = SIZE_EXPAND_FILL

	_tabs = TabBar.new()
	_tabs.visible = false
	_tabs.clip_tabs = false
	_tabs.tab_clicked.connect(func(index: int) -> void: tab_selected.emit(index))
	add_child(_tabs)

	_header_bar = PanelContainer.new()
	var header_style := StyleBoxFlat.new()
	header_style.bg_color = Color(1, 1, 1, 0.045)
	header_style.content_margin_left = 8.0
	header_style.content_margin_right = 4.0
	header_style.content_margin_top = 2.0
	header_style.content_margin_bottom = 2.0
	_header_bar.add_theme_stylebox_override("panel", header_style)
	_header_bar.visible = false

	var header_row := HBoxContainer.new()
	header_row.add_theme_constant_override("separation", 8)

	_header_label = Label.new()
	_header_label.clip_text = true
	_header_label.size_flags_horizontal = SIZE_EXPAND_FILL
	_header_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.88))
	_header_label.mouse_filter = Control.MOUSE_FILTER_PASS
	header_row.add_child(_header_label)

	_stats_added = Label.new()
	_stats_added.add_theme_color_override("font_color", DiffRows.COLOR_ADDED_TEXT)
	header_row.add_child(_stats_added)

	_stats_removed = Label.new()
	_stats_removed.add_theme_color_override("font_color", DiffRows.COLOR_REMOVED_TEXT)
	header_row.add_child(_stats_removed)

	_options_button = MenuButton.new()
	_options_button.text = "⋯"
	_options_button.tooltip_text = "Diff options"
	_options_button.flat = true
	_build_options_menu()
	header_row.add_child(_options_button)

	_header_bar.add_child(header_row)
	add_child(_header_bar)

	_empty_label = Label.new()
	_empty_label.text = "No diff to show."
	_empty_label.modulate.a = 0.6
	_empty_label.size_flags_vertical = SIZE_EXPAND_FILL
	_empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_empty_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_empty_label)

	_scroll = ScrollContainer.new()
	_scroll.size_flags_horizontal = SIZE_EXPAND_FILL
	_scroll.size_flags_vertical = SIZE_EXPAND_FILL
	_scroll.visible = false
	add_child(_scroll)

	_rows_view = DiffRows.new()
	_rows_view.row_double_clicked.connect(func(new_line: int) -> void:
		if new_line > 0 and not String(_context.get("path", "")).is_empty():
			open_location_requested.emit(_context["path"], new_line)
	)
	_scroll.add_child(_rows_view)
	_scroll.resized.connect(func() -> void:
		_rows_view._recalculate_layout()
		_rows_view.queue_redraw()
	)
	_scroll.get_h_scroll_bar().value_changed.connect(func(_v: float) -> void: _rows_view.queue_redraw())
	_scroll.get_v_scroll_bar().value_changed.connect(func(_v: float) -> void: _rows_view.queue_redraw())


# --- options -----------------------------------------------------------------


static func _setting(key: String, default: Variant) -> Variant:
	return Settings.get_value("diff_" + key, default)


## {"context": int, "ignore_whitespace": bool} — pass to GitCliRepo's diff getters.
func get_options() -> Dictionary:
	return { "context": _setting("context", 3), "ignore_whitespace": _setting("ignore_whitespace", false) }


func _build_options_menu() -> void:
	var popup := _options_button.get_popup()
	popup.hide_on_checkable_item_selection = false
	popup.about_to_popup.connect(_sync_options_menu)
	popup.add_check_item("Ignore whitespace", OPT_IGNORE_WHITESPACE)
	popup.add_separator("Context")
	popup.add_radio_check_item("3 lines", OPT_CONTEXT_3)
	popup.add_radio_check_item("10 lines", OPT_CONTEXT_10)
	popup.add_radio_check_item("25 lines", OPT_CONTEXT_25)
	popup.add_radio_check_item("Whole file", OPT_CONTEXT_FULL)
	popup.id_pressed.connect(_on_option_pressed)


func _sync_options_menu() -> void:
	var popup := _options_button.get_popup()
	popup.set_item_checked(popup.get_item_index(OPT_IGNORE_WHITESPACE), _setting("ignore_whitespace", false))
	var context: int = _setting("context", 3)
	for id in CONTEXT_BY_ID:
		popup.set_item_checked(popup.get_item_index(id), CONTEXT_BY_ID[id] == context)


func _on_option_pressed(id: int) -> void:
	match id:
		OPT_IGNORE_WHITESPACE:
			Settings.set_value("diff_ignore_whitespace", not _setting("ignore_whitespace", false))
			options_changed.emit()
		_:
			if CONTEXT_BY_ID.has(id):
				Settings.set_value("diff_context", CONTEXT_BY_ID[id])
				options_changed.emit()
	_sync_options_menu()


# --- content -----------------------------------------------------------------


## context (all optional): {"path", "note"}.
func show_diff(diff_text: String, context: Dictionary = {}) -> void:
	var previous_path: String = _context.get("path", "")
	var keep_scroll: bool = previous_path == context.get("path", "") and not previous_path.is_empty() and _diff_text != ""
	_diff_text = diff_text
	_context = context
	_rerender(keep_scroll)


func clear_diff() -> void:
	set_tabs([])
	show_diff("")


## Small tab strip above the diff (e.g. Unstaged / Staged); empty hides it.
func set_tabs(labels: Array, current: int = 0) -> void:
	_tabs.visible = labels.size() > 1
	if not _tabs.visible:
		return
	_tabs.tab_count = labels.size()
	for i in labels.size():
		_tabs.set_tab_title(i, labels[i])
	_tabs.set_block_signals(true)
	_tabs.current_tab = current
	_tabs.set_block_signals(false)


func _rerender(keep_scroll: bool = false) -> void:
	var parsed := _parse(_diff_text)

	var path: String = parsed["path"] if not String(parsed["path"]).is_empty() else _context.get("path", "")
	var rows: Array = parsed["rows"]
	var note: String = _context.get("note", "")

	_header_bar.visible = not path.is_empty()
	_header_label.text = path + ("   · " + note if not note.is_empty() else "")
	_header_label.tooltip_text = path
	_stats_added.text = ("+%d" % parsed["added"]) if parsed["added"] > 0 else ""
	_stats_removed.text = ("−%d" % parsed["removed"]) if parsed["removed"] > 0 else ""

	_rows_view.set_content(rows)
	var has_rows := not rows.is_empty()
	_scroll.visible = has_rows
	_empty_label.visible = not has_rows
	if not has_rows:
		_empty_label.text = "Binary file changed." if parsed["binary"] else "No diff to show."

	if not keep_scroll:
		# Otherwise the previous file's scroll offset carries over and clips the top of the new diff.
		_scroll.scroll_horizontal = 0
		_scroll.scroll_vertical = 0


## {"path", "added", "removed", "binary", "is_new", "is_deleted", "rows"}; rows are line rows {"type", "old_no"/"new_no" (-1 = none), "text", "hunk"} or hunk rows {"type": "hunk", "hunk", "gap", "heading", "header"}.
static func _parse(diff_text: String) -> Dictionary:
	var result := {"path": "", "added": 0, "removed": 0, "binary": false, "is_new": false, "is_deleted": false, "rows": []}
	var rows: Array = result["rows"]
	if diff_text.is_empty():
		return result

	var lines := diff_text.split("\n")
	var n := lines.size()

	var hunk_regex := RegEx.new()
	hunk_regex.compile(HUNK_HEADER_PATTERN)

	var prev_new_end := 0
	var hunk_index := -1

	var i := 0
	while i < n:
		var line: String = lines[i]

		if line.begins_with("Binary files "):
			result["binary"] = true
		if line.begins_with("new file mode"):
			result["is_new"] = true
		if line.begins_with("deleted file mode"):
			result["is_deleted"] = true

		if (line.begins_with("+++ ") or line.begins_with("--- ")) and String(result["path"]).is_empty():
			var p := line.substr(4).strip_edges()
			if p != "/dev/null":
				result["path"] = _strip_ab_prefix(p)
			i += 1
			continue

		var header_match := hunk_regex.search(line)
		if header_match == null:
			i += 1
			continue

		hunk_index += 1
		var old_start := header_match.get_string(1).to_int()
		var new_start := header_match.get_string(3).to_int()
		rows.append({
			"type": "hunk", "hunk": hunk_index, "header": line,
			"gap": maxi(0, new_start - prev_new_end - 1) if hunk_index > 0 or new_start > 1 else 0,
			"heading": header_match.get_string(5).strip_edges(),
		})

		var old_line := old_start
		var new_line := new_start
		i += 1

		while i < n and not lines[i].begins_with("@@") and not lines[i].begins_with("diff --git"):
			var body_line: String = lines[i]
			i += 1
			if body_line.length() > 0 and body_line[0] == "\\": # "\ No newline at end of file"
				continue
			if body_line.is_empty() and i == n:
				break # trailing newline of the whole diff

			if body_line.begins_with("-"):
				rows.append(_line_row("removed", old_line, -1, body_line.substr(1), hunk_index))
				old_line += 1
				result["removed"] += 1
			elif body_line.begins_with("+"):
				rows.append(_line_row("added", -1, new_line, body_line.substr(1), hunk_index))
				new_line += 1
				result["added"] += 1
			else:
				rows.append(_line_row("context", old_line, new_line, body_line.substr(1), hunk_index))
				old_line += 1
				new_line += 1

		prev_new_end = new_line - 1

	return result


static func _line_row(type: String, old_no: int, new_no: int, text: String, hunk: int) -> Dictionary:
	return {"type": type, "old_no": old_no, "new_no": new_no, "text": text, "hunk": hunk}


static func _strip_ab_prefix(path: String) -> String:
	if path.begins_with("a/") or path.begins_with("b/"):
		return path.substr(2)
	return path


## Custom-drawn rows (RTL's [bgcolor] can't fill a row edge-to-edge): backgrounds, gutters, line numbers; only visible rows are drawn.
class DiffRows:
	extends Control

	signal row_double_clicked(new_line: int)

	const GUTTER_PAD := 10.0
	const MARKER_WIDTH := 22.0
	const TEXT_RIGHT_PAD := 24.0
	const LINE_PAD_Y := 6.0
	const CONTENT_PAD_Y := 4.0

	const COLOR_ADDED_BG := Color(0.208, 0.408, 0.235, 0.35)
	const COLOR_REMOVED_BG := Color(0.443, 0.176, 0.192, 0.35)
	const COLOR_ADDED_TEXT := Color(0.643, 0.851, 0.667)
	const COLOR_REMOVED_TEXT := Color(0.925, 0.588, 0.604)
	const COLOR_CONTEXT_TEXT := Color(0.78, 0.78, 0.8)
	const COLOR_LINE_NO := Color(0.45, 0.45, 0.5)
	const COLOR_HUNK_BG := Color(0.35, 0.5, 0.85, 0.12)
	const COLOR_HUNK_TEXT := Color(0.6, 0.68, 0.85)

	var _rows: Array = []
	var _gutter_width := 30.0
	var _row_height := 20.0
	var _baseline_offset := 14.0


	func _init() -> void:
		size_flags_horizontal = SIZE_EXPAND_FILL
		size_flags_vertical = SIZE_EXPAND_FILL
		mouse_filter = Control.MOUSE_FILTER_PASS
		focus_mode = Control.FOCUS_CLICK


	## The script editor's own monospace font, so the diff reads like code
	## instead of UI text. Falls back to the default UI font outside the
	## editor theme (e.g. when unit-testing this script standalone).
	func _code_font() -> Font:
		if has_theme_font("source", "EditorFonts"):
			return get_theme_font("source", "EditorFonts")
		return get_theme_default_font()


	func _code_font_size() -> int:
		if has_theme_font_size("source_size", "EditorFonts"):
			return get_theme_font_size("source_size", "EditorFonts")
		return get_theme_default_font_size()


	func _notification(what: int) -> void:
		if what == NOTIFICATION_THEME_CHANGED and not _rows.is_empty():
			_recalculate_layout()
			queue_redraw()


	func set_content(rows: Array) -> void:
		_rows = rows
		_recalculate_layout()
		queue_redraw()


	func _recalculate_layout() -> void:
		if _rows.is_empty():
			custom_minimum_size = Vector2.ZERO
			return

		var font := _code_font()
		var font_size := _code_font_size()
		_row_height = ceilf(font.get_height(font_size)) + LINE_PAD_Y
		_baseline_offset = font.get_ascent(font_size) + LINE_PAD_Y * 0.5

		var max_no := 1
		var max_text := 0.0
		for row in _rows:
			if row["type"] == "hunk":
				continue
			max_no = maxi(max_no, maxi(int(row["old_no"]), int(row["new_no"])))
			max_text = maxf(max_text, font.get_string_size(row["text"], HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x)

		var digits := str(max_no).length()
		_gutter_width = font.get_string_size("0".repeat(digits), HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x + GUTTER_PAD

		var width := _gutter_width * 2 + MARKER_WIDTH + max_text + TEXT_RIGHT_PAD
		custom_minimum_size = Vector2(width, _rows.size() * _row_height + CONTENT_PAD_Y * 2)


	func _scroll_container() -> ScrollContainer:
		return get_parent() as ScrollContainer


	func _row_top(index: int) -> float:
		return CONTENT_PAD_Y + index * _row_height


	func _draw() -> void:
		if _rows.is_empty():
			return

		var sc := _scroll_container()
		var view_top := float(sc.scroll_vertical) if sc != null else 0.0
		var view_height := sc.size.y if sc != null else size.y
		var view_left := float(sc.scroll_horizontal) if sc != null else 0.0

		var first := maxi(0, int((view_top - CONTENT_PAD_Y) / _row_height) - 1)
		var last := mini(_rows.size() - 1, int((view_top + view_height - CONTENT_PAD_Y) / _row_height) + 1)

		for idx in range(first, last + 1):
			var y := _row_top(idx)
			var row: Dictionary = _rows[idx]
			if row["type"] == "hunk":
				_draw_hunk_row(row, y, view_left)
			else:
				_draw_line(row, y)


	## Draws one line row: background, old + new line numbers, marker and text.
	func _draw_line(row: Dictionary, y: float) -> void:
		var font := _code_font()
		var font_size := _code_font_size()
		var baseline := y + _baseline_offset
		var type: String = row["type"]
		var text: String = row["text"]

		var bg_color := Color(0, 0, 0, 0)
		var text_color := COLOR_CONTEXT_TEXT
		var marker := " "
		match type:
			"added":
				bg_color = COLOR_ADDED_BG
				text_color = COLOR_ADDED_TEXT
				marker = "+"
			"removed":
				bg_color = COLOR_REMOVED_BG
				text_color = COLOR_REMOVED_TEXT
				marker = "-"

		if bg_color.a > 0.0:
			draw_rect(Rect2(0, y, size.x, _row_height), bg_color)

		if row["old_no"] > 0:
			draw_string(font, Vector2(0, baseline), str(row["old_no"]),
					HORIZONTAL_ALIGNMENT_RIGHT, _gutter_width - GUTTER_PAD * 0.5, font_size, COLOR_LINE_NO)
		if row["new_no"] > 0:
			draw_string(font, Vector2(_gutter_width, baseline), str(row["new_no"]),
					HORIZONTAL_ALIGNMENT_RIGHT, _gutter_width - GUTTER_PAD * 0.5, font_size, COLOR_LINE_NO)
		var number_x := _gutter_width * 2

		draw_string(font, Vector2(number_x, baseline), marker, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, text_color)
		var text_x := number_x + MARKER_WIDTH

		draw_string(font, Vector2(text_x, baseline), text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, text_color)


	func _draw_hunk_row(row: Dictionary, y: float, view_left: float) -> void:
		var code_font := _code_font()
		var code_size := _code_font_size()
		draw_rect(Rect2(0, y, size.x, _row_height), COLOR_HUNK_BG)

		var gap: int = row["gap"]
		var label := ""
		if gap > 0:
			label = "⋯ %d unchanged line%s" % [gap, "" if gap == 1 else "s"]
		var heading: String = row["heading"]
		if not heading.is_empty():
			label += ("    " if not label.is_empty() else "") + heading
		if label.is_empty():
			label = row["header"]
		var baseline := y + _baseline_offset
		draw_string(code_font, Vector2(view_left + 8.0, baseline), label, HORIZONTAL_ALIGNMENT_LEFT, -1, maxi(1, code_size - 1), COLOR_HUNK_TEXT)


	## Row index under pos, or -1.
	func _row_at(pos: Vector2) -> int:
		var idx := int((pos.y - CONTENT_PAD_Y) / _row_height)
		return idx if idx >= 0 and idx < _rows.size() else -1


	func _gui_input(event: InputEvent) -> void:
		if not (event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed and event.double_click):
			return
		var idx := _row_at(event.position)
		if idx >= 0 and _rows[idx]["type"] != "hunk":
			var row: Dictionary = _rows[idx]
			row_double_clicked.emit(row["new_no"] if row["new_no"] > 0 else _nearest_new_line(idx))
			accept_event()


	## A removed line has no new-file number — use the closest following one.
	func _nearest_new_line(idx: int) -> int:
		for k in range(idx, _rows.size()):
			if _rows[k]["type"] != "hunk" and int(_rows[k]["new_no"]) > 0:
				return _rows[k]["new_no"]
		return 1
