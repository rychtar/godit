extends "res://tests/assertions.gd"

const ConflictResolver = preload("res://addons/godit/dock/widgets/conflict_resolver.gd")

func test_parse() -> void:
	var segments := ConflictResolver.parse("x\n<<<<<<< HEAD\nours 1\nours 2\n=======\ntheirs\n>>>>>>> feature\ny\n")
	check("three segments", segments.size(), 3)
	check("text before", Array(segments[0].text), ["x"])
	check("ours", Array(segments[1].ours), ["ours 1", "ours 2"])
	check("theirs", Array(segments[1].theirs), ["theirs"])
	check("labels", [segments[1].ours_label, segments[1].theirs_label], ["HEAD", "feature"])
	check("text after", Array(segments[2].text), ["y", ""])

func test_parse_with_a_diff3_base() -> void:
	var segments := ConflictResolver.parse("<<<<<<< HEAD\nours\n||||||| base\noriginal\n=======\ntheirs\n>>>>>>> other\n")
	check("base", Array(segments[0].base), ["original"])
	check("ours", Array(segments[0].ours), ["ours"])

func test_parse_keeps_an_unterminated_block_as_text() -> void:
	var segments := ConflictResolver.parse("a\n<<<<<<< HEAD\nours\n=======\ntheirs\n")
	check("no conflict segment", segments.filter(func(s: Dictionary) -> bool: return s.has("ours")).size(), 0)

func test_parse_two_conflicts() -> void:
	var segments := ConflictResolver.parse("<<<<<<< a\n1\n=======\n2\n>>>>>>> b\nmiddle\n<<<<<<< a\n3\n=======\n4\n>>>>>>> b\n")
	check("conflicts", segments.filter(func(s: Dictionary) -> bool: return s.has("ours")).size(), 2)

func _compose(text: String, choice: String) -> String:
	var resolver: ConflictResolver = track(ConflictResolver.new())
	resolver._segments = ConflictResolver.parse(text)
	resolver._status_label = track(Label.new())
	for i in resolver._segments.size():
		if resolver._segments[i].has("ours"):
			var result: CodeEdit = track(CodeEdit.new())
			result.text = "<<<<<<< placeholder"
			resolver._results[i] = result
			resolver._apply_choice(i, choice)
	return resolver._compose()

func test_choosing_a_side() -> void:
	var text := "x\n<<<<<<< HEAD\nmine\n=======\ntheirs\n>>>>>>> br\ny\n"
	check("ours", _compose(text, "ours"), "x\nmine\ny\n")
	check("theirs", _compose(text, "theirs"), "x\ntheirs\ny\n")
	check("both", _compose(text, "ours_theirs"), "x\nmine\ntheirs\ny\n")
	check("both, the other way", _compose(text, "theirs_ours"), "x\ntheirs\nmine\ny\n")

func test_an_empty_side_removes_the_lines_a_blank_one_keeps_its_line() -> void:
	check("empty ours", _compose("x\n<<<<<<< HEAD\n=======\ntheirs\n>>>>>>> br\ny\n", "ours"), "x\ny\n")
	check("empty theirs", _compose("x\n<<<<<<< HEAD\nmine\n=======\n>>>>>>> br\ny\n", "theirs"), "x\ny\n")
	check("a blank line stays", _compose("x\n<<<<<<< HEAD\n\n=======\ntheirs\n>>>>>>> br\ny\n", "ours"), "x\n\ny\n")

func test_crlf_files_stay_crlf() -> void:
	var resolver: ConflictResolver = track(ConflictResolver.new())
	var dir := make_temp_dir()
	write_file(dir.path_join("f.txt"), "x\r\n<<<<<<< HEAD\r\nmine\r\n=======\r\ntheirs\r\n>>>>>>> br\r\ny\r\n")
	var repo := GitCliRepo.new()
	repo._repo_root = dir
	# open() builds the dialog; only the parsing and line-ending detection matter here
	resolver._repo = repo
	resolver._crlf = read_file(dir.path_join("f.txt")).contains("\r\n")
	resolver._segments = ConflictResolver.parse(read_file(dir.path_join("f.txt")).replace("\r\n", "\n"))
	resolver._status_label = track(Label.new())
	for i in resolver._segments.size():
		if resolver._segments[i].has("ours"):
			var result: CodeEdit = track(CodeEdit.new())
			resolver._results[i] = result
			resolver._apply_choice(i, "ours")
	check("composed with CRLF", resolver._compose(), "x\r\nmine\r\ny\r\n")
