# topologylib — placement as a declared property, in the language it governs.
#
# One application, declared placements (docs/topology.md). The names are
# C3's, not RingServ's private ones: `:site` is WHERE a service runs and
# `:authority` is WHO decides, because a placement and a decision are two
# questions and `:both` used to answer them with one word.
#
# What this file is NOT: a compiler. The topology is *data* the server
# publishes and enforces; the page compiles `serv.call` into a local
# dispatch or a fetch by reading it. Putting the compiler here would put
# it on the wrong side of the wire.

aRsTopoDecl = []
lRsTopoDeclared = 0

# ------------------------------------------------------------ the seam

func Topology aDecl
	aRsTopoDecl = aDecl
	lRsTopoDeclared = 1

# ------------------------------------------- what the Zig core asks for

# The placement map, resolved and validated, as data:
#
#   [ :declared = 1, :app = "fieldnotes", :solution = "",
#     :services = [ [ :name = "notes", :site = "local",
#                     :authority = "", :answerable = 0 ], ... ],
#     :data     = [ [ :name = "notes", :store = "local",
#                     :sync = "onreconnect" ], ... ],
#     :problems = [ [ :code = "RS_TOPOLOGY_...", :message = "..." ], ... ] ]
#
# `answerable` is the whole point of publishing this: it says whether
# /api/v1 will answer a call for that service at all. A `:local` service
# with no authority runs in the page and NOWHERE else, so a wire call to
# it is an application mistake rather than a request to serve.
func __rs_topology aIgnored
	if lRsTopoDeclared = 0
		return [ :declared = 0, :app = "", :solution = "",
			 :services = [], :data = [], :problems = [] ]
	ok

	aProblems = []
	aServices = []
	aData     = []

	# Services declared to RingServ(), so the topology can be checked
	# against something rather than believed.
	aDeclared = RsTopoServiceNames()

	for aEntry in RsDeclGet(aRsTopoDecl, "services", [])
		if not (islist(aEntry) and len(aEntry) = 2 and isstring(aEntry[1]))
			add(aProblems, RsTopoProblem("RS_TOPOLOGY_MALFORMED", "a :services entry is not a name = declaration pair"))
			loop
		ok
		cName = aEntry[1]
		aSpec = aEntry[2]

		cSite = lower("" + RsDeclGet(aSpec, "site", ""))
		cAuth = lower("" + RsDeclGet(aSpec, "authority", ""))

		if cSite = ""
			add(aProblems, RsTopoProblem("RS_TOPOLOGY_NO_SITE", "service `" + cName + "` declares no :site — defaulting to :server"))
			cSite = "server"
		but not RsTopoValidSite(cSite)
			add(aProblems, RsTopoProblem("RS_TOPOLOGY_UNKNOWN_SITE",
				"service `" + cName + "` declares :site = " + cSite +
				" — the sites are :local, :server and :device"))
			cSite = "server"
		ok

		if cAuth != "" and cAuth != "server"
			# C3 §2.2: the server is the only site that has authority.
			add(aProblems, RsTopoProblem("RS_TOPOLOGY_AUTHORITY_NOT_SERVER",
				"service `" + cName + "` declares :authority = " + cAuth +
				" — only :server may be an authority"))
			cAuth = "server"
		ok

		if len(aDeclared) > 0 and find(aDeclared, lower(cName)) = 0
			add(aProblems, RsTopoProblem("RS_TOPOLOGY_UNKNOWN_SERVICE",
				"topology places service `" + cName +
				"`, which no RingServ() declaration declares"))
		ok

		# Answerable over the wire when the server runs it (`:server`) or
		# decides it (`:authority = :server`). A `:device` service is
		# routed, not run here — phase 7 territory, refused meanwhile.
		nAnswer = 0
		if cSite = "server" or cAuth = "server"
			nAnswer = 1
		ok

		add(aServices, [ :name = cName, :site = cSite,
				 :authority = cAuth, :answerable = nAnswer ])
	next

	for aEntry in RsDeclGet(aRsTopoDecl, "data", [])
		if not (islist(aEntry) and len(aEntry) = 2 and isstring(aEntry[1]))
			add(aProblems, RsTopoProblem("RS_TOPOLOGY_MALFORMED", "a :data entry is not a name = declaration pair"))
			loop
		ok
		cName  = aEntry[1]
		aSpec  = aEntry[2]
		cStore = lower("" + RsDeclGet(aSpec, "store", "server"))
		cSync  = lower("" + RsDeclGet(aSpec, "sync", ""))
		# :stream — WHO GOVERNS A SUBSCRIPTION to this shape (phase 19).
		# Three states and no fourth: a service name (you may subscribe
		# exactly when you may CALL it), `never`, or absent. ABSENT MEANS
		# OPEN, which is phase 18's behaviour kept deliberately: this
		# declaration ADDS governance and does not switch streaming on.
		# A phase that quietly turns working pages off teaches people to
		# fear upgrades.
		cStream = "" + RsDeclGet(aSpec, "stream", "")

		if not RsTopoValidStore(cStore)
			add(aProblems, RsTopoProblem("RS_TOPOLOGY_UNKNOWN_STORE",
				"data `" + cName + "` declares :store = " + cStore +
				" — the stores are :local, :server and :shadow"))
			cStore = "server"
		ok
		if cSync != "" and cSync != "live" and cSync != "onreconnect"
			add(aProblems, RsTopoProblem("RS_TOPOLOGY_UNKNOWN_SYNC",
				"data `" + cName + "` declares :sync = " + cSync +
				" — the modes are :live and :onreconnect"))
			cSync = ""
		ok
		if cSync != "" and cStore != "local"
			# Syncing a server-only table is a contradiction, not a nuance:
			# there is no local replica for the shape log to feed.
			add(aProblems, RsTopoProblem("RS_TOPOLOGY_SYNC_WITHOUT_LOCAL",
				"data `" + cName + "` declares :sync on a :store = " + cStore +
				" table — only a :local store has anything to sync"))
			cSync = ""
		ok

		# A `:stream` naming a service that does not exist is a boot-time
		# problem, not a surprise at subscribe time -- the whole point of
		# declaring it is that the mistake is found before a page is.
		if cStream != "" and lower(cStream) != "never"
			lFound = 0
			for aSvc in aServices
				if lower(aSvc[:name]) = lower(cStream)
					lFound = 1
				ok
			next
			if lFound = 0
				add(aProblems, RsTopoProblem("RS_TOPOLOGY_STREAM_UNKNOWN_SERVICE",
					"data `" + cName + "` declares :stream = " + cStream +
					" — no service by that name is declared, so nothing " +
					"would govern a subscription to it"))
				cStream = ""
			ok
		ok
		if cStream != "" and cSync = ""
			# Governing a shape that is not a shape governs nothing.
			add(aProblems, RsTopoProblem("RS_TOPOLOGY_STREAM_WITHOUT_SYNC",
				"data `" + cName + "` declares :stream on a table with no " +
				":sync mode — there is no shape log to subscribe to"))
			cStream = ""
		ok

		add(aData, [ :name = cName, :store = cStore, :sync = cSync,
			     :stream = cStream ])
	next

	return [
		:declared = 1,
		:app      = "" + RsDeclGet(aRsTopoDecl, "app", ""),
		# Solution membership is what makes the manifest a MUST rather
		# than a MAY (contracts/placement.md §6, ratified 2026-08-18).
		# Absent, this is a standalone Ring application server and owes
		# no zing.json at all.
		:solution = "" + RsDeclGet(aRsTopoDecl, "solution", ""),
		:services = aServices,
		:data     = aData,
		:problems = aProblems
	]

