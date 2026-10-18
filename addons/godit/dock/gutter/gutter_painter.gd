## Draws the diff and blame gutters from what diff_gutter.gd and blame_gutter.gd keep on each CodeEdit, from a script of its own: while one of those is being edited and doesn't compile, the columns keep showing their last state.
extends RefCounted

const GitIcons := preload("res://addons/godit/util/git_icons.gd")

## line (1-based) -> {"type": "added"|"modified"|"deleted_before"|"deleted_after", "region": index into diff_gutter.gd's META_REGIONS}.
const META_FLAGS := "godit_diff_flags"
## line (0-based) -> Array of Vector2i(start, length): changed characters of modified lines, painted behind the text.
const META_INLINE := "godit_diff_inline"
## line -> Array of Rect2 of META_INLINE's characters, x in content pixels (h_scroll added) and y from the line's top, captured after a draw: the editor gives no positions while drawing.
const META_INLINE_RECTS := "godit_diff_inline_rects"
## Width, line height and gutter width the rects were captured at.
const META_INLINE_VIEW := "godit_diff_inline_view"
## blame_gutter.gd's result: one {"oid", "author", "time", "summary"} per line.
const META_BLAME := "godit_blame"
const INLINE_COLOR := Color(GitIcons.COLOR_MODIFIED, 0.22)


## The diff gutter's cell: a bar for added/modified lines, an edge for deletions, and the changed characters' backgrounds. line is 0-based, the flags 1-based (git's convention).
static func draw_diff(line: int, _gutter: int, region: Rect2, code_edit: CodeEdit) -> void:
	var flags: Dictionary = code_edit.get_meta(META_FLAGS, {})
	if not flags.has(line + 1):
		return
	if code_edit.get_meta(META_INLINE_VIEW, "") == inline_view(code_edit):
		for rect: Rect2 in code_edit.get_meta(META_INLINE_RECTS, {}).get(line, []):
			code_edit.draw_rect(Rect2(rect.position.x - code_edit.get_h_scroll(), region.position.y + rect.position.y, rect.size.x, rect.size.y), INLINE_COLOR)

	var bar := Vector2(maxf(4.0, region.size.x * 0.3), region.size.y - 2)
	var edge := maxf(3.0, region.size.y * 0.15)
	match flags[line + 1]["type"]:
		"added":
			code_edit.draw_rect(Rect2(region.position + Vector2(region.size.x * 0.2, 1), bar), GitIcons.COLOR_ADDED)
		"modified":
			code_edit.draw_rect(Rect2(region.position + Vector2(region.size.x * 0.2, 1), bar), GitIcons.COLOR_MODIFIED)
		"deleted_before":
			code_edit.draw_rect(Rect2(region.position, Vector2(region.size.x, edge)), GitIcons.COLOR_DELETED)
		"deleted_after":
			code_edit.draw_rect(Rect2(region.position + Vector2(0, region.size.y - edge), Vector2(region.size.x, edge)), GitIcons.COLOR_DELETED)


static func inline_view(code_edit: CodeEdit) -> String:
	return "%s|%d|%d" % [code_edit.size.x, code_edit.get_line_height(), code_edit.get_total_gutter_width()]


## After each draw: positions of the changed characters on screen; when they differ from what was just drawn, one more draw paints them.
static func capture_inline(code_edit: CodeEdit) -> void:
	var rects := {}
	var inline: Dictionary = code_edit.get_meta(META_INLINE, {})
	for line: int in inline:
		var top := code_edit.get_rect_at_line_column(line, 0).position.y
		if top < 0:
			continue # first row scrolled out of view
		var line_rects: Array = []
		for r: Vector2i in inline[line]:
			for column in range(r.x, r.x + r.y):
				# The rect at caret column c is the character before it.
				var cell := Rect2(code_edit.get_rect_at_line_column(line, column + 1))
				if cell.position.x < 0 or cell.position.y < 0:
					continue
				cell.position += Vector2(code_edit.get_h_scroll(), -top)
				if not line_rects.is_empty() and is_equal_approx(line_rects[-1].position.y, cell.position.y) and line_rects[-1].end.x >= cell.position.x - 1:
					line_rects[-1] = line_rects[-1].merge(cell)
				else:
					line_rects.append(cell)
		rects[line] = line_rects
	var known: Dictionary = code_edit.get_meta(META_INLINE_RECTS, {})
	for line: int in known:
		if inline.has(line) and not rects.has(line):
			rects[line] = known[line] # off screen now: the rects stay valid while only scrolling
	var view := inline_view(code_edit)
	if rects != known or view != code_edit.get_meta(META_INLINE_VIEW, ""):
		code_edit.set_meta(META_INLINE_RECTS, rects)
		code_edit.set_meta(META_INLINE_VIEW, view)
		code_edit.queue_redraw.call_deferred() # a redraw asked for during drawing is dropped


## The blame column's cell: author and age, dimmed where it repeats the line above, and a hairline where another commit's lines begin.
static func draw_blame(line: int, _gutter: int, region: Rect2, code_edit: CodeEdit) -> void:
	var lines: Array = code_edit.get_meta(META_BLAME, [])
	if line >= lines.size() or region.size.x <= 1.0: # collapsed while blame is off
		return
	var entry: Dictionary = lines[line]
	var starts_run: bool = line == 0 or lines[line - 1]["oid"] != entry["oid"]
	if starts_run and line > 0:
		code_edit.draw_rect(Rect2(region.position + Vector2(4, 0), Vector2(region.size.x - 8, 1)), Color(1, 1, 1, 0.07))

	var font := code_edit.get_theme_font("font")
	var font_size := blame_font_size(code_edit)
	var baseline := region.position.y + (region.size.y + font.get_ascent(font_size) - font.get_descent(font_size)) / 2.0
	var color: Color = GitIcons.COLOR_MODIFIED if String(entry["oid"]).is_empty() else code_edit.get_theme_color("font_color")
	# Every line is labelled; repeats of the line above are dimmed so each commit's first line still stands out.
	color.a = 0.55 if starts_run else 0.22
	code_edit.draw_string(font, Vector2(region.position.x + 4, baseline), blame_label(entry), HORIZONTAL_ALIGNMENT_LEFT, region.size.x - 10, font_size, color)


static func blame_label(entry: Dictionary) -> String:
	return "not committed" if String(entry["oid"]).is_empty() else "%s · %s" % [entry["author"], relative_age(entry["time"])]


static func blame_font_size(code_edit: CodeEdit) -> int:
	return maxi(code_edit.get_theme_font_size("font_size") - 2, 8)


## Compact age for the blame column: "now", "5h", "3d", "2w", "4mo", "1y".
static func relative_age(unix_time: int) -> String:
	var secs := int(Time.get_unix_time_from_system()) - unix_time
	if secs < 3600:
		return "now"
	if secs < 86400:
		return "%dh" % (secs / 3600)
	if secs < 86400 * 14:
		return "%dd" % (secs / 86400)
	if secs < 86400 * 60:
		return "%dw" % (secs / (86400 * 7))
	if secs < 86400 * 365:
		return "%dmo" % (secs / (86400 * 30))
	return "%dy" % (secs / (86400 * 365))
