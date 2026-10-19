extends "res://tests/assertions.gd"

# The window's list and staging; committing goes through the Changes panel (and the editor's save check), tested there.

const ChangesPanelScene = preload("res://addons/godit/dock/panels/changes_panel.tscn")
const QuickCommit = preload("res://addons/godit/dock/widgets/quick_commit.gd")
const Settings = preload("res://addons/godit/util/settings.gd")

# Auto-staging off (in the runner's temp settings): the window shows what the checkboxes did.
func _window() -> QuickCommit:
	await tree.process_frame # the root isn't in the tree yet while the runner starts
	Settings.set_value("auto_stage_changes", false)
	var repo := make_repo()
	commit_file(repo, "a.txt", "1\n", "first")
	commit_file(repo, "b.txt", "1\n", "second")
	write_file(repo.get_repo_root().path_join("a.txt"), "2\n")
	write_file(repo.get_repo_root().path_join("b.txt"), "2\n")
	var panel: Control = track(ChangesPanelScene.instantiate())
	panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	panel.size = Vector2(900, 600)
	tree.root.add_child(panel)
	panel.set_repo(repo)
	await tree.process_frame
	var window: QuickCommit = track(QuickCommit.new(panel))
	tree.root.add_child(window)
	window._fill()
	return window

func _rows(window: QuickCommit) -> Array:
	return window._tree.get_root().get_children().map(func(item: TreeItem) -> Array: return [item.get_metadata(0), item.is_checked(0)])

func test_checkboxes_stage_the_files() -> void:
	var window := await _window()
	check("the active changelist starts staged, as in Changes", _rows(window), [["a.txt", true], ["b.txt", true]])
	window.set_staged("a.txt", false)
	check("a.txt left out", _rows(window), [["a.txt", false], ["b.txt", true]])
	check_contains("counted", window._summary.text, "1 of 2 changed files staged")
	window.set_staged("a.txt", true)
	check("and back in", _rows(window), [["a.txt", true], ["b.txt", true]])

func test_commit_needs_a_message_and_a_staged_file() -> void:
	var window := await _window()
	window._message.text = "Fix b"
	window._message.text_changed.emit()
	check("ready", window.get_ok_button().disabled, false)
	check("one draft with the panel", window._panel._commit_message.text, "Fix b")
	window.set_staged("a.txt", false)
	window.set_staged("b.txt", false)
	check("nothing staged", window.get_ok_button().disabled, true)
	window._message.text = ""
	window._message.text_changed.emit()
	window.set_staged("b.txt", true)
	check("no message", window.get_ok_button().disabled, true)
