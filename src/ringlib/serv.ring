# servlib — the RingServ service model, in the language it serves.
#
# The wire contract (docs/services.md, held fixed by ALIGNMENT.md):
#   in:  { "service": name, "action": name, "payload": anything }
#   out: { "code": n, "message": s, "data": anything }
# Transport status travels through the __rs_status C hook; business
# status lives in the envelope. One request = one __dispatch call,
# made by the Zig core through the rs_call machinery.

aRsServDecl = []
lRsServDeclared = 0

# ------------------------------------------------------------ the seam

# Is this dispatch answering THE WIRE, and how deep is it?
#
# Both exist for one narrow purpose: a JavaScript reply can be carried to
# the socket verbatim (lossless booleans and null -- see jsserv.ring), but
# ONLY when that reply is the whole response. A Ring service that calls a
# JS service inspects the result as a Ring list, and `ringserv test` does
# too, so those paths must still get a decoded list. The flag says "a
# socket is waiting"; the depth says "and nothing is wrapping me".
lRsOnWire = 0
nRsDispatchDepth = 0

func RingServ aDecl
	aRsServDecl = aDecl
	lRsServDeclared = 1
	# ringserv.yaml fills what the declaration left unset; collisions are
	# reported and the declaration wins. See src/ringlib/config.ring.
	RsConfigFold()

func Reply pCode, pData
	return ReplyMsg(pCode, "", pData)

func ReplyMsg pCode, cMsg, pData
	nCode = 1
	cMessage = cMsg
	if isstring(pCode)
		switch lower(pCode)
		on "ok"
			nCode = 0
			if cMessage = "" cMessage = "OK" ok
		on "fail"
			nCode = 1
			if cMessage = "" cMessage = "FAIL" ok
		other
			nCode = 1
			if cMessage = "" cMessage = pCode ok
		off
	but isnumber(pCode)
		nCode = pCode
		if cMessage = ""
			if nCode = 0
				cMessage = "OK"
			else
				cMessage = "FAIL"
			ok
		ok
	ok
	return [ :code = nCode, :message = cMessage, :data = pData ]

# ------------------------------------------------------- the dispatcher

# The HTTP core hands the request body over as a STRING (JSON-encoded by
# the Zig side), so the decode happens HERE, inside a catch — a body that
# is not JSON is a 400 by contract, never a 500.
func __dispatch_raw cBody
	try
		aReq = JsonDecode(cBody)
	catch
		return RsRefuse(400, "malformed request: body is not valid JSON")
	done
	# THE WIRE ENTRY, and the only one. Everything else that reaches
	# __dispatch -- a Ring service calling another, `ringserv test` -- is
	# a Ring caller that will read the reply as a list.
	lRsOnWire = 1
	pOut = __dispatch(aReq)
	lRsOnWire = 0
	return pOut

func __dispatch aReq
	nRsDispatchDepth++
	pRsOut = __dispatch_inner(aReq)
	nRsDispatchDepth--
	return pRsOut

