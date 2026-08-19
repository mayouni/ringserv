# Phase-8 fixture: the actor seam.
#
# Three services, covering the three answers auth can give: no
# requirement, "any verified caller", and a named permission.

RingServ([
	:port     = 8088,
	:workers  = 2,
	:database = ":memory:",

	:services = [
		:public = [
			:ping = func aReq { return Reply(:ok, [ :ok = 1 ]) }
		],
		:me = [
			# Echoes what the server decided about the caller, so a gate
			# can assert the ACTOR and not merely the status code.
			:who = func aReq {
				pA = aReq[:actor]
				if not islist(pA)
					return Reply(:ok, [ :sub = "", :anon = 1 ])
				ok
				return Reply(:ok, [ :sub = "" + RsDeclGet(pA, "sub", ""),
						    :anon = 0 ])
			}
		],
		:orders = [
			:place  = func aReq { return Reply(:ok, [ :placed = 1 ]) },
			:refund = func aReq { return Reply(:ok, [ :refunded = 1 ]) }
		]
	]
])

Actor([
	:secret = "test-secret-do-not-ship",
	:leeway = 0
])

Contract(:me, [
	:who = [ :auth = :required ]
])

Contract(:orders, [
	:place  = [ :auth = :required ],
	:refund = [ :auth = "orders.manage" ]
])
