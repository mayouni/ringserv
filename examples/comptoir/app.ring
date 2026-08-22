# Comptoir — the broad reference application.
#
# Fieldnotes (examples/fieldnotes) is the TEACHING example: one seam at a
# time, in the order the guide introduces them. Comptoir is the STRESS
# example: every hostable form RingServ has, in one application, wired to
# each other the way a real counter application wires them.
#
# It is a café counter — orders taken, sent to a kitchen, paid for, and
# recorded in a fiscal journal that may never be altered. That shape is
# deliberate: it is the shape of a real proprietary application this
# server was designed against, rebuilt in the open so the gates can run
# on it and so anyone can read the whole thing.
#
# THE FORMS IT HOSTS, all six, all reachable at /api/v1:
#
#   :menu     a GENERIC TABLE service      — five actions from one line
#   :orders   a CLASS service              — an object, Action-suffixed
#   :kitchen  a DECLARATIVE service        — a hash of anonymous funcs
#   :receipt  a JAVASCRIPT service         — QuickJS, same envelope
#   :journal  a JOURNALED store's service  — read-only by construction
#   :sync     the sync layer's own service — offered, never automatic
#
# ...over a journaled store, a synced table, contracts, placement, an
# actor seam, static files, and a ringserv.yaml beside it. Plus a
# seventh form that needs no declaration at all: tools/tip.ring is a
# file of plain functions, served by `ringserv serve` (docs/gesture.md).
#
#   ringserv run examples/comptoir/app.ring
#   node tests/comptoir-gates.js          the whole thing, driven

# State the journal rebuilds. Nothing here is ever written to a table:
# replay is the only thing that puts it back (docs/COMMONS.md §1).
aTickets  = []
nTicketNo = 0

RingServ([
	:port     = 8110,
	:workers  = 2,
	:database = sysget("COMPTOIR_DB"),

	:data = [
		# The menu is ordinary mutable state — prices change, and the
		# current price is the truth. It syncs to the page.
		:menu = [
			:name     = :text,
			:price    = :number,
			:category = :text
		],
		# The day's takings, DERIVED from the journal by replay. It is a
		# table only so the page can read it without replaying anything.
		:takings = [
			:day    = :text,
			:total  = :number,
			:count  = :number
		]
	],

	:services = [
		# ---------------------------------------------- 1. generic table
		# list / get / create / update / delete, from one line.
		:menu = [ :table = "menu" ],

		# ------------------------------------------------- 2. the class
		# A service with internal state and private helpers. Methods
		# ending in Action are reachable; nothing else is.
		:orders = new OrdersService,

		# ------------------------------------------- 3. the declarative
		# A hash of anonymous functions — the shortest form that still
		# takes a payload.
		:kitchen = [
			:queue = func aReq {
				aOut = []
				for aT in aTickets
					if aT[:etat] != "servi" and aT[:etat] != "annule"
						add(aOut, aT)
					ok
				next
				return Reply(:ok, [ :tickets = aOut, :waiting = len(aOut) ])
			},

			:advance = func aReq {
				aP = aReq[:payload]
				nNo = RsDeclGet(aP, "ticket", 0)
				cTo = "" + RsDeclGet(aP, "to", "")
				if not RsComptoirIsState(cTo)
					return RsRefuse(422, "unknown state `" + cTo +
						"` — a ticket goes recue -> en_cuisine -> prete -> servi")
				ok
				aRec = JournalAppend("ventes", [
					:type   = "avancer",
					:ticket = nNo,
					:etat   = cTo ])
				return Reply(:ok, [ :seq = aRec[:seq], :ticket = nNo, :etat = cTo ])
			}
		],

		# -------------------------------------------- 4. the JavaScript
		# Money formatting and the receipt, in JS, calling back into Ring
		# services by name through the same seam a Ring service uses.
		:receipt = [ :js = "services/receipt.js" ],

		# ------------------------------------------------ 5. the journal
		# Read-only by construction: verify and read, and no append.
		:journal = RsJournalService("ventes"),

		# --------------------------------------------------- 6. the sync
		# Offered explicitly, because compaction discards history and a
		# server that let anyone reach it would have a denial-of-service
		# endpoint.
		:sync = RsSyncService()
	],

	:routes = [
		[ :static, "/", "public/" ]
	]
])

# --------------------------------------------------------- the journal
#
# The fiscal record. Append-only, hash-chained, replayed to state, never
# compacted — because a takings record some jurisdictions require to be
# inalterable cannot live in a store whose defining feature is that the
# floor moves.

Journal([
	:name  = "ventes",
	:apply = func aEvent {
		cType = "" + RsDeclGet(aEvent, "type", "")

		if cType = "commander"
			nTicketNo++
			add(aTickets, [
				:numero = nTicketNo,
				:client = "" + RsDeclGet(aEvent, "client", ""),
				:lignes = RsDeclGet(aEvent, "lignes", []),
				:total  = RsDeclGet(aEvent, "total", 0),
				:etat   = "recue",
				:paye   = 0 ])

		but cType = "avancer"
			nNo = RsDeclGet(aEvent, "ticket", 0)
			if isnumber(nNo) and nNo >= 1 and nNo <= len(aTickets)
				aTickets[nNo][:etat] = "" + RsDeclGet(aEvent, "etat", "")
			ok

		but cType = "encaisser"
			nNo = RsDeclGet(aEvent, "ticket", 0)
			if isnumber(nNo) and nNo >= 1 and nNo <= len(aTickets)
				aTickets[nNo][:paye] = 1
			ok

		but cType = "annuler"
			# A cancellation is an EVENT, never a deletion. The order
			# stays in the record with a reason beside it, which is the
			# whole difference between a journal and a table.
			nNo = RsDeclGet(aEvent, "ticket", 0)
			if isnumber(nNo) and nNo >= 1 and nNo <= len(aTickets)
				aTickets[nNo][:etat] = "annule"
				aTickets[nNo][:motif] = "" + RsDeclGet(aEvent, "motif", "")
			ok
		ok
		return 1
	}
])

