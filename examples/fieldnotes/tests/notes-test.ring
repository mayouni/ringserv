# The application's own tests, run by `ringserv test` against a scratch
# in-memory database. No server, no port, nothing to clean up afterwards.
#
# Tests call services the way a client does — same dispatch, same
# contracts, same placement. What they do NOT do is go over the wire,
# which is why they are fast enough to run on every save.

# --- the generic table service, which nobody wrote
aReply = Ask(:notes, :create,
	[ :title = "First light", :place = "Sidi Bou", :weight = 12 ])
ExpectOk("creates a note", aReply)
nId = aReply[:data][:id]

aReply = Ask(:notes, :get, [ :id = nId ])
ExpectOk("reads it back", aReply)
Expect("with the place it was given", aReply[:data][:place], "Sidi Bou")

aReply = Ask(:notes, :list, [])
Expect("lists exactly one note", aReply[:data][:count], 1)

# --- the contract refuses before the action runs
aReply = Ask(:notes, :create, [ :body = "no title" ])
ExpectCode("refuses a note with no title", aReply, 1)
ExpectStatus("...with a 422, not a 500", 422)

aReply = Ask(:notes, :create, [ :title = "too heavy", :weight = 900 ])
ExpectCode("refuses a weight outside its range", aReply, 1)

# --- the hand-written service
Ask(:notes, :create, [ :title = "Second", :place = "Sidi Bou", :weight = 30 ])
Ask(:notes, :create, [ :title = "Third", :place = "Kairouan", :weight = 5 ])

aReply = Ask(:report, :summary, [])
ExpectOk("summarises by place", aReply)
Expect("two places", aReply[:data][:count], 2)

aReply = Ask(:report, :heaviest, [ :limit = 2 ])
ExpectOk("ranks by weight", aReply)
Expect("heaviest first", aReply[:data][:rows][1][:title], "Second")

# --- the JavaScript service, which is just a service
aReply = Ask(:digest, :brief, [ :limit = 2 ])
ExpectOk("the JS service answers", aReply)
ExpectTrue("...and reached the Ring services through serv.call",
	aReply[:data][:places] = 2)