func __dispatch_inner aReq
	if not islist(aReq)
		return RsRefuse(400, "malformed request: body must be a JSON object")
	ok
	cService = RsDeclGet(aReq, "service", "")
	cAction  = RsDeclGet(aReq, "action", "")
	pPayload = RsDeclGet(aReq, "payload", [])
	if not (RsValidName(cService) and RsValidName(cAction))
		return RsRefuse(400, "malformed request: service and action are required names")
	ok
	if lRsServDeclared = 0
		return RsRefuse(500, "no RingServ() declaration in this application")
	ok
	aServices = RsDeclGet(aRsServDecl, "services", [])
	pSvc = RsDeclGet(aServices, cService, "")
	if isstring(pSvc)
		return RsRefuse(404, "unknown service: " + cService)
	ok

	# Placement is enforced at the door, next to contracts, and for the
	# same reason: a deployment declaration that the runtime does not
	# hold to is a comment. A service the topology puts in the page with
	# no server authority runs THERE and nowhere else, so answering a
	# wire call to it would quietly make :local mean "local, mostly".
	#
	# 501, not 404: the service exists and this is a truthful statement
	# about what this host implements. Saying "unknown" would be a lie
	# with a number in it, and 421 invites HTTP/2 clients to retry.
	aPlace = RsTopoPlacement(cService)
	if islist(aPlace) and aPlace[:answerable] = 0
		# The sentence lives in topology.ring because a subscription to a
		# shape this service governs must be refused in the SAME words
		# (phase 19). Two doors, one rule, one sentence.
		return RsRefuse(501, RsTopoUnanswerable(aPlace, cService))
	ok

	# A worker answers from state it rebuilt at boot, so it must fold in
	# whatever OTHER workers have journaled since. Normally an indexed
	# query returning nothing; see RsJournalCatchUp for the measurement
	# that made this necessary rather than tidy.
	RsJournalCatchUpAll()

	aReq2 = [ :service = cService, :action = cAction, :payload = pPayload ]

	# WHO is asking, before WHAT they asked. An action that requires a
	# caller must not run its contract against a payload from someone the
	# server cannot identify — and 401 and 403 stay distinct, because "I
	# do not know who you are" and "I know, and no" are different problems
	# for the caller.
	pActor = RsActorOfRequest()
	cDenied = RsActorCheck(cService, cAction, pActor)
	if cDenied != ""
		return [ :code = 1, :message = cDenied, :data = "" ]
	ok
	aReq2[:actor] = pActor

	# Contracts are enforced at the door: the action never sees a
	# payload that violates its declaration (docs/services.md §5).
	cViolation = RsContractCheck(cService, cAction, pPayload)
	if cViolation != ""
		__rs_status(422)
		return [ :code = 1, :message = cViolation, :data = "" ]
	ok

	# JS form: the implementation lives in a .js file and the guest
	# answers. Checked before the two Ring forms because it is a property
	# of the DECLARATION, not of the handler — and note what is already
	# behind us: the contract ran, the placement was enforced, the envelope
	# is the same. That is the whole claim of two guests, one dispatcher.
	cJsFile = RsJsFile(pSvc)
	if cJsFile != ""
		try
			return RsJsDispatch(cService, cJsFile, aReq2)
		catch
			return RsFailed(cCatchError)
		done
	ok

	# Class form: an object whose <action>Action methods are reachable —
	# the Action suffix rule (docs/services.md §3). The method name is
	# built from a validated name, then reached through eval in local
	# scope (Ring has no direct call-method-by-name in the core).
	if isobject(pSvc)
		cMethod = lower(cAction) + "action"
		if find(methods(pSvc), cMethod) = 0
			return RsRefuse(404, "unknown action: " + cService + "." + cAction)
		ok
		__rs_obj = pSvc
		__rs_out = ""
		try
			eval("__rs_out = __rs_obj." + cMethod + "(aReq2)")
		catch
			return RsFailed(cCatchError)
		done
		return __rs_out
	ok

	# Declarative form: a hash of action = anonymous function (Ring
	# stores a func value as its generated name — a string).
	pHandler = RsDeclGet(pSvc, cAction, "")
	if not isstring(pHandler) or pHandler = ""
		# No explicit handler — a declared :table may still answer this
		# action generically. Explicit always wins: the lookup above
		# ran first, so overriding is just defining the action.
		if RsHasGeneric(pSvc, cAction)
			try
				return RsRunGeneric(pSvc, aReq2)
			catch
				return RsFailed(cCatchError)
			done
		ok
		return RsRefuse(404, "unknown action: " + cService + "." + cAction)
	ok
	try
		pOut = call pHandler(aReq2)
	catch
		return RsFailed(cCatchError)
	done
	return pOut

# ------------------------------------------------ the Zig core asks this

