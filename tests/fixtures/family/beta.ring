# Family fixture B: announces as `beta`, with an L1 identity declared.
RingServ([
	:port = 8124,
	:app  = "beta",
	:identity = [ :custody = "L1", :alg = "ES256" ],
	:services = [
		:hello = [
			:greet = func aReq {
				return Reply(:ok, [ :message = "Ahlan, " +
					RsDeclGet(aReq[:payload], "name", "?") + "! — beta here" ])
			}
		]
	]
])
