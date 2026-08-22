# synclib — the local-first sync protocol, deliberately boring.
#
# Two halves, each borrowed rather than invented (docs/topology.md §3):
#
#   READ  — shapes over HTTP, ElectricSQL's model. The server keeps an
#           append-only log of operations with monotonic offsets; the
#           client reads from an offset, pages until up to date, then
#           long-polls. Plain HTTP: cacheable, resumable from any offset.
#
#   WRITE — an idempotent mutation queue, Replicache's model. Offline
#           writes queue locally as SERVICE CALLS, are POSTed in order,
#           and are executed authoritatively here. A mutation IS a
#           service call, so the model needs no second vocabulary.
#
# What makes it exactly-once is not hope: a mutation is CLAIMED and
# PERFORMED inside one write transaction (db.zig's __db_write_*), so a
# crash between the two rolls both back, and a duplicate finds the claim
# already taken.

# ------------------------------------------------------------ the schema

# Applied by every worker at boot, beside the app's own tables.
func RsSyncApply
	aSynced = RsSyncedTables()
	if len(aSynced) = 0
		return 0
	ok

	# The log. `offset` is the client's cursor and must be monotonic per
	# INSERT, which AUTOINCREMENT guarantees even across deletes — a
	# plain rowid could be reused after a compaction and hand a client
	# rows it had already seen.
	__db_exec("CREATE TABLE IF NOT EXISTS __rs_shape_log (" +
		"offset INTEGER PRIMARY KEY AUTOINCREMENT, " +
		"shape TEXT NOT NULL, op TEXT NOT NULL, " +
		"row_id INTEGER NOT NULL, row TEXT, at INTEGER NOT NULL)")
	__db_exec("CREATE INDEX IF NOT EXISTS __rs_shape_log_shape " +
		"ON __rs_shape_log (shape, offset)")

	# Per-client high-water marks. One row per client, and the whole of
	# exactly-once lives in the WHERE clause of one UPSERT below.
	__db_exec("CREATE TABLE IF NOT EXISTS __rs_sync_client (" +
		"client_id TEXT PRIMARY KEY, " +
		"last_mutation_id INTEGER NOT NULL DEFAULT 0, " +
		"at INTEGER NOT NULL DEFAULT 0)")

	# The log floor: what a compaction has thrown away. A client asking
	# for an offset below it is told to refetch rather than handed a
	# silently incomplete history.
	__db_exec("CREATE TABLE IF NOT EXISTS __rs_shape_floor (" +
		"shape TEXT PRIMARY KEY, floor INTEGER NOT NULL DEFAULT 0)")

	for cTable in aSynced
		RsSyncInstallTriggers(cTable)
	next
	return len(aSynced)

# Triggers, not application code, because the log must be true for EVERY
# write — a generic service, a hand-written DataExec, a cascade, a future
# path nobody has thought of yet. A log maintained by the code that
# happens to remember to maintain it is a log that is wrong exactly when
# it matters.
func RsSyncInstallTriggers cTable
	if not RsValidName(cTable)
		return 0
	ok
	aCols = __db_columns(cTable)
	if len(aCols) = 0
		return 0            # table not declared (yet) — nothing to log
	ok

	cNew = RsSyncJsonObject(aCols, "new")
	cOld = RsSyncJsonObject(aCols, "old")

	# The column set is stamped into the trigger NAME, so a table that
	# gains a column through additive migration gets a differently-named
	# trigger rather than a silently stale one.
	cFinger = RsSyncFingerprint(aCols)

	# Identifiers go in unquoted here. Every name has passed RsValidName
	# (letters, digits, underscore), so there is nothing to quote against,
	# and a trigger body is easier to read — and to debug from
	# `sqlite_master` — without a double quote every third character.
	RsSyncTrigger(cTable, "ins", cFinger, "AFTER INSERT", "insert", "new", cNew)
	RsSyncTrigger(cTable, "upd", cFinger, "AFTER UPDATE", "update", "new", cNew)
	# A delete logs the row it removed, not just its id: a client undoing
	# a local prediction needs to know what was there.
	RsSyncTrigger(cTable, "del", cFinger, "AFTER DELETE", "delete", "old", cOld)
	return 1

