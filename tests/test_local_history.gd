extends "res://tests/assertions.gd"

# Local History: snapshots stay out of the branches, the index and the working tree; what goes in; versions, restore and pruning.

const LocalHistory = preload("res://addons/godit/util/local_history.gd")
const DAY := 86400

var _now := 1760000000

func _ctx(repo: GitCliRepo, overrides := {}) -> Dictionary:
	var ctx := LocalHistory.context(repo, "")
	ctx.merge(overrides, true)
	return ctx

# a snapshot a minute after the last one
func _snap(ctx: Dictionary, why := "") -> Dictionary:
	_now += 60
	return LocalHistory.snapshot(ctx, why, _now)

func _files_in(repo: GitCliRepo, tree: String) -> Array:
	return Array(git(repo.get_repo_root(), ["ls-tree", "-r", "--name-only", tree]).split("\n", false))

func test_snapshots_leave_git_alone() -> void:
	var repo := make_repo()
	var root := repo.get_repo_root()
	commit_file(repo, "a.gd", "1\n", "first")
	write_file(root.path_join("a.gd"), "2\n")
	git(root, ["add", "a.gd"])
	write_file(root.path_join("a.gd"), "3\n")
	write_file(root.path_join("new.gd"), "new\n")
	var status := git(root, ["status", "--porcelain"])
	var index := git(root, ["ls-files", "-s"])
	var ctx := _ctx(repo)
	var snapshot := _snap(ctx)
	check("taken", [snapshot.ok, snapshot.taken], [true, true])
	check("the same status", git(root, ["status", "--porcelain"]), status)
	check("the same index", git(root, ["ls-files", "-s"]), index)
	check("no commit on the branch", head_subjects(repo), ["first"])
	check("git log --all doesn't list it", git(root, ["log", "--all", "--format=%s"]), "first")
	check("the file as on disk, not as staged", git(root, ["show", snapshot.tree + ":a.gd"]), "3")
	check("the new file too", git(root, ["show", snapshot.tree + ":new.gd"]), "new")
	check("nothing changed: no new snapshot", _snap(ctx).taken, false)
	git(root, ["gc", "-q", "--prune=now"])
	check("git gc keeps it", git(root, ["cat-file", "-t", snapshot.tree]), "tree")

func test_ignored_big_lfs_and_godot_files_stay_out() -> void:
	var repo := make_repo()
	var root := repo.get_repo_root()
	write_file(root.path_join(".gitignore"), "ignored.txt\nforced.txt\n")
	write_file(root.path_join(".gitattributes"), "*.psd filter=lfs diff=lfs merge=lfs -text\n")
	commit_file(repo, "a.gd", "1\n", "first")
	write_file(root.path_join("forced.txt"), "tracked though ignored\n")
	git(root, ["add", "-f", "forced.txt"])
	write_file(root.path_join("ignored.txt"), "x\n")
	write_file(root.path_join(".godot/editor/state.cfg"), "x\n")
	write_file(root.path_join("art.psd"), "small, but in Git LFS\n")
	write_file(root.path_join("big.bin"), "x".repeat(200))
	write_file(root.path_join("grows.txt"), "small\n")
	var ctx := _ctx(repo, {"max_bytes": 100})
	var files := _files_in(repo, _snap(ctx).tree)
	check("only these", files, [".gitattributes", ".gitignore", "a.gd", "forced.txt", "grows.txt"])
	write_file(root.path_join("grows.txt"), "y".repeat(200))
	check("a file that got big leaves, rather than keep an old version", _files_in(repo, _snap(ctx).tree).has("grows.txt"), false)

func test_an_unreadable_file_doesnt_keep_the_rest_out() -> void:
	if OS.get_name() == "Windows":
		return # no chmod
	var repo := make_repo()
	var root := repo.get_repo_root()
	write_file(root.path_join("a.gd"), "a\n")
	write_file(root.path_join("locked.gd"), "x\n")
	write_file(root.path_join("z.gd"), "z\n")
	OS.execute("chmod", ["000", root.path_join("locked.gd")])
	var snapshot := _snap(_ctx(repo))
	OS.execute("chmod", ["644", root.path_join("locked.gd")])
	check("taken without it", [snapshot.ok, _files_in(repo, snapshot.tree)], [true, ["a.gd", "z.gd"]])

