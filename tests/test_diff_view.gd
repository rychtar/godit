extends "res://tests/assertions.gd"

const DiffView = preload("res://addons/godit/dock/widgets/diff_view.gd")

const DIFF := "diff --git a/scripts/f.gd b/scripts/f.gd\nindex 1..2 100644\n--- a/scripts/f.gd\n+++ b/scripts/f.gd\n@@ -1,4 +1,4 @@ func heading\n a\n-b old\n+b new\n c\n-d\n+D\n@@ -20,2 +20,3 @@\n x\n+added\n z\n"

func test_parse_rows_and_stats() -> void:
	var parsed := DiffView._parse(DIFF, true)
	check("path without the a/ prefix", parsed.path, "scripts/f.gd")
	check("stats", [parsed.added, parsed.removed], [3, 2])
	var types: Array = parsed.rows.map(func(r: Dictionary) -> String: return r.type)
	check("rows", types, ["hunk", "context", "removed", "added", "context", "removed", "added", "hunk", "context", "added", "context"])
	check("hunk heading", parsed.rows[0].heading, "func heading")
	check("the gap between hunks", parsed.rows[7].gap, 15)

func test_line_numbers_follow_both_sides() -> void:
	var parsed := DiffView._parse(DIFF, true)
	var removed: Dictionary = parsed.rows[2]
	var added: Dictionary = parsed.rows[3]
	check("a removed line has only an old number", [removed.old_no, removed.new_no], [2, -1])
	check("an added line has only a new number", [added.old_no, added.new_no], [-1, 2])
	check("context has both", [parsed.rows[4].old_no, parsed.rows[4].new_no], [3, 3])

func test_line_indices_match_the_hunks_for_partial_staging() -> void:
	var parsed := DiffView._parse(DIFF, true)
	check("li of the first removed line", parsed.rows[2].li, 1)
	check("li of the added line", parsed.rows[3].li, 2)
	check("a modified pair knows its other half", [parsed.rows[2].pair_li, parsed.rows[3].pair_li], [2, 1])

func test_new_deleted_and_binary_files() -> void:
	check("new", DiffView._parse("diff --git a/n b/n\nnew file mode 100644\n--- /dev/null\n+++ b/n\n@@ -0,0 +1 @@\n+x\n", true).is_new, true)
	check("deleted", DiffView._parse("diff --git a/n b/n\ndeleted file mode 100644\n--- a/n\n+++ /dev/null\n@@ -1 +0,0 @@\n-x\n", true).is_deleted, true)
	var binary := DiffView._parse("diff --git a/i.png b/i.png\nBinary files a/i.png and b/i.png differ\n", true)
	check("binary", [binary.binary, binary.rows.size()], [true, 0])
	check("nothing", DiffView._parse("", true).rows.size(), 0)

func test_godot_noise_is_dimmed() -> void:
	var diff := "--- a/s.tscn\n+++ b/s.tscn\n@@ -1 +1 @@\n-[gd_scene load_steps=2 format=3 uid=\"uid://aaa\"]\n+[gd_scene load_steps=3 format=3 uid=\"uid://bbb\"]\n"
	check("dimmed", DiffView._parse(diff, true).rows.map(func(r: Dictionary) -> String: return r.type).slice(1), ["noise", "noise"])
	check("shown as a normal change without the option", DiffView._parse(diff, false).rows.map(func(r: Dictionary) -> String: return r.type).slice(1), ["removed", "added"])

func test_word_diff() -> void:
	var ranges := DiffView._word_diff("var speed = 10", "var speed = 25")
	check("old side", ranges[0], [Vector2i(12, 2)])
	check("new side", ranges[1], [Vector2i(12, 2)])
	check("a line that changed almost entirely gets no highlight", DiffView._word_diff("abc", "xyz"), [[], []])

func test_tokenize_and_prefix_suffix_diff() -> void:
	check("tokens", Array(DiffView._tokenize("a_b  c(1)")), ["a_b", "  ", "c", "(", "1", ")"])
	check("prefix and suffix", DiffView._prefix_suffix_diff("hello world", "hello brave world"), [[], [Vector2i(6, 6)]])
