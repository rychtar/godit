extends "res://tests/assertions.gd"

const DiffHunks = preload("res://addons/godit/util/diff_hunks.gd")

const DIFF := "diff --git a/f.gd b/f.gd\nindex 1..2 100644\n--- a/f.gd\n+++ b/f.gd\n@@ -1,3 +1,3 @@\n a\n-b\n+B\n c\n@@ -10,2 +10,3 @@\n x\n+y\n z\n"

func test_split_hunks() -> void:
	var split := DiffHunks.split_hunks(DIFF)
	check("file header", split.file_header, "diff --git a/f.gd b/f.gd\nindex 1..2 100644\n--- a/f.gd\n+++ b/f.gd")
	check("two hunks", split.hunks.size(), 2)
	check("hunk header", split.hunks[0].header, "@@ -1,3 +1,3 @@")
	check("hunk lines", Array(split.hunks[0].lines), [" a", "-b", "+B", " c"])
	check("the last hunk loses the trailing newline's empty line", Array(split.hunks[1].lines), [" x", "+y", " z"])

func test_split_hunks_stops_at_a_second_file() -> void:
	var split := DiffHunks.split_hunks(DIFF + "diff --git a/g.gd b/g.gd\n--- a/g.gd\n+++ b/g.gd\n@@ -1 +1 @@\n-q\n+r\n")
	check("only the first file", split.hunks.size(), 2)

func test_parse_regions() -> void:
	var regions := DiffHunks.parse_regions("@@ -2 +2 @@\n-b\n+c\n@@ -5,0 +6,2 @@\n+x\n+y\n@@ -8,2 +9,0 @@\n-p\n-q\n")
	check("three regions", regions.size(), 3)
	check("modified", [regions[0].old_start, regions[0].old_count, regions[0].new_start, regions[0].new_count], [2, 1, 2, 1])
	check("old lines of a modification", Array(regions[0].old_lines), ["b"])
	check("added", [regions[1].old_count, regions[1].new_start, regions[1].new_count], [0, 6, 2])
	check("deleted", [regions[2].old_count, regions[2].new_count], [2, 0])
	check("deleted lines", Array(regions[2].old_lines), ["p", "q"])
	check("types", regions.map(DiffHunks.region_type), ["modified", "added", "deleted"])

func test_parse_regions_of_nothing() -> void:
	check("empty diff", DiffHunks.parse_regions("").size(), 0)

func test_build_patch_of_a_whole_hunk() -> void:
	var split := DiffHunks.split_hunks(DIFF)
	var patch := DiffHunks.build_patch(split.file_header, split.hunks[0], PackedInt32Array(), false)
	check("patch", patch, split.file_header + "\n@@ -1,3 +1,3 @@\n a\n-b\n+B\n c\n")

func test_build_patch_of_selected_lines() -> void:
	var split := DiffHunks.split_hunks(DIFF)
	# only the added line (index 2): the removal stays as context
	var staged := DiffHunks.build_patch(split.file_header, split.hunks[0], PackedInt32Array([2]), false)
	check("stage only +B", staged.get_slice("\n@@ -1,3 +1,3 @@\n", 1), " a\n b\n+B\n c\n")
	# only the removed line (index 1), reversed (unstage / revert): the addition stays as context
	var reverted := DiffHunks.build_patch(split.file_header, split.hunks[0], PackedInt32Array([1]), true)
	check("revert only -b", reverted.get_slice("\n@@ -1,3 +1,3 @@\n", 1), " a\n-b\n B\n c\n")

func test_build_patch_keeps_the_no_newline_marker_with_its_line() -> void:
	var hunk := { "header": "@@ -1 +1 @@", "lines": PackedStringArray(["-a", "\\ No newline at end of file", "+a"]) }
	var patch := DiffHunks.build_patch("--- a/f\n+++ b/f", hunk, PackedInt32Array([2]), false)
	check("marker follows the kept context line", patch.get_slice("@@ -1 +1 @@\n", 1), " a\n\\ No newline at end of file\n+a\n")
