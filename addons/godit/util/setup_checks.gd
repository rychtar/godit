## What the Check Setup window checks, and the fixes it offers: git, who commits, a remote, logging in to it, .godot/ ignored, line endings, Git LFS and big files. Each check is {"id", "title", "state": OK|WARN|FAIL, "detail", "fixes": [[fix id, button label]], "commands": [text to copy and run in a terminal], "links": [[label, url]]}. No class_name: internal helper, addressed via preload.
extends RefCounted

const GitCli := preload("res://addons/godit/util/git_cli.gd")
const GitErrors := preload("res://addons/godit/util/git_errors.gd")
const RepoSetup := preload("res://addons/godit/util/repo_setup.gd")
const WebLinks := preload("res://addons/godit/util/web_links.gd")

const OK := "ok"
const WARN := "warn"
const FAIL := "fail"
## Committed files over this size are worth moving to Git LFS (GitHub rejects files over 100 MB).
const BIG_FILE_BYTES := 10 * 1024 * 1024
const SSH_KEY_FILES := ["id_ed25519.pub", "id_ecdsa.pub", "id_rsa.pub"]
## Where each host takes a new SSH key, by WebLinks' site kind (with the host filled in, so self-hosted GitLab works too).
const SSH_KEY_PAGES := {"github": "https://%s/settings/keys", "gitlab": "https://%s/-/user_settings/ssh_keys", "bitbucket": "https://%s/account/settings/ssh-keys/"}
const MB := 1024 * 1024


## Everything but logging in, which needs the network (login()).
static func local_checks(repo: RefCounted, big_file_bytes := BIG_FILE_BYTES) -> Array:
	return [_git(repo), _identity(repo), remote_check(repo), _ignore(repo), _line_endings(repo), _lfs(repo, big_file_bytes)]


static func _check(id: String, title: String, state: String, detail: String) -> Dictionary:
	return {"id": id, "title": title, "state": state, "detail": detail, "fixes": [], "commands": [], "links": []}


static func _git(repo: RefCounted) -> Dictionary:
	var version: String = GitCli.run(repo.get_repo_root(), ["--version"])["text"].strip_edges()
	return _check("git", "Git", OK if not version.is_empty() else FAIL, version.trim_prefix("git version ").strip_edges() if not version.is_empty() else "git isn't on the PATH.")


static func _identity(repo: RefCounted) -> Dictionary:
	var root: String = repo.get_repo_root()
	var name: String = GitCli.run(root, ["config", "user.name"])["text"].strip_edges()
	var email: String = GitCli.run(root, ["config", "user.email"])["text"].strip_edges()
	if name.is_empty() or email.is_empty():
		var check := _check("identity", "Your name for commits", FAIL, "Every commit carries a name and an email, and git has none yet, so committing fails.")
		check["fixes"] = [["identity", "Set Name and Email…"]]
		return check
	return _check("identity", "Your name for commits", OK, "%s <%s>" % [name, email])


## The remote that fetch, pull and push use; {} details when there's none.
static func remote_check(repo: RefCounted) -> Dictionary:
	var remote := _default_remote(repo)
	if remote.is_empty():
		var check := _check("remote", "Remote", WARN, "No remote: commits stay on this computer only. Add one to back them up and share them.")
		check["fixes"] = [["remote", "Add Remote…"]]
		return check
	return _check("remote", "Remote", OK, "%s → %s" % [remote["name"], remote["url"]])


## {"name", "url"} of origin (or the first remote), or {}.
static func _default_remote(repo: RefCounted) -> Dictionary:
	var remotes: Array = repo.list_remotes()
	if remotes.is_empty():
		return {}
	var chosen: Dictionary = remotes[0]
	for r: Dictionary in remotes:
		if r["name"] == "origin":
			chosen = r
	return {"name": chosen["name"], "url": chosen["fetch_url"]}


static func _ignore(repo: RefCounted) -> Dictionary:
	var root: String = repo.get_repo_root()
	var project := _project_prefix(root)
	var lines := _lines(root.path_join(project).path_join(".gitignore")) + _lines(root.path_join(".gitignore"))
	var ignored := lines.any(func(l: String) -> bool: return l.trim_prefix("/").trim_suffix("/") in [".godot", project.path_join(".godot")])
	var tracked: String = GitCli.run(root, ["ls-files", "--", project.path_join(".godot")])["text"].strip_edges()
	if not tracked.is_empty():
		var check := _check("ignore", "Godot's cache", FAIL, ".godot/ is in git: it's rebuilt on every computer and changes all the time, so it only causes conflicts.")
		check["fixes"] = [["untrack_godot", "Stop Tracking .godot/"]]
		return check
	if not ignored:
		var check := _check("ignore", "Godot's cache", FAIL, ".godot/ isn't in .gitignore, so it would show up in Changes and get committed.")
		check["fixes"] = [["ignore_godot", "Add .godot/ to .gitignore"]]
		return check
	return _check("ignore", "Godot's cache", OK, ".godot/ is ignored.")


