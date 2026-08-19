# Fieldnotes — the worked example behind docs/fieldnotes-app.md.
#
# One application that uses every seam RingServ has, in the order the
# guide introduces them. It is a real app, not an excerpt: `ringserv run
# examples/fieldnotes/app.ring` serves it, `ringserv test` tests it, and
# tests/guide-gates.js proves the guide's claims against THIS file — so a
# change here that contradicts the guide fails the build.

# ------------------------------------------------------------ services
#
# Everything the application IS lives in one declaration: its port, its
# database, its tables, its services and its static files. There is no
# second place to look.

RingServ([
	:port     = 8100,
	:database = "fieldnotes.db",

	# One table. Every table gets an `id` whether you declare one or
	# not, because everything above this layer addresses rows by id.
	:data = [
		:notes = [
			:title  = :text,
			:body   = :text,
			:place  = :text,
			:weight = :number
		]
	],

	:services = [
		# A GENERIC TABLE SERVICE. Five actions — list, get, create,
		# update, delete — from one line, because most services are that
		# and writing them out again is how a codebase gets long without
		# getting better.
		:notes = [ :table = "notes" ],

		# A HAND-WRITTEN SERVICE, for the thing a table cannot do.
		:report = [
			:summary = func aReq {
				aRows = DataQuery("select place, count(*) as n, " +
					"sum(weight) as total from notes group by place " +
					"order by n desc", [])
				return Reply(:ok, [ :places = aRows, :count = len(aRows) ])
			},

			:heaviest = func aReq {
				nLimit = 5
				aP = aReq[:payload]
				if islist(aP) and isnumber(RsDeclGet(aP, "limit", ""))
					nLimit = RsDeclGet(aP, "limit", 5)
				ok
				return Reply(:ok, [ :rows = DataQuery(
					"select id, title, weight from notes " +
					"order by weight desc limit ?", [ nLimit ]) ])
			}
		],

		# A JAVASCRIPT SERVICE. Same envelope, same contracts, same
		# placement — the only thing that changed is the language.
		:digest = [ :js = "services/digest.js" ]
	],

	:routes = [
		[ :static, "/", "public/" ]
	]
])

# ----------------------------------------------------------- contracts
#
# Validation belongs at the door, not inside each action: an action that
# has to check its own payload is an action written twice.

Contract(:notes, [
	:create = [
		:in = [
			:title  = [ :type = :string, :required = true, :maxlen = 120 ],
			:body   = [ :type = :string, :maxlen = 4000 ],
			:place  = [ :type = :string, :maxlen = 80 ],
			:weight = [ :type = :number, :min = 0, :max = 100 ]
		],
		:out = [ :id = :number ]
	],
	:get = [
		:in = [ :id = [ :type = :number, :required = true ] ]
	]
])

Contract(:report, [
	:heaviest = [
		:in = [ :limit = [ :type = :number, :min = 1, :max = 100 ] ]
	]
])

# ----------------------------------------------------------- placement
#
# Where each service runs. `notes` is predicted in the page and decided
# here; `report` and `digest` are server work and stay server work.

Topology([
	:app = "fieldnotes",

	:data = [
		:notes = [ :store = :local, :sync = :onreconnect ]
	],

	:services = [
		:notes  = [ :site = :local, :authority = :server ],
		:report = [ :site = :server ],
		:digest = [ :site = :server ]
	]
])
