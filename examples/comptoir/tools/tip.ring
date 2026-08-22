# The seventh hostable form: NO DECLARATION AT ALL.
#
#   ringserv serve examples/comptoir/tools/tip.ring
#
# Every top-level function becomes an action, payload keys map to
# parameters by name, and `serve --explain` prints exactly what got
# exposed. A small tool beside a big application should not have to
# become a big application first.

func split total, people
	if people < 1
		return [ :error = "how many people?" ]
	ok
	nEach = ceil(total / people)
	return [ :each = nEach, :people = people, :total = total,
		 :rounded_up_by = (nEach * people) - total ]

func tip total, percent
	nTip = ceil(total * percent / 100)
	return [ :tip = nTip, :total_with_tip = total + nTip, :percent = percent ]

func _internal
	return "unreachable from the wire"
