extends "res://tests/assertions.gd"

const DiffHunks = preload("res://addons/godit/util/diff_hunks.gd")
const GitStatusFlags = preload("res://addons/godit/util/git_status_flags.gd")

func _stage_first_hunk(repo: GitCliRepo, path: String) -> Dictionary:
	var split := DiffHunks.split_hunks(repo.get_diff(path, false))
	return repo.apply_patch(DiffHunks.build_patch(split.file_header, split.hunks[0], PackedInt32Array(), false), true, false)

func test_parse_status() -> void:
	var repo := GitCliRepo.new()
	var entries := repo.parse_status("## main...origin/main [ahead 1]\n M a.gd\nR  old.gd -> new.gd\n?? \"my file.gd\"\nUU c.gd\nA  b.gd\nMM d.gd\n")
	check("header", repo.status_header, "## main...origin/main [ahead 1]")
	check("paths", entries.map(func(e: Dictionary) -> String: return e.path), ["a.gd", "new.gd", "my file.gd", "c.gd", "b.gd", "d.gd"])
	check("modified in the working tree", entries[0].status, GitStatusFlags.WT_MODIFIED)
	check("rename", [entries[1].status, entries[1].renamed_from], [GitStatusFlags.INDEX_RENAMED, "old.gd"])
	check("untracked", entries[2].status, GitStatusFlags.WT_NEW)
	check("conflict", entries[3].status & GitStatusFlags.CONFLICTED != 0, true)
	check("added", entries[4].status, GitStatusFlags.INDEX_NEW)
	check("partly staged", entries[5].status, GitStatusFlags.INDEX_MODIFIED | GitStatusFlags.WT_MODIFIED)

func test_status_of_a_file_named_with_an_arrow() -> void:
	var repo := make_repo()
	write_file(repo.get_repo_root().path_join("a -> b.txt"), "x\n")
	var entries := repo.get_status()
	check("one untracked file with that name", entries.map(func(e: Dictionary) -> String: return e.path), ["a -> b.txt"])
	check("it isn't a rename", entries[0].renamed_from, "")

func test_status_of_a_clean_repo_still_has_a_header() -> void:
	var repo := make_repo()
	check("no entries", repo.get_status().size(), 0)
	check_true("but the branch line is there", not repo.status_header.is_empty())

func test_the_root_keeps_the_spelling_it_was_opened_with() -> void:
	if OS.get_name() == "Windows":
		return
	var repo := make_repo()
	var link := OS.get_temp_dir().path_join("godit_test_link_%d" % OS.get_process_id())
	OS.execute("ln", ["-s", repo.get_repo_root(), link])
	var via_link := GitCliRepo.new()
	check("opened", via_link.open(link), true)
	check("root", via_link.get_repo_root(), link)
	DirAccess.make_dir_recursive_absolute(repo.get_repo_root().path_join("sub"))
	var via_sub := GitCliRepo.new()
	via_sub.open(link.path_join("sub"))
	check("root from a folder inside", via_sub.get_repo_root(), link)
	DirAccess.remove_absolute(link)

func test_stage_a_hunk_and_commit() -> void:
	var repo := make_repo()
	commit_file(repo, "f.gd", "a\nb\nc\n", "first")
	write_file(repo.get_repo_root().path_join("f.gd"), "a\nB\nc\n")
	check_contains("diff", repo.get_diff("f.gd", false), "+B")
	check("nothing staged yet", repo.has_staged_changes(), false)
	check("staged", _stage_first_hunk(repo, "f.gd").ok, true)
	check("staged now", repo.has_staged_changes(), true)
	check_contains("staged diff", repo.get_diff("f.gd", true), "+B")
	var result := repo.commit("second")
	check("committed", result.ok, true)
	check("oid", result.oid.length(), 40)
	check("head message", repo.get_head_info().message.strip_edges(), "second")