# THE REFUSAL SENTENCE FOR A MISPLACED SERVICE, in one place because two
# doors now produce it: a CALL to the service (serv.ring) and a
# SUBSCRIPTION to a shape it governs (sync.ring). A caller who is told
# "no" in two different sentences learns that the rule is two rules, so
# the gate for phase 19 asserts these are byte-identical -- which is only
# assertable because there is one of them.
func RsTopoUnanswerable aPlace, cService
	return "service `" + cService + "` is placed :site = :" +
		aPlace[:site] + ", so this server does not run it — call it " +
		RsTopoWhere(aPlace[:site]) +
		", or give it :authority = :server to be answered here"

# The placement of one service, for the dispatcher. Returns "" for a
# service the topology says nothing about — silence is not a refusal,
# because an application may declare no topology at all and every phase
# before this one worked that way.
func RsTopoPlacement cService
	if lRsTopoDeclared = 0
		return ""
	ok
	aTopo = __rs_topology([])
	for aSvc in aTopo[:services]
		if lower(aSvc[:name]) = lower(cService)
			return aSvc
		ok
	next
	return ""

# The published seam: what a page needs to compile `serv.call` into a
# local dispatch or a fetch, and nothing else. Deliberately NOT the whole
# declaration — the topology may say things about data placement that are
# the server's business, and an endpoint that returns everything becomes
# an endpoint nobody can change.
func __rs_topology_public aIgnored
	aTopo = __rs_topology([])
	if aTopo[:declared] = 0
		return [ :code = 0, :message = "OK",
			 :data = [ :declared = 0, :app = "", :services = [], :data = [] ] ]
	ok
	aSvc = []
	for x in aTopo[:services]
		add(aSvc, [ :name = x[:name], :site = x[:site],
			    :authority = x[:authority], :answerable = x[:answerable] ])
	next
	aDat = []
	for x in aTopo[:data]
		add(aDat, [ :name = x[:name], :store = x[:store], :sync = x[:sync] ])
	next
	return [ :code = 0, :message = "OK", :data = [
		:declared = 1,
		:app      = aTopo[:app],
		:services = aSvc,
		:data     = aDat
	] ]

