# The fixture behind the phase-19 gates: who governs a subscription.
#
# It declares the three states of `:stream` plus the two ways to declare
# it wrongly, in one application, because the gates are about how these
# ANSWER and an answer needs the others beside it to mean anything.
#
# Comptoir deliberately does NOT carry these. A demo application with a
# broken declaration in it teaches the refusal by making the example
# worse; a fixture is where a wrong declaration costs nobody anything.

RingServ([
	:port     = 8118,
	:workers  = 2,
	:database = sysget("RINGSERV_TEST_DB"),

	:data = [
		:notes  = [ :title = :text, :body = :text ],
		:secret = [ :title = :text ],
		:loose  = [ :title = :text ],
		:orphan = [ :title = :text ]
	],

	:services = [
		:notes  = [ :table = "notes" ],
		:secret = [ :table = "secret" ],
		:loose  = [ :table = "loose" ],
		:orphan = [ :table = "orphan" ],

		# A service the topology places IN THE PAGE with no server
		# authority, so this server refuses to answer a call to it. The
		# whole phase-19 question is whether a SUBSCRIPTION to a shape it
		# governs is refused in the same words.
		:onlyonthedevice = [
			:ping = func aReq { return Reply(:ok, [ :ok = 1 ]) }
		]
	]
])

Topology([
	:app = "streamgov",

	:data = [
		# 1. GOVERNED by a service this server DOES answer -> may subscribe.
		:notes  = [ :store = :local, :sync = :live, :stream = "notes" ],

		# 2. GOVERNED by a service placed in the page -> the subscription is
		#    refused with the CALL's own sentence.
		:secret = [ :store = :local, :sync = :live, :stream = "onlyonthedevice" ],

		# 3. NEVER -> refused, naming the declaration, so the reader knows
		#    it is a decision and stops looking for a defect.
		:loose  = [ :store = :local, :sync = :live, :stream = :never ],

		# 4. UNDECLARED -> streams, exactly as phase 18 shipped. The absence
		#    of a declaration must not turn a working page off.
		:orphan = [ :store = :local, :sync = :live ]
	],

	:services = [
		:notes           = [ :site = :server ],
		:secret          = [ :site = :server ],
		:loose           = [ :site = :server ],
		:orphan          = [ :site = :server ],
		:onlyonthedevice = [ :site = :local ]
	]
])
