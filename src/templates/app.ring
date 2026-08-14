# __APPNAME__ — a RingServ application.
#
# Run it:      ringserv dev
# Test it:     ringserv test
# Deploy it:   ringserv run app.ring   (one binary, one folder)

RingServ([
	:port     = 8080,
	:database = "__APPNAME__.db",

	# Tables are declared, not migrated by hand. Adding a column here
	# adds it to the database on the next start; nothing is ever dropped.
	:data = [
		:notes = [
			:title = :string,
			:body  = :string
		]
	],

	:services = [
		# A service you wrote.
		:hello = [
			:greet = func aReq {
				cName = aReq[:payload][:name]
				return Reply(:ok, [ :message = "Ahlan, " + cName + "!" ])
			}
		],

		# A whole CRUD service you did not: declaring the table is enough
		# to answer list / get / create / update / delete.
		:notes = [ :table = "notes" ]
	],

	:routes = [
		[ :static, "/", "public/" ]
	]
])

# Contracts govern what an action accepts. Violations are refused at the
# door with a 422 and a message naming every problem at once — your
# action never sees a bad payload.
Contract(:hello, [
	:greet = [
		:in = [ :name = [ :type = :string, :required = true, :maxlen = 40 ] ]
	]
])

Contract(:notes, [
	:create = [
		:in = [
			:title = [ :type = :string, :required = true, :maxlen = 120 ],
			:body  = [ :type = :string ]
		],
		:out = [ :id = :number ]
	]
])
