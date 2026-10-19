extends "res://tests/assertions.gd"

const RepoSetup = preload("res://addons/godit/util/repo_setup.gd")

func test_init_a_repository_with_a_first_commit() -> void:
	var dir := make_temp_dir()
	write_file(dir.path_join("game.gd"), "extends Node\n")
	write_file(dir.path_join(".godot/cache.bin"), "x")
	var result: Dictionary = await RepoSetup.init_repo(dir, { "commit": true })
	check("created", result, { "ok": true, "error": "" })
	check("first commit", head_subjects_of(dir), ["Initial commit"])
	check_contains("the ignore file", read_file(dir.path_join(".gitignore")), ".godot/")
	check_contains("the attributes file", read_file(dir.path_join(".gitattributes")), "* text=auto eol=lf")
	var tracked := git(dir, ["ls-files"])
	check_contains("project files are tracked", tracked, "game.gd")
	check("the .godot folder is not", tracked.contains(".godot/"), false)

func test_init_without_a_commit_and_existing_ignore_lines_are_kept() -> void:
	var dir := make_temp_dir()
	write_file(dir.path_join(".gitignore"), "mine/\n.godot/")
	var result: Dictionary = await RepoSetup.init_repo(dir, { "commit": false })
	check("created", result.ok, true)
	check("no commits", git(dir, ["rev-list", "--all", "--count"]), "0")
	var lines := Array(read_file(dir.path_join(".gitignore")).split("\n"))
	check("existing lines are kept, none duplicated", lines.count(".godot/"), 1)
	check_true("mine/ is still there", lines.has("mine/"))
	check_true("the Godot ones were added", lines.has("/android/"))

func test_the_identity_is_set_when_given() -> void:
	var dir := make_temp_dir()
	await RepoSetup.init_repo(dir, { "commit": false, "name": "Jane Doe", "email": "jane@example.com" })
	check("name", git(dir, ["config", "--local", "user.name"]), "Jane Doe")
	check("email", git(dir, ["config", "--local", "user.email"]), "jane@example.com")
	check("an identity exists", RepoSetup.has_identity(dir), true)

func test_suggested_repo_name() -> void:
	var original: Variant = ProjectSettings.get_setting("application/config/name")
	ProjectSettings.set_setting("application/config/name", "My Game!  v2")
	check("unsafe characters become dashes", RepoSetup.suggested_repo_name(), "My-Game-v2")
	ProjectSettings.set_setting("application/config/name", "!!!")
	check("nothing usable", RepoSetup.suggested_repo_name(), "godot-project")
	ProjectSettings.set_setting("application/config/name", original)

func head_subjects_of(dir: String) -> Array:
	return Array(git(dir, ["log", "--format=%s"]).split("\n"))
