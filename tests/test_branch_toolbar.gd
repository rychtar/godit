extends "res://tests/assertions.gd"

# The toolbar button and its list; switching itself needs the editor (saving open files first), so it's left to the editor runs.

const BranchToolbar = preload("res://addons/godit/dock/widgets/branch_toolbar.gd")

func _published_repo() -> GitCliRepo:
	var remote := make_temp_dir().path_join("remote.git")
	DirAccess.make_dir_recursive_absolute(remote)
	git(remote, ["init", "-q", "--bare", "-b", "main"])
	var repo := make_repo()
	commit_file(repo, "a.txt", "1\n", "first")
	repo.add_remote("origin", remote)
	git(repo.get_repo_root(), ["push", "-q", "-u", "origin", "main"])
	return repo

func _button(repo: GitCliRepo) -> BranchToolbar:
	var button: BranchToolbar = track(BranchToolbar.new())
	tree.root.add_child(button)
	button.set_repo(repo)
	return button

func _names(button: BranchToolbar) -> Array:
	return button._items.map(func(item: Dictionary) -> String: return "%s:%s" % [item["kind"], item["name"]])

func test_shows_the_branch_and_the_commits_to_push() -> void:
	var repo := _published_repo()
	commit_file(repo, "a.txt", "2\n", "second")
	var button := _button(repo)
	check("branch and one to push", button.text, "main ↑1")
	check_contains("the upstream in the tooltip", button.tooltip_text, "main → origin/main")

func test_lists_local_then_remote_branches_and_filters_them() -> void:
	var repo := _published_repo()
	var root := repo.get_repo_root()
	git(root, ["branch", "feature/login"])
	git(root, ["push", "-q", "origin", "main:shared"])
	git(root, ["fetch", "-q", "origin"])
	var button := _button(repo)
	button._fill()
	check("locals, the remote one without a local branch, New Branch", _names(button), ["local:feature/login", "local:main", "remote:origin/shared", "new:"])
	check("the first one to switch to is selected", Array(button._list.get_selected_items()), [0])
	check_contains("the current one is marked", button._list.get_item_text(1), "(current)")
	button._filter.text = "sha"
	button._fill()
	check("filtered", _names(button), ["remote:origin/shared", "new:sha"])
	check("New Branch takes the typed name", button._list.get_item_text(1), "New Branch \"sha\"…")
