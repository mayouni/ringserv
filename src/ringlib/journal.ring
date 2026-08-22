# journallib — history as the only truth.
#
# A second store beside Data(), NOT a mode of it. The distinction is the
# whole design (docs/COMMONS.md §1) and it is not stylistic:
#
#   Data()     current state. Mutable rows, additive migration, and a shape
#              log derived by triggers that COMPACTION DELIBERATELY TRIMS.
#   Journal()  history. Append-only, hash-chained, replayed to state, and
#              NEVER trimmed.
#
# A primitive whose defining feature is "the floor moves" is disqualified by
# construction from holding a record the law requires to be inalterable —
# French anti-fraud law, in the case this was designed for. So compaction
# refuses a journal by name, the mirror image of it refusing a non-shape.
#
#     Journal([
#         :name   = "ventes",
#         :apply  = func aEvent { … the application folds it into its own state … }
#     ])
#
#     JournalAppend("ventes", [ :type = "passer_commande", :commande = … ])
#     JournalVerify("ventes")     ->  [ :events = 41, :chain = "INTACTE" ]
#
# ONE WRITE PATH and one recovery path, exactly as the germ this comes from
# had them: chain, append, apply — and replay is the only way state is ever
# rebuilt. Nothing derived is stored outside the journal, so a restart
# mid-service loses nothing because there is nothing outside to lose.

aRsJournals = []

# The applied high-water mark, per journal. Per WORKER and in memory only —
# see RsJournalCatchUp. Declared HERE, beside the other global, because a
# Ring file executes its top-level statements only until the first `func`:
# an assignment written further down is parsed and never run, and the first
# use fails with "uninitialized variable" nowhere near the real line.
aRsJournalSeen = []

func Journal aDecl
	if not islist(aDecl)
		raise("Journal(): expects a declaration list")
	ok
	cName = "" + RsDeclGet(aDecl, "name", "")
	if not RsValidName(cName)
		raise("Journal(): a journal needs a :name of letters, digits or _")
	ok
	# Re-declaration is idempotent, because every worker evaluates the
	# application at boot and they must not fight over the list.
	for aJ in aRsJournals
		if lower(aJ[1]) = lower(cName)
			return 1
		ok
	next
	add(aRsJournals, [ lower(cName), aDecl ])
	return 1

func RsJournalDecl cName
	for aJ in aRsJournals
		if lower(aJ[1]) = lower(cName)
			return aJ[2]
		ok
	next
	return ""

func RsJournalNames
	aOut = []
	for aJ in aRsJournals
		add(aOut, aJ[1])
	next
	return aOut

func RsJournalTable cName
	return "__rs_journal_" + lower(cName)

# ------------------------------------------------------------ the schema

# Applied by every worker at boot, beside the app's own tables.
#
# `seq` is AUTOINCREMENT so a number is never reused: a rowid recycled after
# a delete would let two different records share an identity, and in a
# record that must be inalterable that is not a cosmetic problem. Nothing
# ever deletes from here — the column exists to make the promise structural
# rather than behavioural.
func RsJournalApply
	if len(aRsJournals) = 0
		return 0
	ok
	for cName in RsJournalNames()
		cT = RsJournalTable(cName)
		__db_exec("CREATE TABLE IF NOT EXISTS " + cT + " (" +
			"seq INTEGER PRIMARY KEY AUTOINCREMENT, " +
			"ts INTEGER NOT NULL, type TEXT NOT NULL, " +
			"prev TEXT NOT NULL, hash TEXT NOT NULL, body TEXT NOT NULL)")
		__db_exec("CREATE INDEX IF NOT EXISTS " + cT + "_hash ON " + cT + " (hash)")
	next
	return len(aRsJournals)

# The hash of the last record, or GENESE.
#
# GENESE is kept verbatim from the germ so a journal written by it imports
# here and verifies unmodified — the migration this design promised is a
# deversement, not a translation.
func RsJournalHead cName
	cT = RsJournalTable(cName)
	cHead = "" + DataValue("select hash from " + cT +
		" order by seq desc limit 1", [], "")
	if cHead = ""
		return "GENESE"
	ok
	return cHead

