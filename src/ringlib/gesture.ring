# gesturelib — a file of plain functions becomes a service.
#
# The vision's first sentence (docs/VISION.md): hosting anything is a
# dead-simple gesture, "even a simple function". This is that gesture:
#
#     # calc.ring — no declarations, just functions
#     func add a, b
#         return a + b
#
#     > ringserv serve calc.ring
#     POST /api/v1  {"service":"calc","action":"add","payload":{"a":1,"b":2}}
#     {"code":0,"message":"OK","data":3}
#
# THE MAPPING IS DELIBERATELY BORING, because magic that cannot be
# explained is a debugging loss dressed as a convenience (the risk named
# in docs/PLAN.md phase 10):
#
#   service   the file's base name
#   actions   every top-level function, except names starting with `_`
#   payload   maps to parameters BY NAME, case-insensitively — no
#             positional guessing, no prefix stripping, no coercion
#   return    the function's return value, enveloped as data
#
# `ringserv serve --explain file.ring` prints exactly this mapping and
# exits, so what got exposed is never a matter of trust.
#
# This is the FIRST-TOUCH form. The declarative RingServ([...]) form
# remains the precise one — contracts, placement, actors, tables — and a
# file that has grown into needing those has outgrown the gesture.

aRsGestureMap = []		# [ [action, [params...]], ... ] — this worker's map
aRsGestureHidden = []		# names scanned but not exposed, for --explain

# ------------------------------------------------------------- the scan
#
# Top-level `func` / `def` lines, textually. Textual on purpose: the
# scan must work on a file that is ABOUT to be evaluated, and it feeds
# --explain, which must never need a running server to answer. The VM
# remains the authority on what actually exists — a name scanned here
# but not defined after eval fails at call time with the VM's own error.
func RsGestureScan cSource
	aOut = []
	aRsGestureHidden = []
	aLines = str2list(cSource)
	for cLine in aLines
		cT = trim(cLine)
		# strip a trailing CR — the scan must not depend on line endings
		while len(cT) > 0 and ascii(right(cT, 1)) = 13
			cT = left(cT, len(cT) - 1)
		end
		cLow = lower(cT)
		cRest = ""
		if left(cLow, 5) = "func "
			cRest = trim(substr(cT, 6))
		but left(cLow, 4) = "def "
			cRest = trim(substr(cT, 5))
		else
			loop
		ok
		# the name: identifier characters up to the first non-identifier
		cName = ""
		for i = 1 to len(cRest)
			c = substr(cRest, i, 1)
			if isalnum(c) or c = "_"
				cName += c
			else
				exit
			ok
		next
		if cName = ""
			loop
		ok
		# parameters: the rest of the line, parens optional in Ring
		cParams = trim(substr(cRest, len(cName) + 1))
		if left(cParams, 1) = "(" cParams = substr(cParams, 2) ok
		if right(cParams, 1) = ")" cParams = left(cParams, len(cParams) - 1) ok
		# comma-split by hand — Ring's split() is stdlib, and ringlib
		# loads no stdlib (the runtime must be whole on its own)
		aParams = []
		cCur = ""
		for i = 1 to len(cParams)
			c = substr(cParams, i, 1)
			if c = ","
				if trim(cCur) != "" add(aParams, lower(trim(cCur))) ok
				cCur = ""
			else
				cCur += c
			ok
		next
		if trim(cCur) != "" add(aParams, lower(trim(cCur))) ok
		if left(cName, 1) = "_"
			add(aRsGestureHidden, lower(cName))
			loop
		ok
		add(aOut, [ lower(cName), aParams ])
	next
	return aOut

# ------------------------------------------------------------- the boot
#
# Called by the trailer `ringserv serve` prepends to the user's file —
# BEFORE the user source in the composed program, because Ring executes
# top-level statements only until the first `func`. Runs in every worker.
func RsGestureBoot cPath, cService, nPort
	aFns = RsGestureScan(read(cPath))
	if len(aFns) = 0
		raise("ringserv serve: no functions found in " + cPath + " — " +
		      "the gesture exposes top-level `func` definitions, and this " +
		      "file has none (names starting with _ stay private)")
	ok
	aRsGestureMap = aFns
	# Every action routes through ONE named handler. Not an anonymous
	# function per action: Ring's anonymous functions do not capture
	# enclosing locals (see journal.ring for the scar), and one handler
	# reading aReq[:action] needs no capture at all.
	aActions = []
	for aF in aFns
		add(aActions, [ aF[1], "RsGestureCall" ])
	next
	if nPort > 0
		RingServ([ :port = nPort, :services = [ [ cService, aActions ] ] ])
	else
		# No :port in the declaration — ringserv.yaml may provide one
		# (config.ring folds it in), else the default holds.
		RingServ([ :services = [ [ cService, aActions ] ] ])
	ok
	return len(aFns)

