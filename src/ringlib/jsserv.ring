# jsserv — the second guest, as a service form.
#
# RingServ has two service forms already: a hash of action = function
# (declarative) and an object whose <action>Action methods are the surface
# (class). This adds a third, and the whole design goal is that it is
# ONLY a third form — the envelope, the contract, the placement and the
# sync path do not know which guest answered.
#
#     :report = [ :js = "services/report.js" ]
#
# and, beside app.ring:
#
#     const service = {
#         build(payload) { return { code: 0, message: "OK", data: {…} } },
#     };
#
# The object's methods are the actions. Everything else in the file is
# private — the JS analogue of the class form's Action suffix, and it
# gives privacy by structure rather than by naming convention.
#
# WHY RING READS THE FILE. The guest never sees a path, only source. That
# is what keeps "the JS guest has no filesystem" a property of the build
# instead of a promise in a document: there is no host function that takes
# a path, so there is nothing to escape from.

# Loaded service names, per worker. A worker evaluates each file once and
# keeps the guest resident for its whole life — the same bargain the Ring
# side makes, and the reason a JS service costs no more per request than
# a Ring one after the first.
aRsJsLoaded = []

# The :js file a service declares, or "" when it is not a JS service.
func RsJsFile pSvc
	if isobject(pSvc) or not islist(pSvc)
		return ""
	ok
	cFile = RsDeclGet(pSvc, "js", "")
	if not isstring(cFile)
		return ""
	ok
	return cFile

# Load on first use, not at boot.
#
# Deliberate: a server whose JS services are never called should not pay
# for a QuickJS context, and a worker that boots before a file exists
# (`dev` reloads on save) should fail the REQUEST rather than fail to
# start. The cost is one evaluation on the first call to each service.
func RsJsEnsure cService, cFile
	if find(aRsJsLoaded, lower(cService))
		return 1
	ok

	# Relative to the APPLICATION, never to the directory the server was
	# started from: `ringserv run /elsewhere/app.ring` must find the same
	# files as `ringserv run app.ring`.
	cRoot = __rs_approot()
	cPath = cFile
	if cRoot != "" and not RsJsAbsolute(cFile)
		cPath = cRoot + "/" + cFile
	ok
	if not fexists(cPath)
		raise("service `" + cService + "` declares :js = " + cFile +
		      ", which does not exist (looked in " + cPath + ")")
	ok

	cSource = read(cPath)

	# TWO FORMS, detected from the source. A file using ES modules
	# (top-level import/export) is loaded WITH ITS GRAPH and must say
	# `export const service = ...`; anything else is the classic form,
	# unchanged. Ring walks the graph and reads every file itself — the
	# guest still has no filesystem, it can only import what was staged.
	if RsJsIsModule(cSource)
		cEntry = RsJsModKey(cFile)
		RsJsStageGraph(cEntry, cSource, cRoot, [])
		__js_load_module(cService, cEntry)
	else
		__js_load(cService, cSource)
	ok
	add(aRsJsLoaded, lower(cService))
	return 1

# Does this source use ES modules at the top level? A textual test, and
# honestly so: it looks at line starts, so `import` inside a string on
# its own line can fool it — at the cost of loading as a module, whose
# error will say exactly what it expected. The VM stays the authority.
func RsJsIsModule cSource
	for cLine in str2list(cSource)
		cT = trim(cLine)
		if RsJsLineImports(cT) return 1 ok
		if left(cT, 7) = "export " return 1 ok
	next
	return 0

# Does this line begin an import statement? One place, because Ring's
# parser dislikes conditions continued across lines and this test is
# needed twice.
func RsJsLineImports cT
	if left(cT, 7) = "import " return 1 ok
	if left(cT, 7) = "import" + char(34) return 1 ok
	if left(cT, 7) = "import" + char(39) return 1 ok
	return 0

