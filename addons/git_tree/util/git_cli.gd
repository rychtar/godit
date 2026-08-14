## Thin wrapper around OS.execute() for running `git` in a given repo root.
## No class_name: internal helper, addressed via preload.
extends RefCounted

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