# --------------------------------------------------------- the dispatch
#
# One handler for every gesture action. The action name is looked up in
# the SCANNED map, never called blind — a request can only reach a
# function the scan chose to expose, so `call` here is bounded the same
# way the declarative form's handler strings are.
func RsGestureCall aReq
	cAction = lower("" + aReq[:action])
	aParams = ""
	for aF in aRsGestureMap
		if aF[1] = cAction
			aParams = aF[2]
		ok
	next
	if not islist(aParams)
		return RsRefuse(404, "unknown action: " + cAction)
	ok

	pPayload = aReq[:payload]
	aArgs = []
	aMissing = []
	for cP in aParams
		pV = RsDeclGet(pPayload, cP, "__rs_gesture_absent__")
		if isstring(pV) and pV = "__rs_gesture_absent__"
			add(aMissing, cP)
		else
			add(aArgs, pV)
		ok
	next
	# Every missing parameter at once, the way contracts report — a
	# caller should fix the payload in one round trip, not one per field.
	if len(aMissing) > 0
		cList = ""
		for cM in aMissing
			if cList != "" cList += ", " ok
			cList += cM
		next
		return RsRefuse(422, "missing parameter(s): " + cList +
			" — the gesture maps payload keys to parameters by name")
	ok

	# Ring's `call` needs a literal argument list, so arity is a switch.
	# Ten is the honest limit and the refusal says where to go next.
	n = len(aArgs)
	pOut = ""
	switch n
	on 0  pOut = call cAction()
	on 1  pOut = call cAction(aArgs[1])
	on 2  pOut = call cAction(aArgs[1], aArgs[2])
	on 3  pOut = call cAction(aArgs[1], aArgs[2], aArgs[3])
	on 4  pOut = call cAction(aArgs[1], aArgs[2], aArgs[3], aArgs[4])
	on 5  pOut = call cAction(aArgs[1], aArgs[2], aArgs[3], aArgs[4], aArgs[5])
	on 6  pOut = call cAction(aArgs[1], aArgs[2], aArgs[3], aArgs[4], aArgs[5], aArgs[6])
	on 7  pOut = call cAction(aArgs[1], aArgs[2], aArgs[3], aArgs[4], aArgs[5], aArgs[6], aArgs[7])
	on 8  pOut = call cAction(aArgs[1], aArgs[2], aArgs[3], aArgs[4], aArgs[5], aArgs[6], aArgs[7], aArgs[8])
	on 9  pOut = call cAction(aArgs[1], aArgs[2], aArgs[3], aArgs[4], aArgs[5], aArgs[6], aArgs[7], aArgs[8], aArgs[9])
	on 10 pOut = call cAction(aArgs[1], aArgs[2], aArgs[3], aArgs[4], aArgs[5], aArgs[6], aArgs[7], aArgs[8], aArgs[9], aArgs[10])
	other
		return RsRefuse(400, "the gesture maps up to 10 parameters; `" +
			cAction + "` declares " + n + " — a function this wide wants " +
			"the declarative form and a payload object")
	off
	return Reply(:ok, pOut)

# ---------------------------------------------------------- the explain
#
# `ringserv serve --explain file.ring` — the mapping, printed, no server.
# This is the risk clause of phase 10 discharged: what got exposed is
# stated by the tool, not inferred by the reader.
func RsGestureExplain cPath, cService
	aFns = RsGestureScan(read(cPath))
	? "gesture: " + cPath + "  ->  service `" + cService + "`"
	if len(aFns) = 0
		? "  exposed: nothing — no top-level functions found"
	else
		? "  exposed:"
		for aF in aFns
			cSig = ""
			for cP in aF[2]
				if cSig != "" cSig += ", " ok
				cSig += cP
			next
			? "    " + cService + "." + aF[1] + "(" + cSig + ")"
		next
	ok
	if len(aRsGestureHidden) > 0
		? "  private (leading _):"
		for cH in aRsGestureHidden
			? "    " + cH
		next
	ok
	if len(aFns) > 0
		aF = aFns[1]
		cShape = '{"service":"' + cService + '","action":"' + aF[1] + '","payload":{'
		cSep = ""
		for cP in aF[2]
			cShape += cSep + '"' + cP + '": ...'
			cSep = ", "
		next
		cShape += "}}"
		? "  call shape:"
		? "    POST /api/v1  " + cShape
	ok
	return len(aFns)
