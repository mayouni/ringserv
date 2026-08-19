# actorlib — who is calling, and whether they may.
#
# Phase 8's auth seam. Two halves, split where the responsibility splits:
#
#   THE HOST verifies a token. It knows one format it can check without
#   asking anyone — a JWT signed with a shared secret — and it checks it
#   properly: HS256 only, signature before claims, constant-time compare,
#   `alg: none` refused by name (see bridge.zig).
#
#   THIS FILE decides what a verified actor MAY DO, because permissions
#   are an application's vocabulary. A host that invented roles would be
#   a host every application had to work around.
#
# Declared once:
#
#     Actor([ :secret = sysget("APP_SECRET"), :leeway = 60 ])
#
# ...or with an application's own verifier, for anything this host does
# not check — asymmetric keys, an introspection endpoint, a session table:
#
#     Actor([ :verify = func cToken { return [ :sub = ..., :scope = ... ] } ])
#
# Required per action, in the contract that already governs the payload:
#
#     Contract(:orders, [
#         :place  = [ :auth = :required, :in = [ ... ] ],
#         :refund = [ :auth = "orders.manage" ]
#     ])
#
# WHAT IS NOT HERE, DELIBERATELY: any notion of a signed principal
# assertion that another host would accept. That is C5, it is co-authored
# with Zing's stzAppServer, and inventing a format here would mean
# inventing the thing the contract exists to agree on. This file is the
# seam C5 will plug into, not a guess at C5.

aRsActorDecl = []
lRsActorDeclared = 0

func Actor aDecl
	if not islist(aDecl)
		raise("Actor(): expects a declaration list")
	ok
	aRsActorDecl = aDecl
	lRsActorDeclared = 1
	return 1

# The verified actor for the request being served, or "" when the caller
# presented nothing this server could verify.
#
# Recomputed per dispatch rather than cached: a worker serves many
# requests, and an actor cached across them is the bug that hands one
# caller another caller's identity.
func RsActorOfRequest
	if lRsActorDeclared = 0
		return ""
	ok
	cToken = __rs_authtoken()
	if cToken = ""
		return ""
	ok

	# An application's own verifier wins, and gets the whole token. It may
	# return a list (the claims) or anything else (meaning "no").
	pVerify = RsDeclGet(aRsActorDecl, "verify", "")
	if isstring(pVerify) and pVerify != ""
		try
			pOut = call pVerify(cToken)
		catch
			return ""      # a verifier that raises has refused
		done
		if islist(pOut)
			return pOut
		ok
		return ""
	ok

	cSecret = "" + RsDeclGet(aRsActorDecl, "secret", "")
	if cSecret = ""
		return ""          # nothing to verify against is not "verified"
	ok
	nLeeway = RsDeclGet(aRsActorDecl, "leeway", 0)
	if not isnumber(nLeeway) nLeeway = 0 ok

	cClaims = __rs_jwt_verify(cToken, cSecret, nLeeway)
	if cClaims = ""
		return ""
	ok
	try
		return JsonDecode(cClaims)
	catch
		return ""
	done

# What an action requires: "" (nothing), "required", or a permission name.
func RsActorRequirement cService, cAction
	aSpec = RsContractSpec(cService, cAction)
	if not islist(aSpec)
		return ""
	ok
	pAuth = RsDeclGet(aSpec, "auth", "")
	if isstring(pAuth)
		return lower(pAuth)
	ok
	return ""

# The gate, run beside the contract and BEFORE dispatch. Returns "" when
# the call may proceed, or the refusal message.
#
# Two different answers on purpose, because they are two different
# problems for the caller: 401 means "I do not know who you are", 403
# means "I know, and no". Collapsing them into one status is a small
# unkindness that costs a developer an afternoon.
func RsActorCheck cService, cAction, pActor
	cNeed = RsActorRequirement(cService, cAction)
	if cNeed = ""
		return ""
	ok

	if not islist(pActor)
		__rs_status(401)
		return "authentication required: " + cService + "." + cAction +
		       " needs a verified caller"
	ok

	if cNeed = "required"
		return ""
	ok

	if RsActorHas(pActor, cNeed)
		return ""
	ok
	__rs_status(403)
	return "permission denied: " + cService + "." + cAction +
	       " needs `" + cNeed + "`"

# Does this actor carry a permission?
#
# Read from `scope` (a space-separated string, the OAuth convention) or
# from `permissions` / `roles` (a list). All three are accepted because
# all three are in the wild, and an application that already issues one of
# them should not have to reissue its tokens to use this.
func RsActorHas pActor, cNeed
	pScope = RsDeclGet(pActor, "scope", "")
	if isstring(pScope) and pScope != ""
		for cPart in split(pScope, " ")
			if lower(cPart) = cNeed
				return 1
			ok
		next
	ok
	for cKey in [ "permissions", "roles", "scopes" ]
		pList = RsDeclGet(pActor, cKey, "")
		if islist(pList)
			for pItem in pList
				if isstring(pItem) and lower(pItem) = cNeed
					return 1
				ok
			next
		ok
	next
	return 0

# Split on a single-character separator. Ring's own split takes a string
# separator in some builds and a character in others; doing it here keeps
# this file working whichever way the vendored VM leans.
func split cText, cSep
	aOut = []
	cCur = ""
	for i = 1 to len(cText)
		if cText[i] = cSep
			if cCur != "" add(aOut, cCur) ok
			cCur = ""
		else
			cCur += cText[i]
		ok
	next
	if cCur != "" add(aOut, cCur) ok
	return aOut
