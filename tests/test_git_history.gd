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

func test_fixup_folds_staged_changes_into_an_older_commit() -> void:
	var repo := _linear()
	write_file(repo.get_repo_root().path_join("b.txt"), "b\n")
	git(repo.get_repo_root(), ["add", "b.txt"])
	check("folded", repo.fixup_commit(_oid(repo, "c2")).ok, true)
	check("history", head_subjects(repo), ["c3", "c2", "c1"])
	check("the file is in c2 now", git(repo.get_repo_root(), ["show", "--name-only", "--format=", _oid(repo, "c2")]).contains("b.txt"), true)
	check("working tree is clean", repo.get_status().size(), 0)

func test_fixup_needs_something_staged_and_refuses_merges() -> void:
	var repo := _linear()
	check("nothing staged", repo.fixup_commit(_oid(repo, "c2")).ok, false)
	var merged := _with_a_merge()
	write_file(merged.get_repo_root().path_join("b.txt"), "b\n")
	git(merged.get_repo_root(), ["add", "b.txt"])
	var result := merged.fixup_commit(_oid(merged, "c2"))
	check("a merge follows", result.ok, false)
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
