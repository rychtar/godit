## Godit Setup ("Godit: Check Setup…", Tools > Godit, "Help Me Log In" after a login error): is git set up for this project, each check with what's wrong and a fix (see setup_checks.gd). Logging in is tried for real, in the background.
@tool
extends AcceptDialog

const SetupChecks := preload("res://addons/godit/util/setup_checks.gd")
const RepoSetup := preload("res://addons/godit/util/repo_setup.gd")
const RepoWatcher := preload("res://addons/godit/util/repo_watcher.gd")
const Dialogs := preload("res://addons/godit/dock/widgets/dialogs.gd")
const UiScale := preload("res://addons/godit/util/ui_scale.gd")

const RECHECK := &"godit_recheck"
const STATE_ICONS := {SetupChecks.OK: &"StatusSuccess", SetupChecks.WARN: &"StatusWarning", SetupChecks.FAIL: &"StatusError"}

var _repo: RefCounted
var _list: VBoxContainer
## Path of a logged-in GitHub CLI, or "" (looked up once per check, it asks the network).
var _gh := ""
## Bumped by every refresh, so a slow login check from an earlier one doesn't land in the new list.
var _round := 0


func _init(repo: RefCounted) -> void:
	_repo = repo
	title = "Godit Setup"
	ok_button_text = "Close"
	min_size = UiScale.size_i(480, 320)
	auto_translate_mode = AUTO_TRANSLATE_MODE_DISABLED # English throughout, see godit_dock.gd
	add_button("Check Again", true, RECHECK)
	custom_action.connect(func(action: StringName) -> void:
		if action == RECHECK:
			refresh()
	)
	var layout := VBoxContainer.new()
	add_child(layout)
	var where := Label.new()
	where.text = repo.get_repo_root()
	where.modulate.a = 0.6
	where.clip_text = true
	layout.add_child(where)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	layout.add_child(scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", int(UiScale.px(12)))
	scroll.add_child(_list)


func open() -> void:
	var screen := DisplayServer.screen_get_usable_rect(DisplayServer.window_get_current_screen()).size
	popup_centered(Vector2i(mini(int(UiScale.px(680)), int(screen.x * 0.8)), mini(int(UiScale.px(600)), int(screen.y * 0.85))))
	refresh()


## Runs every check again; the login one fills in when the remote answers.
func refresh() -> void:
	_round += 1
	var this_round := _round
	for child in _list.get_children():
		child.free()
	for check: Dictionary in SetupChecks.local_checks(_repo):
		_list.add_child(_row(check))
	var pending := _row({"id": "login", "title": "Logging in to the remote", "state": "", "detail": "Checking…", "fixes": [], "commands": [], "links": []})
	_list.add_child(pending)
	_list.move_child(pending, 3) # after the remote
	_gh = await RepoSetup.find_gh()
	var login: Dictionary = await SetupChecks.login(_repo, _gh)
	if this_round != _round or not is_instance_valid(pending):
		return
	var row := _row(login)
	_list.add_child(row)
	_list.move_child(row, pending.get_index())
	pending.free()


func _row(check: Dictionary) -> Control:
	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", int(UiScale.px(4)))
	var head := HBoxContainer.new()
	row.add_child(head)
	var icon := TextureRect.new()
	icon.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	var icon_name: StringName = STATE_ICONS.get(check["state"], &"Search")
	if has_theme_icon(icon_name, &"EditorIcons"):
		icon.texture = get_theme_icon(icon_name, &"EditorIcons")
	head.add_child(icon)
	var title_label := Label.new()
	title_label.text = check["title"]
	title_label.theme_type_variation = &"HeaderSmall"
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title_label)
	for fix: Array in check["fixes"]:
		var button := Button.new()
		button.text = fix[1]
		button.pressed.connect(_fix.bind(fix[0]))
		head.add_child(button)
	for link: Array in check["links"]:
		var button := Button.new()
		button.text = link[0]
		button.pressed.connect(OS.shell_open.bind(link[1]))
		head.add_child(button)
	var detail := Label.new()
	detail.text = check["detail"]
	detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	detail.modulate.a = 0.7
	row.add_child(detail)
	for command: String in check["commands"]:
		var line := HBoxContainer.new()
		var text := LineEdit.new()
		text.text = command
		text.editable = false
		text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		line.add_child(text)
		var copy := Button.new()
		copy.text = "Copy"
		copy.tooltip_text = "Copy it, then run it in a terminal"
		copy.pressed.connect(DisplayServer.clipboard_set.bind(command))
		line.add_child(copy)
		row.add_child(line)
	return row


## Asks what a fix needs, applies it and checks again.
func _fix(fix: String) -> void:
	var values := {}
	match fix:
		"identity":
			var answer: Variant = await Dialogs.form(self, "Your Name for Commits", [
				{ "key": "name", "label": "Name", "placeholder": "Jane Doe" },
				{ "key": "email", "label": "Email", "placeholder": "jane@example.com", "tooltip": "GitHub and GitLab link commits to your account by this address" },
				{ "key": "global", "label": "For all my repositories", "type": "check", "default": true },
			], "Save")
			if answer == null or String(answer["name"]).strip_edges().is_empty() or String(answer["email"]).strip_edges().is_empty():
				return
			values = answer
		"remote":
			var answer: Variant = await Dialogs.form(self, "Add Remote", [
				{ "key": "name", "label": "Name", "default": "origin" },
				{ "key": "url", "label": "URL", "placeholder": "git@github.com:you/game.git or https://github.com/you/game.git", "tooltip": "Copy it from the repository's page on GitHub, GitLab or Bitbucket" },
			], "Add")
			if answer == null or String(answer["url"]).strip_edges().is_empty():
				return
			values = answer
		"gh_setup_git":
			values = {"gh": _gh}
		"untrack_godot":
			if not await Dialogs.confirm(self, "Stop Tracking .godot/", "Removes .godot/ from git and ignores it; the folder stays on disk. Commit the change, so it goes for everyone.", "Stop Tracking"):
				return
		"lfs_track":
			if not await Dialogs.confirm(self, "Track with Git LFS", "Their file types go to Git LFS from now on, and the files are staged that way for your next commit. The versions already in the history stay as they are.", "Track"):
				return
	var result: Dictionary = await SetupChecks.apply(_repo, fix, values)
	if not result["ok"]:
		await Dialogs.error(self, "Couldn't Fix It", result["error"])
	if is_instance_valid(RepoWatcher.instance):
		RepoWatcher.instance.poll_now() # Changes shows what the fix changed
	refresh()