static func _line_endings(repo: RefCounted) -> Dictionary:
	var lines := _lines(repo.get_repo_root().path_join(".gitattributes"))
	if lines.any(func(l: String) -> bool: return l.begins_with("* text=auto")):
		return _check("line_endings", "Line endings", OK, "Pinned in .gitattributes.")
	var check := _check("line_endings", "Line endings", WARN, "Not pinned in .gitattributes: teammates on Windows and macOS can turn each other's files into whole-file changes. After adding it, files committed with Windows endings show as changed once.")
	check["fixes"] = [["line_endings", "Add * text=auto eol=lf"]]
	return check


static func _lfs(repo: RefCounted, big_file_bytes: int) -> Dictionary:
	var root: String = repo.get_repo_root()
	var uses_lfs := _lines(root.path_join(".gitattributes")).any(func(l: String) -> bool: return l.contains("filter=lfs"))
	var installed := RepoSetup.lfs_available()
	if uses_lfs and not installed:
		var check := _check("lfs", "Git LFS", FAIL, "This repository keeps files in Git LFS, but git-lfs isn't installed: those files are only small pointer files here.")
		check["links"] = [["Get Git LFS", "https://git-lfs.com"]]
		return check
	var big := big_files(repo, big_file_bytes)
	if big.is_empty():
		return _check("lfs", "Big files", OK, "Git LFS is set up." if uses_lfs else "No committed file is over %d MB." % int(big_file_bytes / float(MB)))
	var listed := ", ".join(big.slice(0, 5).map(func(e: Dictionary) -> String: return "%s (%s)" % [e["path"].get_file(), String.humanize_size(e["size"])]))
	var check := _check("lfs", "Big files", WARN, "%d committed file%s over %d MB: %s. They make every clone slower, and GitHub rejects files over 100 MB." % [big.size(), "" if big.size() == 1 else "s", int(big_file_bytes / float(MB)), listed])
	if installed:
		check["fixes"] = [["lfs_track", "Track Them with Git LFS"]]
	else:
		check["links"] = [["Get Git LFS", "https://git-lfs.com"]]
	return check


## [{"path", "size"}] of the files at HEAD over bytes, biggest first (LFS pointer files are tiny, so tracked ones don't count).
static func big_files(repo: RefCounted, bytes: int) -> Array:
	var out: Array = []
	for line in GitCli.lines(GitCli.run(repo.get_repo_root(), ["ls-tree", "-r", "-l", "HEAD"])["text"]):
		var tab := line.find("\t")
		var meta := line.substr(0, tab).split(" ", false)
		if tab == -1 or meta.size() < 4 or meta[1] != "blob":
			continue
		var size := meta[3].to_int()
		if size > bytes:
			out.append({"path": GitCli.unquote(line.substr(tab + 1)), "size": size})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["size"] > b["size"])
	return out


## "ssh", "https", "file" or "" for a remote URL.
static func protocol(url: String) -> String:
	if url.begins_with("https://") or url.begins_with("http://"):
		return "https"
	if url.begins_with("ssh://") or (url.contains("@") and url.contains(":") and not url.contains("://")):
		return "ssh"
	if url.begins_with("file://") or url.begins_with("/") or url.begins_with(".") or (url.length() > 2 and url[1] == ":"):
		return "file"
	return ""


## "github.com" from https://github.com/a/b, git@github.com:a/b or ssh://git@github.com:22/a/b; "" for a local path.
static func host(url: String) -> String:
	if protocol(url) == "file":
		return ""
	var authority := (url.get_slice("://", 1) if url.contains("://") else url).get_slice("/", 0)
	if authority.contains("@"):
		authority = authority.get_slice("@", 1)
	return authority.get_slice(":", 0)


## Coroutine: asks the remote for its branches without changing anything (git never prompts, so a missing login fails instead of waiting). gh: path of a logged-in GitHub CLI, or "".
static func login(repo: RefCounted, gh: String) -> Dictionary:
	var remote := _default_remote(repo)
	if remote.is_empty():
		return _check("login", "Logging in to the remote", WARN, "Add a remote first.")
	var url: String = remote["url"]
	var r: Dictionary = await GitCli.start(repo.get_repo_root(), ["ls-remote", "--heads", remote["name"]], false).finished
	var where := host(url) if not host(url).is_empty() else url
	var kind := protocol(url)
	if r["exit_code"] == 0:
		return _check("login", "Logging in to the remote", OK, "Connected to %s%s." % [where, " over SSH" if kind == "ssh" else (" over HTTPS" if kind == "https" else "")])
	var error: String = r["text"].strip_edges()
	match GitErrors.classify(error):
		GitErrors.AUTH:
			return _ssh_help(where, url) if kind == "ssh" else _https_help(repo, where, url, gh)
		GitErrors.HOST_KEY:
			var check := _check("login", "Logging in to the remote", FAIL, "%s's SSH host key isn't trusted yet, and Godit can't answer ssh's question. Connect once in a terminal and answer yes:" % where)
			check["commands"] = ["ssh -T git@%s" % where]
			return check
	return _check("login", "Logging in to the remote", FAIL, "Couldn't reach %s: offline, or the address is wrong?\n%s" % [where, error.left(300)])