func __rs_serv_config aIgnored
	if lRsServDeclared = 0
		return [ :serv = 0, :port = 0, :workers = 0 ]
	ok
	return [
		:serv     = 1,
		:port     = RsDeclGet(aRsServDecl, "port", 8080),
		# Loopback by default, always. Reaching the network is a
		# deliberate act, and :behindproxy is where the operator says
		# they have put TLS in front — see docs/TLS.md.
		:host       = "" + RsDeclGet(aRsServDecl, "host", "127.0.0.1"),
		:behindproxy = RsBool(RsDeclGet(aRsServDecl, "behindproxy", 0)),
		:workers  = RsDeclGet(aRsServDecl, "workers", 0),
		# The family handshake (docs/PLAN.md phase 12). ON by default —
		# zero-config symbiosis is the point — and :announce = false
		# refuses ENTIRELY: no socket, no beacon, nothing to overhear.
		:announce = RsBool(RsDeclGet(aRsServDecl, "announce", 1)),
		:app      = "" + RsDeclGet(aRsServDecl, "app", "app"),
		:custody  = "" + RsDeclGet(RsDeclGet(aRsServDecl, "identity", []), "custody", "L0"),
		:alg      = "" + RsDeclGet(RsDeclGet(aRsServDecl, "identity", []), "alg", "none"),
		:database = RsDeclGet(aRsServDecl, "database", ":memory:"),
		:static   = RsStaticRoutes()
	]

# The [ prefix, directory ] pairs declared as [ :static, "/", "public/" ]
# in :routes. The Zig core serves these directly — a file is a file,
# and the VM has no business in that path.
func RsStaticRoutes
	aOut = []
	aRoutes = RsDeclGet(aRsServDecl, "routes", [])
	if not islist(aRoutes)
		return aOut
	ok
	for aRoute in aRoutes
		if not (islist(aRoute) and len(aRoute) = 3)
			loop
		ok
		if not isstring(aRoute[1]) or lower(aRoute[1]) != "static"
			loop
		ok
		# Named keys, not a bare pair: Ring's JsonEncode renders a list of
		# [key, value] pairs as an OBJECT, so [ "/", "public/" ] would
		# reach the Zig side as {"/": "public/"} instead of a route.
		if isstring(aRoute[2]) and isstring(aRoute[3])
			add(aOut, [ :prefix = aRoute[2], :dir = RsStaticDir(aRoute[3]) ])
		ok
	next
	return aOut

# A declared static directory, resolved AGAINST THE APPLICATION.
#
# `:js` paths already resolve this way, and static files must agree with
# them: an application that works as `ringserv run app.ring` has to work
# as `ringserv run /elsewhere/app.ring` too. Before this, `public/` was
# joined to the PROCESS WORKING DIRECTORY, so running the reference
# application from the repository root served 404 for its own page while
# its JS service loaded fine -- two path rules in one declaration, which
# is one more than any application should have to know about.
func RsStaticDir cDir
	if not isstring(cDir) or cDir = ""
		return cDir
	ok
	# Already absolute: a leading separator, or a drive letter.
	c1 = left(cDir, 1)
	if c1 = "/" or c1 = (char(92))
		return cDir
	ok
	if len(cDir) >= 2 and substr(cDir, 2, 1) = ":"
		return cDir
	ok
	cRoot = __rs_approot()
	if cRoot = "" or cRoot = "."
		return cDir
	ok
	return cRoot + "/" + cDir

# The Zig core calls this in every worker after the app is evaluated:
# a worker's own connection must see the schema too, and CREATE TABLE
# IF NOT EXISTS makes the repeat free.
func __rs_data_apply aIgnored
	# The journal is schema too, and it is set up BEFORE the early return
	# below: an application may declare a journal and no tables at all, and
	# a journal-only app that silently got no journal is exactly the kind of
	# failure this store exists to make impossible.
	RsJournalApply()
	RsJournalReplayAll()

	aData = RsDeclGet(aRsServDecl, "data", [])
	if len(aData) = 0
		return 0
	ok
	nTables = RsSchemaApply(aData)
	# The shape log rides the same boot step, and for the same reason:
	# it is schema. Idempotent, so N workers racing to install it is safe.
	RsSyncApply()
	return nTables

# --------------------------------------------------------------- helpers

# Value for cKey in a hash-shaped list, else pDefault. Deliberate scan,
# not index-by-string: absent keys must answer pDefault, never raise.
func RsDeclGet aList, cKey, pDefault
	if not islist(aList)
		return pDefault
	ok
	for x in aList
		if islist(x) and len(x) = 2 and isstring(x[1]) and lower(x[1]) = lower(cKey)
			return x[2]
		ok
	next
	return pDefault