# The chain link. Hashed over PREV + THE EXACT BODY TEXT that is stored,
# never over a re-serialisation of it: two JSON encoders disagreeing about
# whitespace would otherwise be a ROMPUE that never happened.
func RsJournalHash cPrev, cBody
	return __rs_sha256(cPrev + cBody)

# ------------------------------------------------------------- the write

func JournalAppend cName, aEvent
	aDecl = RsJournalDecl(cName)
	if not islist(aDecl)
		raise("JournalAppend(): no journal named `" + cName + "`")
	ok
	if not islist(aEvent)
		raise("JournalAppend(): an event must be a list")
	ok
	cType = "" + RsDeclGet(aEvent, "type", "")
	if cType = ""
		raise("JournalAppend(): an event needs a :type")
	ok

	# Catch up before appending: this worker is about to fold in its own
	# event, and folding it onto state that is missing another worker's
	# events would leave a gap no later catch-up can find.
	RsJournalCatchUp(cName)

	cT = RsJournalTable(cName)
	aRecord = ""
	__db_write_begin()
	try
		# The head is read INSIDE the transaction. Reading it outside would
		# be a guess: another worker could append between the read and the
		# insert, and the chain would fork silently — which is the one
		# failure this structure exists to make impossible.
		cPrev = RsJournalHead(cName)
		nTs   = RsJournalNow()
		aFull = aEvent
		aFull[:ts] = nTs
		cBody = JsonEncode(aFull)
		cHash = RsJournalHash(cPrev, cBody)

		__db_exec("INSERT INTO " + cT + " (ts, type, prev, hash, body) " +
			"VALUES (?, ?, ?, ?, ?)", [ nTs, cType, cPrev, cHash, cBody ])
		nSeq = DataInsertId()
		aRecord = [ :seq = nSeq, :ts = nTs, :type = cType,
			    :prev = cPrev, :hash = cHash, :event = aFull ]
	catch
		__db_write_rollback()
		raise(cCatchError)
	done
	__db_write_commit()

	# Applied only after the commit. An application that folded an event
	# into its state and then lost the transaction would hold state the
	# journal cannot account for, which is the one direction this must
	# never fail in.
	RsJournalApplyOne(aDecl, aRecord[:event])
	RsJournalSetSeen(cName, aRecord[:seq])
	return aRecord

func RsJournalNow
	return RsSyncNumber(DataValue(
		"select CAST(strftime('%s','now') AS INTEGER) as n", [], 0))

func RsJournalApplyOne aDecl, aEvent
	pApply = RsDeclGet(aDecl, "apply", "")
	if isstring(pApply) and pApply != ""
		call pApply(aEvent)
	ok
	return 1

# ------------------------------------------------------------ the recovery

# Replay the whole journal through :apply, in order. THE ONLY WAY STATE IS
# EVER REBUILT — see the note at the top about nothing derived living
# outside the journal.
func JournalReplay cName
	aDecl = RsJournalDecl(cName)
	if not islist(aDecl)
		raise("JournalReplay(): no journal named `" + cName + "`")
	ok
	nCount = 0
	for aRow in DataQuery("select seq, body from " + RsJournalTable(cName) +
			      " order by seq asc", [])
		try
			aEvent = JsonDecode(aRow[:body])
		catch
			loop        # verification reports it; replay does not stop on it
		done
		RsJournalApplyOne(aDecl, aEvent)
		RsJournalSetSeen(cName, aRow[:seq])
		nCount++
	next
	return nCount

# Replay every declared journal. Called once per worker at boot.
func RsJournalReplayAll
	nTotal = 0
	for cName in RsJournalNames()
		nTotal += JournalReplay(cName)
	next
	return nTotal

# ---------------------------------------------------- N workers, one history
#
# REPLAY AT BOOT IS NOT ENOUGH, and this is the germ's single-process
# assumption meeting RingServ's worker model.
#
# Each worker owns a private VM and rebuilds its own state from the journal
# at boot. But `:apply` runs only in the worker that performed the append,
# so every other worker's state stops at the moment it booted. With two
# workers and three appends, the per-day counter went 1, 1, 2 — each worker
# counting only its own. Measured, not imagined: it is what the first run of
# the phase-9 fixture printed.
#
# So a worker CATCHES UP before it answers: apply every record newer than
# the last one this worker has seen. Normally that is an indexed query
# returning nothing. It is called at the door, beside contracts and
# placement, because the alternative — asking applications to remember — is
# how a rule becomes advisory.
#
# The high-water mark is per WORKER and lives only in memory (aRsJournalSeen,
# declared at the top of this file). It is not state to be persisted: it
# describes what this VM has folded in, not what the journal contains, and a
# stored copy would be wrong for every other worker that read it.

