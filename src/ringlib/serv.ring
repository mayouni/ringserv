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

func RingServ aDecl
	aRsServDecl = aDecl
	lRsServDeclared = 1

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
	return __dispatch(aReq)

func __dispatch aReq
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

	aReq2 = [ :service = cService, :action = cAction, :payload = pPayload ]

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
		:workers  = RsDeclGet(aRsServDecl, "workers", 0),
		:database = RsDeclGet(aRsServDecl, "database", ":memory:")
	]

# The Zig core calls this in every worker after the app is evaluated:
# a worker's own connection must see the schema too, and CREATE TABLE
# IF NOT EXISTS makes the repeat free.
func __rs_data_apply aIgnored
	aData = RsDeclGet(aRsServDecl, "data", [])
	if len(aData) = 0
		return 0
	ok
	return RsSchemaApply(aData)

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
