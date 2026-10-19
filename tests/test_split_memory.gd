extends "res://tests/assertions.gd"

# Only keys that are never saved: a test must not write into the project's user:// settings.

const SplitMemory = preload("res://addons/godit/util/split_memory.gd")

func _split(vertical := false) -> SplitContainer:
	var split: SplitContainer = track(VSplitContainer.new() if vertical else HSplitContainer.new())
	for i in 2:
		var side := Control.new()
		side.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		side.size_flags_vertical = Control.SIZE_EXPAND_FILL
		split.add_child(side)
	tree.root.add_child(split)
	return split

func test_ratio_follows_resizes_until_dragged() -> void:
	var split := _split()
	split.size = Vector2(1000, 300)
	SplitMemory.keep_ratio(split, "test_never_saved", 0.4)
	check("40% of 1000 px, counted from the middle", split.split_offset, -100)
	split.size = Vector2(500, 300)
	check("still 40% after a resize", split.split_offset, -50)

func test_vertical_split_uses_the_height() -> void:
	var split := _split(true)
	split.size = Vector2(300, 800)
	SplitMemory.keep_ratio(split, "test_never_saved", 0.75)
	check("75% of 800 px", split.split_offset, 200)

func test_without_a_default_the_scene_offset_stays() -> void:
	var split := _split()
	split.split_offset = 40
	split.size = Vector2(1000, 300)
	SplitMemory.keep_ratio(split, "test_never_saved")
	check("untouched", split.split_offset, 40)
