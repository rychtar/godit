extends "res://tests/assertions.gd"

# Sync's fetch-and-push half; pulling goes through the editor's save check first, so the editor runs cover it.

const RemoteActions = preload("res://addons/godit/dock/widgets/remote_actions.gd")
const OperationBar = preload("res://addons/godit/dock/widgets/operation_bar.gd")

func _setup() -> Dictionary:
	await tree.process_frame
	var remote := make_temp_dir().path_join("remote.git")
	DirAccess.make_dir_recursive_absolute(remote)
	git(remote, ["init", "-q", "--bare", "-b", "main"])
	var repo := make_repo()
	commit_file(repo, "a.txt", "1\n", "first")
	repo.add_remote("origin", remote)
	git(repo.get_repo_root(), ["push", "-q", "-u", "origin", "main"])
	var bar: OperationBar = track(OperationBar.new())
	tree.root.add_child(bar)
	var parent: Control = track(Control.new())
	tree.root.add_child(parent)
	return {"repo": repo, "remote": remote, "bar": bar, "parent": parent}

func test_pushes_the_commits_that_are_only_here() -> void:
	var s := await _setup()
	var repo: GitCliRepo = s.repo
	commit_file(repo, "a.txt", "2\n", "second")
	check("one to push", repo.get_sync_status().ahead, 1)
	check("synced", await RemoteActions.sync(s.parent, repo, s.bar), true)
	check("nothing left to push", repo.get_sync_status().ahead, 0)
	check("the remote has it", git(s.remote, ["log", "-1", "--format=%s", "main"]), "second")

func test_says_so_when_there_is_nothing_to_do() -> void:
	var s := await _setup()
	check("synced", await RemoteActions.sync(s.parent, s.repo, s.bar), true)
	check_contains("in sync", s.bar._label.text, "In sync with origin/main")