func test_unstage_selected_lines() -> void:
	var repo := make_repo()
	commit_file(repo, "f.gd", "a\nb\nc\nd\n", "first")
	write_file(repo.get_repo_root().path_join("f.gd"), "a\nB\nc\nD\n")
	git(repo.get_repo_root(), ["add", "f.gd"])
	var split := DiffHunks.split_hunks(repo.get_diff("f.gd", true))
	# the lines of the second change only (-d, +D)
	var lines: PackedStringArray = split.hunks[0].lines
	var selected := PackedInt32Array()
	for i in lines.size():
		if lines[i] == "-d" or lines[i] == "+D":
			selected.append(i)
	var patch := DiffHunks.build_patch(split.file_header, split.hunks[0], selected, true)
	check("unstaged", repo.apply_patch(patch, true, true).ok, true)
	check_contains("the first change stays staged", repo.get_diff("f.gd", true), "+B")
	check("the second is back in the working tree only", repo.get_diff("f.gd", true).contains("+D"), false)
	check_contains("unstaged", repo.get_diff("f.gd", false), "+D")

func test_hunks_stage_with_noprefix_in_the_users_config() -> void:
	var repo := make_repo()
	commit_file(repo, "scripts/f.gd", "a\nb\nc\n", "first")
	git(repo.get_repo_root(), ["config", "diff.noprefix", "true"])
	write_file(repo.get_repo_root().path_join("scripts/f.gd"), "a\nB\nc\n")
	check_contains("prefixes are fixed", repo.get_diff("scripts/f.gd", false), "--- a/scripts/f.gd")
	check("staged", _stage_first_hunk(repo, "scripts/f.gd").ok, true)
	git(repo.get_repo_root(), ["config", "diff.mnemonicPrefix", "true"])
	git(repo.get_repo_root(), ["config", "--unset", "diff.noprefix"])
	check_contains("also with mnemonic prefixes", repo.get_diff("scripts/f.gd", true), "--- a/scripts/f.gd")

func test_diffs_ignore_an_external_diff_tool() -> void:
	if OS.get_name() == "Windows":
		return
	var repo := make_repo()
	git(repo.get_repo_root(), ["config", "diff.external", "echo EXTERNAL"])
	var diff := repo.diff_texts("a\nb\n", "a\nc\n")
	check_contains("a unified diff", diff, "@@")
	check("not the tool's output", diff.contains("EXTERNAL"), false)
	commit_file(repo, "f.gd", "a\n", "first")
	write_file(repo.get_repo_root().path_join("f.gd"), "b\n")
	check("get_diff too", repo.get_diff("f.gd", false).contains("EXTERNAL"), false)

func test_head_text_for_the_gutter() -> void:
	var repo := make_repo()
	commit_file(repo, "a.gd", "committed\n", "first")
	write_file(repo.get_repo_root().path_join("a.gd"), "edited\n")
	check("a committed file", repo.get_head_text("a.gd"), "committed\n")
	write_file(repo.get_repo_root().path_join("new.gd"), "x\n")
	check("untracked: everything is new", repo.get_head_text("new.gd"), "")
	git(repo.get_repo_root(), ["add", "new.gd"])
	check("added to git: everything is new", repo.get_head_text("new.gd"), "")
	check("not in the repo at all", repo.get_head_text("nothing.gd"), null)

func test_reverting_a_staged_rename_brings_the_old_file_back() -> void:
	var repo := make_repo()
	commit_file(repo, "a.txt", "hello\n", "first")
	git(repo.get_repo_root(), ["mv", "a.txt", "b.txt"])
	check("it's a rename", repo.get_status()[0].renamed_from, "a.txt")
	check("reverted", repo.revert_file("b.txt").ok, true)
	check("the old file is back", read_file(repo.get_repo_root().path_join("a.txt")), "hello\n")
	check("the new one is gone", FileAccess.file_exists(repo.get_repo_root().path_join("b.txt")), false)
	check("clean", repo.get_status().size(), 0)