# CREATE the current trigger, THEN drop any older generation — never the
# other way round.
#
# This order is load-bearing and was found by a gate, not by reasoning.
# DROP-then-CREATE leaves a window in which the table has no trigger, and
# every worker re-runs this at boot while the server is ALREADY SERVING
# (health answers as soon as the first worker is up). A write landing in
# another worker's window is a write missing from the log forever — the
# quietest possible corruption in a local-first system.
func RsSyncTrigger cTable, cSuffix, cFinger, cWhen, cOp, cRef, cJson
	cName = "__rs_log_" + cTable + "_" + cSuffix + "_" + cFinger
	__db_exec("CREATE TRIGGER IF NOT EXISTS " + cName + " " + cWhen +
		" ON " + cTable +
		" BEGIN INSERT INTO __rs_shape_log (shape, op, row_id, row, at)" +
		" VALUES ('" + cTable + "', '" + cOp + "', " + cRef + ".id, " + cJson +
		", CAST(strftime('%s','now') AS INTEGER)); END")

	# Older generations, if the schema moved. Dropping them now is safe:
	# the replacement is already in place, so nothing is ever unlogged.
	# The double-logging that happens for the instant both exist is
	# harmless — the client replays a log, and replaying the same row
	# twice yields the same row.
	aStale = DataQuery("select name from sqlite_master where type = 'trigger' " +
		"and name like ? and name <> ?",
		[ "__rs_log_" + cTable + "_" + cSuffix + "_%", cName ])
	for aRow in aStale
		if RsValidName(aRow[:name])
			__db_exec("DROP TRIGGER IF EXISTS " + aRow[:name])
		ok
	next

# A short, stable stamp for a column set. Not cryptographic and does not
# need to be: it distinguishes one declared schema from another, and a
# collision costs a stale trigger on a table whose columns changed to a
# set of the same length and the same letter sum, which does not happen
# by accident and is repaired by a restart when it does.
func RsSyncFingerprint aCols
	nSum = len(aCols)
	for cCol in aCols
		nSum += len(cCol)
		for i = 1 to len(cCol)
			nSum += ascii(cCol[i]) * i
		next
	next
	return "g" + nSum

# json_object('col', ref."col", ...) over the live columns. Column names
# come from the database itself, so a table that gained a column through
# additive migration logs it without anyone re-writing a trigger by hand.
func RsSyncJsonObject aCols, cRef
	aParts = []
	for cCol in aCols
		if not RsValidName(cCol)
			loop
		ok
		add(aParts, "'" + cCol + "', " + cRef + "." + cCol)
	next
	if len(aParts) = 0
		return "NULL"
	ok
	return "json_object(" + RsJoin(aParts, ", ") + ")"

# The tables the topology says are synced: :store = :local with a :sync
# mode. A :server table has no local replica, so it has nothing to sync
# and gets no trigger — the topology already refuses that combination.
func RsSyncedTables
	aOut = []
	aTopo = __rs_topology([])
	if aTopo[:declared] = 0
		return aOut
	ok
	for aEntry in aTopo[:data]
		if aEntry[:store] = "local" and aEntry[:sync] != ""
			add(aOut, aEntry[:name])
		ok
	next
	return aOut

# --------------------------------------------------------- the read path

# GET /sync/shape?shape=notes&offset=N&limit=M
#
# Answers the ops after `offset`, in order, plus the offset to ask from
# next. `upToDate` says the client has caught up — the signal to switch
# from paging to long-polling.
func __rs_sync_shape cQuery
	try
		aQ = JsonDecode(cQuery)
	catch
		return RsRefuse(400, "malformed sync request")
	done

	cShape = "" + RsDeclGet(aQ, "shape", "")
	nFrom  = RsSyncNumber(RsDeclGet(aQ, "offset", 0))
	nLimit = RsSyncNumber(RsDeclGet(aQ, "limit", 500))
	if nLimit < 1 or nLimit > 5000
		nLimit = 500
	ok

	if find(RsSyncedTables(), cShape) = 0
		return RsRefuse(404, "no synced shape named `" + cShape + "` — " +
			"a shape is a :store = :local table with a :sync mode")
	ok

	# Compaction honesty: a client below the floor has a gap it cannot
	# close by paging, and telling it to refetch is the only correct
	# answer. Silence here is how local-first systems corrupt quietly.
	nFloor = RsSyncNumber(DataValue(
		"select floor from __rs_shape_floor where shape = ?", [ cShape ], 0))
	if nFrom > 0 and nFrom < nFloor
		return [ :code = 0, :message = "OK", :data = [
			:shape = cShape, :control = "must-refetch", :offset = nFloor,
			:upToDate = 0, :ops = [] ] ]
	ok

	aRows = DataQuery("select offset, op, row_id, row from __rs_shape_log " +
		"where shape = ? and offset > ? order by offset asc limit ?",
		[ cShape, nFrom, nLimit ])

	aOps = []
	nLast = nFrom
	for aRow in aRows
		nLast = RsSyncNumber(aRow[:offset])
		pRow = ""
		if isstring(aRow[:row]) and aRow[:row] != ""
			try
				pRow = JsonDecode(aRow[:row])
			catch
				pRow = ""
			done
		ok
		add(aOps, [ :offset = nLast, :op = aRow[:op],
			    :id = RsSyncNumber(aRow[:row_id]), :row = pRow ])
	next

	# Up to date when this page did not fill: the client has seen
	# everything that existed at the moment of the query.
	nUp = 0
	if len(aOps) < nLimit
		nUp = 1
	ok
	return [ :code = 0, :message = "OK", :data = [
		:shape = cShape, :control = "", :offset = nLast,
		:upToDate = nUp, :ops = aOps ] ]

