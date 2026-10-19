## Keeps SplitContainer dividers where the user last dragged them, across resizes and editor restarts. No class_name: internal helper, addressed via preload.
extends RefCounted

const Settings := preload("res://addons/godit/util/settings.gd")


## For splits whose two sides both expand, where split_offset counts from the middle: the divider stays at the first side's share of the length (default_ratio until dragged; below 0 keeps the scene's own offset).
static func keep_ratio(split: SplitContainer, key: String, default_ratio := -1.0) -> void:
	var setting := "split_" + key
	var state := {"ratio": float(Settings.get_value(setting, default_ratio))} # a Dictionary, so the lambdas share it
	var apply := func() -> void:
		var length := _length(split)
		if state["ratio"] >= 0.0 and length > 0.0:
			split.split_offset = roundi(length * (state["ratio"] - 0.5))
	split.resized.connect(apply)
	apply.call()
	split.drag_ended.connect(func() -> void:
		var length := _length(split)
		if length > 0.0:
			split.clamp_split_offset()
			state["ratio"] = clampf(0.5 + split.split_offset / length, 0.05, 0.95)
			Settings.set_value(setting, state["ratio"])
	)


## For splits whose first side has a fixed minimum width (a sidebar): the divider stays that many pixels past it.
static func keep_offset(split: SplitContainer, key: String) -> void:
	var setting := "split_" + key
	split.split_offset = Settings.get_value(setting, split.split_offset)
	split.drag_ended.connect(func() -> void:
		split.clamp_split_offset()
		Settings.set_value(setting, split.split_offset)
	)


static func _length(split: SplitContainer) -> float:
	return split.size.y if split is VSplitContainer else split.size.x
