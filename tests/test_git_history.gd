extends "res://tests/assertions.gd"

# history rewriting: the commit is picked by its subject

func _oid(repo: GitCliRepo, subject: String) -> String:
	return git(repo.get_repo_root(), ["log", "--format=%H", "--grep=^%s$" % subject])

func _linear() -> GitCliRepo:
	var repo := make_repo()
	commit_file(repo, "a.txt", "1\n", "c1")
	commit_file(repo, "a.txt", "2\n", "c2")
	commit_file(repo, "a.txt", "3\n", "c3")
	return repo

# main with a merge commit after c2
func _with_a_merge() -> GitCliRepo:
	var repo := make_repo()
	commit_file(repo, "a.txt", "1\n", "c1")
	commit_file(repo, "a.txt", "2\n", "c2")
	repo.create_branch("side", "", true)
	commit_file(repo, "s.txt", "s\n", "side1")
	repo.checkout_branch("main")
	commit_file(repo, "a.txt", "3\n", "c3")
	git(repo.get_repo_root(), ["merge", "-q", "--no-ff", "side", "-m", "merge-side"])
	commit_file(repo, "a.txt", "4\n", "c4")
	return repo

func test_reword_an_older_commit() -> void:
	var repo := _linear()
	check("reworded", repo.reword_commit(_oid(repo, "c2"), "c2 reworded").ok, true)
	check("history", head_subjects(repo), ["c3", "c2 reworded", "c1"])
	check("content untouched", read_file(repo.get_repo_root().path_join("a.txt")), "3\n")

func test_reword_the_head_commit() -> void:
	var repo := _linear()
	check("reworded", repo.reword_commit(repo.get_head_oid(), "c3 reworded").ok, true)
	check("history", head_subjects(repo), ["c3 reworded", "c2", "c1"])

func test_reword_refuses_when_a_merge_follows() -> void:
	var repo := _with_a_merge()
	var before := repo.get_head_oid()
	var result := repo.reword_commit(_oid(repo, "c2"), "x")
	check("refused", result.ok, false)
	check_contains("why", result.error, "merge")
	check("history untouched", repo.get_head_oid(), before)

func test_edit_an_older_commit_with_staged_changes() -> void:
	var repo := _linear()
	commit_file(repo, "c.txt", "c\n", "c2") # a second "c2" after the one edited
	write_file(repo.get_repo_root().path_join("b.txt"), "b\n")
	git(repo.get_repo_root(), ["add", "b.txt"])
	var target: String = Array(_oid(repo, "c2").split("\n")).back() # the older one
	check("edited", repo.edit_commit(target, "c2 edited\n\nwith b").ok, true)
	check("history", head_subjects(repo), ["c2", "c3", "c2 edited", "c1"])
	var edited := git(repo.get_repo_root(), ["log", "--format=%H", "--grep=c2 edited"])
	check("the file is in the edited commit", git(repo.get_repo_root(), ["show", "--name-only", "--format=", edited]).contains("b.txt"), true)
	check("its body", git(repo.get_repo_root(), ["log", "-1", "--format=%b", edited]), "with b")
	check("nothing left staged", repo.has_staged_changes(), false)

func test_edit_without_staged_changes_only_rewords() -> void:
	var repo := _linear()
	check("edited", repo.edit_commit(_oid(repo, "c2"), "c2 reworded").ok, true)
	check("history", head_subjects(repo), ["c3", "c2 reworded", "c1"])

func test_edit_the_head_commit_with_staged_changes() -> void:
	var repo := _linear()
	write_file(repo.get_repo_root().path_join("b.txt"), "b\n")
	git(repo.get_repo_root(), ["add", "b.txt"])
	check("edited", repo.edit_commit(repo.get_head_oid(), "c3 edited").ok, true)
	check("history", head_subjects(repo), ["c3 edited", "c2", "c1"])
	check("the file is in it", git(repo.get_repo_root(), ["show", "--name-only", "--format=", "HEAD"]).contains("b.txt"), true)

func test_edit_with_the_same_message_folds_staged_changes_in() -> void:
	var repo := _linear()
	write_file(repo.get_repo_root().path_join("b.txt"), "b\n")
	git(repo.get_repo_root(), ["add", "b.txt"])
	check("folded", repo.edit_commit(_oid(repo, "c2"), "c2").ok, true)
	check("history", head_subjects(repo), ["c3", "c2", "c1"])
	check("the file is in c2 now", git(repo.get_repo_root(), ["show", "--name-only", "--format=", _oid(repo, "c2")]).contains("b.txt"), true)
	check("working tree is clean", repo.get_status().size(), 0)

func test_edit_refuses_when_a_merge_follows() -> void:
	var merged := _with_a_merge()
	write_file(merged.get_repo_root().path_join("b.txt"), "b\n")
	git(merged.get_repo_root(), ["add", "b.txt"])
	var result := merged.edit_commit(_oid(merged, "c2"), "x")
	check("refused", result.ok, false)
	check_contains("why", result.error, "merge")

func test_squash_to_head() -> void:
	var repo := _linear()
	check("squashed", repo.squash_to_head(_oid(repo, "c2"), "c2 and c3").ok, true)
	check("history", head_subjects(repo), ["c2 and c3", "c1"])
	check("content", read_file(repo.get_repo_root().path_join("a.txt")), "3\n")
	check("messages for the prefill", repo.get_messages_since(repo.get_head_oid()), "c2 and c3")

