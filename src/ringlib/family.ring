# familylib — the family handshake, from the application's side.
#
# Two RingServ processes on one host or LAN find each other with zero
# configuration (docs/PLAN.md phase 12). This file is the whole surface
# an application sees:
#
#     Family()                          -> who is around, right now
#     FamilyCall("beta", "hello.greet", [ :name = "alpha" ])
#
# THE ROSTER IS A PHONE BOOK, NOT A TRUST STORE. Hearing a beacon proves
# someone can send UDP, nothing more: the called sibling still enforces
# its own contracts, placement and actors on every call, exactly as it
# would for a stranger — because over the wire, family IS a stranger
# with a known address.
#
# The beacon carries the device-identity fields relayed from microring
# (custody axis L0/L1/L2, algorithm named even when "none"). The shape
# is PROVISIONAL until Central answers PLAN-HANDSHAKE-12; this file
# will not need to change when it freezes — only the datagram might.

func Family
	try
		return JsonDecode(__rs_family())
	catch
		return []
	done

# The sibling with this app name, or "". Two siblings may share a name
# (two counters of one shop); the FIRST — most recently confirmed —
# answers, which is the useful default and the documented one.
func RsFamilyFind cApp
	for aSib in Family()
		if lower("" + aSib[:app]) = lower("" + cApp)
			return aSib
		ok
	next
	return ""

func FamilyCall cApp, cCall, pPayload
	aSib = RsFamilyFind(cApp)
	if not islist(aSib)
		raise("FamilyCall(): no sibling named `" + cApp + "` is announcing " +
		      "right now — Family() lists who is; a sibling that stopped, or " +
		      "declared :announce = false, is not callable by name")
	ok
	nDot = substr(cCall, ".")
	if nDot = 0
		raise("FamilyCall(): the call is `service.action`, got `" + cCall + "`")
	ok
	aReq = [ :service = left(cCall, nDot - 1),
		 :action  = substr(cCall, nDot + 1),
		 :payload = pPayload ]
	cReply = __rs_family_call("" + aSib[:host], aSib[:port], JsonEncode(aReq))
	try
		return JsonDecode(cReply)
	catch
		raise("FamilyCall(): `" + cApp + "` answered something that is not " +
		      "JSON — is " + aSib[:host] + ":" + aSib[:port] + " really a RingServ?")
	done
