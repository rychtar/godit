extends "res://tests/assertions.gd"

const EditorCommands = preload("res://addons/godit/util/editor_commands.gd")

# a key press: physical is where the key is, keycode what the layout prints on it
func _press(physical: Key, keycode: Key, command := false, alt := false) -> InputEventKey:
	var event := InputEventKey.new()
	event.physical_keycode = physical
	event.keycode = keycode
	if OS.get_name() == "macOS":
		event.meta_pressed = command
	else:
		event.ctrl_pressed = command
	event.alt_pressed = alt
	event.pressed = true
	return event

func test_digit_shortcuts_go_by_the_key_not_the_character() -> void:
	var shortcut := Shortcut.new()
	shortcut.events = [EditorCommands.command_digit(KEY_1)]
	check_true("Ctrl/Cmd+1", shortcut.matches_event(_press(KEY_1, KEY_1, true)))
	check_true("the same key on a Czech layout, where it types +", shortcut.matches_event(_press(KEY_1, KEY_PLUS, true)))
	check("without Ctrl/Cmd", shortcut.matches_event(_press(KEY_1, KEY_1)), false)
	check("another digit", shortcut.matches_event(_press(KEY_2, KEY_2, true)), false)

func test_alt_shortcuts_go_by_the_letter() -> void:
	var shortcut := Shortcut.new()
	shortcut.events = [EditorCommands.alt_key(KEY_G)]
	check_true("Alt+G", shortcut.matches_event(_press(KEY_G, KEY_G, false, true)))
	check("G alone", shortcut.matches_event(_press(KEY_G, KEY_G)), false)
	check("Ctrl/Cmd+Alt+G", shortcut.matches_event(_press(KEY_G, KEY_G, true, true)), false)
