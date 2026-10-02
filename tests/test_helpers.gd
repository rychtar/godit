extends "res://tests/assertions.gd"

const CompanionFiles = preload("res://addons/godit/util/companion_files.gd")
const GitStatusFlags = preload("res://addons/godit/util/git_status_flags.gd")
const GitIcons = preload("res://addons/godit/util/git_icons.gd")
const SyntaxColors = preload("res://addons/godit/util/syntax_colors.gd")
const BlameGutter = preload("res://addons/godit/dock/gutter/blame_gutter.gd")
const DiffGutter = preload("res://addons/godit/dock/gutter/diff_gutter.gd")

func test_owner_of_a_sidecar() -> void:
	check("uid", CompanionFiles.owner_of("scripts/player.gd.uid"), "scripts/player.gd")
	check("import", CompanionFiles.owner_of("icon.svg.import"), "icon.svg")
	check("a normal file", CompanionFiles.owner_of("player.gd"), "")
	check("a file named like the suffix", CompanionFiles.owner_of("dir/.uid"), "")

func test_with_companions() -> void:
	var changed := { "a.gd": true, "a.gd.uid": true, "b.png.import": true }
	check("sidecars follow, in order, no duplicates", CompanionFiles.with_companions(["a.gd", "b.png", "a.gd"], changed), ["a.gd", "a.gd.uid", "b.png", "b.png.import"])

func test_status_flags() -> void:
	check("staged", GitStatusFlags.is_staged(GitStatusFlags.INDEX_MODIFIED), true)
	check("unstaged", GitStatusFlags.is_unstaged(GitStatusFlags.WT_MODIFIED), true)
	check("untracked isn't unstaged", GitStatusFlags.is_unstaged(GitStatusFlags.WT_NEW), false)
	check("untracked", GitStatusFlags.is_untracked(GitStatusFlags.WT_NEW), true)
	check("label", GitStatusFlags.short_label(GitStatusFlags.INDEX_NEW), "Added")
	check("letter", GitIcons.status_letter(GitStatusFlags.WT_DELETED), "D")
	check("letter of a rename", GitIcons.status_letter(GitStatusFlags.INDEX_RENAMED), "R")
	check("delta letter", GitIcons.delta_letter(GitIcons.DELTA_COPIED), "C")

func test_syntax_spans() -> void:
	check("languages", [SyntaxColors.language_for("a.gd"), SyntaxColors.language_for("a.tscn"), SyntaxColors.language_for("a.png")], ["gdscript", "ini", ""])
	var spans := SyntaxColors.spans("var x = 1 # c", "gdscript")
	var found := spans.map(func(s: Array) -> Array: return [s[0], s[1]])
	check_true("keyword", found.has([0, 3]))
	check_true("number", found.has([8, 1]))
	check_true("comment", found.has([10, 3]))
	check("nothing to color", SyntaxColors.spans("", "gdscript"), [])

func test_blame_age() -> void:
	var now := int(Time.get_unix_time_from_system())
	check("recent", BlameGutter.relative_age(now - 60), "now")
	check("hours", BlameGutter.relative_age(now - 5 * 3600), "5h")
	check("days", BlameGutter.relative_age(now - 3 * 86400), "3d")
	check("weeks", BlameGutter.relative_age(now - 21 * 86400), "3w")
	check("years", BlameGutter.relative_age(now - 800 * 86400), "2y")

func test_gutter_flags_and_text_normalizing() -> void:
	var regions := [
		{ "old_start": 2, "old_count": 1, "new_start": 2, "new_count": 1 },
		{ "old_start": 5, "old_count": 0, "new_start": 6, "new_count": 2 },
		{ "old_start": 8, "old_count": 2, "new_start": 9, "new_count": 0 },
		{ "old_start": 1, "old_count": 1, "new_start": 0, "new_count": 0 },
	]
	var flags := DiffGutter._flags_for(regions)
	check("modified", flags[2].type, "modified")
	check("added", [flags[6].type, flags[7].type], ["added", "added"])
	check("deleted after a line", flags[9].type, "deleted_after")
	check("deleted at the top", flags[1].type, "deleted_before")
	check("CRLF and a missing final newline", DiffGutter._normalized("a\r\nb"), "a\nb\n")
	check("empty", DiffGutter._normalized(""), "")
