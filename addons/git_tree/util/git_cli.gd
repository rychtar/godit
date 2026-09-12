## Thin wrapper around OS.execute() for running `git` in a given repo root.
## No class_name: internal helper, addressed via preload (see
## git_status_flags.gd for why).
extends RefCounted

## Record/unit separators for parsing multi-field git log output (see
## git_cli_repo.gd). Git's usual -z (NUL) delimiter doesn't survive
## OS.execute's output capture — the string truncates at the first NUL
## byte — so these control characters are used instead.
const RS := "\u001e"
const US := "\u001f"

const LOG_LIMIT := 400

## Env vars set for the whole editor process while the plugin is enabled, so no git command can ever block on an interactive prompt (there's no terminal to answer it) — see prepare_environment().
const ENV_OVERRIDES := {
	"GIT_TERMINAL_PROMPT": "0",
	"GIT_EDITOR": "true",
	"GIT_SEQUENCE_EDITOR": "true",
	"GIT_MERGE_AUTOEDIT": "no",
}

## Every mutating/async command run, newest last: {"time": int, "args": PackedStringArray, "exit_code": int, "text": String}. Shared by all repo instances (static), read by the Git Console tab.
static var command_log: Array = []
## Bumped on every append, so the console can cheaply tell whether to redraw.
static var command_log_revision := 0

static var _saved_env: Dictionary = {}


## Runs `git <args>` in repo_root, returning {"exit_code": int, "text":
## String}. OS.execute passes args directly as argv (no shell), so nothing
## needs escaping.
##
## include_stderr=true merges stderr into "text" — use it for mutating
## commands where a failure's error text matters (commit, checkout,
## branch, reset, push). Leave it false for read-only commands whose
## stdout gets parsed, since git sometimes writes chatter to stderr even
## on success. Mutating (include_stderr) calls are also recorded in command_log.
static func run(repo_root: String, args: Array, include_stderr: bool = false) -> Dictionary:
	var full_args: PackedStringArray = PackedStringArray(["-C", repo_root])
	for a in args:
		full_args.append(a)

	var output: Array = []
	var exit_code := OS.execute("git", full_args, output, include_stderr, false)
	var text: String = output[0] if not output.is_empty() else ""
	if include_stderr:
		record(args, exit_code, text)
	return { "exit_code": exit_code, "text": text }


## Starts `git <args>` on a worker thread and returns a Job; `await job.finished` yields the same {"exit_code", "text", "cancelled"} shape as run() (stderr always included). For network operations, which would otherwise freeze the editor.
static func start(repo_root: String, args: Array) -> Job:
	var job := Job.new()
	job.finished.connect(func(result: Dictionary) -> void: record(args, result["exit_code"], result["text"]))
	job.start(repo_root, args)
	return job


static func record(args: Array, exit_code: int, text: String) -> void:
	command_log.append({
		"time": int(Time.get_unix_time_from_system()),
		"args": PackedStringArray(args),
		"exit_code": exit_code,
		"text": text,
	})
	if command_log.size() > LOG_LIMIT:
		command_log = command_log.slice(command_log.size() - LOG_LIMIT)
	command_log_revision += 1


## Splits git output into non-empty lines.
static func lines(text: String) -> PackedStringArray:
	var result := PackedStringArray()
	for line in text.split("\n"):
		if not line.is_empty():
			result.append(line)
	return result


