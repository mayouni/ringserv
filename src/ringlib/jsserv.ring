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
	RsJsEnsure(cService, cFile)
	cAction = RsDeclGet(aReq, "action", "")
	if __js_has(cService, cAction) = 0
		return RsRefuse(404, "unknown action: " + cService + "." + cAction)
	ok
	cOut = __js_call(cService, cAction, JsonEncode(RsDeclGet(aReq, "payload", [])))
	try
		pReply = JsonDecode(cOut)
	catch
		raise("service `" + cService + "." + cAction +
		      "` returned something that is not JSON")
	done
	return pReply

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
