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
	__js_load(cService, cSource)
	add(aRsJsLoaded, lower(cService))
	return 1

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
	try
		pReply = JsonDecode(cOut)
	catch
		raise("service `" + cService + "." + cAction +
		      "` returned something that is not JSON")
	done
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
