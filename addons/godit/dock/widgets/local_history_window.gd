## Local History of a file or folder (FileSystem and script editor menus, Changes, Git Log, the Command Palette): the snapshots that changed it, newest first, each compared with how it is now, and Restore. A folder lists what differs from now under it, files created since included, filtered by name and grouped by folder if wanted.
@tool
extends AcceptDialog

const LocalHistory := preload("res://addons/godit/util/local_history.gd")
const LocalHistoryRecorder := preload("res://addons/godit/util/local_history_recorder.gd")
const DiffViewScript := preload("res://addons/godit/dock/widgets/diff_view.gd")
const EditorOpen := preload("res://addons/godit/util/editor_open.gd")
const SaveGuard := preload("res://addons/godit/dock/widgets/save_guard.gd")
const Dialogs := preload("res://addons/godit/dock/widgets/dialogs.gd")
const Settings := preload("res://addons/godit/util/settings.gd")
const UiScale := preload("res://addons/godit/util/ui_scale.gd")
const CompanionFiles := preload("res://addons/godit/util/companion_files.gd")
const GitIcons := preload("res://addons/godit/util/git_icons.gd")
const RepoWatcher := preload("res://addons/godit/util/repo_watcher.gd")
const TreeFolders := preload("res://addons/godit/util/tree_folders.gd")

const DELETE_ACTION := &"godit_delete_history"
const GROUP_KEY := "local_history_group_folders"
const WEEKDAYS := ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
const MONTHS := ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
const STATUS_COLORS := {"A": GitIcons.COLOR_ADDED, "M": GitIcons.COLOR_MODIFIED, "D": GitIcons.COLOR_DELETED}
const DIM := Color(1, 1, 1, 0.5)

## Set by plugin.gd: opens the window for a repo-relative path; folder: path is a folder ("" = the whole project).
static var opener: Callable

var _repo: RefCounted
var _ctx: Dictionary
var _path := ""
var _folder := false
## The snapshot tree of the files as they are now, which every version is compared with.
var _now := ""
## Every snapshot (LocalHistory.entries()), filtered again as the name filter changes.
var _all: Array = []
var _versions: Array = []
## Folder mode: [status, added, deleted, path] of what differs between the selected version and now, matching the filter.
var _changes: Array = []
## Bumped by every refresh, so a slow snapshot from an earlier one doesn't land in the new list.
var _round := 0
var _where: Label
var _filter: LineEdit
var _group: Button
var _message: Label
var _turn_on: Button
var _split: HSplitContainer
var _list: Tree
var _files: Tree
var _diff: DiffViewScript
var _note: Label
var _restore: Button
var _restore_all: Button


## Opens Local History when Godit runs (it sets opener); a no-op otherwise.
static func open_for(path: String, folder := false) -> void:
	if opener.is_valid():
		opener.call(path, folder)