# Service and action names are identifiers: letters, digits, underscore.
# Enforced BEFORE any name reaches an eval or a call.
# A declaration value read as a flag. Ring has no boolean literal type,
# so true / 1 / "yes" all have to mean the same thing — an operator who
# writes the wrong one should get the behaviour they meant, not a silent
# no.
func RsBool pValue
	if isnumber(pValue)
		if pValue != 0 return 1 else return 0 ok
	ok
	if isstring(pValue)
		cV = lower(pValue)
		if cV = "1" or cV = "true" or cV = "yes" or cV = "on"
			return 1
		ok
	ok
	return 0

func RsValidName cName
	if not isstring(cName)
		return 0
	ok
	if cName = ""
		return 0
	ok
	cT = substr(cName, "_", "")
	if cT = ""
		return 1
	ok
	return isalnum(cT)

func RsRefuse nStatus, cMsg
	__rs_status(nStatus)
	return [ :code = 1, :message = cMsg, :data = "" ]

func RsFailed cErr
	__rs_status(500)
	return [ :code = 1, :message = "service error: " + cErr, :data = "" ]

# ------------------------------------------- the catalog (check & docs)
#
# The application's own declaration, as data: services with their
# actions and any table, plus every contract. `ringserv check` and
# `ringserv docs` read THIS rather than reconstructing the same facts
# from an AST — the runtime already holds the truth, and it stays
# right for declarations that were computed rather than written.

func __rs_catalog aIgnored
	aServices = []
	for aEntry in RsDeclGet(aRsServDecl, "services", [])
		if not (islist(aEntry) and len(aEntry) = 2 and isstring(aEntry[1]))
			loop
		ok
		cName = aEntry[1]
		pSvc  = aEntry[2]
		aActions = []
		cTable   = ""
		if isobject(pSvc)
			# Class form: methods ending in "action" are the surface.
			for cM in methods(pSvc)
				if len(cM) > 6 and right(lower(cM), 6) = "action"
					add(aActions, left(cM, len(cM) - 6))
				ok
			next
		but RsJsFile(pSvc) != ""
			# JS form: ask the GUEST what it answers. Parsing the file
			# here would be a second, weaker opinion about a fact the
			# runtime already holds — the same reason the class form asks
			# methods() rather than reading the source.
			aActions = RsJsActions(cName, RsJsFile(pSvc))
		but islist(pSvc)
			cTable = RsDeclGet(pSvc, "table", "")
			if not isstring(cTable) cTable = "" ok
			for aPair in pSvc
				if not (islist(aPair) and len(aPair) = 2 and isstring(aPair[1]))
					loop
				ok
				cKey = lower(aPair[1])
				if cKey = "table" or cKey = "actions"
					loop
				ok
				add(aActions, aPair[1])
			next
		ok
		add(aServices, [ :name = cName, :table = cTable, :actions = aActions ])
	next

	aOut = []
	for aEntry in aRsContracts
		cService = aEntry[1]
		for aAct in aEntry[2]
			if not (islist(aAct) and len(aAct) = 2)
				loop
			ok
			add(aOut, [
				:service = cService,
				:action  = aAct[1],
				:in      = RsCatalogFields(RsDeclGet(aAct[2], "in", []))
			])
		next
	next
	return [ :services = aServices, :contracts = aOut ]

func RsCatalogFields aIn
	aOut = []
	if not islist(aIn)
		return aOut
	ok
	for aField in aIn
		if not (islist(aField) and len(aField) = 2 and isstring(aField[1]))
			loop
		ok
		aRule = aField[2]
		cReq = "0"
		if RsDeclGet(aRule, "required", 0) = 1 cReq = "1" ok
		add(aOut, [
			:name     = aField[1],
			:type     = "" + RsDeclGet(aRule, "type", ""),
			:required = cReq,
			:limits   = RsCatalogLimits(aRule)
		])
	next
	return aOut

func RsCatalogLimits aRule
	aBits = []
	for cKey in [ "min", "max", "minlen", "maxlen", "of" ]
		pVal = RsDeclGet(aRule, cKey, "")
		if isnumber(pVal) or (isstring(pVal) and pVal != "")
			add(aBits, cKey + " " + pVal)
		ok
	next
	return RsJoin(aBits, ", ")
