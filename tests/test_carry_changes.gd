extends "res://tests/assertions.gd"

# Switching branches with uncommitted changes in the way: stash, checkout, pop.

const GitErrors = preload("res://addons/godit/util/git_errors.gd")

func _two_branches() -> GitCliRepo:
	var repo := make_repo()
	var root := repo.get_repo_root()
	commit_file(repo, "a.txt", "1\n2\n3\n", "first")
	git(root, ["checkout", "-q", "-b", "other"])
	commit_file(repo, "a.txt", "one\n2\n3\n", "other changes the first line")
	git(root, ["checkout", "-q", "main"])
	return repo

func _stashes(repo: GitCliRepo) -> int:
	var text := git(repo.get_repo_root(), ["stash", "list"])
	return 0 if text.is_empty() else text.split("\n").size()

func test_changes_come_along() -> void:
	var repo := _two_branches()
	var root := repo.get_repo_root()
	write_file(root.path_join("a.txt"), "1\n2\nthree\n")
	write_file(root.path_join("new.txt"), "new\n")
	var plain := repo.checkout_branch("other")
	check("a plain checkout refuses", [plain.ok, GitErrors.classify(plain.error)], [false, GitErrors.DIRTY])
	var carried := repo.checkout_carrying_changes("other")
	check("switched and re-applied", [carried.ok, repo.get_current_branch()], [true, "other"])
	check("the edit on top of the branch's change", read_file(root.path_join("a.txt")), "one\n2\nthree\n")
	check("the new file too", read_file(root.path_join("new.txt")), "new\n")
	check("no stash left behind", _stashes(repo), 0)

func test_a_conflict_keeps_the_stash() -> void:
	var repo := _two_branches()
	write_file(repo.get_repo_root().path_join("a.txt"), "ONE\n2\n3\n")
	var carried := repo.checkout_carrying_changes("other")
	check("switched, but not re-applied cleanly", [carried.ok, carried.switched, carried.conflicts, repo.get_current_branch()], [false, true, true, "other"])
	check("the changes are still stashed", _stashes(repo), 1)

func test_nothing_to_carry_leaves_older_stashes_alone() -> void:
	var repo := _two_branches()
	write_file(repo.get_repo_root().path_join("a.txt"), "older work\n")
	repo.stash_push("older work", false)
	var carried := repo.checkout_carrying_changes("other")
	check("switched", [carried.ok, repo.get_current_branch()], [true, "other"])
	check("the older stash wasn't popped", _stashes(repo), 1)