func _init(repo: RefCounted) -> void:
	_repo = repo
	ok_button_text = "Close"
	min_size = UiScale.size_i(560, 360)
	auto_translate_mode = AUTO_TRANSLATE_MODE_DISABLED # English throughout, see godit_dock.gd
	add_button("Delete All Snapshots…", false, DELETE_ACTION)
	custom_action.connect(func(action: StringName) -> void:
		if action == DELETE_ACTION:
			_delete_all()
	)
	var layout := VBoxContainer.new()
	layout.add_theme_constant_override("separation", int(UiScale.px(6)))
	add_child(layout)
	var top := HBoxContainer.new()
	layout.add_child(top)
	_where = Label.new()
	_where.modulate.a = 0.6
	_where.clip_text = true
	_where.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(_where)
	_filter = LineEdit.new()
	_filter.placeholder_text = "Filter files by name"
	_filter.clear_button_enabled = true
	_filter.custom_minimum_size.x = UiScale.px(260)
	_filter.text_changed.connect(func(_t: String) -> void: _apply_versions())
	top.add_child(_filter)
	_group = Button.new()
	_group.toggle_mode = true
	_group.flat = true
	_group.tooltip_text = "Group the files by folder"
	_group.toggled.connect(func(on: bool) -> void:
		Settings.set_value(GROUP_KEY, on)
		_fill_files(_selected_file_path())
	)
	top.add_child(_group)
	var message_box := VBoxContainer.new()
	message_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	message_box.alignment = BoxContainer.ALIGNMENT_CENTER
	layout.add_child(message_box)
	_message = Label.new()
	_message.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_message.modulate.a = 0.7
	message_box.add_child(_message)
	_turn_on = Button.new()
	_turn_on.text = "Turn On Local History"
	_turn_on.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_turn_on.pressed.connect(func() -> void:
		Settings.set_value(LocalHistory.ENABLED_KEY, true)
		refresh()
	)
	message_box.add_child(_turn_on)
	_split = HSplitContainer.new()
	_split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	layout.add_child(_split)
	_list = Tree.new()
	_list.hide_root = true
	_list.columns = 2
	_list.column_titles_visible = true
	_list.set_column_title(0, "When")
	_list.set_column_title(1, "Changed")
	_list.custom_minimum_size.x = UiScale.px(360)
	_list.item_selected.connect(_on_version_selected)
	_split.add_child(_list)
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_split.add_child(right)
	_files = Tree.new()
	_files.hide_root = true
	_files.columns = 2
	_files.custom_minimum_size.y = UiScale.px(150)
	_files.set_column_expand(1, false)
	_files.set_column_custom_minimum_width(1, int(UiScale.px(110)))
	_files.item_selected.connect(_show_file_diff)
	right.add_child(_files)
	_diff = DiffViewScript.new()
	_diff.options_changed.connect(_show_file_diff)
	right.add_child(_diff)
	var bar := HBoxContainer.new()
	right.add_child(bar)
	_note = Label.new()
	_note.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_note.clip_text = true
	_note.modulate.a = 0.7
	bar.add_child(_note)
	_restore = Button.new()
	_restore.pressed.connect(_on_restore_pressed)
	bar.add_child(_restore)
	_restore_all = Button.new()
	_restore_all.pressed.connect(_on_restore_all_pressed)
	bar.add_child(_restore_all)


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED and _group != null:
		_update_icons()


func _update_icons() -> void:
	_group.icon = get_theme_icon(&"Folder", &"EditorIcons") if has_theme_icon(&"Folder", &"EditorIcons") else null
	_group.text = "" if _group.icon != null else "Folders"
	_filter.right_icon = get_theme_icon(&"Search", &"EditorIcons") if has_theme_icon(&"Search", &"EditorIcons") else null


## Shows path's versions (a file, or a folder when folder; "" = the whole project), taking a snapshot of how things are now first.
func open(path: String, folder: bool) -> void:
	_path = path.trim_suffix("/")
	_folder = folder
	title = "Local History: " + ("Project" if folder and _path.is_empty() else _path.get_file() + ("/" if folder else ""))
	_where.text = (_path + "/" if folder else _path) if not _path.is_empty() else "Every file of the project"
	_filter.visible = folder
	_filter.text = ""
	_group.visible = folder
	_group.set_pressed_no_signal(Settings.get_value(GROUP_KEY, true))
	_files.visible = folder
	_restore.text = "Restore This File" if folder else "Restore This Version"
	_restore_all.visible = false
	_update_icons()
	var screen := DisplayServer.screen_get_usable_rect(DisplayServer.window_get_current_screen()).size
	popup_centered(Vector2i(mini(int(UiScale.px(1040)), int(screen.x * 0.85)), mini(int(UiScale.px(680)), int(screen.y * 0.85))))
	refresh()


## Lists the versions again after a snapshot (why labels it, if it's taken).
func refresh(why := "") -> void:
	_round += 1
	var this_round := _round
	_ctx = {} # the filter waits for the new list
	if not LocalHistory.is_enabled():
		_show_message("Local History is off, so Godit keeps no snapshots of your files. Godit Settings > Local History has its options.", true)
		return
	if not LocalHistoryRecorder.is_on():
		_show_message("Local History needs the project in a git repository.")
		return
	_show_message("Looking for earlier versions…")
	var result: Dictionary = await LocalHistoryRecorder.instance.take(why)
	if this_round != _round or not is_inside_tree():
		return
	if not result["ok"]:
		_show_message("Local History couldn't take a snapshot:\n" + result["error"])
		return
	_now = result["tree"]
	_ctx = LocalHistoryRecorder.instance.context()
	_all = LocalHistory.entries(_ctx)
	_apply_versions()


