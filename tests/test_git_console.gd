extends "res://tests/assertions.gd"

const GitConsole = preload("res://addons/godit/dock/widgets/git_console.gd")

func _risky(line: String, alias := "") -> bool:
	return not GitConsole.risk(GitConsole.split_args(line), alias).is_empty()

func test_risky_commands_need_a_confirmation() -> void:
	for line in ["reset --hard", "-C sub reset --hard HEAD~1", "clean -fd", "clean -xdf", "push --force", "push -uf origin main", "push origin +main", "push origin :old",
			"push --delete origin old", "checkout -- .", "checkout .", "switch -f main", "restore a.gd", "restore --staged --worktree a.gd", "branch -D old",
			"stash drop", "stash clear", "rm -f a.gd", "filter-branch --all", "config --global user.name Me", "config --global --unset user.name", "-c alias.x=!rm x"]:
		check_true("confirm: " + line, _risky(line))

func test_safe_commands_run_at_once() -> void:
	for line in ["status", "log --oneline -5", "reset --soft HEAD~1", "clean -n", "clean -fdn", "clean --dry-run -fd", "push", "push -u origin main",
			"checkout main", "switch -c new", "restore --staged a.gd", "branch -d merged", "stash list", "stash", "rm --cached -f a.gd",
			"config --global user.name", "config --global --get user.name", "config --global --list", "config user.name Me", "-c core.quotepath=false status"]:
		check("run: " + line, _risky(line), false)

func test_aliases() -> void:
	check_true("a shell alias", _risky("nuke", "!rm -rf ."))
	check_true("an alias for a risky command", _risky("undo-all", "reset --hard"))
	check("an alias for a safe one", _risky("st", "status -sb"), false)
