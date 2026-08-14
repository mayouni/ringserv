# Tests for __APPNAME__ — run them with `ringserv test`.
#
# Tests call services in process, the way a client would over the wire:
# same dispatch, same contracts, same database (a scratch one, so your
# real data is never touched).

# --- the service you wrote
aReply = Ask(:hello, :greet, [ :name = "Mansour" ])
ExpectOk("greets by name", aReply)
Expect("says hello in Arabic", aReply[:data][:message], "Ahlan, Mansour!")

# --- contracts refuse bad payloads before the action runs
aReply = Ask(:hello, :greet, [])
ExpectCode("refuses a missing name", aReply, 1)
ExpectStatus("...with a 422", 422)

# --- the CRUD service you did not write
aReply = Ask(:notes, :create, [ :title = "first note", :body = "hello" ])
ExpectOk("creates a note", aReply)
nId = aReply[:data][:id]

aReply = Ask(:notes, :get, [ :id = nId ])
ExpectOk("reads it back", aReply)
Expect("with the right title", aReply[:data][:title], "first note")

aReply = Ask(:notes, :list, [])
Expect("lists one note", aReply[:data][:count], 1)

aReply = Ask(:notes, :delete, [ :id = nId ])
ExpectOk("deletes it", aReply)

aReply = Ask(:notes, :get, [ :id = nId ])
ExpectStatus("and then it is gone (404)", 404)
