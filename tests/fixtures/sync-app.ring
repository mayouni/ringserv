# Fixture for the phase-6 sync gates.
#
# One synced table and one that is not, so the gates can prove the shape
# log is SELECTIVE — logging everything would be easy and wrong.
#
# `notes` also carries a Contract, because a rejected mutation must roll
# back its own claim and stay resendable, and that path only exists when
# something can actually reject.

# The placement of `notes` is a variable, so the convergence oracle can
# be run TWICE — once with the service on the server, once predicted in
# the page with the server as authority — and the two final states
# compared. That is the contract's owed placement case: the same move,
# across an offline interleaving rather than an online call.
cSite = sysget("RINGSERV_TEST_SITE")
if cSite = "" cSite = "server" ok

if cSite = "local"
	aNotesPlacement = [ :site = :local, :authority = :server ]
else
	aNotesPlacement = [ :site = :server ]
ok

RingServ([
	:port     = 8093,
	:workers  = 3,
	:database = sysget("RINGSERV_TEST_DB"),

	:data = [
		:notes  = [ :title = :text, :body = :text, :weight = :number ],
		:audit  = [ :what = :text ]
	],

	:services = [
		:notes = [ :table = "notes" ],
		:audit = [ :table = "audit" ],
		:boom  = [
			:now = func aReq {
				# A service that fails hard, so a mutation raising inside
				# a transaction is exercised rather than imagined.
				raise("deliberate failure")
			}
		]
	]
])

Contract(:notes, [
	:create = [
		:in = [
			:title  = [ :type = :string, :required = true, :maxlen = 40 ],
			:body   = [ :type = :string ],
			:weight = [ :type = :number ]
		]
	]
])

Topology([
	:app = "sync-fixture",
	:data = [
		:notes = [ :store = :local,  :sync = :live ],
		:audit = [ :store = :server ]
	],
	:services = [
		:notes = aNotesPlacement,
		:audit = [ :site = :server ],
		:boom  = [ :site = :server ]
	]
])
