extends "res://tests/assertions.gd"

const CommitGraph = preload("res://addons/godit/dock/widgets/commit_graph.gd")

func _commit(oid: String, parents: Array) -> Dictionary:
	return { "oid": oid, "parents": PackedStringArray(parents) }

func test_a_straight_history_stays_in_one_lane() -> void:
	var rows := CommitGraph.compute_layout([_commit("c3", ["c2"]), _commit("c2", ["c1"]), _commit("c1", [])])
	check("lanes", rows.map(func(r: Dictionary) -> int: return r.lane), [0, 0, 0])
	check("rows", rows.map(func(r: Dictionary) -> int: return r.row), [0, 1, 2])

func test_a_merge_uses_a_second_lane_until_it_joins() -> void:
	var rows := CommitGraph.compute_layout([
		_commit("m", ["a", "b"]), _commit("a", ["base"]), _commit("b", ["base"]), _commit("base", []),
	])
	check("lanes", rows.map(func(r: Dictionary) -> int: return r.lane), [0, 0, 1, 0])

func test_the_lane_of_a_finished_branch_is_reused() -> void:
	var rows := CommitGraph.compute_layout([
		_commit("m", ["a", "b"]), _commit("b", ["base"]), _commit("a", ["base"]), _commit("base", ["x"]), _commit("x", []),
	])
	check("lanes", rows.map(func(r: Dictionary) -> int: return r.lane), [0, 1, 0, 0, 0])

func test_relative_time() -> void:
	var now := 1000000
	check("seconds", CommitGraph.format_relative_time(now - 30, now), "just now")
	check("minutes", CommitGraph.format_relative_time(now - 5 * 60, now), "5 minutes ago")
	check("one hour", CommitGraph.format_relative_time(now - 3600, now), "1 hour ago")
	check("days", CommitGraph.format_relative_time(now - 3 * 86400, now), "3 days ago")
	check("the future", CommitGraph.format_relative_time(now + 100, now), "just now")
	check("older than a week", CommitGraph.format_relative_time(0, now), "01.01.1970, 00:00")

func test_badge_labels() -> void:
	check("two names", CommitGraph._badge_label(PackedStringArray(["main", "dev"])), "main & dev")
	check("many names", CommitGraph._badge_label(PackedStringArray(["main", "dev", "x", "y"])), "main +3")