# The app-root-relative key of a declared :js path — forward slashes,
# dot-segments collapsed. BOTH sides of the seam use this shape: Ring
# stages modules under these keys, and QuickJS's resolver produces the
# same shape when it joins an import against its importer.
func RsJsModKey cFile
	cK = ""
	for i = 1 to len(cFile)
		c = substr(cFile, i, 1)
		if c = "\"
			cK += "/"
		else
			cK += c
		ok
	next
	return RsJsCollapse(cK)

# Collapse "." and ".." segments. Answers "" when the path escapes above
# its root — the caller turns that into a refusal WITH the rule, because
# an import that climbs out of the application is not a path problem, it
# is a boundary problem.
func RsJsCollapse cPath
	aOut = []
	aSegs = []
	cCur = ""
	for i = 1 to len(cPath)
		c = substr(cPath, i, 1)
		if c = "/"
			add(aSegs, cCur)
			cCur = ""
		else
			cCur += c
		ok
	next
	add(aSegs, cCur)
	for cSeg in aSegs
		if cSeg = "" or cSeg = "."
			loop
		ok
		if cSeg = ".."
			if len(aOut) = 0
				return ""
			ok
			del(aOut, len(aOut))
			loop
		ok
		add(aOut, cSeg)
	next
	cJoined = ""
	for cSeg in aOut
		if cJoined != "" cJoined += "/" ok
		cJoined += cSeg
	next
	return cJoined

# The directory part of a module key, or "".
func RsJsModDir cKey
	nLast = 0
	for i = 1 to len(cKey)
		if substr(cKey, i, 1) = "/" nLast = i ok
	next
	if nLast = 0
		return ""
	ok
	return left(cKey, nLast - 1)

# Walk one module's static imports, read each file, stage it, recurse.
# Cycle-safe: a module already on the visited list is staged once and
# only once (ES modules link cycles; the walk just must not loop).
func RsJsStageGraph cKey, cSource, cRoot, aSeen
	if find(aSeen, cKey)
		return aSeen
	ok
	add(aSeen, cKey)
	__js_module(cKey, cSource)

	for cSpec in RsJsImportsOf(cSource)
		# The boundary, stated at load time rather than discovered at
		# call time: modules are the application's own files.
		if left(cSpec, 1) != "."
			raise("service module `" + cKey + "` imports `" + cSpec + "` — " +
			      "npm packages are not available; modules are your " +
			      "application's own .js files, imported by relative path " +
			      "(docs/JS.md states the boundary)")
		ok
		cChild = RsJsCollapse(RsJsModDir(cKey) + "/" + cSpec)
		if cChild = ""
			raise("service module `" + cKey + "` imports `" + cSpec + "`, " +
			      "which escapes the application's directory — imports " +
			      "resolve inside the application and never leave it")
		ok
		cChildPath = cChild
		if cRoot != ""
			cChildPath = cRoot + "/" + cChild
		ok
		if not fexists(cChildPath)
			raise("service module `" + cKey + "` imports `" + cSpec + "` " +
			      "(" + cChild + "), which does not exist")
		ok
		aSeen = RsJsStageGraph(cChild, read(cChildPath), cRoot, aSeen)
	next
	return aSeen

# The static import specifiers of one source: `import ... from "x"`,
# `export ... from "x"`, and bare `import "x"`. Dynamic import() is not
# in the subset — the engine's own loader refuses it at call time with
# the boundary named, because a graph that can grow at runtime is a
# graph nobody reviewed.
func RsJsImportsOf cSource
	aOut = []
	for cLine in str2list(cSource)
		cT = trim(cLine)
		lRelevant = RsJsLineImports(cT)
		if left(cT, 7) = "export " and substr(cT, " from ") > 0
			lRelevant = 1
		ok
		if lRelevant = 0
			loop
		ok
		# the specifier is the first quoted string after `from`, or the
		# first quoted string at all for a bare `import "x"`
		nFrom = substr(cT, " from ")
		cTail = cT
		if nFrom > 0
			cTail = substr(cT, nFrom + 6)
		ok
		cSpec = RsJsFirstQuoted(cTail)
		if cSpec != ""
			add(aOut, cSpec)
		ok
	next
	return aOut

