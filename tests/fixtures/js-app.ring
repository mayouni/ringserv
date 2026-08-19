# Phase-7 fixture: a JS service beside Ring ones, in one application.
#
# The claim under test is that NOTHING around the service changes. Both
# services carry contracts, both are placed by the topology, both answer
# on the same endpoint with the same envelope.

RingServ([
	:port     = 8092,
	:workers  = 2,
	:database = sysget("RINGSERV_TEST_DB"),

	:data = [
		:notes = [ :title = :text, :weight = :number ]
	],

	:services = [
		# The JS guest answers this one.
		:greeter = [ :js = "jssvc/greeter.js" ],

		# ...and this one calls back out through serv.call.
		:orchestra = [ :js = "jssvc/orchestra.js" ],

		# ...and a Ring service answers the same shape beside it.
		:ringgreeter = [
			:greet = func aReq {
				aP = aReq[:payload]
				cWho = "world"
				if islist(aP) and RsDeclGet(aP, "name", "") != ""
					cWho = RsDeclGet(aP, "name", "")
				ok
				return Reply(:ok, [ :greeting = "Hello, " + cWho + "!" ])
			}
		],

		:notes = [ :table = "notes" ]
	]
])

# A contract governs the JS service exactly as it governs a Ring one:
# enforced BEFORE dispatch, so the guest never sees a bad payload.
Contract(:greeter, [
	:greet = [
		:in = [ :name = [ :type = :string, :maxlen = 20 ] ]
	],
	:slow = [
		:in = [ :n = [ :type = :number, :required = true ] ]
	]
])

Topology([
	:app = "js-fixture",
	:services = [
		:greeter     = [ :site = :server ],
		:orchestra   = [ :site = :server ],
		:ringgreeter = [ :site = :server ],
		:notes       = [ :site = :local, :authority = :server ]
	]
])
