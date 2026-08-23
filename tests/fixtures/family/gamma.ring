# Family fixture C: :announce = false — REFUSES entirely. No socket, no
# beacon; the packet-capture gate proves the silence.
RingServ([
	:port = 8125,
	:app  = "gamma",
	:announce = false,
	:services = [ :quiet = [ :ping = func aReq { return Reply(:ok, 1) } ] ]
])