# The highest offset in a shape — what a long-poll compares against so
# the Zig side can wait without holding a VM worker.
func __rs_sync_head cShape
	if find(RsSyncedTables(), cShape) = 0
		return -1
	ok
	return RsSyncNumber(DataValue(
		"select max(offset) as m from __rs_shape_log where shape = ?", [ cShape ], 0))

# -------------------------------------------------------- the write path

# POST /sync/push
#
#   { "client_id": "...", "mutations": [
#       { "mutation_id": 1, "service": "notes", "action": "create",
#         "payload": { ... } }, ... ] }
#
# Executed IN ORDER. Each mutation is claimed and performed inside one
# write transaction, so exactly-once is a property of the database rather
# than of the control flow.
func __rs_sync_push cBody
	try
		aReq = JsonDecode(cBody)
	catch
		return RsRefuse(400, "malformed push: body is not valid JSON")
	done
	if not islist(aReq)
		return RsRefuse(400, "malformed push: body must be a JSON object")
	ok

	cClient = "" + RsDeclGet(aReq, "client_id", "")
	if cClient = "" or len(cClient) > 128
		return RsRefuse(400, "push requires a client_id")
	ok
	aMutations = RsDeclGet(aReq, "mutations", [])
	if not islist(aMutations)
		return RsRefuse(400, "push requires a mutations list")
	ok
	if len(aMutations) > 1000
		return RsRefuse(413, "too many mutations in one push (max 1000)")
	ok

	aResults = []
	nApplied = 0
	nSkipped = 0
	lStopped = 0

	for aMut in aMutations
		if not islist(aMut)
			add(aResults, [ :mutation_id = 0, :status = "rejected",
					:message = "a mutation is not an object" ])
			loop
		ok
		nId = RsSyncNumber(RsDeclGet(aMut, "mutation_id", 0))
		if nId < 1
			add(aResults, [ :mutation_id = nId, :status = "rejected",
					:message = "mutation_id must be a positive number" ])
			loop
		ok

		if lStopped
			# Everything after the first mutation that did not land is
			# NOT ATTEMPTED, and says so. Pushing on would either strand
			# the failed one behind a moved high-water mark or fill the
			# results with out-of-order noise; neither is information the
			# client can act on. The client fixes the first failure and
			# resends from there.
			add(aResults, [ :mutation_id = nId, :status = "not-attempted",
					:message = "an earlier mutation in this push did not apply" ])
			loop
		ok

		aOne = RsSyncApplyOne(cClient, nId, aMut)
		add(aResults, aOne)
		switch aOne[:status]
		on "applied"
			nApplied++
		on "duplicate"
			nSkipped++
		other
			lStopped = 1
		off
	next

	nHigh = RsSyncNumber(DataValue(
		"select last_mutation_id from __rs_sync_client where client_id = ?",
		[ cClient ], 0))

	return [ :code = 0, :message = "OK", :data = [
		:client_id = cClient,
		:last_mutation_id = nHigh,
		:applied = nApplied,
		:duplicates = nSkipped,
		:results = aResults ] ]

