@tool
extends Control

signal commit_selected(oid: String)
signal commit_context_requested(oid: String, screen_position: Vector2)

const Settings := preload("res://addons/git_tree/util/settings.gd")

const ROW_HEIGHT := 28.0
const LANE_WIDTH := 16.0
const DOT_RADIUS := 4.5
const LEFT_MARGIN := 12.0
const TEXT_GAP := 14.0
const COLUMN_GAP := 16.0
const DEFAULT_HASH_COL_WIDTH := 64.0
const DEFAULT_AUTHOR_COL_WIDTH := 110.0
const DEFAULT_DATE_COL_WIDTH := 150.0
const MIN_COL_WIDTH := 50.0
const DIVIDER_HIT_MARGIN := 4.0
const BADGE_PADDING := 5.0
const BADGE_GAP := 8.0

const MERGE_MESSAGE_COLOR := Color(0.62, 0.62, 0.66)
const BADGE_BG_COLOR := Color(0.42, 0.58, 0.92, 0.28)
const BADGE_TEXT_COLOR := Color(0.68, 0.78, 1.0)
const TAG_BADGE_BG_COLOR := Color(0.86, 0.7, 0.22, 0.28)
const TAG_BADGE_TEXT_COLOR := Color(0.95, 0.85, 0.55)
const AUTHOR_COLOR := Color(0.85, 0.85, 0.88)
const DATE_COLOR := Color(0.58, 0.58, 0.62)
const HASH_COLOR := Color(0.55, 0.58, 0.66)
const DIVIDER_COLOR := Color(1, 1, 1, 0.08)

const LANE_COLORS := [
	Color(0.36, 0.66, 0.96),
	Color(0.96, 0.56, 0.26),
	Color(0.46, 0.82, 0.44),
	Color(0.86, 0.38, 0.58),
	Color(0.66, 0.52, 0.92),
	Color(0.90, 0.78, 0.26),
]

## Laid-out entries: each is the raw GitRepo.get_commit_graph() dictionary
## plus "lane" and "row". See compute_layout().
var _commits: Array = []
var _by_oid: Dictionary = {}
var _selected_row := -1
## Rows in the (Ctrl/Cmd/Shift-click) multi-selection, _selected_row included.
var _selected_rows := {}
var _head_oid := ""

## User-resizable via dragging the column dividers; persisted across editor
## sessions through util/settings.gd. 0 = not dragging, 1 = the divider
## between the message and hash columns, 2 = between hash and author,
## 3 = between author and date.
var _hash_col_width: float = DEFAULT_HASH_COL_WIDTH
var _author_col_width: float = DEFAULT_AUTHOR_COL_WIDTH
var _date_col_width: float = DEFAULT_DATE_COL_WIDTH
var _dragging_divider := 0


func _init() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	resized.connect(queue_redraw)
	focus_mode = Control.FOCUS_CLICK
	_hash_col_width = Settings.get_value("history_hash_col_width", DEFAULT_HASH_COL_WIDTH)
	_author_col_width = Settings.get_value("history_author_col_width", DEFAULT_AUTHOR_COL_WIDTH)
	_date_col_width = Settings.get_value("history_date_col_width", DEFAULT_DATE_COL_WIDTH)


## head_oid gets a ring around its dot. Selection survives if the selected commits are still listed.
func set_commits(raw_commits: Array, head_oid: String = "") -> void:
	var previously_selected := get_selected_oids()
	var primary := get_selected_oid()
	_commits = compute_layout(raw_commits)
	_head_oid = head_oid
	_by_oid.clear()
	for entry in _commits:
		_by_oid[entry["oid"]] = entry

	# Width follows the parent container (see _init); only height is forced.
	custom_minimum_size.y = _commits.size() * ROW_HEIGHT
	_selected_rows.clear()
	_selected_row = -1
	for oid in previously_selected:
		if _by_oid.has(oid):
			_selected_rows[_by_oid[oid]["row"]] = true
	if _by_oid.has(primary):
		_selected_row = _by_oid[primary]["row"]
	queue_redraw()


## Primary (last clicked) selected commit, or "".
func get_selected_oid() -> String:
	return _commits[_selected_row]["oid"] if _selected_row >= 0 and _selected_row < _commits.size() else ""


## Every selected oid, in graph order (newest first).
func get_selected_oids() -> PackedStringArray:
	var rows := _selected_rows.keys()
	rows.sort()
	var oids := PackedStringArray()
	for row in rows:
		if row < _commits.size():
			oids.append(_commits[row]["oid"])
	return oids


func select_oid(oid: String) -> void:
	if not _by_oid.has(oid):
		return
	_select_single(_by_oid[oid]["row"])


func _select_single(row: int) -> void:
	_selected_row = row
	_selected_rows = { row: true }
	queue_redraw()
	commit_selected.emit(_commits[row]["oid"])
	_scroll_row_into_view(row)


