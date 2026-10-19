@tool
## Two versions of an image on top of each other, at one scale over a checkerboard: "swipe" shows Before left of a line the mouse drags and After right of it, "onion" fades After over Before.
extends Control

const CHECKER_CELL := 8

var old_texture: Texture2D
var new_texture: Texture2D
var mode := "swipe":
	set(value):
		mode = value
		mouse_default_cursor_shape = CURSOR_HSIZE if value == "swipe" else CURSOR_ARROW
		queue_redraw()
## Swipe: where the line is, as a share of the width; onion: how much After shows.
var amount := 0.5:
	set(value):
		amount = clampf(value, 0.0, 1.0)
		queue_redraw()
var _checker: ImageTexture


func _init() -> void:
	clip_contents = true
	size_flags_horizontal = SIZE_EXPAND_FILL
	size_flags_vertical = SIZE_EXPAND_FILL
	mouse_default_cursor_shape = CURSOR_HSIZE
	var image := Image.create(CHECKER_CELL * 2, CHECKER_CELL * 2, false, Image.FORMAT_RGB8)
	image.fill(Color(0.6, 0.6, 0.6))
	image.fill_rect(Rect2i(0, 0, CHECKER_CELL, CHECKER_CELL), Color(0.4, 0.4, 0.4))
	image.fill_rect(Rect2i(CHECKER_CELL, CHECKER_CELL, CHECKER_CELL, CHECKER_CELL), Color(0.4, 0.4, 0.4))
	_checker = ImageTexture.create_from_image(image)


## Where each texture goes: one scale for both (the bigger one fits), each centered.
func layout() -> Dictionary:
	var biggest := Vector2.ONE
	for texture in [old_texture, new_texture]:
		if texture != null:
			biggest = biggest.max(texture.get_size())
	var scale := minf(size.x / biggest.x, size.y / biggest.y)
	var rects := {}
	for key in ["old", "new"]:
		var texture: Texture2D = old_texture if key == "old" else new_texture
		if texture != null:
			var fitted := texture.get_size() * scale
			rects[key] = Rect2((size - fitted) / 2.0, fitted)
	return rects


func _draw() -> void:
	var rects := layout()
	var area := Rect2()
	for key in rects:
		area = rects[key] if not area.has_area() else area.merge(rects[key])
	if not area.has_area():
		return
	draw_texture_rect(_checker, area, true) # shows through transparent pixels
	if mode == "onion":
		if rects.has("old"):
			draw_texture_rect(old_texture, rects["old"], false)
		if rects.has("new"):
			draw_texture_rect(new_texture, rects["new"], false, Color(1, 1, 1, amount))
		return
	var line := size.x * amount
	if rects.has("new"):
		_draw_part(new_texture, rects["new"], line, size.x)
	if rects.has("old"):
		_draw_part(old_texture, rects["old"], 0.0, line)
	draw_line(Vector2(line, 0), Vector2(line, size.y), Color(1, 1, 1, 0.9), 2.0)


## The part of texture drawn at rect that lies between x from and to.
func _draw_part(texture: Texture2D, rect: Rect2, from: float, to: float) -> void:
	var left := maxf(rect.position.x, from)
	var right := minf(rect.end.x, to)
	if right <= left:
		return
	var source_x := (left - rect.position.x) / rect.size.x * texture.get_width()
	var source_width := (right - left) / rect.size.x * texture.get_width()
	draw_texture_rect_region(texture, Rect2(left, rect.position.y, right - left, rect.size.y), Rect2(source_x, 0, source_width, texture.get_height()))


func _gui_input(event: InputEvent) -> void:
	if mode != "swipe":
		return
	var button := event as InputEventMouseButton
	var motion := event as InputEventMouseMotion
	if (button != null and button.pressed and button.button_index == MOUSE_BUTTON_LEFT) or (motion != null and motion.button_mask & MOUSE_BUTTON_MASK_LEFT):
		amount = event.position.x / maxf(size.x, 1.0)
		accept_event()