func RsJournalSeen cName
	for aE in aRsJournalSeen
		if aE[1] = lower(cName)
			return aE[2]
		ok
	next
	return 0

func RsJournalSetSeen cName, nSeq
	for i = 1 to len(aRsJournalSeen)
		if aRsJournalSeen[i][1] = lower(cName)
			aRsJournalSeen[i][2] = nSeq
			return nSeq
		ok
	next
	add(aRsJournalSeen, [ lower(cName), nSeq ])
	return nSeq

func RsJournalCatchUp cName
	aDecl = RsJournalDecl(cName)
	if not islist(aDecl)
		return 0
	ok
	nSeen = RsJournalSeen(cName)
	nApplied = 0
	for aRow in DataQuery("select seq, body from " + RsJournalTable(cName) +
			      " where seq > ? order by seq asc", [ nSeen ])
		try
			aEvent = JsonDecode(aRow[:body])
		catch
			RsJournalSetSeen(cName, aRow[:seq])
			loop
		done
		RsJournalApplyOne(aDecl, aEvent)
		RsJournalSetSeen(cName, aRow[:seq])
		nApplied++
	next
	return nApplied

# Every declared journal, caught up. Called once per dispatch.
func RsJournalCatchUpAll
	if len(aRsJournals) = 0
		return 0
	ok
	nTotal = 0
	for cName in RsJournalNames()
		nTotal += RsJournalCatchUp(cName)
	next
	return nTotal

# --------------------------------------------------------- the verification

# INTACTE or ROMPUE, and WHERE — which the germ did not report and an
# auditor needs first. A verdict without a location is a verdict nobody can
# act on.
func JournalVerify cName
	if not islist(RsJournalDecl(cName))
		raise("JournalVerify(): no journal named `" + cName + "`")
	ok
	cPrev = "GENESE"
	nCount = 0
	for aRow in DataQuery("select seq, prev, hash, body from " +
			      RsJournalTable(cName) + " order by seq asc", [])
		nCount++
		if aRow[:prev] != cPrev
			return [ :events = nCount, :chain = "ROMPUE",
				 :at = aRow[:seq], :why = "prev does not name the record before it" ]
		ok
		if RsJournalHash(aRow[:prev], aRow[:body]) != aRow[:hash]
			return [ :events = nCount, :chain = "ROMPUE",
				 :at = aRow[:seq], :why = "the body does not hash to its recorded hash" ]
		ok
		cPrev = aRow[:hash]
	next
	return [ :events = nCount, :chain = "INTACTE", :at = 0, :why = "" ]

# ------------------------------------------------------------- reading out

func JournalRead cName, nFrom, nLimit
	if not islist(RsJournalDecl(cName))
		raise("JournalRead(): no journal named `" + cName + "`")
	ok
	if not isnumber(nFrom) nFrom = 0 ok
	if not isnumber(nLimit) or nLimit < 1 or nLimit > 5000 nLimit = 500 ok
	aOut = []
	for aRow in DataQuery("select seq, ts, type, prev, hash, body from " +
			RsJournalTable(cName) + " where seq > ? order by seq asc limit ?",
			[ nFrom, nLimit ])
		pEvent = ""
		try
			pEvent = JsonDecode(aRow[:body])
		catch
			pEvent = ""
		done
		add(aOut, [ :seq = aRow[:seq], :ts = aRow[:ts], :type = aRow[:type],
			    :prev = aRow[:prev], :hash = aRow[:hash], :event = pEvent ])
	next
	return aOut

# The interchange format: one JSON object per line, the germ's own shape, so
# a journal moves between a Commons and a RingServ without translation.
func JournalExport cName
	cOut = ""
	for aRow in DataQuery("select body, prev, hash from " +
			RsJournalTable(cName) + " order by seq asc", [])
		cOut += aRow[:body] + nl
	next
	return cOut