func _scroll_row_into_view(row: int) -> void:
	var sc := get_parent() as ScrollContainer
	if sc == null:
		return
	var top := row * ROW_HEIGHT
	if top < sc.scroll_vertical:
		sc.scroll_vertical = int(top)
	elif top + ROW_HEIGHT > sc.scroll_vertical + sc.size.y:
		sc.scroll_vertical = int(top + ROW_HEIGHT - sc.size.y)


## Assigns each commit a lane so a git-log --graph style graph can be
## drawn. commits must be newest-first with "oid" and "parents" per entry.
##
## `lanes` tracks, per column, which oid it's waiting to see next ("" =
## free). A commit takes the lane expecting it (or the first free one, or
## a new one), then that lane starts waiting for its first parent. Extra
## parents (merges) each claim their own lane the same way.
static func compute_layout(commits: Array) -> Array:
	var lanes: Array[String] = []
	var result: Array = []

	for row in commits.size():
		var commit: Dictionary = commits[row]
		var oid: String = commit["oid"]

		var lane_index := lanes.find(oid)
		if lane_index == -1:
			lane_index = lanes.find("")
			if lane_index == -1:
				lane_index = lanes.size()
				lanes.append("")

		# Free any other lane also waiting for this oid (a merge point),
		# so it gets reused for the rest of the graph.
		for i in lanes.size():
			if i != lane_index and lanes[i] == oid:
				lanes[i] = ""

		var entry := commit.duplicate()
		entry["lane"] = lane_index
		entry["row"] = row
		result.append(entry)

		var parents: PackedStringArray = commit["parents"]
		if parents.is_empty():
			lanes[lane_index] = ""
		else:
			lanes[lane_index] = parents[0]
			for i in range(1, parents.size()):
				var parent_oid: String = parents[i]
				if lanes.find(parent_oid) == -1:
					var free_index := lanes.find("")
					if free_index == -1:
						lanes.append(parent_oid)
					else:
						lanes[free_index] = parent_oid

	return result


func _lane_color(lane: int) -> Color:
	return LANE_COLORS[lane % LANE_COLORS.size()]


func _lane_x(lane: int) -> float:
	return LEFT_MARGIN + lane * LANE_WIDTH + LANE_WIDTH * 0.5


func _row_y(row: int) -> float:
	return row * ROW_HEIGHT + ROW_HEIGHT * 0.5


func _max_lane() -> int:
	var m := 0
	for entry in _commits:
		m = maxi(m, int(entry["lane"]))
	return m


## "main & dev", or "main +3" once there are more than two, so a badge
## never grows unbounded with a heavily-tagged/branched commit.
static func _badge_label(names: PackedStringArray) -> String:
	if names.size() <= 2:
		return " & ".join(Array(names))
	return "%s +%d" % [names[0], names.size() - 1]