func test_reverting_a_new_file_deletes_it() -> void:
	var repo := make_repo()
	commit_file(repo, "a.txt", "x\n", "first")
	write_file(repo.get_repo_root().path_join("new.txt"), "n\n")
	git(repo.get_repo_root(), ["add", "new.txt"])
	check("reverted", repo.revert_file("new.txt").ok, true)
	check("deleted", FileAccess.file_exists(repo.get_repo_root().path_join("new.txt")), false)
	check("clean", repo.get_status().size(), 0)

func test_reverting_a_modified_file() -> void:
	var repo := make_repo()
	commit_file(repo, "a.txt", "x\n", "first")
	write_file(repo.get_repo_root().path_join("a.txt"), "changed\n")
	check("reverted", repo.revert_file("a.txt").ok, true)
	check("content", read_file(repo.get_repo_root().path_join("a.txt")), "x\n")

func test_stage_and_unstage() -> void:
	var repo := make_repo()
	commit_file(repo, "a.txt", "x\n", "first")
	write_file(repo.get_repo_root().path_join("a.txt"), "y\n")
	check("stage", repo.stage_file("a.txt"), true)
	check("staged", GitStatusFlags.is_staged(repo.get_status()[0].status), true)
	check("unstage", repo.unstage_file("a.txt"), true)
	check("unstaged", GitStatusFlags.is_staged(repo.get_status()[0].status), false)

func test_branches() -> void:
	var repo := make_repo()
	commit_file(repo, "a.txt", "x\n", "first")
	check("current branch", repo.get_current_branch(), "main")
	check("create and switch", repo.create_branch("feature/x", "", true).ok, true)
	check("on it", repo.get_current_branch(), "feature/x")
	var branches := repo.list_branches()
	check("both listed", branches.map(func(b: Dictionary) -> String: return b.name), ["feature/x", "main"])
	check("the current one is marked", branches.filter(func(b: Dictionary) -> bool: return b.is_head).map(func(b: Dictionary) -> String: return b.name), ["feature/x"])
	check("rename", repo.rename_branch("feature/x", "feature/y").ok, true)
	check("can't delete the current branch", repo.delete_branch("feature/y").ok, false)
	repo.checkout_branch("main")
	check("delete", repo.delete_branch("feature/y").ok, true)
	check("one left", repo.list_branches().size(), 1)

func test_tags() -> void:
	var repo := make_repo()
	commit_file(repo, "a.txt", "x\n", "first")
	check("lightweight", repo.create_tag("v1", "").ok, true)
	check("annotated", repo.create_tag("v2", "", "release").ok, true)
	var tags := repo.list_tags()
	check("names", tags.map(func(t: Dictionary) -> String: return t.name).size(), 2)
	for tag in tags:
		check("annotated flag of " + tag.name, tag.annotated, tag.name == "v2")
	check("delete", repo.delete_tag("v1").ok, true)
	check("one left", repo.list_tags().size(), 1)

func test_a_merge_conflict_can_be_resolved_or_aborted() -> void:
	var repo := make_repo()
	var root := repo.get_repo_root()
	commit_file(repo, "f.txt", "base\n", "base")
	repo.create_branch("other", "", true)
	commit_file(repo, "f.txt", "theirs\n", "theirs")
	repo.checkout_branch("main")
	commit_file(repo, "f.txt", "ours\n", "ours")
	var merged := repo.merge("other")
	check("stopped on conflicts", merged.conflicts, true)
	check("merge in progress", repo.get_operation_state().kind, "merge")
	check("the conflicting file", Array(repo.list_conflicts()), ["f.txt"])
	check_true("markers in the file", repo.has_conflict_markers("f.txt"))
	check("abort", repo.abort_operation().ok, true)
	check("back to ours", read_file(root.path_join("f.txt")), "ours\n")
	check("nothing in progress", repo.get_operation_state().kind, "")
	repo.merge("other")
	check("take theirs", repo.resolve_conflict("f.txt", "theirs").ok, true)
	check("no markers", repo.has_conflict_markers("f.txt"), false)
	check("continue", repo.continue_operation().ok, true)
	check("theirs won", read_file(root.path_join("f.txt")), "theirs\n")
	check("a merge commit", repo.has_parent("HEAD") and repo.get_commit_graph(1)[0].parents.size() == 2, true)