# ---------------------------------------------------------- the manifest
#
# The two-surface doctrine (C3 §6, ratified): `Topology()` is the AUTHORING
# surface and `zing.json` is the ARTIFACT — what ships, and what a court or
# a Zen frontend reads, neither of which can parse Ring.
#
# RingServ emits the `placement` section and NOTHING ELSE. `solution`,
# `governance` and `targets` are Zing's to write: a build decision and a
# deployment decision are different fields (§4.1), and a tool that rewrites
# a section it does not own turns a merge into a loss.

func __rs_manifest_placement aIgnored
	aTopo = __rs_topology([])
	if aTopo[:declared] = 0
		return [ :emit = 0, :reason = "no Topology() declaration", :placement = [] ]
	ok
	if aTopo[:solution] = ""
		# The ratified jurisdiction sentence: the contract binds an app that
		# is part of a Zing solution and reaches no further. A standalone
		# Ring application server owes no manifest, and saying so plainly
		# is better than emitting one nobody asked for.
		return [ :emit = 0,
			 :reason = "this application declares no :solution, so it is a " +
				   "standalone RingServ app and owes no manifest",
			 :placement = [] ]
	ok

	aSvc = []
	for x in aTopo[:services]
		if x[:authority] != ""
			add(aSvc, [ x[:name], [ :site = x[:site], :authority = x[:authority] ] ])
		else
			add(aSvc, [ x[:name], [ :site = x[:site] ] ])
		ok
	next
	aDat = []
	for x in aTopo[:data]
		if x[:sync] != ""
			add(aDat, [ x[:name], [ :store = x[:store], :sync = x[:sync] ] ])
		else
			add(aDat, [ x[:name], [ :store = x[:store] ] ])
		ok
	next

	return [ :emit = 1, :reason = "", :solution = aTopo[:solution],
		 :placement = [ :services = aSvc, :data = aDat ] ]

# --------------------------------------------------------------- helpers

# A problem carries a stable code, because `ringserv check` reports these
# as C2 envelopes and a C2 code is a promise: stable forever, never reused.
func RsTopoProblem cCode, cMessage
	return [ :code = cCode, :message = cMessage ]

# Where a caller should go instead, in words a page developer can act on.
func RsTopoWhere cSite
	switch cSite
	on "local"
		return "in the page"
	on "device"
		return "on the device"
	off
	return "elsewhere"

func RsTopoValidSite cSite
	return cSite = "local" or cSite = "server" or cSite = "device"

func RsTopoValidStore cStore
	return cStore = "local" or cStore = "server" or cStore = "shadow"

# Lowercased names of the services RingServ() declares. Empty when no
# declaration exists yet — a topology loaded before RingServ() must not
# report every service as undeclared.
func RsTopoServiceNames
	aOut = []
	if lRsServDeclared = 0
		return aOut
	ok
	for aEntry in RsDeclGet(aRsServDecl, "services", [])
		if islist(aEntry) and len(aEntry) = 2 and isstring(aEntry[1])
			add(aOut, lower(aEntry[1]))
		ok
	next
	return aOut