## The versions for the path and the filter; the selected time stays selected if it's still listed.
func _apply_versions() -> void:
	if _ctx.is_empty():
		return
	var keep: int = _selected_version().get("t", -1)
	_versions = LocalHistory.folder_versions(_all, _path, _filter.text) if _folder else LocalHistory.file_versions(_all, _path)
	if _versions.size() < 2:
		var what := ("anything in " + _path + "/" if not _path.is_empty() else "any file") if _folder else _path.get_file()
		if _folder and not _filter.text.strip_edges().is_empty():
			_show_message("No file matching \"%s\" changed here in the last %d days." % [_filter.text.strip_edges(), _ctx["days"]])
		elif _versions.size() == 1:
			_show_message("Only the version of %s as it is now so far. Local History keeps an earlier one once it changes." % what)
		else:
			_show_message("No earlier version of %s yet. Local History keeps one whenever files change (on save, every few minutes and before git operations), for %d days." % [what, _ctx["days"]])
		return
	_fill_list(keep)


func _show_message(text: String, offer_turn_on := false) -> void:
	_message.text = text
	_message.get_parent().visible = true
	_turn_on.visible = offer_turn_on
	_split.visible = false
	_diff.clear_diff()


func _fill_list(keep: int) -> void:
	_message.get_parent().visible = false
	_split.visible = true
	_list.clear()
	var root := _list.create_item()
	var now := int(Time.get_unix_time_from_system())
	var selected: TreeItem = null
	for i in _versions.size():
		var version: Dictionary = _versions[i]
		var item := _list.create_item(root)
		item.set_text(0, when(version["t"], now) + ("  · now" if i == 0 else ""))
		item.set_tooltip_text(0, _describe(version, i))
		if not String(version["why"]).is_empty():
			item.set_suffix(1, String(version["why"]).to_lower())
		var change := _change_text(version)
		item.set_text(1, change[0])
		item.set_custom_color(1, change[1])
		item.set_tooltip_text(1, change[2])
		item.set_metadata(0, i)
		# How it is now has nothing to compare with: picking it would only empty the right side.
		if i == 0:
			item.set_selectable(0, false)
			item.set_selectable(1, false)
		elif selected == null or version["t"] == keep:
			selected = item
	# The times keep their width, what changed (and why the snapshot was taken) gets the rest.
	var font := _list.get_theme_font(&"font")
	var font_size := _list.get_theme_font_size(&"font_size")
	var widest := 0.0
	for item in root.get_children():
		widest = maxf(widest, font.get_string_size(item.get_text(0), HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x)
	_list.set_column_expand(0, false)
	_list.set_column_custom_minimum_width(0, int(widest + UiScale.px(20)))
	selected.select(0)


## [text, color, tooltip] of what a version changed: lines for a file, the files for a folder.
func _change_text(version: Dictionary) -> Array:
	if _folder:
		var files: Array = version["files"]
		if files.is_empty():
			return ["oldest", DIM, "How the files were before the changes above"]
		var paths := files.map(func(f: Array) -> String: return f[3])
		var tooltip := "\n".join(paths.slice(0, 15)) + ("\n… and %d more" % (paths.size() - 15) if paths.size() > 15 else "")
		return [String(paths[0]).get_file() if files.size() == 1 else "%d files" % files.size(), Color(1, 1, 1, 0.75), tooltip]
	match version["status"]:
		"A":
			return ["created", STATUS_COLORS["A"], "Created then"]
		"D":
			return ["deleted", STATUS_COLORS["D"], "Deleted then"]
		"":
			return ["oldest", DIM, "The oldest version Local History has"]
	if version["added"] < 0:
		return ["binary", STATUS_COLORS["M"], "A binary change"]
	return ["+%d −%d" % [version["added"], version["deleted"]], STATUS_COLORS["M"], "Lines added and removed then"]


func _describe(version: Dictionary, index: int) -> String:
	var lines := PackedStringArray([Time.get_datetime_string_from_unix_time(version["t"] + _bias(), true)])
	if not String(version["why"]).is_empty():
		lines.append(version["why"])
	lines.append("How it is now: pick an earlier time to compare it with" if index == 0 else "Click to compare with now")
	return "\n".join(lines)


## Index of the selected version in _versions (0 = how it is now), or -1.
func _selected_index() -> int:
	var item := _list.get_selected()
	return item.get_metadata(0) if item != null else -1


func _selected_version() -> Dictionary:
	var index := _selected_index()
	return _versions[index] if index >= 0 and index < _versions.size() else {}


func _on_version_selected() -> void:
	var version := _selected_version()
	if version.is_empty():
		return
	if not _folder:
		_show_file_diff()
		return
	var keep := _selected_file_path()
	var needle := _filter.text.strip_edges().to_lower()
	_changes = LocalHistory.changes(_ctx, version["tree"], _now, _path).filter(func(c: Array) -> bool: return needle.is_empty() or String(c[3]).to_lower().contains(needle))
	_fill_files(keep)


## The files that differ from now, flat or under their folders; keep stays selected if it's there, else the first file.
func _fill_files(keep := "") -> void:
	_files.clear()
	var root := _files.create_item()
	var grouped: bool = Settings.get_value(GROUP_KEY, true)
	var folders := {}
	var selected: TreeItem = null
	for change: Array in _changes:
		var path: String = change[3]
		var shown := path.trim_prefix(_path + "/") if not _path.is_empty() else path
		var parent := TreeFolders.get_or_create_folder(_files, root, folders, shown.get_base_dir()) if grouped else root
		var item := _files.create_item(parent)
		item.set_text(0, shown.get_file() if grouped else shown)
		item.set_tooltip_text(0, path)
		item.set_custom_color(0, STATUS_COLORS.get(change[0], GitIcons.COLOR_DEFAULT))
		item.set_metadata(0, change)
		match change[0]:
			"A":
				item.set_text(1, "created since")
			"D":
				item.set_text(1, "deleted since")
			_:
				item.set_text(1, "binary" if change[1] < 0 else "+%d −%d" % [change[1], change[2]])
		if selected == null or path == keep:
			selected = item
	if _changes.is_empty():
		var none := _files.create_item(root)
		none.set_text(0, "Nothing here differs from now" if _filter.text.strip_edges().is_empty() else "No file matching the filter differs from now")
		none.set_custom_color(0, DIM)
		none.set_selectable(0, false)
		none.set_selectable(1, false)
	_restore_all.text = "Restore All %d Files" % _changes.size()
	_restore_all.visible = _changes.size() > 1
	if selected != null:
		selected.select(0)
	else:
		_show_file_diff()


## Folder mode: the path of the selected file, or "".
func _selected_file_path() -> String:
	var item := _files.get_selected()
	var change: Variant = item.get_metadata(0) if item != null else null
	return change[3] if change is Array else ""


## The selected file (folder mode) or the file, from the selected version to now.
func _show_file_diff() -> void:
	var version := _selected_version()
	var path := _path
	var change: Variant = null
	if _folder:
		var item := _files.get_selected()
		change = item.get_metadata(0) if item != null and item.get_metadata(0) is Array else null
		path = change[3] if change != null else ""
	if version.is_empty() or path.is_empty():
		_diff.clear_diff()
		_note.text = ""
		_restore.disabled = true
		return
	var when_text := when(version["t"], int(Time.get_unix_time_from_system()))
	_diff.show_diff(_repo.get_diff_between(version["tree"], _now, path, _diff.get_options()), {
		"path": path, "repo": _repo, "old_rev": version["tree"], "new_rev": _now, "note": when_text + " → now",
	})
	var gone: bool = not _folder and version["status"] == "D"
	_restore.disabled = gone
	_restore.tooltip_text = "Puts it back as it was %s; Local History keeps the current version" % when_text.to_lower()
	if gone:
		_note.text = "The file didn't exist then."
	elif change != null and change[0] == "A":
		_note.text = "Created since then: restoring deletes it."
	else:
		_note.text = ""


func _on_restore_pressed() -> void:
	var version := _selected_version()
	if version.is_empty():
		return
	var paths: Array
	if _folder:
		var path := _selected_file_path()
		if path.is_empty():
			return
		paths = [path]
	else:
		paths = [_path]
		# A deleted script's .uid comes back with it, so scenes find it by its old uid.
		for suffix: String in CompanionFiles.SUFFIXES:
			if not FileAccess.file_exists(_repo.get_repo_root().path_join(_path + suffix)) and LocalHistory.has_file(_ctx, version["tree"], _path + suffix):
				paths.append(_path + suffix)
	await _restore_paths(version, paths)


func _on_restore_all_pressed() -> void:
	var version := _selected_version()
	if version.is_empty() or _changes.is_empty():
		return
	var created := _changes.filter(func(c: Array) -> bool: return c[0] == "A").size()
	var when_text := when(version["t"], int(Time.get_unix_time_from_system())).to_lower()
	var message := "Put %d file%s %s back to how they were %s?" % [_changes.size(), "" if _changes.size() == 1 else "s", "in " + _path + "/" if not _path.is_empty() else "of the project", when_text]
	if created > 0:
		message += " %d created since then will be deleted." % created
	if not await Dialogs.confirm(self, "Restore All", message + "\n\nLocal History keeps the current versions.", "Restore All"):
		return
	await _restore_paths(version, _changes.map(func(c: Array) -> String: return c[3]))


func _restore_paths(version: Dictionary, paths: Array) -> void:
	if not await SaveGuard.ensure_saved(self, "Restore"): # Local History gets the current versions there
		return
	var result := LocalHistory.restore(_ctx, version["tree"], paths)
	EditorOpen.refresh_external_changes(_repo.get_repo_root(), result["written"])
	if is_instance_valid(RepoWatcher.instance):
		RepoWatcher.instance.poll_now()
	if not result["ok"]:
		await Dialogs.error(self, "Couldn't Restore Everything", result["error"])
	var when_text := when(version["t"], int(Time.get_unix_time_from_system()))
	EditorInterface.get_editor_toaster().push_toast("Godit: %s back to how %s %s." % [
		paths[0].get_file() + " is" if paths.size() == 1 else "%d files are" % paths.size(), "it was" if paths.size() == 1 else "they were", when_text.to_lower()])
	refresh("Restored")


func _delete_all() -> void:
	if not await Dialogs.confirm(self, "Delete All Snapshots",
			"Delete every Local History snapshot of this project? Earlier versions of its files can't be restored from Local History afterwards; git gc frees their space later.", "Delete All"):
		return
	if is_instance_valid(LocalHistoryRecorder.instance) and LocalHistoryRecorder.instance.repo != null:
		await LocalHistoryRecorder.instance.clear()
	refresh()


## "Today 14:05:33", "Yesterday 09:12:00", "Fri 17 Oct 18:30:12", in local time.
static func when(t: int, now: int) -> String:
	var bias := _bias()
	var local := Time.get_datetime_dict_from_unix_time(t + bias)
	var clock := "%02d:%02d:%02d" % [local["hour"], local["minute"], local["second"]]
	var days_ago := floori(float(now + bias) / LocalHistory.DAY) - floori(float(t + bias) / LocalHistory.DAY)
	if days_ago == 0:
		return "Today " + clock
	if days_ago == 1:
		return "Yesterday " + clock
	return "%s %d %s %s" % [WEEKDAYS[local["weekday"]], local["day"], MONTHS[local["month"] - 1], clock]


## Seconds the local time zone is ahead of UTC.
static func _bias() -> int:
	return int(Time.get_time_zone_from_system().get("bias", 0)) * 60