# One mutation, one transaction. The claim and the work are the same
# commit, which is what makes a retried push safe.
func RsSyncApplyOne cClient, nId, aMut
	__db_write_begin()
	pOut = ""
	try
		# THE HIGH-WATER MARK, read inside the transaction. Reading it
		# outside would be a guess: another worker could move it between
		# the read and the claim, which is the entire race this exists to
		# lose.
		nLast = RsSyncNumber(DataValue(
			"select last_mutation_id from __rs_sync_client where client_id = ?",
			[ cClient ], 0))

		if nId <= nLast
			__db_write_rollback()
			return [ :mutation_id = nId, :status = "duplicate",
				 :message = "already applied" ]
		ok

		# A GAP IS REFUSED, not accepted. If a client sends 5 while 4 has
		# never arrived, accepting 5 would strand 4 forever: it would come
		# back later, land at or below the mark, and be discarded as a
		# duplicate it never was. Mutations are a QUEUE, and a queue with
		# a hole in it is not one.
		if nId > nLast + 1
			__db_write_rollback()
			return [ :mutation_id = nId, :status = "out-of-order",
				 :message = "expected mutation " + (nLast + 1) +
					    ", got " + nId + " — resend from " + (nLast + 1) ]
		ok

		# THE CLAIM. Unconditional now that the two impossible cases are
		# out, and safe because this transaction owns the one writer: no
		# other worker can move the mark between the read above and this.
		__db_exec("INSERT INTO __rs_sync_client " +
			"(client_id, last_mutation_id, at) VALUES (?, ?, " +
			"CAST(strftime('%s','now') AS INTEGER)) " +
			"ON CONFLICT(client_id) DO UPDATE SET " +
			"last_mutation_id = excluded.last_mutation_id, at = excluded.at",
			[ cClient, nId ])

		# THE WORK. A mutation is a service call, so this is the ordinary
		# dispatcher — contracts, placement and all. The authority is the
		# server-run action, not a merge heuristic (C3 §2.2).
		aCall = [ :service = "" + RsDeclGet(aMut, "service", ""),
			  :action  = "" + RsDeclGet(aMut, "action", ""),
			  :payload = RsDeclGet(aMut, "payload", []) ]
		pOut = __dispatch(aCall)
	catch
		# The mutex is held by the transaction; releasing it is not
		# optional and cannot wait for a tidier path.
		__db_write_rollback()
		return [ :mutation_id = nId, :status = "failed",
			 :message = "mutation raised: " + cCatchError ]
	done

	nCode = 1
	cMsg = ""
	if islist(pOut)
		nCode = RsSyncNumber(RsDeclGet(pOut, "code", 1))
		cMsg  = "" + RsDeclGet(pOut, "message", "")
	ok

	if nCode != 0
		# A refused mutation is rolled back WITH ITS CLAIM, so the client
		# may fix and resend the same id. Keeping the claim would turn a
		# validation error into permanent data loss.
		__db_write_rollback()
		return [ :mutation_id = nId, :status = "rejected", :message = cMsg,
			 :result = pOut ]
	ok

	__db_write_commit()
	return [ :mutation_id = nId, :status = "applied", :message = cMsg,
		 :result = pOut ]

# What a client asks before it starts: how far this server thinks it got.
func __rs_sync_state cQuery
	try
		aQ = JsonDecode(cQuery)
	catch
		return RsRefuse(400, "malformed sync request")
	done
	cClient = "" + RsDeclGet(aQ, "client_id", "")
	if cClient = ""
		return RsRefuse(400, "state requires a client_id")
	ok
	aShapes = []
	for cShape in RsSyncedTables()
		add(aShapes, [ :shape = cShape, :head = __rs_sync_head(cShape) ])
	next
	return [ :code = 0, :message = "OK", :data = [
		:client_id = cClient,
		:last_mutation_id = RsSyncNumber(DataValue(
			"select last_mutation_id from __rs_sync_client where client_id = ?",
			[ cClient ], 0)),
		:shapes = aShapes ] ]

# --------------------------------------------------------------- helpers

# A number from whatever JSON handed over. Strings are accepted because
# query parameters arrive as text and refusing them would make the
# endpoint unusable from a URL, which is the point of shapes over HTTP.
func RsSyncNumber pValue
	if isnumber(pValue)
		return pValue
	ok
	if isstring(pValue) and pValue != ""
		if isdigit(pValue)
			return number(pValue)
		ok
	ok
	return 0

# ----------------------------------------------------------- compaction
#
# The shape log is append-only, so it grows forever unless something
# trims it. Compaction is that something, and the whole difficulty is
# that trimming a log a client is reading from is how a local-first
# system corrupts QUIETLY: the client asks for offset N, gets rows that
# start at N+400, and believes it has caught up.
#
# So compaction and the floor move TOGETHER, in one transaction, and the
# floor is what `/sync/shape` checks before it answers. A client below
# the floor is told `must-refetch` — the honest answer, and the only one
# that cannot silently lose a row.
#
# WHAT IS KEPT. Not "the last N entries" but "everything a live client
# could still ask for": the retention window is expressed in ENTRIES
# behind the head, and the default is generous because the cost of
# keeping too much is disk, while the cost of keeping too little is every
# slow client refetching its whole shape.

