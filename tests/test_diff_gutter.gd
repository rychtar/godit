extends "res://tests/assertions.gd"

# Next and Previous Change in the script editor: which change the caret goes to (the caret itself needs the editor).

const DiffGutter = preload("res://addons/godit/dock/gutter/diff_gutter.gd")

# lines 3-4 changed, line 10 added, lines deleted after line 20 (1-based, as parse_regions() gives them)
const REGIONS := [{"new_start": 3, "new_count": 2}, {"new_start": 10, "new_count": 1}, {"new_start": 20, "new_count": 0}]

func test_next_change_is_the_first_below_the_caret() -> void:
	check("from the top", DiffGutter.change_index(REGIONS, 0, 1), 0)
	check("from inside a change", DiffGutter.change_index(REGIONS, 3, 1), 1)
	check("on the last one it wraps around", DiffGutter.change_index(REGIONS, 19, 1), 0)

func test_previous_change_is_the_last_above_the_caret() -> void:
	check("from below the last", DiffGutter.change_index(REGIONS, 30, -1), 2)
	check("from a change's first line", DiffGutter.change_index(REGIONS, 9, -1), 0)
	check("from inside a change: its start", DiffGutter.change_index(REGIONS, 3, -1), 0)
	check("on the first one it wraps around", DiffGutter.change_index(REGIONS, 2, -1), 2)