func test_squash_refuses_the_first_commit_and_staged_changes() -> void:
	var repo := _linear()
	check("the first commit", repo.squash_to_head(_oid(repo, "c1"), "x").ok, false)
	write_file(repo.get_repo_root().path_join("b.txt"), "b\n")
	git(repo.get_repo_root(), ["add", "b.txt"])
	check("staged changes", repo.squash_to_head(_oid(repo, "c2"), "x").ok, false)

func test_drop_a_commit() -> void:
	var repo := make_repo()
	commit_file(repo, "a.txt", "1\n", "c1")
	commit_file(repo, "b.txt", "b\n", "c2")
	commit_file(repo, "c.txt", "c\n", "c3")
	check("dropped", repo.drop_commit(_oid(repo, "c2")).ok, true)
	check("history", head_subjects(repo), ["c3", "c1"])
	check("its file is gone", FileAccess.file_exists(repo.get_repo_root().path_join("b.txt")), false)
	check("the later one stays", FileAccess.file_exists(repo.get_repo_root().path_join("c.txt")), true)

func test_merges_since_and_ancestors() -> void:
	var repo := _with_a_merge()
	check("a merge after c2", repo.has_merges_since(_oid(repo, "c2")), true)
	check("none after c4", repo.has_merges_since(repo.get_head_oid()), false)
	check("c2 is in head's history", repo.is_ancestor_of_head(_oid(repo, "c2")), true)
	check("branches containing", Array(repo.branches_containing(_oid(repo, "c1"))).has("side"), true)

func test_undo_a_merge_with_keep() -> void:
	var repo := _with_a_merge()
	git(repo.get_repo_root(), ["reset", "-q", "--hard", _oid(repo, "merge-side")])
	var op := repo.last_head_operation()
	check("something to undo", op.is_empty(), false)
	check("undone", repo.undo_head_operation(op).ok, true)

# c1..c4, each adding its own file, so any order replays cleanly
func _four_files() -> GitCliRepo:
	var repo := make_repo()
	for i in range(1, 5):
		commit_file(repo, "f%d.txt" % i, "%d\n" % i, "c%d" % i)
	return repo

func _step(repo: GitCliRepo, action: String, subject: String, message := "") -> Dictionary:
	return { "action": action, "oid": _oid(repo, subject), "message": message }

func test_commits_since() -> void:
	var repo := _four_files()
	var commits := repo.commits_since(_oid(repo, "c3"))
	check("newest first", commits.map(func(c: Dictionary) -> String: return c.summary), ["c4", "c3"])
	check("from the root", repo.commits_since(_oid(repo, "c1")).size(), 4)

func test_interactive_rebase_reorders_and_drops() -> void:
	var repo := _four_files()
	var result := repo.interactive_rebase(_oid(repo, "c2"), [_step(repo, "pick", "c4"), _step(repo, "drop", "c3"), _step(repo, "pick", "c2")])
	check("done", result.ok, true)
	check("history", head_subjects(repo), ["c2", "c4", "c1"])
	check("the dropped commit's file is gone", FileAccess.file_exists(repo.get_repo_root().path_join("f3.txt")), false)

func test_interactive_rebase_squashes_fixes_and_rewords() -> void:
	var repo := _four_files()
	var result := repo.interactive_rebase(_oid(repo, "c1"), [
		_step(repo, "reword", "c1", "first\n\nwith a body"), _step(repo, "fixup", "c2"), _step(repo, "pick", "c3"), _step(repo, "squash", "c4"),
	])
	check("done", result.ok, true)
	check("history", head_subjects(repo), ["c3", "first"])
	check("the reworded body", git(repo.get_repo_root(), ["log", "-1", "--format=%b", "HEAD~1"]), "with a body")
	check("the squash keeps both messages", git(repo.get_repo_root(), ["log", "-1", "--format=%B", "HEAD"]).replace("\n", " "), "c3  c4")
	check("every file is there", ["f1.txt", "f2.txt", "f3.txt", "f4.txt"].all(func(f: String) -> bool: return FileAccess.file_exists(repo.get_repo_root().path_join(f))), true)

const RebaseDialog = preload("res://addons/godit/dock/widgets/rebase_dialog.gd")

func test_rebase_dialog_steps_and_problems() -> void:
	var commits := [
		{ "oid": "c3c3c3c", "summary": "c3", "message": "c3" },
		{ "oid": "c2c2c2c", "summary": "c2", "message": "c2" },
		{ "oid": "c1c1c1c", "summary": "c1", "message": "c1" },
	]
	var dialog: ConfirmationDialog = track(RebaseDialog.new(commits))
	check("nothing changed yet", dialog.problem(), "Nothing to change yet.")
	dialog._commits[0]["action"] = "squash"
	check("oldest first", dialog.steps().map(func(s: Dictionary) -> String: return "%s %s" % [s.action, s.oid]), ["pick c1c1c1c", "pick c2c2c2c", "squash c3c3c3c"])
	check("fine", dialog.problem(), "")
	dialog._commits[2]["action"] = "fixup"
	check("the oldest can't fold down", dialog.problem(), "The lowest kept commit has nothing below it to fold into.")
	dialog._commits[2]["action"] = "drop"
	dialog._commits[1]["action"] = "reword"
	dialog._commits[1]["message"] = " "
	check("a reword needs a message", dialog.problem(), "A reworded commit needs a message.")
