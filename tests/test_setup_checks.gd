extends "res://tests/assertions.gd"

const SetupChecks = preload("res://addons/godit/util/setup_checks.gd")

func _states(repo: GitCliRepo, bytes := SetupChecks.BIG_FILE_BYTES) -> Dictionary:
	var out := {}
	for check: Dictionary in SetupChecks.local_checks(repo, bytes):
		out[check["id"]] = check["state"]
	return out

func _find(repo: GitCliRepo, id: String, bytes := SetupChecks.BIG_FILE_BYTES) -> Dictionary:
	for check: Dictionary in SetupChecks.local_checks(repo, bytes):
		if check["id"] == id:
			return check
	return {}

func test_reads_remote_urls() -> void:
	check("ssh, scp-like", [SetupChecks.protocol("git@github.com:me/game.git"), SetupChecks.host("git@github.com:me/game.git")], ["ssh", "github.com"])
	check("ssh url", [SetupChecks.protocol("ssh://git@gitlab.example.com:2222/me/game.git"), SetupChecks.host("ssh://git@gitlab.example.com:2222/me/game.git")], ["ssh", "gitlab.example.com"])
	check("https", [SetupChecks.protocol("https://github.com/me/game.git"), SetupChecks.host("https://github.com/me/game.git")], ["https", "github.com"])
	check("a folder", [SetupChecks.protocol("/srv/git/game.git"), SetupChecks.host("/srv/git/game.git")], ["file", ""])
	check("a relative folder", [SetupChecks.protocol("../remote.git"), SetupChecks.host("../remote.git")], ["file", ""])

func test_a_fresh_repository_and_its_fixes() -> void:
	var repo := make_repo()
	var states := _states(repo)
	check("as git init leaves it", [states["git"], states["identity"], states["remote"], states["ignore"], states["line_endings"]],
			[SetupChecks.OK, SetupChecks.OK, SetupChecks.WARN, SetupChecks.FAIL, SetupChecks.WARN])
	await SetupChecks.apply(repo, "ignore_godot")
	await SetupChecks.apply(repo, "line_endings")
	states = _states(repo)
	check("fixed", [states["ignore"], states["line_endings"]], [SetupChecks.OK, SetupChecks.OK])
	check_contains("written", read_file(repo.get_repo_root().path_join(".gitignore")), ".godot/")

func test_a_committed_godot_folder_gets_untracked() -> void:
	var repo := make_repo()
	commit_file(repo, ".godot/editor/cache.cfg", "x\n", "oops")
	var ignore := _find(repo, "ignore")
	check("caught", [ignore["state"], ignore["fixes"][0][0]], [SetupChecks.FAIL, "untrack_godot"])
	check("untracked", (await SetupChecks.apply(repo, "untrack_godot"))["ok"], true)
	check("ignored and no longer in git", _states(repo)["ignore"], SetupChecks.OK)
	check_true("still on disk", FileAccess.file_exists(repo.get_repo_root().path_join(".godot/editor/cache.cfg")))

func test_big_committed_files() -> void:
	var repo := make_repo()
	commit_file(repo, "art/big.psd", "x".repeat(4000), "art")
	commit_file(repo, "small.gd", "extends Node\n", "code")
	check("over the limit", SetupChecks.big_files(repo, 1000).map(func(e: Dictionary) -> String: return e["path"]), ["art/big.psd"])
	check("warned", _find(repo, "lfs", 1000)["state"], SetupChecks.WARN)
	check("none over 10 MB", _find(repo, "lfs")["state"], SetupChecks.OK)

func test_logging_in_to_the_remote() -> void:
	var repo := make_repo()
	commit_file(repo, "a.txt", "1\n", "first")
	check("no remote yet", (await SetupChecks.login(repo, ""))["state"], SetupChecks.WARN)
	var remote := make_temp_dir().path_join("remote.git")
	DirAccess.make_dir_recursive_absolute(remote)
	git(remote, ["init", "-q", "--bare", "-b", "main"])
	repo.add_remote("origin", remote)
	check("reachable", (await SetupChecks.login(repo, ""))["state"], SetupChecks.OK)
	git(repo.get_repo_root(), ["remote", "set-url", "origin", remote + "-missing"])
	var gone := await SetupChecks.login(repo, "")
	check("unreachable", gone["state"], SetupChecks.FAIL)
	check_contains("says so", gone["detail"], "Couldn't reach")
