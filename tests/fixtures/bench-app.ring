# A probe fixture: times the pieces of a write, inside one request, so
# HTTP, dispatch and worker hand-off all drop out of the measurement.

cDb = sysget("RINGSERV_TEST_DB")
cW  = sysget("RINGSERV_TEST_WORKERS")
if cDb = "" cDb = ":memory:" ok

RingServ([
	:port     = 8096,
	:workers  = RsBenchWorkers(),
	:database = cDb,

	:data = [
		:notes = [ :title = :string, :body = :string, :weight = :number ]
	],

	:services = [
		:bench = [
			# N inserts in a loop, one request. If this is ~N x 11ms the
			# cost is the write itself; if it is far less, the cost is
			# per-REQUEST and lives outside DataExec.
			:inserts = func aReq {
				n = aReq[:payload][:n]
				t1 = clock()
				for i = 1 to n
					DataExec("insert into notes (title,body,weight) values (?,?,?)",
					         [ "t"+i, "body", i ])
				next
				t2 = clock()
				return Reply(:ok, [ :ms = t2 - t1, :per = (t2-t1) / n ])
			},

			# The same inserts wrapped in ONE transaction.
			:txinserts = func aReq {
				n = aReq[:payload][:n]
				t1 = clock()
				DataExec("begin", [])
				for i = 1 to n
					DataExec("insert into notes (title,body,weight) values (?,?,?)",
					         [ "t"+i, "body", i ])
				next
				DataExec("commit", [])
				t2 = clock()
				return Reply(:ok, [ :ms = t2 - t1, :per = (t2-t1) / n ])
			},

			# What the generic create action does BESIDES the insert:
			# ask the live schema for its columns, every single time.
			:columns = func aReq {
				n = aReq[:payload][:n]
				t1 = clock()
				for i = 1 to n
					aCols = __db_columns("notes")
				next
				t2 = clock()
				return Reply(:ok, [ :ms = t2 - t1, :per = (t2-t1) / n ])
			},

			# A read of the same shape, for scale.
			:reads = func aReq {
				n = aReq[:payload][:n]
				t1 = clock()
				for i = 1 to n
					aRows = DataQuery("select * from notes where id = ?", [ i ])
				next
				t2 = clock()
				return Reply(:ok, [ :ms = t2 - t1, :per = (t2-t1) / n ])
			},

			# The whole generic create path, called in a loop in process.
			:generic = func aReq {
				n = aReq[:payload][:n]
				t1 = clock()
				for i = 1 to n
					aRs = Ask(:notes, :create, [ :title = "g"+i, :weight = i ])
				next
				t2 = clock()
				return Reply(:ok, [ :ms = t2 - t1, :per = (t2-t1) / n ])
			},

			:nothing = func aReq {
				return Reply(:ok, [ :ms = 0 ])
			},

			# Set SQLite's WAL autocheckpoint threshold (in pages) on this
			# worker's connection, to test whether checkpointing is what
			# makes a mature database's writes expensive.
			:autockpt = func aReq {
				n = aReq[:payload][:n]
				DataExec("pragma wal_autocheckpoint=" + n, [])
				aRs = DataQuery("pragma wal_autocheckpoint", [])
				return Reply(:ok, [ :now = aRs ])
			},

			# What mode is this connection actually in? db.zig asks for
			# WAL on every non-memory connection; this reports what SQLite
			# says it got, which is not the same claim.
			:pragmas = func aReq {
				return Reply(:ok, [
					:journal_mode = DataQuery("pragma journal_mode", []),
					:synchronous  = DataQuery("pragma synchronous", []),
					:path         = DataPath()
				])
			}
		],

		:notes = [ :table = "notes" ]
	]
])


# Worker count from the environment, so one fixture can measure how the
# write path behaves as the pool grows.
func RsBenchWorkers
	if cW = "" return 1 ok
	return number(cW)
