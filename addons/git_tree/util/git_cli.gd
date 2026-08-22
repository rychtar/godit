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

## Env vars set for the whole editor process while the plugin is enabled, so no git command can ever block on an interactive prompt (there's no terminal to answer it) — see prepare_environment().
const ENV_OVERRIDES := {
	"GIT_TERMINAL_PROMPT": "0",
	"GIT_EDITOR": "true",
	"GIT_SEQUENCE_EDITOR": "true",
	"GIT_MERGE_AUTOEDIT": "no",
}

static var _saved_env: Dictionary = {}


## Runs `git <args>` in repo_root, returning {"exit_code": int, "text":
## String}. OS.execute passes args directly as argv (no shell), so nothing
## needs escaping.
##
## include_stderr=true merges stderr into "text" — use it for mutating
## commands where a failure's error text matters (commit, checkout,
## branch, reset, push). Leave it false for read-only commands whose
## stdout gets parsed, since git sometimes writes chatter to stderr even
## on success.
static func run(repo_root: String, args: Array, include_stderr: bool = false) -> Dictionary:
	var full_args: PackedStringArray = PackedStringArray(["-C", repo_root])
	for a in args:
		full_args.append(a)

	var output: Array = []
	var exit_code := OS.execute("git", full_args, output, include_stderr, false)
	var text: String = output[0] if not output.is_empty() else ""
	return { "exit_code": exit_code, "text": text }


## Starts `git <args>` on a worker thread and returns a Job; `await job.finished` yields the same {"exit_code", "text", "cancelled"} shape as run() (stderr always included). For slow commands, which would otherwise freeze the editor.
static func start(repo_root: String, args: Array) -> Job:
	var job := Job.new()
	job.start(repo_root, args)
	return job


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

	signal finished(result: Dictionary)

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
		# Both pipes drained at once, so neither can fill up and stall git.
		var out_thread := Thread.new()
		out_thread.start(_drain.bind(stdio))
		var err := _drain(stderr)
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
	func _drain(pipe: FileAccess) -> String:
		var bytes := PackedByteArray()
		while pipe.is_open():
			var chunk := pipe.get_buffer(4096)
			if chunk.is_empty():
				break
			bytes.append_array(chunk)
		pipe.close()
		return bytes.get_string_from_utf8()


	func _finish(result: Dictionary) -> void:
		_thread.wait_to_finish()
		is_running = false
		finished.emit(result)