## Called by plugin.gd on enable; restore_environment() undoes it on disable. SSH gets BatchMode so an unknown host key / missing agent fails with a message instead of waiting for a tty that doesn't exist.
static func prepare_environment() -> void:
	_saved_env.clear()
	var overrides := ENV_OVERRIDES.duplicate()
	if not OS.has_environment("GIT_SSH_COMMAND") and not OS.has_environment("GIT_SSH"):
		overrides["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes"
	for key in overrides:
		_saved_env[key] = OS.get_environment(key) if OS.has_environment(key) else null
		OS.set_environment(key, overrides[key])


static func restore_environment() -> void:
	for key in _saved_env:
		if _saved_env[key] == null:
			OS.unset_environment(key)
		else:
			OS.set_environment(key, _saved_env[key])
	_saved_env.clear()


## One background git process. Reads its output on a Thread (OS.execute_with_pipe) so it can be killed mid-way via cancel(); finished is emitted on the main thread.
class Job:
	extends RefCounted

	# Per instance, built on the main thread: a static var here was still null on the worker thread in the editor, killing _run() so finished never fired.
	var _progress_re := RegEx.create_from_string("^(remote: )?[A-Za-z ]+:\\s+\\d+% \\(")
	## Everything --progress adds on top of the meters themselves.
	var _progress_noise_re := RegEx.create_from_string("^(remote: )?([A-Za-z ]+:\\s+\\d+% \\(|Enumerating objects: \\d+, done|Delta compression using|Total \\d+ \\(delta)")

	signal finished(result: Dictionary)
	## Latest progress line from git's stderr ("Receiving objects:  45% (9/20)"), for commands run with --progress.
	signal progress(text: String)

	var args: PackedStringArray
	var is_running := false
	var _thread: Thread
	var _pid := -1
	var _cancelled := false
	## Guards _pid/_cancelled: cancel() can arrive before the worker has the pid.
	var _mutex := Mutex.new()


	func start(repo_root: String, command_args: Array) -> void:
		args = PackedStringArray(command_args)
		is_running = true
		_thread = Thread.new()
		_thread.start(_run.bind(repo_root))


	func cancel() -> void:
		_mutex.lock()
		if is_running and not _cancelled:
			_cancelled = true
			if _pid > 0:
				OS.kill(_pid)
		_mutex.unlock()


	func _run(repo_root: String) -> void:
		var full_args := PackedStringArray(["-C", repo_root])
		full_args.append_array(args)
		var info := OS.execute_with_pipe("git", full_args, true)
		if info.is_empty():
			_finish.call_deferred({ "exit_code": -1, "text": "Couldn't start `git` — is it on PATH?", "cancelled": false })
			return

		_mutex.lock()
		_pid = info["pid"]
		if _cancelled:
			OS.kill(_pid)
		_mutex.unlock()
		var stdio: FileAccess = info["stdio"]
		var stderr: FileAccess = info["stderr"]
		# Both pipes drained at once, so neither can fill up and stall git; stderr here, since that's where progress arrives.
		var out_thread := Thread.new()
		out_thread.start(_drain.bind(stdio, false))
		var err := _strip_progress(_drain(stderr, true))
		var out: String = out_thread.wait_to_finish()
		if _cancelled:
			# OS.kill() already reaped the process — querying it again would only log "process does not exist".
			_finish.call_deferred({ "exit_code": -1, "text": "Cancelled.", "cancelled": true })
			return
		while OS.is_process_running(_pid):
			OS.delay_msec(5)
		var exit_code := OS.get_process_exit_code(_pid)
		var text := out + ("\n" if not out.is_empty() and not err.is_empty() else "") + err
		_finish.call_deferred({ "exit_code": exit_code, "text": text, "cancelled": false })


	## Reads until EOF. The pipe is blocking, so an empty read only happens once git has closed its end — a short read isn't EOF, and get_error() flags those too, so it can't be used here.
	func _drain(pipe: FileAccess, report_progress: bool) -> String:
		var bytes := PackedByteArray()
		var last_progress := ""
		while pipe.is_open():
			var chunk := pipe.get_buffer(4096)
			if chunk.is_empty():
				break
			bytes.append_array(chunk)
			if report_progress:
				var line := _last_progress_line(bytes)
				if line != last_progress:
					last_progress = line
					_emit_progress.call_deferred(line)
		pipe.close()
		return bytes.get_string_from_utf8()


	## Progress lines are rewritten in place with \r; only the tail is decoded (ASCII) since a chunk may end mid-UTF-8.
	func _last_progress_line(bytes: PackedByteArray) -> String:
		var tail := bytes.slice(maxi(0, bytes.size() - 256)).get_string_from_ascii()
		var pieces := tail.replace("\r", "\n").split("\n", false)
		for i in range(pieces.size() - 1, -1, -1):
			var piece := pieces[i].strip_edges()
			if _progress_re.search(piece) != null:
				return piece.trim_prefix("remote: ").trim_suffix(", done.")
		return ""


	## Drops the progress meter lines --progress adds, so the text (errors, Git Console) reads as it did without it.
	func _strip_progress(text: String) -> String:
		var kept := PackedStringArray()
		for line in text.split("\n"):
			var pieces := line.split("\r", false)
			var last := pieces[pieces.size() - 1] if not pieces.is_empty() else ""
			if _progress_noise_re.search(last) == null:
				kept.append(last)
		return "\n".join(kept)


	func _emit_progress(text: String) -> void:
		if is_running:
			progress.emit(text)


	func _finish(result: Dictionary) -> void:
		_thread.wait_to_finish()
		is_running = false
		finished.emit(result)