# -------------------------------------------------------- the contracts
#
# Validation at the door. An action that checks its own payload is an
# action written twice.

Contract(:orders, [
	:place = [
		:in = [
			:client = [ :type = :string, :required = true, :maxlen = 60 ],
			:lignes = [ :type = :list, :required = true ]
		],
		:out = [ :ticket = :number ]
	],
	:pay = [
		:in = [ :ticket = [ :type = :number, :required = true, :min = 1 ] ]
	],
	# Cancelling is the one action that needs a person behind it: it is
	# the only way a paid ticket leaves the day's takings.
	:cancel = [
		:auth = :required,
		:in = [
			:ticket = [ :type = :number, :required = true, :min = 1 ],
			:motif  = [ :type = :string, :required = true, :maxlen = 200 ]
		]
	]
])

Contract(:kitchen, [
	:advance = [
		:in = [
			:ticket = [ :type = :number, :required = true, :min = 1 ],
			:to     = [ :type = :string, :required = true ]
		]
	]
])

# ------------------------------------------------------------ the actor
#
# The host verifies the token; this application decides what a verified
# actor may do. 401 and 403 stay distinct, because "I do not know you"
# and "I know you, and no" are different problems for the caller.

Actor([ :secret = sysget("COMPTOIR_SECRET") ])

# ---------------------------------------------------------- the placement
#
# Where each service runs. The menu is predicted in the page and decided
# here; everything touching the fiscal record is server work and says so.

Topology([
	:app = "comptoir",

	:data = [
		:menu = [ :store = :local, :sync = :onreconnect ]
	],

	:services = [
		:menu    = [ :site = :local, :authority = :server ],
		:orders  = [ :site = :server ],
		:kitchen = [ :site = :server ],
		:receipt = [ :site = :server ],
		:journal = [ :site = :server ],
		:sync    = [ :site = :server ]
	]
])

# ------------------------------------------------------------- helpers

func RsComptoirIsState cTo
	if cTo = "recue" return 1 ok
	if cTo = "en_cuisine" return 1 ok
	if cTo = "prete" return 1 ok
	if cTo = "servi" return 1 ok
	return 0

func ComptoirTickets
	return aTickets

# ------------------------------------------------------- the class form

class OrdersService

	func PlaceAction aReq
		aP = aReq[:payload]
		aLignes = RsDeclGet(aP, "lignes", [])
		nTotal = This.Total(aLignes)
		if nTotal <= 0
			return RsRefuse(422, "an order needs at least one priced line")
		ok
		aRec = JournalAppend("ventes", [
			:type   = "commander",
			:client = "" + RsDeclGet(aP, "client", ""),
			:lignes = aLignes,
			:total  = nTotal ])
		return Reply(:ok, [ :ticket = nTicketNo, :total = nTotal,
				    :seq = aRec[:seq], :hash = aRec[:hash] ])

	func PayAction aReq
		nNo = RsDeclGet(aReq[:payload], "ticket", 0)
		aT = This.Ticket(nNo)
		if not islist(aT)
			return RsRefuse(404, "no ticket " + nNo)
		ok
		if aT[:paye] = 1
			return RsRefuse(409, "ticket " + nNo + " is already paid")
		ok
		JournalAppend("ventes", [ :type = "encaisser", :ticket = nNo,
					  :montant = aT[:total] ])
		This.RecordTakings(aT[:total])
		return Reply(:ok, [ :ticket = nNo, :paye = 1, :total = aT[:total] ])

	func CancelAction aReq
		aP = aReq[:payload]
		nNo = RsDeclGet(aP, "ticket", 0)
		aT = This.Ticket(nNo)
		if not islist(aT)
			return RsRefuse(404, "no ticket " + nNo)
		ok
		JournalAppend("ventes", [ :type = "annuler", :ticket = nNo,
					  :motif = "" + RsDeclGet(aP, "motif", "") ])
		return Reply(:ok, [ :ticket = nNo, :etat = "annule" ])

	func StateAction aReq
		nPaid = 0
		nOpen = 0
		for aT in aTickets
			if aT[:paye] = 1 nPaid++ ok
			if aT[:etat] != "servi" and aT[:etat] != "annule" nOpen++ ok
		next
		return Reply(:ok, [ :tickets = len(aTickets), :paid = nPaid,
				    :open = nOpen, :counter = nTicketNo ])

	# Not Action-suffixed: unreachable from the wire, by the same rule
	# that makes a JS file's non-exported functions unreachable.
	func Total aLignes
		nSum = 0
		if not islist(aLignes)
			return 0
		ok
		for aL in aLignes
			nQty = RsDeclGet(aL, "qty", 1)
			nPrice = RsDeclGet(aL, "price", 0)
			if isnumber(nQty) and isnumber(nPrice)
				nSum += nQty * nPrice
			ok
		next
		return nSum

	func Ticket nNo
		if not isnumber(nNo) or nNo < 1 or nNo > len(aTickets)
			return ""
		ok
		return aTickets[nNo]

	func RecordTakings nAmount
		cDay = "" + DataValue("select date('now') as d", [], "")
		nHave = DataValue("select count(*) as n from takings where day = ?",
				  [ cDay ], 0)
		if nHave = 0
			DataExec("insert into takings (day, total, count) values (?, ?, 1)",
				 [ cDay, nAmount ])
		else
			DataExec("update takings set total = total + ?, count = count + 1 " +
				 "where day = ?", [ nAmount, cDay ])
		ok
		return 1