# Ring: SyncCompact(cShape, nKeep) — trim one shape, move its floor.
#
# Returns how many entries were removed. Safe to call at any time from
# any worker: it is one transaction on the single writer, so a reader
# paging through the log either sees the log before the trim or after it,
# never halfway.
func SyncCompact cShape, nKeep
	if not RsValidName(cShape)
		raise("SyncCompact(): not a shape name: " + cShape)
	ok
	if find(RsJournalNames(), lower(cShape))
		# The mirror image of refusing a non-shape, and the more important
		# half: a journal is a record something is required to keep whole.
		# Compaction discards history, so it may not be pointed at one --
		# see docs/COMMONS.md section 1 for why the two stores are opposite
		# primitives rather than two settings of one.
		raise("SyncCompact(): `" + cShape + "` is a JOURNAL and is never " +
		      "compacted -- its whole value is that nothing leaves it")
	ok
	if find(RsSyncedTables(), cShape) = 0
		raise("SyncCompact(): `" + cShape + "` is not a synced shape")
	ok
	if not isnumber(nKeep) or nKeep < 1
		nKeep = 10000
	ok

	nRemoved = 0
	__db_write_begin()
	try
		nHead = RsSyncNumber(DataValue(
			"select max(offset) as m from __rs_shape_log where shape = ?",
			[ cShape ], 0))

		# The new floor is the highest offset we are about to DISCARD.
		# A client at exactly the floor has seen everything below it and
		# nothing above, which is a valid place to resume from — so the
		# refetch test in __rs_sync_shape is `<`, not `<=`.
		nFloor = nHead - nKeep
		if nFloor <= 0
			__db_write_rollback()
			return 0
		ok

		nRemoved = __db_exec(
			"delete from __rs_shape_log where shape = ? and offset <= ?",
			[ cShape, nFloor ])

		# The floor moves in the SAME transaction as the delete. Two
		# statements would leave a window in which the rows are gone and
		# the floor still says they are there, and a client reading in
		# that window is handed a gap it will never know about.
		__db_exec("INSERT INTO __rs_shape_floor (shape, floor) VALUES (?, ?) " +
			"ON CONFLICT(shape) DO UPDATE SET floor = excluded.floor " +
			"WHERE excluded.floor > __rs_shape_floor.floor",
			[ cShape, nFloor ])
	catch
		__db_write_rollback()
		raise(cCatchError)
	done
	__db_write_commit()
	return nRemoved

# Compact every synced shape. What an application calls from a scheduled
# job, or what `SyncMaintain()` calls for it.
func SyncCompactAll nKeep
	nTotal = 0
	for cShape in RsSyncedTables()
		nTotal += SyncCompact(cShape, nKeep)
	next
	return nTotal

# What a shape looks like right now: head, floor, and how many entries
# are live. The number an operator needs before deciding to compact, and
# the number a gate needs to prove compaction happened.
func SyncShapeState cShape
	return [
		:shape = cShape,
		:head  = RsSyncNumber(DataValue(
			"select max(offset) as m from __rs_shape_log where shape = ?",
			[ cShape ], 0)),
		:floor = RsSyncNumber(DataValue(
			"select floor from __rs_shape_floor where shape = ?", [ cShape ], 0)),
		:entries = RsSyncNumber(DataValue(
			"select count(*) as n from __rs_shape_log where shape = ?",
			[ cShape ], 0))
	]

# The service an application may expose to operate its own sync layer.
# NOT registered automatically: compaction discards history, and a server
# that let anyone who can reach /api/v1 discard history would be a server
# with a denial-of-service endpoint. An application opts in:
#
#     :sync = [ :table = "", :actions = [] ]   # no
#     :sync = RsSyncService()                  # yes, and place it :server
func RsSyncService
	return [
		:state = func aReq {
			aOut = []
			for cShape in RsSyncedTables()
				add(aOut, SyncShapeState(cShape))
			next
			return Reply(:ok, [ :shapes = aOut ])
		},
		:compact = func aReq {
			aP = aReq[:payload]
			nKeep = 10000
			if islist(aP) and isnumber(RsDeclGet(aP, "keep", ""))
				nKeep = RsDeclGet(aP, "keep", 10000)
			ok
			cShape = "" + RsDeclGet(aP, "shape", "")
			if cShape != ""
				return Reply(:ok, [ :removed = SyncCompact(cShape, nKeep) ])
			ok
			return Reply(:ok, [ :removed = SyncCompactAll(nKeep) ])
		}
	]
