# datalib — the schema layer, in the language it serves.
#
# A RingServ() declaration may carry :data. Each entry names a table and
# its columns with Ring-side types; the runtime materializes them into
# SQLite at boot, idempotently, so a restart against an existing file is
# a no-op and an added column is added.
#
# This layer deliberately does NOT define the developer's query surface —
# that name is settled separately (see issue #1). What lives here is the
# schema, and the two primitives every layer above will stand on:
# __db_exec and __db_query, both raising trappable Ring errors.

aRsDataDecl = []

# --------------------------------------------------------------- the seam

func Data aDecl
	aRsDataDecl = aDecl
	return RsSchemaApply(aDecl)

# Column type names, Ring side -> SQLite storage class. Ring has strings
# and numbers; :list and :object are stored as JSON text, decoded on the
# way out by the layer above.
func RsSqlType cType
	switch lower(cType)
	on "number"  return "REAL"
	on "int"     return "INTEGER"
	on "string"  return "TEXT"
	on "text"    return "TEXT"
	on "list"    return "TEXT"
	on "object"  return "TEXT"
	on "bool"    return "INTEGER"
	other        return "TEXT"
	off

# CREATE TABLE IF NOT EXISTS per declared table, then ALTER TABLE ADD
# COLUMN for any column the declaration gained since the file was made.
# Both steps are safe to repeat: that is what makes boot idempotent.
func RsSchemaApply aDecl
	if not islist(aDecl)
		return 0
	ok
	nTables = 0
	for aEntry in aDecl
		if not (islist(aEntry) and len(aEntry) = 2 and isstring(aEntry[1]))
			loop
		ok
		cTable = aEntry[1]
		aCols  = aEntry[2]
		if not RsValidName(cTable) or not islist(aCols)
			raise("Data(): invalid table name or columns: " + cTable)
		ok

		# Build the column definitions first, then assemble — every table
		# gets an "id" primary key, whether or not the declaration names
		# one, so every row is addressable by the layers above.
		aDefs = [ '"id" INTEGER PRIMARY KEY AUTOINCREMENT' ]
		for aCol in aCols
			if not (islist(aCol) and len(aCol) = 2 and isstring(aCol[1]))
				loop
			ok
			cName = aCol[1]
			if not RsValidName(cName)
				raise("Data(): invalid column name in " + cTable + ": " + cName)
			ok
			if lower(cName) = "id"
				loop        # already provided, and its type is not negotiable
			ok
			add(aDefs, '"' + cName + '" ' + RsSqlType(aCol[2]))
		next
		__db_exec('CREATE TABLE IF NOT EXISTS "' + cTable + '" (' +
		          RsJoin(aDefs, ", ") + ")")

		# Additive migration: columns present in the declaration but not
		# in the table are appended. Removals are NOT applied — dropping
		# data is never automatic.
		aHave = __db_columns(cTable)
		for aCol in aCols
			if not (islist(aCol) and len(aCol) = 2 and isstring(aCol[1]))
				loop
			ok
			cName = aCol[1]
			if lower(cName) = "id"
				loop
			ok
			lFound = 0
			for cHave in aHave
				if lower(cHave) = lower(cName)
					lFound = 1
					exit
				ok
			next
			if lFound = 0
				__db_exec('ALTER TABLE "' + cTable + '" ADD COLUMN "' +
				          cName + '" ' + RsSqlType(aCol[2]))
			ok
		next
		nTables++
	next
	return nTables

func RsJoin aList, cSep
	cOut = ""
	for i = 1 to len(aList)
		if i > 1
			cOut += cSep
		ok
		cOut += aList[i]
	next
	return cOut

# --------------------------------------------------- the query surface
#
# RingServ speaks SQL over SQLite — the engine's own language, which
# every Ring developer can already read, and which commits this server
# to no framework's dialect. Higher-level query languages (Softanza's
# ZQL among them) are LAYERS: pure-Ring libraries an application loads,
# compiling down to these two calls. Nothing in this core knows them.
#
# Parameters are always bound, never interpolated: aParams is a list,
# because Ring has no variadic user functions.

func DataQuery cSql, aParams
	if not islist(aParams) aParams = [ aParams ] ok
	return __db_rows(cSql, aParams)

func DataExec cSql, aParams
	if not islist(aParams) aParams = [ aParams ] ok
	return __db_exec(cSql, aParams)

# The single scalar of a single-row, single-column query — count(*),
# max(id), and friends. Returns pDefault when there is no row.
func DataValue cSql, aParams, pDefault
	if not islist(aParams) aParams = [ aParams ] ok
	aRows = __db_query(cSql, aParams)
	if len(aRows) = 0 or len(aRows[1]) = 0
		return pDefault
	ok
	return aRows[1][1]

func DataInsertId
	return __db_insertid()

# ------------------------------------------------- introspection helpers

func DataTables
	aOut = []
	for aRow in __db_query("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
		add(aOut, aRow[1])
	next
	return aOut

func DataColumns cTable
	if not RsValidName(cTable)
		raise("DataColumns(): invalid table name: " + cTable)
	ok
	return __db_columns(cTable)

func DataPath
	return __db_path()
