extends "res://tests/assertions.gd"

# The clock behind the reminders (settings go to the runner's temp folder).

const Reminders = preload("res://addons/godit/util/reminders.gd")
const HOUR := 3600

func test_reminds_after_the_interval_and_again_after_as_long() -> void:
	var key := "reminder_test_clock"
	check("starts the clock", Reminders.due(key, true, 0, 2), 0)
	check("not yet after an hour", Reminders.due(key, true, HOUR, 2), 0)
	check("due after two, for that long", Reminders.due(key, true, 2 * HOUR, 2), 2 * HOUR)
	check("quiet right after", Reminders.due(key, true, 3 * HOUR, 2), 0)
	check("again two hours later, counted from the start", Reminders.due(key, true, 4 * HOUR, 2), 4 * HOUR)

func test_done_work_stops_the_clock() -> void:
	var key := "reminder_test_clock"
	Reminders.due(key, true, 0, 2)
	check("committed: nothing due", Reminders.due(key, false, 3 * HOUR, 2), 0)
	check("changed again later: a new clock", Reminders.due(key, true, 4 * HOUR, 2), 0)
	check("not due an hour into it", Reminders.due(key, true, 5 * HOUR, 2), 0)
