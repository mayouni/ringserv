# Generic table services — the boilerplate killer.
#
# Most services are CRUD over one table (Pionia's lesson, itself from
# Django REST's generic views). Declaring a table is enough:
#
#   :notes = [ :table = "notes" ]                        # all five
#   :notes = [ :table = "notes", :actions = [ :list, :get ] ]
#   :notes = [ :table = "notes", :list = func aReq { … } ]   # override
#
# Safety rule that runs through everything here: column names are never
# taken from the request. They are matched against the LIVE schema
# (__db_columns) and anything unknown is dropped, so a payload key can
# never reach the statement text. Values always travel as bound
# parameters.

func RsGenericActions
	return [ "list", "get", "create", "update", "delete" ]

# Is cAction one of the generic actions this declaration offers?
func RsHasGeneric pSvc, cAction
	cTable = RsDeclGet(pSvc, "table", "")
	if not isstring(cTable) or cTable = ""
		return 0
	ok
	if find(RsGenericActions(), lower(cAction)) = 0
		return 0
	ok
	# :actions restricts the set when present.
	aAllowed = RsDeclGet(pSvc, "actions", "")
	if islist(aAllowed)
		for cA in aAllowed
			if isstring(cA) and lower(cA) = lower(cAction)
				return 1
			ok
		next
		return 0
	ok
	return 1

func RsRunGeneric pSvc, aReq
	cTable   = RsDeclGet(pSvc, "table", "")
	cAction  = lower(aReq[:action])
	pPayload = aReq[:payload]
	if not RsValidName(cTable)
		return RsFailed("invalid table name: " + cTable)
	ok
	aCols = __db_columns(cTable)
	if len(aCols) = 0
		return RsFailed("no such table: " + cTable)
	ok

	switch cAction
	on "list"    return RsGenericList(cTable, aCols, pPayload)
	on "get"     return RsGenericGet(cTable, pPayload)
	on "create"  return RsGenericCreate(cTable, aCols, pPayload)
	on "update"  return RsGenericUpdate(cTable, aCols, pPayload)
	on "delete"  return RsGenericDelete(cTable, pPayload)
	off
	return RsRefuse(404, "unknown action: " + cTable + "." + cAction)

# list — optional equality filters, limit/offset paging, id order.
func RsGenericList cTable, aCols, pPayload
	cWhere  = ""
	aParams = []
	aFilter = RsDeclGet(pPayload, "filter", "")
	if islist(aFilter)
		cSep = ""
		for aPair in aFilter
			if not (islist(aPair) and len(aPair) = 2 and isstring(aPair[1]))
				loop
			ok
			cCol = RsMatchColumn(aCols, aPair[1])
			if cCol = ""
				loop            # unknown column: dropped, never interpolated
			ok
			cWhere += cSep + '"' + cCol + '" = ?'
			add(aParams, aPair[2])
			cSep = " and "
		next
		if cWhere != "" cWhere = " where " + cWhere ok
	ok

	cLimit = ""
	nLimit = RsDeclGet(pPayload, "limit", 0)
	if isnumber(nLimit) and nLimit > 0
		cLimit = " limit ?"
		add(aParams, nLimit)
		nOffset = RsDeclGet(pPayload, "offset", 0)
		if isnumber(nOffset) and nOffset > 0
			cLimit += " offset ?"
			add(aParams, nOffset)
		ok
	ok

	aRows = DataQuery('select * from "' + cTable + '"' + cWhere +
	                  ' order by id' + cLimit, aParams)
	return Reply(:ok, [ :rows = aRows, :count = len(aRows) ])

func RsGenericGet cTable, pPayload
	nId = RsDeclGet(pPayload, "id", "")
	if not isnumber(nId)
		return RsRefuse(400, "get: numeric id is required")
	ok
	aRows = DataQuery('select * from "' + cTable + '" where id = ?', [ nId ])
	if len(aRows) = 0
		return RsRefuse(404, "no such row: " + cTable + "." + nId)
	ok
	return Reply(:ok, aRows[1])

func RsGenericCreate cTable, aCols, pPayload
	aNames  = []
	aMarks  = []
	aParams = []
	for aPair in RsPairs(pPayload)
		cCol = RsMatchColumn(aCols, aPair[1])
		if cCol = "" or lower(cCol) = "id"
			loop
		ok
		add(aNames, '"' + cCol + '"')
		add(aMarks, "?")
		add(aParams, RsStorable(aPair[2]))
	next
	if len(aNames) = 0
		return RsRefuse(400, "create: no known columns in the payload")
	ok
	DataExec('insert into "' + cTable + '" (' + RsJoin(aNames, ", ") +
	         ") values (" + RsJoin(aMarks, ", ") + ")", aParams)
	return Reply(:ok, [ :id = DataInsertId() ])

func RsGenericUpdate cTable, aCols, pPayload
	nId = RsDeclGet(pPayload, "id", "")
	if not isnumber(nId)
		return RsRefuse(400, "update: numeric id is required")
	ok
	aSets   = []
	aParams = []
	for aPair in RsPairs(pPayload)
		cCol = RsMatchColumn(aCols, aPair[1])
		if cCol = "" or lower(cCol) = "id"
			loop
		ok
		add(aSets, '"' + cCol + '" = ?')
		add(aParams, RsStorable(aPair[2]))
	next
	if len(aSets) = 0
		return RsRefuse(400, "update: no known columns in the payload")
	ok
	add(aParams, nId)
	nChanged = DataExec('update "' + cTable + '" set ' + RsJoin(aSets, ", ") +
	                    " where id = ?", aParams)
	if nChanged = 0
		return RsRefuse(404, "no such row: " + cTable + "." + nId)
	ok
	return Reply(:ok, [ :id = nId, :changed = nChanged ])

func RsGenericDelete cTable, pPayload
	nId = RsDeclGet(pPayload, "id", "")
	if not isnumber(nId)
		return RsRefuse(400, "delete: numeric id is required")
	ok
	nChanged = DataExec('delete from "' + cTable + '" where id = ?', [ nId ])
	if nChanged = 0
		return RsRefuse(404, "no such row: " + cTable + "." + nId)
	ok
	return Reply(:ok, [ :id = nId, :deleted = nChanged ])

# ---------------------------------------------------------- helpers

# The declared column whose name matches cWanted, or "" — the gate that
# keeps request keys out of statement text.
func RsMatchColumn aCols, cWanted
	if not isstring(cWanted)
		return ""
	ok
	for cCol in aCols
		if lower(cCol) = lower(cWanted)
			return cCol
		ok
	next
	return ""

# The [key, value] pairs of a hash-shaped list, or [].
func RsPairs pList
	aOut = []
	if not islist(pList)
		return aOut
	ok
	for x in pList
		if islist(x) and len(x) = 2 and isstring(x[1])
			add(aOut, x)
		ok
	next
	return aOut

# Lists and objects are stored as JSON text (see RsSqlType); scalars go
# through untouched.
func RsStorable pValue
	if islist(pValue)
		return JsonEncode(pValue)
	ok
	return pValue
