## Splits a `git diff` into hunks and builds partial patches from them, for hunk/line staging. No class_name: internal helper, addressed via preload.
extends RefCounted


## Splits a single-file unified diff into {"file_header": String (everything before the first @@), "hunks": [{"header": String, "lines": PackedStringArray}]}.
static func split_hunks(diff_text: String) -> Dictionary:
	var header_lines := PackedStringArray()
	var hunks: Array = []
	var current: Dictionary = {}
	for line in diff_text.split("\n"):
		if line.begins_with("@@"):
			current = { "header": line, "lines": PackedStringArray() }
			hunks.append(current)
		elif current.is_empty():
			header_lines.append(line)
		elif line.begins_with("diff --git"):
			break # a second file — callers only ever diff one path
		else:
			var lines: PackedStringArray = current["lines"]
			lines.append(line)
			current["lines"] = lines
	# The text ends with "\n", which leaves an empty trailing entry in the last hunk.
	if not hunks.is_empty():
		var last_lines: PackedStringArray = hunks[-1]["lines"]
		while not last_lines.is_empty() and last_lines[-1].is_empty():
			last_lines.remove_at(last_lines.size() - 1)
		hunks[-1]["lines"] = last_lines
	return { "file_header": "\n".join(header_lines), "hunks": hunks }


## Patch for `git apply --recount` with one hunk, limited to selected line indices (empty = whole hunk); reverse must match how it's applied so only the selected lines change.
static func build_patch(file_header: String, hunk: Dictionary, selected: PackedInt32Array, reverse: bool) -> String:
	var lines: PackedStringArray = hunk["lines"]
	var out := PackedStringArray()
	var kept_previous := true
	for i in lines.size():
		var line := lines[i]
		if line.begins_with("\\"):
			if kept_previous:
				out.append(line)
			continue
		var is_selected := selected.is_empty() or selected.has(i)
		var marker := line.substr(0, 1)
		var body := line.substr(1)
		kept_previous = true
		if marker == "+" and not is_selected:
			if reverse:
				out.append(" " + body)
			else:
				kept_previous = false
		elif marker == "-" and not is_selected:
			if reverse:
				kept_previous = false
			else:
				out.append(" " + body)
		else:
			out.append(line if not line.is_empty() else " ")
	return "%s\n%s\n%s\n" % [file_header.strip_edges(false, true), hunk["header"], "\n".join(out)]
