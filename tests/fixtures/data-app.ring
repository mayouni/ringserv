# Phase-3 fixture: the schema layer under a real server.
# The database path is injected by the harness through RINGSERV_TEST_DB
# so one fixture serves both the in-memory and the on-disk gates.

cDb = sysget("RINGSERV_TEST_DB")
if cDb = "" cDb = ":memory:" ok

RingServ([
	:port     = 8094,
	:workers  = 4,
	:database = cDb,

	:data = [
		:notes = [
			:title   = :string,
			:body    = :string,
			:weight  = :number,
			:tags    = :list
		],
		:visits = [ :who = :string ]
	],

	:services = [
		:notes = [
			# Writes through the primitives the query surface will use.
			:add = func aReq {
				cTitle = aReq[:payload][:title]
				nW     = aReq[:payload][:weight]
				__db_exec("insert into notes (title, weight) values (?, ?)", cTitle, nW)
				return Reply(:ok, [ :count = NoteCount() ])
			},
			:count = func aReq {
				return Reply(:ok, [ :count = NoteCount() ])
			},
			:titles = func aReq {
				aOut = []
				for aRow in __db_query("select title from notes order by id")
					add(aOut, aRow[1])
				next
				return Reply(:ok, [ :titles = aOut ])
			},
			# A deliberately bad statement: the DB error must arrive as a
			# clean 500 envelope, never a dead worker.
			:bad = func aReq {
				__db_query("select * from no_such_table")
				return Reply(:ok, [])
			},
			# Schema introspection over the wire, for the gates.
			:schema = func aReq {
				return Reply(:ok, [
					:tables = DataTables(),
					:notes  = DataColumns("notes"),
					:path   = DataPath()
				])
			}
		]
	]
])

func NoteCount
	aRows = __db_query("select count(*) from notes")
	return aRows[1][1]
