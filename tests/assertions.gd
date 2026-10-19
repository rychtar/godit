extends RefCounted

# Base of the test files: check() records a failure, the runner reports it.
# make_repo() gives a throwaway git repository; git is isolated from the machine's own config.

const GitCli := preload("res://addons/godit/util/git_cli.gd")
const GitCliRepo := preload("res://addons/godit/util/git_cli_repo.gd")

static var _git_ready := false

var tree: SceneTree
var failures: Array[String] = []
var _nodes: Array[Object] = []
var _temp_dirs: Array[String] = []

func check(description: String, got: Variant, expected: Variant) -> void:
	if typeof(got) != typeof(expected) or got != expected:
		failures.append("%s\ngot:      %s\nexpected: %s" % [description, var_to_str(got), var_to_str(expected)])

func check_true(description: String, condition: bool) -> void:
	check(description, condition, true)

func check_contains(description: String, text: String, part: String) -> void:
	if not text.contains(part):
		failures.append("%s\n%s\ndoes not contain: %s" % [description, var_to_str(text), var_to_str(part)])

# an object that is freed after the test
func track(object: Object) -> Object:
	_nodes.append(object)
	return object

# an empty folder that is deleted after the test
func make_temp_dir() -> String:
	var dir := OS.get_temp_dir().path_join("godit_test_%d_%d" % [OS.get_process_id(), _temp_dirs.size()])
	_remove_recursive(dir)
	DirAccess.make_dir_recursive_absolute(dir)
	_temp_dirs.append(dir)
	return dir

func write_file(path: String, content: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(content)
	file.close()

func read_file(path: String) -> String:
	return FileAccess.get_file_as_string(path) if FileAccess.file_exists(path) else ""

# `git <args>` in dir, stdout and stderr together
func git(dir: String, args: Array) -> String:
	_setup_git()
	return GitCli.run(dir, args, true)["text"].strip_edges()

# a repository with no commits yet (branch main)
func make_repo() -> GitCliRepo:
	_setup_git()
	var dir := make_temp_dir()
	git(dir, ["init", "-q", "-b", "main"])
	var repo := GitCliRepo.new()
	repo.open(dir)
	return repo

# writes, stages and commits a file (the other files stay as they are)
func commit_file(repo: GitCliRepo, path: String, content: String, message: String) -> void:
	var root := repo.get_repo_root()
	write_file(root.path_join(path), content)
	git(root, ["add", "--", path])
	git(root, ["commit", "-q", "-m", message])

func head_subjects(repo: GitCliRepo) -> Array:
	return Array(git(repo.get_repo_root(), ["log", "--format=%s"]).split("\n"))

func _setup_git() -> void:
	if _git_ready:
		return
	_git_ready = true
	var config := OS.get_temp_dir().path_join("godit_test_gitconfig_%d" % OS.get_process_id())
	write_file(config, "[user]\n\tname = Test\n\temail = test@example.com\n[init]\n\tdefaultBranch = main\n[commit]\n\tgpgsign = false\n[core]\n\tautocrlf = false\n")
	OS.set_environment("GIT_CONFIG_GLOBAL", config)
	OS.set_environment("GIT_CONFIG_NOSYSTEM", "1")
	for key in GitCli.ENV_OVERRIDES:
		OS.set_environment(key, GitCli.ENV_OVERRIDES[key])

func _remove_recursive(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.include_hidden = true # .git
	for sub in dir.get_directories():
		_remove_recursive(path.path_join(sub))
	for file in dir.get_files():
		DirAccess.remove_absolute(path.path_join(file))
	DirAccess.remove_absolute(path)

func cleanup() -> void:
	for object in _nodes:
		if is_instance_valid(object):
			object.free()
	_nodes.clear()
	for dir in _temp_dirs:
		_remove_recursive(dir)
	_temp_dirs.clear()
