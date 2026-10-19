## Godit's commands in the editor's Command Palette, each with a shortcut: rebindable in Editor Settings > Shortcuts > Godit on Godot 4.5+, fixed defaults before. No class_name: internal helper, addressed via preload.
extends RefCounted

const PATH_PREFIX := "godit/"
const PALETTE_PREFIX := "Godit: "

## key -> {"run": Callable, "shortcut": Shortcut, "palette": bool}
var _commands := {}


## keys: the default shortcut's events (none leaves it unbound). An invalid run registers only the shortcut, for something the editor runs itself (a dock's toggle shortcut).
func add(key: String, title: String, run: Callable, keys: Array = []) -> void:
	var shortcut := _shortcut(key, title, keys)
	_commands[key] = {"run": run, "shortcut": shortcut, "palette": run.is_valid()}
	if run.is_valid():
		EditorInterface.get_command_palette().add_command(PALETTE_PREFIX + title, PATH_PREFIX + key, run, shortcut.get_as_text() if not shortcut.events.is_empty() else "None")


func shortcut(key: String) -> Shortcut:
	return _commands[key]["shortcut"] if _commands.has(key) else null


## key -> Shortcut for every command.
func shortcuts() -> Dictionary:
	var out := {}
	for key: String in _commands:
		out[key] = _commands[key]["shortcut"]
	return out


## Runs the command the key press is bound to; false when it isn't bound to any.
func handle(event: InputEvent) -> bool:
	if not event.is_pressed() or event.is_echo():
		return false
	for command: Dictionary in _commands.values():
		if command["run"].is_valid() and command["shortcut"].matches_event(event):
			command["run"].call()
			return true
	return false


## Takes the commands out of the palette. The shortcuts stay registered, so a rebinding survives turning the plugin off and on.
func clear() -> void:
	var palette := EditorInterface.get_command_palette()
	for key: String in _commands:
		if _commands[key]["palette"]:
			palette.remove_command(PATH_PREFIX + key)
	_commands.clear()


## The user's binding when Editor Settings has one (saved from an earlier session or plugin run), the defaults otherwise.
func _shortcut(key: String, title: String, keys: Array) -> Shortcut:
	var path := PATH_PREFIX + key
	var settings := EditorInterface.get_editor_settings()
	# Through call(): add_shortcut() and the rest don't exist before 4.5, and naming them would break parsing there.
	var registrable := settings.has_method("add_shortcut")
	var shortcut: Shortcut = settings.call("get_shortcut", path) if registrable and settings.call("has_shortcut", path) else null
	if shortcut == null:
		shortcut = Shortcut.new()
		shortcut.events = keys
		if registrable:
			settings.call("add_shortcut", path, shortcut)
	shortcut.resource_name = title # its name in Editor Settings > Shortcuts
	shortcut.set_meta("original", keys) # what Revert goes back to; the editor saves only bindings that differ from it
	return shortcut


## Ctrl, or Cmd on macOS, with the key at a digit's place whatever the keyboard layout (on Czech or French ones the digits need Shift).
static func command_digit(keycode: Key) -> InputEventKey:
	var event := InputEventKey.new()
	event.physical_keycode = keycode
	event.command_or_control_autoremap = true
	return event


## Alt (Option on macOS) with a letter, like the editor's own bottom panel shortcuts.
static func alt_key(keycode: Key) -> InputEventKey:
	var event := InputEventKey.new()
	event.keycode = keycode
	event.alt_pressed = true
	return event