## Longest prefix of text (plus an ellipsis) that fits within max_width at
## the given font/size, or text unchanged if it already fits.
static func _truncate_to_width(font: Font, font_size: int, text: String, max_width: float) -> String:
	if max_width <= 0.0:
		return ""
	if font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x <= max_width:
		return text

	var ellipsis_width := font.get_string_size("…", HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	var lo := 0
	var hi := text.length()
	while lo < hi:
		var mid := (lo + hi + 1) / 2
		var w := font.get_string_size(text.substr(0, mid), HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x + ellipsis_width
		if w <= max_width:
			lo = mid
		else:
			hi = mid - 1

	return (text.substr(0, lo) + "…") if lo > 0 else "…"


## "25 minutes ago", falling back to a "DD.MM.YYYY, HH:MM" stamp once
## it's more than a week old.
static func format_relative_time(unix_time: int, now: int = -1) -> String:
	if now < 0:
		now = int(Time.get_unix_time_from_system())
	var delta := now - unix_time
	if delta < 0:
		delta = 0

	if delta < 60:
		return "just now"
	if delta < 3600:
		var m := delta / 60
		return "%d minute%s ago" % [m, "" if m == 1 else "s"]
	if delta < 86400:
		var h := delta / 3600
		return "%d hour%s ago" % [h, "" if h == 1 else "s"]
	if delta < 7 * 86400:
		var d := delta / 86400
		return "%d day%s ago" % [d, "" if d == 1 else "s"]

	var dt := Time.get_datetime_dict_from_unix_time(unix_time)
	return "%02d.%02d.%04d, %02d:%02d" % [dt["day"], dt["month"], dt["year"], dt["hour"], dt["minute"]]


func _draw() -> void:
	if _commits.is_empty():
		return

	var font := get_theme_default_font()
	var font_size := get_theme_default_font_size()

	# Only rows inside the scroll viewport are drawn — the log can be thousands of commits long once "load more" kicks in.
	var sc := get_parent() as ScrollContainer
	var view_top := float(sc.scroll_vertical) if sc != null else 0.0
	var view_bottom := view_top + (sc.size.y if sc != null else size.y)
	var first_row := maxi(0, int(view_top / ROW_HEIGHT) - 1)
	var last_row := mini(_commits.size() - 1, int(view_bottom / ROW_HEIGHT) + 1)

	for row in _selected_rows:
		if row >= first_row and row <= last_row:
			draw_rect(Rect2(0, row * ROW_HEIGHT, size.x, ROW_HEIGHT), Color(1, 1, 1, 0.08 if row == _selected_row else 0.05))
	if _selected_rows.size() > 1 and _selected_row >= first_row and _selected_row <= last_row:
		draw_rect(Rect2(0, _selected_row * ROW_HEIGHT, 3.0, ROW_HEIGHT), BADGE_TEXT_COLOR)

	# Connectors first (dots draw on top); a line spanning many rows is drawn whenever it crosses the view.
	for entry in _commits:
		if int(entry["row"]) > last_row:
			break
		var from := Vector2(_lane_x(entry["lane"]), _row_y(entry["row"]))
		var parents: PackedStringArray = entry["parents"]
		for parent_oid in parents:
			if _by_oid.has(parent_oid):
				var parent_entry: Dictionary = _by_oid[parent_oid]
				if int(parent_entry["row"]) < first_row:
					continue
				var to := Vector2(_lane_x(parent_entry["lane"]), _row_y(parent_entry["row"]))
				draw_line(from, to, _lane_color(entry["lane"]), 2.0, true)

	var graph_width := LEFT_MARGIN + (_max_lane() + 1) * LANE_WIDTH + TEXT_GAP
	var text_x := graph_width
	var date_x := size.x - _date_col_width
	var author_x := date_x - _author_col_width
	var hash_x := author_x - _hash_col_width
	var message_max_width := maxf(0.0, hash_x - COLUMN_GAP - text_x)
	var now := int(Time.get_unix_time_from_system())

	draw_line(Vector2(hash_x - COLUMN_GAP * 0.5, 0), Vector2(hash_x - COLUMN_GAP * 0.5, size.y), DIVIDER_COLOR, 1.0)
	draw_line(Vector2(author_x - COLUMN_GAP * 0.5, 0), Vector2(author_x - COLUMN_GAP * 0.5, size.y), DIVIDER_COLOR, 1.0)
	draw_line(Vector2(date_x - COLUMN_GAP * 0.5, 0), Vector2(date_x - COLUMN_GAP * 0.5, size.y), DIVIDER_COLOR, 1.0)

	for row in range(first_row, last_row + 1):
		var entry: Dictionary = _commits[row]
		var dot := Vector2(_lane_x(entry["lane"]), _row_y(entry["row"]))
		draw_circle(dot, DOT_RADIUS, _lane_color(entry["lane"]))
		if entry["oid"] == _head_oid:
			draw_arc(dot, DOT_RADIUS + 3.0, 0.0, TAU, 20, Color.WHITE, 1.5, true)

		var baseline_y := _row_y(entry["row"]) + font_size * 0.35
		var is_merge: bool = (entry["parents"] as PackedStringArray).size() > 1
		var message_color := MERGE_MESSAGE_COLOR if is_merge else Color.WHITE

		# Branches and tags get separate colored pills (tags gold-ish) since
		# both can be present on the same commit.
		var badges: Array = []
		var refs: PackedStringArray = entry["refs"]
		if not refs.is_empty():
			badges.append({"text": _badge_label(refs), "bg": BADGE_BG_COLOR, "fg": BADGE_TEXT_COLOR})
		var tags: PackedStringArray = entry.get("tags", PackedStringArray())
		if not tags.is_empty():
			badges.append({"text": _badge_label(tags), "bg": TAG_BADGE_BG_COLOR, "fg": TAG_BADGE_TEXT_COLOR})

		var total_badge_width := 0.0
		for b in badges:
			b["width"] = font.get_string_size(b["text"], HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x + BADGE_PADDING * 2
			total_badge_width += b["width"] + BADGE_GAP

		var summary: String = entry["summary"]
		var message_width_budget := message_max_width - total_badge_width
		var shown_summary := _truncate_to_width(font, font_size, summary, message_width_budget)

		draw_string(font, Vector2(text_x, baseline_y), shown_summary, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, message_color)

		if not badges.is_empty():
			var shown_width := font.get_string_size(shown_summary, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
			var badge_x := text_x + shown_width + BADGE_GAP
			for b in badges:
				var badge_rect := Rect2(badge_x, _row_y(entry["row"]) - font_size * 0.65, b["width"], font_size * 1.3)
				draw_rect(badge_rect, b["bg"])
				draw_string(font, Vector2(badge_x + BADGE_PADDING, baseline_y), b["text"],
						HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, b["fg"])
				badge_x += b["width"] + BADGE_GAP

		draw_string(font, Vector2(hash_x, baseline_y), String(entry["oid"]).substr(0, 7),
				HORIZONTAL_ALIGNMENT_LEFT, _hash_col_width - COLUMN_GAP, font_size, HASH_COLOR)

		var author: String = entry.get("author_name", "")
		draw_string(font, Vector2(author_x, baseline_y), _truncate_to_width(font, font_size, author, _author_col_width - COLUMN_GAP),
				HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, AUTHOR_COLOR)

		var date_text := format_relative_time(int(entry.get("time", 0)), now)
		draw_string(font, Vector2(date_x, baseline_y), date_text,
				HORIZONTAL_ALIGNMENT_LEFT, _date_col_width, font_size, DATE_COLOR)


## Which divider (if any) is within DIVIDER_HIT_MARGIN of local x: 1 for the
## message/hash divider, 2 for hash/author, 3 for author/date, 0 for neither.
func _divider_at_x(x: float) -> int:
	var divider1_x := size.x - _date_col_width - _author_col_width - _hash_col_width - COLUMN_GAP * 0.5
	var divider2_x := size.x - _date_col_width - _author_col_width - COLUMN_GAP * 0.5
	var divider3_x := size.x - _date_col_width - COLUMN_GAP * 0.5
	if absf(x - divider1_x) <= DIVIDER_HIT_MARGIN:
		return 1
	if absf(x - divider2_x) <= DIVIDER_HIT_MARGIN:
		return 2
	if absf(x - divider3_x) <= DIVIDER_HIT_MARGIN:
		return 3
	return 0


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		if _dragging_divider == 1:
			_hash_col_width = clampf(size.x - _date_col_width - _author_col_width - COLUMN_GAP * 0.5 - event.position.x,
					MIN_COL_WIDTH, size.x - _date_col_width - _author_col_width - MIN_COL_WIDTH)
			queue_redraw()
		elif _dragging_divider == 2:
			_author_col_width = clampf(size.x - _date_col_width - COLUMN_GAP * 0.5 - event.position.x,
					MIN_COL_WIDTH, size.x - _date_col_width - _hash_col_width - MIN_COL_WIDTH)
			queue_redraw()
		elif _dragging_divider == 3:
			_date_col_width = clampf(size.x - COLUMN_GAP * 0.5 - event.position.x,
					MIN_COL_WIDTH, size.x - _author_col_width - _hash_col_width - MIN_COL_WIDTH)
			queue_redraw()
		else:
			mouse_default_cursor_shape = Control.CURSOR_HSIZE if _divider_at_x(event.position.x) != 0 else Control.CURSOR_ARROW
		return

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			var divider := _divider_at_x(event.position.x)
			if divider != 0:
				_dragging_divider = divider
				return

			var row := int(event.position.y / ROW_HEIGHT)
			if row >= 0 and row < _commits.size():
				if event.shift_pressed and _selected_row >= 0:
					if not (event.ctrl_pressed or event.meta_pressed):
						_selected_rows.clear()
					for r in range(mini(_selected_row, row), maxi(_selected_row, row) + 1):
						_selected_rows[r] = true
					queue_redraw()
				elif event.ctrl_pressed or event.meta_pressed:
					if _selected_rows.has(row) and _selected_rows.size() > 1:
						_selected_rows.erase(row)
						if _selected_row == row:
							_selected_row = _selected_rows.keys()[0]
					else:
						_selected_rows[row] = true
						_selected_row = row
						commit_selected.emit(_commits[row]["oid"])
					queue_redraw()
				else:
					_select_single(row)
		elif _dragging_divider != 0:
			_dragging_divider = 0
			Settings.set_value("history_hash_col_width", _hash_col_width)
			Settings.set_value("history_author_col_width", _author_col_width)
			Settings.set_value("history_date_col_width", _date_col_width)
		return

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		var row := int(event.position.y / ROW_HEIGHT)
		if row < 0 or row >= _commits.size():
			return
		# Right-click inside a multi-selection keeps it (the menu acts on all of them).
		if not _selected_rows.has(row):
			_selected_rows = { row: true }
		_selected_row = row
		queue_redraw()
		commit_context_requested.emit(_commits[row]["oid"], get_screen_position() + event.position.round())
		return

	if event is InputEventKey and event.pressed and not _commits.is_empty():
		var step := 0
		match event.keycode:
			KEY_UP: step = -1
			KEY_DOWN: step = 1
			KEY_PAGEUP: step = -10
			KEY_PAGEDOWN: step = 10
		if step != 0:
			_select_single(clampi(_selected_row + step, 0, _commits.size() - 1))
			accept_event()