func test_cherry_pick_and_revert() -> void:
	var repo := make_repo()
	commit_file(repo, "a.txt", "1\n", "first")
	repo.create_branch("other", "", true)
	commit_file(repo, "b.txt", "b\n", "add b")
	var picked := repo.get_head_oid()
	repo.checkout_branch("main")
	check("cherry-pick", repo.cherry_pick(PackedStringArray([picked])).ok, true)
	check("file arrived", FileAccess.file_exists(repo.get_repo_root().path_join("b.txt")), true)
	check("revert", repo.revert_commit(repo.get_head_oid()).ok, true)
	check("file is gone", FileAccess.file_exists(repo.get_repo_root().path_join("b.txt")), false)
	check_contains("revert commit message", head_subjects(repo)[0], "Revert")

func test_commit_graph_and_history_filter() -> void:
	var repo := make_repo()
	commit_file(repo, "a.txt", "1\n", "one")
	commit_file(repo, "b.txt", "1\n", "two")
	commit_file(repo, "a.txt", "2\n", "three")
	var all := repo.get_commit_graph(10)
	check("newest first", all.map(func(c: Dictionary) -> String: return c.summary), ["three", "two", "one"])
	check("parent link", all[0].parents[0], all[1].oid)
	check("only a.txt", repo.get_commit_graph(10, { "path": "a.txt" }).map(func(c: Dictionary) -> String: return c.summary), ["three", "one"])
	check("paging", repo.get_commit_graph(1, { "skip": 1 })[0].summary, "two")
	check("files of a commit", repo.get_commit_files(all[1].oid).map(func(f: Dictionary) -> String: return f.path), ["b.txt"])

func test_undo_the_last_commit() -> void:
	var repo := make_repo()
	commit_file(repo, "a.txt", "1\n", "one")
	commit_file(repo, "a.txt", "2\n", "two")
	var op := repo.last_head_operation()
	check("what can be undone", op.mode, "soft")
	check_contains("label", op.label, "two")
	check("undo", repo.undo_head_operation(op).ok, true)
	check("history", head_subjects(repo), ["one"])
	check("the change is still staged", repo.has_staged_changes(), true)

func test_an_unborn_branch_has_nothing_to_compare() -> void:
	var repo := make_repo()
	check("no head", repo.get_head_oid(), "")
	check("no head info", repo.get_head_info(), {})
	check("no commits", repo.get_commit_graph(5).size(), 0)
	check("nothing to undo", repo.last_head_operation(), {})

func test_blame() -> void:
	var repo := make_repo()
	commit_file(repo, "a.gd", "one\ntwo\n", "first")
	var blamed = await repo.blame("a.gd", "one\nCHANGED\nthree\n")
	check("a line per line", blamed.size(), 3)
	check("committed line", blamed[0].oid.length(), 40)
	check("author", blamed[0].author, "Test")
	check("summary", blamed[0].summary, "first")
	check("changed line is not committed", blamed[1].oid, "")
	check("so is a new one", blamed[2].oid, "")

func test_search_commits() -> void:
	var repo := make_repo()
	commit_file(repo, "a.txt", "1\n", "fix(parser): the thing")
	commit_file(repo, "a.txt", "2\n", "add something")
	var by_message = await repo.search_commits("fix(", "message", 10)
	check("a plain-text message search", by_message.map(func(c: Dictionary) -> String: return c.summary), ["fix(parser): the thing"])
	var by_author = await repo.search_commits("test@example", "author", 10)
	check("by author", by_author.size(), 2)
	var by_code = await repo.search_commits("2", "code", 10)
	check("by the code a commit added", by_code.map(func(c: Dictionary) -> String: return c.summary), ["add something"])
	var by_hash = await repo.search_commits(repo.get_head_oid().substr(0, 8), "message", 10)
	check("by hash", by_hash[0].oid, repo.get_head_oid())
