# The test vocabulary — what `ringserv test` gives an app's tests.
#
# Tests call services the way a client would, but IN PROCESS: Ask()
# goes straight through __dispatch, so the service model, contracts,
# generic actions and the database are all exercised without a port,
# a client, or a flake. (The HTTP layer itself is covered by this
# repository's own gates, not by every application's tests.)
#
#   Ask(:notes, :create, [ :title = "x" ])   -> the envelope
#   ExpectOk("creates a note", aReply)
#   Expect("counts", aReply[:data][:count], 3)
#   ExpectCode("rejects empties", aReply, 1)
#   ExpectStatus("422 on violation", 422)

nRsTestsPassed = 0
nRsTestsFailed = 0
cRsTestFile    = ""

func Ask cService, cAction, pPayload
	return __dispatch([
		:service = cService,
		:action  = cAction,
		:payload = pPayload
	])

# The transport status the last Ask would have answered with.
func LastStatus
	return __rs_laststatus()

func Expect cWhat, pGot, pWant
	if RsSame(pGot, pWant)
		RsTestPass(cWhat)
	else
		RsTestFail(cWhat, "expected " + RsShow(pWant) + ", got " + RsShow(pGot))
	ok

func ExpectOk cWhat, aReply
	if not islist(aReply)
		RsTestFail(cWhat, "no envelope returned")
		return
	ok
	nCode = RsDeclGet(aReply, "code", -1)
	if nCode = 0
		RsTestPass(cWhat)
	else
		RsTestFail(cWhat, "envelope code " + nCode + ": " +
		           RsDeclGet(aReply, "message", ""))
	ok

func ExpectCode cWhat, aReply, nWant
	nCode = RsDeclGet(aReply, "code", -1)
	if nCode = nWant
		RsTestPass(cWhat)
	else
		RsTestFail(cWhat, "expected code " + nWant + ", got " + nCode)
	ok

func ExpectStatus cWhat, nWant
	nGot = LastStatus()
	if nGot = nWant
		RsTestPass(cWhat)
	else
		RsTestFail(cWhat, "expected status " + nWant + ", got " + nGot)
	ok

func ExpectTrue cWhat, lCond
	if lCond
		RsTestPass(cWhat)
	else
		RsTestFail(cWhat, "condition was false")
	ok

# ------------------------------------------------------------ internals

func RsTestPass cWhat
	nRsTestsPassed++
	see "  PASS  " + cWhat + nl

func RsTestFail cWhat, cWhy
	nRsTestsFailed++
	see "  FAIL  " + cWhat + " — " + cWhy + nl

func RsTestBegin cFile
	cRsTestFile = cFile
	see cFile + nl

# Takes an ignored argument because rs_call always passes exactly one —
# and the CLI reads the failure count from the return value.
func RsTestReport aIgnored
	see nl
	if nRsTestsFailed = 0
		see "All " + nRsTestsPassed + " expectations passed." + nl
	else
		see "" + nRsTestsFailed + " expectation(s) FAILED (" +
		    nRsTestsPassed + " passed)." + nl
	ok
	return nRsTestsFailed

func RsSame pA, pB
	if isstring(pA) and isstring(pB)
		return pA = pB
	ok
	if isnumber(pA) and isnumber(pB)
		return pA = pB
	ok
	if islist(pA) and islist(pB)
		return JsonEncode(pA) = JsonEncode(pB)
	ok
	return 0

func RsShow pVal
	if isstring(pVal)
		return '"' + pVal + '"'
	but isnumber(pVal)
		return "" + pVal
	but islist(pVal)
		return JsonEncode(pVal)
	ok
	return "?"