func test_versions_and_restore() -> void:
	var repo := make_repo()
	var root := repo.get_repo_root()
	commit_file(repo, "a.gd", "1\n", "first")
	commit_file(repo, "dir/b.gd", "b\n", "second")
	var ctx := _ctx(repo)
	_snap(ctx)
	write_file(root.path_join("a.gd"), "1\n2\n")
	_snap(ctx, "Before Pull")
	write_file(root.path_join("a.gd"), "3\n")
	DirAccess.remove_absolute(root.path_join("dir/b.gd"))
	_snap(ctx)
	var all := LocalHistory.entries(ctx)
	check("three snapshots", all.size(), 3)
	var versions := LocalHistory.file_versions(all, "a.gd")
	check("newest first, with the version before the oldest change", versions.map(func(v: Dictionary) -> Array: return [v.status, v.added, v.deleted, v.why]),
			[["M", 1, 2, ""], ["M", 1, 0, "Before Pull"], ["", 0, 0, ""]])
	var folder := LocalHistory.folder_versions(all, "dir")
	check("the folder changed once", folder.map(func(v: Dictionary) -> Array: return v.files), [[["D", 0, 1, "dir/b.gd"]], []])
	check("a whole-project list", LocalHistory.folder_versions(all, "").size(), 3)
	check("filtered by name, with the one before", LocalHistory.folder_versions(all, "", "B.GD").map(func(v: Dictionary) -> int: return v.files.size()), [1, 0])
	check("what differs from then", LocalHistory.changes(ctx, versions[2].tree, all[-1].tree, ""), [["M", 1, 1, "a.gd"], ["D", 0, 1, "dir/b.gd"]])
	var restored := LocalHistory.restore(ctx, versions[1].tree, ["a.gd", "dir/b.gd"])
	check("restored", [restored.ok, restored.written], [true, ["a.gd", "dir/b.gd"]])
	check("the old content", read_file(root.path_join("a.gd")), "1\n2\n")
	check("a deleted file is back", read_file(root.path_join("dir/b.gd")), "b\n")
	write_file(root.path_join("later.gd"), "x\n")
	LocalHistory.restore(ctx, versions[1].tree, ["later.gd"])
	check("a file the snapshot didn't have is deleted", FileAccess.file_exists(root.path_join("later.gd")), false)

func test_restore_goes_through_line_endings() -> void:
	var repo := make_repo()
	var root := repo.get_repo_root()
	write_file(root.path_join(".gitattributes"), "*.txt eol=crlf\n")
	write_file(root.path_join("a.txt"), "one\r\ntwo\r\n")
	var ctx := _ctx(repo)
	var tree: String = _snap(ctx).tree
	check("stored as git would", git(root, ["cat-file", "-p", tree + ":a.txt"]), "one\ntwo")
	write_file(root.path_join("a.txt"), "changed\r\n")
	LocalHistory.restore(ctx, tree, ["a.txt"])
	check("written back with CRLF", read_file(root.path_join("a.txt")), "one\r\ntwo\r\n")

func test_old_days_are_dropped() -> void:
	var repo := make_repo()
	var root := repo.get_repo_root()
	commit_file(repo, "a.gd", "1\n", "first")
	write_file(root.path_join("a.gd"), "only in the old snapshot\n")
	var ctx := _ctx(repo, {"days": 2})
	var old: String = _snap(ctx).tree
	write_file(root.path_join("a.gd"), "2\n")
	_now += DAY
	_snap(ctx)
	check("both kept a day later", LocalHistory.entries(ctx).size(), 2)
	write_file(root.path_join("a.gd"), "3\n")
	_now += 4 * DAY
	var newest: String = _snap(ctx).tree
	check("only the newest is left", LocalHistory.entries(ctx).map(func(e: Dictionary) -> String: return e.tree), [newest])
	check("one day in the ref", git(root, ["ls-tree", "--name-only", LocalHistory.REF]).split("\n").size(), 1)
	git(root, ["gc", "-q", "--prune=now"])
	check("git gc drops it", git(root, ["cat-file", "-t", old]).contains("fatal"), true)
	check("the new one stays", git(root, ["cat-file", "-t", newest]), "tree")

func test_clear_and_starting_over() -> void:
	var repo := make_repo()
	var root := repo.get_repo_root()
	commit_file(repo, "a.gd", "1\n", "first")
	var ctx := _ctx(repo)
	_snap(ctx)
	LocalHistory.clear(ctx)
	check("no ref", git(root, ["for-each-ref", "refs/godit"]), "")
	check("no snapshots", LocalHistory.entries(ctx), [])
	check("a new first one", [_snap(ctx).taken, LocalHistory.entries(ctx).size()], [true, 1])

func test_a_linked_worktree_has_its_own() -> void:
	var repo := make_repo()
	commit_file(repo, "a.gd", "1\n", "first")
	var other := make_temp_dir().path_join("feature x")
	git(repo.get_repo_root(), ["worktree", "add", "-q", "-b", "feature", other])
	var linked := GitCliRepo.new()
	linked.open(other)
	var ctx := _ctx(linked)
	check("its own ref", [ctx.ref.begins_with(LocalHistory.REF + "-"), git(repo.get_repo_root(), ["check-ref-format", ctx.ref])], [true, ""])
	check("its own folder", ctx.dir.begins_with(linked.get_git_dir()), true)
	write_file(other.path_join("a.gd"), "2\n")
	check("snapshots there", _snap(ctx).taken, true)
	check("not in the main one's", LocalHistory.entries(_ctx(repo)), [])
