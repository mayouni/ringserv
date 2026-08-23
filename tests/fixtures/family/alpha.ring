# Family fixture A: announces as `alpha`, and can call its sibling.
RingServ([
	:port = 8123,
	:app  = "alpha",
	:services = [
		:me = [
			:family = func aReq {
				return Reply(:ok, [ :siblings = Family() ])
			},
			:ask = func aReq {
				# The placed call across processes: alpha -> beta, found
				# by announcement, no address configured anywhere.
				aOut = FamilyCall("beta", "hello.greet",
					[ :name = "" + RsDeclGet(aReq[:payload], "name", "alpha") ])
				return Reply(:ok, [ :beta_said = aOut[:data][:message] ])
			}
		]
	]
])