func RsJsFirstQuoted cText
	cQ = ""
	cOut = ""
	for i = 1 to len(cText)
		c = substr(cText, i, 1)
		if cQ = ""
			if c = char(34) or c = char(39)
				cQ = c
			ok
		else
			if c = cQ
				return cOut
			ok
			cOut += c
		ok
	next
	return ""

# A path that already names its own root. Windows drive letters count,
# which is why this is not just a leading-slash test.
func RsJsAbsolute cPath
	if len(cPath) = 0
		return 0
	ok
	if cPath[1] = "/" or cPath[1] = "\"
		return 1
	ok
	if len(cPath) > 2 and cPath[2] = ":"
		return 1
	ok
	return 0

# Dispatch one call into the guest. The reply crosses as JSON and is
# decoded here, so what the dispatcher hands back is an ordinary Ring
# envelope that the rest of servlib cannot distinguish from a Ring one.
# Does this text begin and end as a JSON object? A first-and-last-character
# question, deliberately -- it is asked on every JS reply that goes to the
# wire, so it may not walk the payload.
#
# INDEXED, NEVER substr(): `substr(s, i, 1)` COPIES on Ring 1.27 (316 us
# per call on a 1.8 MB buffer, measured by Central 2026-08-20), and a
# "cheap check" that copies the string is not a cheap check.
func RsJsIsObjectText cText
	nLen = len(cText)
	if nLen < 2
		return 0
	ok
	i = 1
	while i <= nLen and RsJsIsSpace(cText[i])
		i++
	end
	if i > nLen or cText[i] != "{"
		return 0
	ok
	j = nLen
	while j >= 1 and RsJsIsSpace(cText[j])
		j--
	end
	if j < 1 or cText[j] != "}"
		return 0
	ok
	return 1

func RsJsIsSpace c
	return c = " " or c = char(9) or c = char(10) or c = char(13)

func RsJsDispatch cService, cFile, aReq
	# Nesting, not rounds. A service that calls ITSELF does not loop inside
	# one trampoline — it opens a new one each time, so the round counter
	# below never sees it and the Ring stack overflows first. The guest's
	# own frame stack already knows how deep we are, and it is right by
	# construction because js_service_call pushes and pops it on every
	# path, including the ones that raise.
	if __js_depth() >= 16
		return RsRefuse(508, "service `" + cService + "` is nested more than " +
			"16 service calls deep — a cycle? Each level here is one JS " +
			"action waiting on another.")
	ok
	RsJsEnsure(cService, cFile)
	cAction = RsDeclGet(aReq, "action", "")
	if __js_has(cService, cAction) = 0
		return RsRefuse(404, "unknown action: " + cService + "." + cAction)
	ok
	cOut = __js_call(cService, cAction, JsonEncode(RsDeclGet(aReq, "payload", [])))
	cOut = RsJsTrampoline(cService, cAction, cOut)

	# THE WIRE PATH DOES NOT DECODE AT ALL (2026-08-26).
	#
	# When this reply is the whole response, the guest's own text goes out
	# verbatim -- so decoding it first, only to throw the result away, was
	# a full JSON parse per request whose entire product was discarded.
	# MEASURED, which is why this exists: a 100-item reply is 5.6 KB, and
	# QuickJS builds AND encodes the whole thing in 0.145 ms while the
	# request cost 0.62 ms more than an empty one. The parse was most of
	# the difference.
	#
	# It is safe to skip because the text came from JS_JSONStringify
	# (src/js.zig, encodeValue) and that function's output is valid JSON
	# or an exception -- there is no third outcome. What the decode was
	# ALSO doing is the `islist` check below, "an object, not a bare
	# value", and that is answered by looking at the first and last
	# characters rather than at everything between them.
	#
	# ANYTHING THAT DOES NOT LOOK LIKE AN OBJECT FALLS THROUGH to the
	# original path, so every error message below is produced exactly as
	# before -- a guest that answers `42`, or nothing at all, gets the
	# same sentence it always got.
	if lRsOnWire = 1 and nRsDispatchDepth = 1 and RsJsIsObjectText(cOut)
		return [ "__rs_raw_json__", cOut ]
	ok

	# Validate by decoding, then RETURN THE GUEST'S OWN TEXT.
	#
	# The decode happens for a RING caller -- another service, or
	# `ringserv test` -- because it wants a list. Its result is thrown
	# away only on the wire path above: Ring has no boolean and no null,
	# so a reply of { ok: false, error: null } decoded into Ring and
	# re-encoded came back out as { ok: 0, error: "" }. The reference
	# application found it the first time a receipt called an unpaid
	# ticket `paid: 0`.
	#
	# So the text the guest produced is carried through verbatim (the
	# __rs_raw_json__ sentinel, honoured by the encoder in src/rs_json.c).
	try
		pReply = JsonDecode(cOut)
	catch
		raise("service `" + cService + "." + cAction +
		      "` returned something that is not JSON")
	done
	if not islist(pReply)
		raise("service `" + cService + "." + cAction +
		      "` must answer an object, not a bare value")
	ok
	# Verbatim ONLY when this reply is the whole wire response. A Ring
	# caller -- another service, or `ringserv test` -- reads the reply as
	# a list and must keep getting one; it pays the round trip, and the
	# limitation is named in docs/JS.md rather than hidden.
	if lRsOnWire = 1 and nRsDispatchDepth = 1
		return [ "__rs_raw_json__", cOut ]
	ok
	return pReply

