extends "res://tests/assertions.gd"

# The recorder's snapshots and the Local History window's lists; restoring is tested in test_local_history.gd (here it'd need the editor).

const LocalHistory = preload("res://addons/godit/util/local_history.gd")
const Recorder = preload("res://addons/godit/util/local_history_recorder.gd")
const LocalHistoryWindow = preload("res://addons/godit/dock/widgets/local_history_window.gd")
const Settings = preload("res://addons/godit/util/settings.gd")

var _repo: GitCliRepo
var _recorder: Node

# a repo with a.gd committed, its recorder, and a first snapshot
func _setup() -> void:
	await tree.process_frame # the root isn't in the tree yet while the runner starts
	_repo = make_repo()
	commit_file(_repo, "a.gd", "1\n", "first")
	commit_file(_repo, "scenes/level.tscn", "[gd_scene]\n", "second")
	_recorder = track(Recorder.new())
	tree.root.add_child(_recorder)
	_recorder.set_repo(_repo, "")
	await _recorder.take("")

func _edit(path: String, content: String, why := "") -> void:
	write_file(_repo.get_repo_root().path_join(path), content)
	await _recorder.take(why)

func _window(path: String, folder: bool) -> LocalHistoryWindow:
	var window: LocalHistoryWindow = track(LocalHistoryWindow.new(_repo))
	tree.root.add_child(window)
	window.open(path, folder)
	await window.refresh()
	return window

func _rows(window: LocalHistoryWindow) -> Array:
	return window._list.get_root().get_children().map(func(item: TreeItem) -> Array: return [item.get_text(1), item.get_suffix(1)])

func test_the_recorder_takes_snapshots_one_at_a_time() -> void:
	await _setup()
	write_file(_repo.get_repo_root().path_join("a.gd"), "2\n")
	_recorder.request("")
	var second: Dictionary = await _recorder.take("Before Pull")
	check("the request ran first, the take found nothing new", [second.ok, second.taken], [true, false])
	check("two snapshots", LocalHistory.entries(_recorder.context()).size(), 2)
	await Recorder.before("Revert")
	check("nothing changed: none before Revert", LocalHistory.entries(_recorder.context()).size(), 2)
	Settings.set_value(LocalHistory.ENABLED_KEY, false)
	write_file(_repo.get_repo_root().path_join("a.gd"), "3\n")
	check("off: none taken", (await _recorder.take("")).ok, false)
	check("and it says so", Recorder.is_on(), false)
	Settings.set_value(LocalHistory.ENABLED_KEY, true)
	check("on again", (await _recorder.take("")).ok, true) # after the one turning it on started

func test_a_files_versions() -> void:
	await _setup()
	await _edit("a.gd", "1\n2\n", "Before Pull")
	await _edit("a.gd", "3\n")
	await _edit("scenes/level.tscn", "[gd_scene format=3]\n")
	var window := await _window("a.gd", false)
	check("title", window.title, "Local History: a.gd")
	check("newest first, then the version before its oldest change", _rows(window), [["+1 −2", ""], ["+1 −0", "before pull"], ["oldest", ""]])
	check("the one before now is selected", window._selected_index(), 1)
	check("compared with now", window._diff._diff_text.contains("-1\n-2\n+3"), true)
	check("restorable", window._restore.disabled, false)
	check("now has nothing to compare with", window._list.get_root().get_child(0).is_selectable(0), false)

func test_a_folders_versions() -> void:
	await _setup()
	await _edit("scenes/level.tscn", "[gd_scene format=3]\n")
	await _edit("scenes/new.tscn", "[gd_scene]\n")
	await _edit("a.gd", "2\n")
	var window := await _window("scenes", true)
	check("title", window.title, "Local History: scenes/")
	check("only what changed in the folder", _rows(window).map(func(r: Array) -> String: return r[0]), ["new.tscn", "level.tscn", "oldest"])
	window._list.get_root().get_child(2).select(0)
	var files := window._files.get_root().get_children().map(func(item: TreeItem) -> Array: return [item.get_text(0), item.get_text(1)])
	check("what differs from now", files, [["level.tscn", "+1 −1"], ["new.tscn", "created since"]])
	check("restore them all", [window._restore_all.text, window._restore_all.visible], ["Restore All 2 Files", true])
	window._files.get_root().get_child(1).select(0)
	check("a file created since goes", window._note.text, "Created since then: restoring deletes it.")
	window.hide() # one dialog at a time
	var project := await _window("", true)
	check("the whole project", [project.title, project._versions.size()], ["Local History: Project", 4])
	project._list.get_root().get_child(3).select(0)
	check("under their folders", _file_rows(project._files.get_root()), ["a.gd", "scenes/", "  level.tscn", "  new.tscn"])
	project._group.button_pressed = false
	check("or flat", _file_rows(project._files.get_root()), ["a.gd", "scenes/level.tscn", "scenes/new.tscn"])
	project._filter.text = "new"
	project._filter.text_changed.emit("new")
	check("filtered: the times that changed it", _rows(project).map(func(r: Array) -> String: return r[0]), ["new.tscn", "oldest"])
	check("and only those files", _file_rows(project._files.get_root()), ["scenes/new.tscn"])
	Settings.set_value(LocalHistoryWindow.GROUP_KEY, true)

# file names in the files list, folders ending in "/" with their files indented
func _file_rows(parent: TreeItem, indent := "") -> Array:
	var out: Array = []
	for item in parent.get_children():
		var folder: bool = item.get_metadata(0) is Dictionary
		out.append(indent + item.get_text(0) + ("/" if folder else ""))
		if folder:
			out.append_array(_file_rows(item, indent + "  "))
	return out

func test_nothing_yet() -> void:
	await _setup()
	var window := await _window("a.gd", false)
	check("says so", [window._split.visible, window._message.text.begins_with("No earlier version of a.gd yet")], [false, true])

func test_times_read_like_a_clock() -> void:
	var noon := 20000 * LocalHistory.DAY + 12 * 3600 - LocalHistoryWindow._bias() # Friday 4 Oct 2024, 12:00 here
	check("today", LocalHistoryWindow.when(noon - 3600, noon), "Today 11:00:00")
	check("yesterday", LocalHistoryWindow.when(noon - LocalHistory.DAY, noon), "Yesterday 12:00:00")
	check("earlier", LocalHistoryWindow.when(noon - 3 * LocalHistory.DAY + 5, noon), "Tue 1 Oct 12:00:05")
