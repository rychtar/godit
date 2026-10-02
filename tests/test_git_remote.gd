extends "res://tests/assertions.gd"

# a bare "remote" next to a working repository that has it as origin

func _setup() -> Dictionary:
	var remote := make_temp_dir().path_join("remote.git")
	DirAccess.make_dir_recursive_absolute(remote)
	git(remote, ["init", "-q", "--bare", "-b", "main"])
	var repo := make_repo()
	commit_file(repo, "a.txt", "1\n", "first")
	repo.add_remote("origin", remote)
	return { "repo": repo, "remote": remote }

func test_push_publishes_a_branch_and_sets_the_upstream() -> void:
	var s := _setup()
	var repo: GitCliRepo = s.repo
	check("no upstream yet", repo.get_upstream(), "")
	var result: Dictionary = await repo.push({ "remote": "origin", "branch": "main", "set_upstream": true })
	check("pushed", result.ok, true)
	check("upstream", repo.get_upstream(), "origin/main")
	var sync := repo.get_sync_status()
	check("in sync", [sync.ahead, sync.behind], [0, 0])
	commit_file(repo, "a.txt", "2\n", "second")
	check("one ahead", repo.get_sync_status().ahead, 1)
	check("remotes", repo.list_remotes().map(func(r: Dictionary) -> String: return r.name), ["origin"])

func test_fetch_and_pull_bring_in_a_collaborators_commit() -> void:
	var s := _setup()
	var repo: GitCliRepo = s.repo
	await repo.push({ "remote": "origin", "branch": "main", "set_upstream": true })
	var other := make_temp_dir()
	git(other, ["clone", "-q", s.remote, "."])
	write_file(other.path_join("b.txt"), "b\n")
	git(other, ["add", "b.txt"])
	git(other, ["commit", "-q", "-m", "from the other side"])
	git(other, ["push", "-q", "origin", "main"])
	var fetched: Dictionary = await repo.fetch()
	check("fetched", fetched.ok, true)
	check("one behind", repo.get_sync_status().behind, 1)
	check("incoming files overlap with nothing local", repo.incoming_overlap([]), {})
	write_file(repo.get_repo_root().path_join("b.txt"), "local\n")
	check("an uncommitted change to an incoming file is flagged", repo.incoming_overlap(["b.txt"]), { "b.txt": "uncommitted" })
	DirAccess.remove_absolute(repo.get_repo_root().path_join("b.txt"))
	var pulled: Dictionary = await repo.pull("ff-only")
	check("pulled", pulled.ok, true)
	check("file arrived", read_file(repo.get_repo_root().path_join("b.txt")), "b\n")
	check("in sync again", repo.get_sync_status().behind, 0)

func test_a_rejected_push_is_reported() -> void:
	var s := _setup()
	var repo: GitCliRepo = s.repo
	await repo.push({ "remote": "origin", "branch": "main", "set_upstream": true })
	var other := make_temp_dir()
	git(other, ["clone", "-q", s.remote, "."])
	write_file(other.path_join("b.txt"), "b\n")
	git(other, ["add", "b.txt"])
	git(other, ["commit", "-q", "-m", "other"])
	git(other, ["push", "-q", "origin", "main"])
	commit_file(repo, "a.txt", "2\n", "mine")
	var result: Dictionary = await repo.push()
	check("rejected", result.ok, false)
	check_true("the error is there", not result.error.is_empty())

func test_force_with_lease_and_deleting_a_remote_branch() -> void:
	var s := _setup()
	var repo: GitCliRepo = s.repo
	await repo.push({ "remote": "origin", "branch": "main", "set_upstream": true })
	repo.create_branch("topic", "", false)
	var pushed: Dictionary = await repo.push_refspec("origin", "topic")
	check("pushed a second branch", pushed.ok, true)
	check("it is on the remote", git(s.remote, ["branch", "--list", "topic"]).contains("topic"), true)
	var deleted: Dictionary = await repo.push_refspec("origin", ":refs/heads/topic")
	check("deleted it", deleted.ok, true)
	check("it's gone", git(s.remote, ["branch", "--list", "topic"]), "")
	repo.reset_branch_to(repo.get_head_oid(), false)
	commit_file(repo, "a.txt", "amended\n", "second")
	git(repo.get_repo_root(), ["commit", "-q", "--amend", "-m", "second again"])
	var forced: Dictionary = await repo.push({ "force_with_lease": true })
	check("a rewritten commit can be pushed with a lease", forced.ok, true)

func test_a_failed_job_keeps_its_error_text() -> void:
	var repo := make_repo()
	var result: Dictionary = await repo.fetch()
	check("nothing to fetch from", result.ok, true) # no remotes: git fetch --all is a no-op
	var failed: Dictionary = await repo.pull()
	check("pull without a remote fails", failed.ok, false)
	check_true("with git's message", not failed.error.is_empty())
