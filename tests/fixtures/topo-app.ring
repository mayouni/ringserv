# Fixture for the phase-6 placement gates.
#
# Deliberately covers all four shapes a topology can put a service in:
# server-only, local-only, local-with-server-authority, and a service
# with no topology entry at all — because "the topology is silent" must
# keep working exactly as it did before phase 6 existed.

RingServ([
	:port     = 8097,
	:workers  = 2,
	:database = sysget("RINGSERV_TEST_DB"),

	:data = [
		:notes = [ :title = :text, :body = :text, :weight = :number ]
	],

	:services = [
		# Placed :server — the ordinary case.
		:report = [
			:build = func aReq {
				return Reply(:ok, [ :rows = 3, :where = "server" ])
			}
		],

		# Placed :local with NO authority — runs in the page and nowhere
		# else. A wire call to this must be refused.
		:draft = [
			:preview = func aReq {
				return Reply(:ok, [ :where = "should never be reached" ])
			}
		],

		# Placed :local WITH :authority = :server — predicted in the page,
		# decided here. A wire call to this must be ANSWERED.
		:notes = [ :table = "notes" ],

		# No topology entry at all. Silence is not a refusal.
		:hello = [
			:greet = func aReq {
				return Reply(:ok, [ :where = "unplaced" ])
			}
		]
	]
])

Topology([
	:app = "topo-fixture",

	:data = [
		:notes = [ :store = :local, :sync = :live ]
	],

	:services = [
		:report = [ :site = :server ],
		:draft  = [ :site = :local ],
		:notes  = [ :site = :local, :authority = :server ]
	]
])