static func _ssh_help(where: String, url: String) -> Dictionary:
	var check := _check("login", "Logging in to the remote", FAIL, "%s refused the SSH key. Add your public key to your account there (and to ssh-agent, if it has a passphrase)." % where)
	var key := ""
	for file: String in SSH_KEY_FILES:
		var path := OS.get_environment("HOME").path_join(".ssh").path_join(file)
		if not OS.get_environment("HOME").is_empty() and FileAccess.file_exists(path):
			key = path
			break
	var site := WebLinks.site_for_url(url)
	if not key.is_empty():
		check["fixes"].append(["copy_ssh_key:" + key, "Copy Public Key"])
		check["commands"] = ["ssh-add " + key.trim_suffix(".pub")]
	else:
		check["detail"] += " There's no key in ~/.ssh yet; this creates one:"
		check["commands"] = ["ssh-keygen -t ed25519"]
	if not site.is_empty():
		check["links"] = [["Open %s's SSH Keys Page" % site["name"], SSH_KEY_PAGES[site["kind"]] % where]]
	return check


static func _https_help(repo: RefCounted, where: String, url: String, gh: String) -> Dictionary:
	var check := _check("login", "Logging in to the remote", FAIL, "%s asked for a login, and Godit can't answer password prompts. Let git remember it: log in once from a terminal, with a credential helper set up." % where)
	if not gh.is_empty() and where.contains("github"):
		check["detail"] = "%s asked for a login. The GitHub CLI is logged in here, so git can use its login." % where
		check["fixes"] = [["gh_setup_git", "Use the GitHub CLI's Login"]]
		return check
	match OS.get_name():
		"macOS":
			check["commands"] = ["git config --global credential.helper osxkeychain"]
		"Windows":
			check["detail"] += " Git for Windows comes with Git Credential Manager, which opens a login window."
			check["commands"] = ["git config --global credential.helper manager"]
		_:
			check["commands"] = ["git config --global credential.helper libsecret"]
	check["commands"].append("git -C \"%s\" fetch" % repo.get_repo_root())
	return check


## Applies a fix from a check's "fixes"; values: what the fix asked for (name and email, remote URL…). {"ok", "error"}.
static func apply(repo: RefCounted, fix: String, values: Dictionary = {}) -> Dictionary:
	var root: String = repo.get_repo_root()
	match fix:
		"identity":
			var scope := ["--global"] if values.get("global", true) else []
			for key in ["name", "email"]:
				var r := GitCli.run(root, ["config"] + scope + ["user." + key, String(values[key]).strip_edges()], true)
				if r["exit_code"] != 0:
					return {"ok": false, "error": r["text"].strip_edges()}
		"remote":
			return repo.add_remote(String(values.get("name", "origin")).strip_edges(), String(values["url"]).strip_edges())
		"ignore_godot":
			RepoSetup.append_missing_lines(root.path_join(_project_prefix(root)).path_join(".gitignore"), [".godot/"])
		"untrack_godot":
			var r := GitCli.run(root, ["rm", "-r", "--cached", "--quiet", "--", _project_prefix(root).path_join(".godot")], true)
			if r["exit_code"] != 0:
				return {"ok": false, "error": r["text"].strip_edges()}
			RepoSetup.append_missing_lines(root.path_join(_project_prefix(root)).path_join(".gitignore"), [".godot/"])
		"line_endings":
			RepoSetup.append_missing_lines(root.path_join(".gitattributes"), RepoSetup.GITATTRIBUTES_LINES)
		"lfs_track":
			return repo.lfs_track(big_files(repo, int(values.get("bytes", BIG_FILE_BYTES))).map(func(e: Dictionary) -> String: return e["path"]))
		"gh_setup_git":
			var r: Dictionary = await RepoSetup.run_program(values["gh"], ["auth", "setup-git"])
			if r["exit_code"] != 0:
				return {"ok": false, "error": r["text"].strip_edges()}
		_:
			if fix.begins_with("copy_ssh_key:"):
				DisplayServer.clipboard_set(FileAccess.get_file_as_string(fix.trim_prefix("copy_ssh_key:")).strip_edges())
	return {"ok": true, "error": ""}


## The Godot project's folder inside the repository ("" when it's the root).
static func _project_prefix(root: String) -> String:
	var project := ProjectSettings.globalize_path("res://").trim_suffix("/")
	return project.trim_prefix(root).trim_prefix("/") if project.begins_with(root) else ""


static func _lines(path: String) -> Array:
	if not FileAccess.file_exists(path):
		return []
	return Array(FileAccess.get_file_as_string(path).split("\n")).map(func(l: String) -> String: return l.strip_edges())