# The trampoline: RING stays the outer loop.
#
# A JS action that calls `serv.call` cannot dispatch for itself — dispatch
# is Ring code and we are already inside a Ring call, so re-entering the VM
# is exactly what its guard forbids. Instead the guest answers a sentinel,
# Ring performs the calls through its OWN `__dispatch`, hands the results
# back, and asks the guest to continue.
#
# What that buys is worth the machinery: `serv.call` from JS is the SAME
# dispatch a Ring service gets — contracts, placement, sync and all —
# rather than a second, weaker path that would drift from it.
func RsJsTrampoline cService, cAction, cOut
	nRounds = 0
	while cOut = "__RS_PENDING__"
		nRounds++
		if nRounds > 32
			# A depth limit, not a timeout: 32 rounds of service calls is
			# a service calling itself, and saying so beats hanging.
			raise("service `" + cService + "." + cAction + "` is still " +
			      "waiting after 32 rounds of serv.call — a cycle?")
		ok

		aPending = JsonDecode(__js_pending_calls())
		if len(aPending) = 0
			raise("service `" + cService + "." + cAction +
			      "` is waiting on nothing this host can provide")
		ok

		for aCall in aPending
			nId = aCall[:id]
			try
				# The ordinary dispatcher. A JS service calling a Ring
				# service, a generic table service, or another JS service
				# all arrive here, and none of them is a special case.
				pReply = __dispatch([
					:service = aCall[:service],
					:action  = aCall[:action],
					:payload = aCall[:payload] ])
				__js_resolve_call(nId, JsonEncode(pReply))
			catch
				# A raise on the Ring side becomes a rejected promise in
				# the guest, so `try`/`catch` works across the seam.
				__js_reject_call(nId, cCatchError)
			done
		next

		cOut = __js_continue()
	end
	return cOut

# The actions a JS service answers, for the catalog `check` and `docs`
# read. Asked of the GUEST, never parsed out of the file — the same rule
# the Ring side follows, applied to the other runtime.
func RsJsActions cService, cFile
	try
		RsJsEnsure(cService, cFile)
	catch
		return []
	done
	try
		return JsonDecode(__js_actions(cService))
	catch
		return []
	done
