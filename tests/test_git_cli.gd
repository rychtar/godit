extends "res://tests/assertions.gd"

const GitConsole = preload("res://addons/godit/dock/widgets/git_console.gd")

func test_unquote() -> void:
	check("plain path", GitCli.unquote("a/b.gd"), "a/b.gd")
	check("quoted with a space", GitCli.unquote("\"a b.txt\""), "a b.txt")
	check("escaped quote", GitCli.unquote("\"q\\\"x.txt\""), "q\"x.txt")
	check("a lone quote", GitCli.unquote("\""), "\"")

func test_lines_and_paths() -> void:
	check("empty lines are dropped", Array(GitCli.lines("a\n\nb\n")), ["a", "b"])
	check("paths are unquoted", Array(GitCli.paths("x.gd\n\"y z.gd\"\n")), ["x.gd", "y z.gd"])

func test_argv() -> void:
	var argv := GitCli.argv("/repo", ["status", "-s"])
	check("repo root", Array(argv.slice(0, 2)), ["-C", "/repo"])
	check_true("paths are not quoted", argv.has("core.quotePath=false"))
	check_true("no gpg lines in the log", argv.has("log.showSignature=false"))
	check("command at the end", Array(argv.slice(argv.size() - 2)), ["status", "-s"])

func test_split_args() -> void:
	check("plain", Array(GitConsole.split_args("log -n 3")), ["log", "-n", "3"])
	check("double quotes", Array(GitConsole.split_args("log --format=\"%h %s\" -n 1")), ["log", "--format=%h %s", "-n", "1"])
	check("single quotes", Array(GitConsole.split_args("commit -m 'a b'")), ["commit", "-m", "a b"])
	check("empty quotes are an argument", Array(GitConsole.split_args("config ''")), ["config", ""])
	check("no shell expansion", Array(GitConsole.split_args("echo $(whoami)")), ["echo", "$(whoami)"])

func test_run() -> void:
	var result := GitCli.run(OS.get_temp_dir(), ["--version"])
	check("exit code", result.exit_code, 0)
	check_contains("output", result.text, "git version")

func test_execute_of_a_missing_program() -> void:
	check_true("it fails", GitCli.execute("godit-no-such-program", PackedStringArray())["exit_code"] != 0)

func test_a_job_finishes() -> void:
	var job := GitCli.start(OS.get_temp_dir(), ["--version"], false)
	var result: Dictionary = await job.finished
	check("exit code", result.exit_code, 0)
	check("not cancelled", result.cancelled, false)
	check_contains("output", result.text, "git version")

func test_a_job_can_be_cancelled() -> void:
	# an alias running a long sleep: killing git alone would leave the shell and sleep holding the pipes
	var job := GitCli.start(OS.get_temp_dir(), ["-c", "alias.slow=!sleep 30", "slow"], false)
	await tree.create_timer(0.5).timeout
	job.cancel()
	var started := Time.get_ticks_msec()
	var result: Dictionary = await job.finished
	check("cancelled", result.cancelled, true)
	check_true("returned quickly", Time.get_ticks_msec() - started < 5000)