# The service an application may expose to operate its own journal. NOT
# registered automatically, and read-only by construction: `verify` and
# `read` answer, and nothing here appends. An endpoint that let any caller
# write to a fiscal record would be a worse idea than no endpoint.
# The journal a request means: named in the payload, or the only one there
# is. NOT closed over, because Ring's anonymous functions do not capture
# outer locals -- `func aReq { ... cName ... }` compiles and then fails at
# run time with "uninitialized variable", which is a trap worth naming here
# rather than rediscovering in every service that tries it.
func RsJournalOf aReq
	aP = aReq[:payload]
	if islist(aP)
		cWanted = "" + RsDeclGet(aP, "journal", "")
		if cWanted != ""
			return cWanted
		ok
	ok
	aNames = RsJournalNames()
	if len(aNames) = 1
		return aNames[1]
	ok
	return ""

func RsJournalService cName
	return [
		:verify = func aReq {
			cJ = RsJournalOf(aReq)
			if cJ = ""
				return RsRefuse(400, "name the journal: this application declares " +
					"more than one, so :journal is required")
			ok
			return Reply(:ok, JournalVerify(cJ))
		},
		:read = func aReq {
			cJ = RsJournalOf(aReq)
			if cJ = ""
				return RsRefuse(400, "name the journal: this application declares " +
					"more than one, so :journal is required")
			ok
			aP = aReq[:payload]
			nFrom = 0
			nLimit = 100
			if islist(aP)
				if isnumber(RsDeclGet(aP, "from", "")) nFrom = RsDeclGet(aP, "from", 0) ok
				if isnumber(RsDeclGet(aP, "limit", "")) nLimit = RsDeclGet(aP, "limit", 100) ok
			ok
			return Reply(:ok, [ :records = JournalRead(cJ, nFrom, nLimit) ])
		}
	]

# ------------------------------------------- the command-line ambassador
#
# `ringserv journal list | verify | export` reaches the journal through
# THIS one entry point rather than calling JournalExport/JournalVerify
# across the bridge one by one. Two reasons, and neither is tidiness:
#
#   rs_call is JSON in, JSON out -- so a single list-in/list-out surface
#   is the only shape whose argument survives the trip unambiguously,
#   whatever a journal is named.
#
#   WHICH JOURNAL A REQUEST MEANS is a rule, not a lookup: named, or the
#   only one declared, or a refusal. RsJournalService already answers it
#   for HTTP callers; a second copy in Zig would be a second answer, and
#   the two would drift on the first application that declares three.
#
# THE TABLE IS NEVER CREATED HERE. A command that reads a record the law
# requires to be inalterable must not be able to manufacture an empty one
# by being pointed at the wrong file -- so a missing table is reported as
# the fact it is, and the caller decides what that means.
func __rs_journal_cli aArgs
	cOp   = ""
	cName = ""
	if islist(aArgs)
		cOp   = "" + RsDeclGet(aArgs, "op", "")
		cName = "" + RsDeclGet(aArgs, "journal", "")
	ok
	aNames = RsJournalNames()

	if cOp = "list"
		return [ :ok = 1, :error = "", :names = aNames ]
	ok

	if cName = ""
		if len(aNames) = 0
			return [ :ok = 0, :names = aNames,
				 :error = "this application declares no journal" ]
		but len(aNames) > 1
			return [ :ok = 0, :names = aNames,
				 :error = "name the journal with --journal: this application " +
					  "declares more than one" ]
		ok
		cName = aNames[1]
	ok

	if not islist(RsJournalDecl(cName))
		return [ :ok = 0, :names = aNames,
			 :error = "no journal named `" + cName + "` in this application" ]
	ok

	aRes = []
	try
		if cOp = "export"
			aRes = [ :ok = 1, :error = "", :journal = cName,
				 :text = JournalExport(cName) ]
		but cOp = "verify"
			aV = JournalVerify(cName)
			aRes = [ :ok = 1, :error = "", :journal = cName,
				 :events = aV[:events], :chain = aV[:chain],
				 :at = aV[:at], :why = aV[:why] ]
		else
			aRes = [ :ok = 0, :names = aNames,
				 :error = "unknown operation `" + cOp + "`" ]
		ok
	catch
		aRes = [ :ok = 0, :names = aNames, :error = cCatchError ]
	done
	return aRes
