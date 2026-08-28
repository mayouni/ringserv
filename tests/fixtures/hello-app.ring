# Phase-2 fixture: both service forms, all the gate cases.
# Ring file order: statements first, classes after — RingServ() leads.

# Two suites share this one fixture (soak-lite.js and serv-gates.js) --
# each sets its own port so they can run without colliding, rather than
# forcing one number on both.
cPort = sysget("RINGSERV_TEST_PORT")
if cPort = "" cPort = "8093" ok

RingServ([
	:port = number(cPort),
	:workers = 2,

	:services = [
		:hello = [
			:greet = func aReq {
				cName = aReq[:payload][:name]
				return Reply(:ok, [ :message = "Ahlan, " + cName + "!" ])
			},
			:fail = func aReq {
				return ReplyMsg(:fail, "not today", [ :reason = "testing" ])
			},
			:boom = func aReq {
				oops()            # declarative-form runtime error
			}
		],
		:math = new MathService
	]
])

class MathService
	func SquareAction aReq
		n = aReq[:payload][:n]
		return Reply(:ok, [ :square = n * n ])

	func BoomAction aReq
		nosuchfunction()          # a real runtime error — must 500 cleanly

	private
		func Hidden aReq          # not reachable: no Action suffix
			return 0
