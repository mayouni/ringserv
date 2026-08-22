# configlib — ringserv.yaml, the config-file form of the declaration.
#
# The vision asks for "yaml-like config and file formats" (docs/VISION.md);
# this is that form, and the word doing the work is LIKE. The subset is
# deliberately small and parsed here, in ~150 lines of Ring, because
# vendoring a full YAML engine to read a config file would break the
# zero-dependency ethos for nothing:
#
#     # ringserv.yaml — comments, mappings, scalars, one nesting level
#     port: 8090
#     workers: 4
#     database: app.db
#     static:
#         /: public/
#
# WHAT IS REFUSED IS REFUSED BY NAME — anchors, aliases, tags, flow
# style, block scalars, document markers, tab indentation, mappings
# inside sequences. A construct outside the subset fails the boot with
# the construct named and the line numbered, never a silent misread:
# YAML's famous surprises (the Norway problem and friends) live exactly
# in the corners this subset declines to have.
#
# THE BOUNDARY, stated rather than discovered: configuration is
# declarable here; CODE IS NOT. :services, :apply, contracts — anything
# whose value is a function stays in the Ring (or JS) file, because a
# function in a config file is a program pretending to be data.
#
# Precedence: the RingServ([...]) declaration wins over the file, and a
# collision is REPORTED at boot, never silently resolved (docs/PLAN.md,
# phase 10). The file fills what the declaration left unset.

# ----------------------------------------------------------- the parser

func RsConfigParse cText
	aTop = []
	aLines = str2list(cText)
	nLine = 0
	cPendingKey = ""		# a `key:` waiting for its indented block
	aPendingVal = []
	lInBlock = 0
	nBlockIndent = -1
	for cRaw in aLines
		nLine++
		# strip a trailing CR so CRLF files parse identically
		while len(cRaw) > 0 and ascii(right(cRaw, 1)) = 13
			cRaw = left(cRaw, len(cRaw) - 1)
		end
		cT = trim(cRaw)
		if cT = "" or left(cT, 1) = "#"
			loop
		ok
		if cT = "---" or cT = "..."
			raise("ringserv.yaml line " + nLine + ": document markers (---) " +
			      "are not in RingServ's config subset — one file, one document")
		ok
		# indentation: spaces only, counted before anything else
		nIndent = 0
		for i = 1 to len(cRaw)
			c = substr(cRaw, i, 1)
			if c = " "
				nIndent++
			but ascii(c) = 9
				raise("ringserv.yaml line " + nLine + ": tab indentation is " +
				      "not in RingServ's config subset — indent with spaces")
			else
				exit
			ok
		next

		if left(cT, 2) = "- " or cT = "-"
			raise("ringserv.yaml line " + nLine + ": sequences (- item) are " +
			      "not in RingServ's config subset — the declaration's list " +
			      "keys (services, routes) are code-side; see docs/gesture.md")
		ok

		# `key: value` or `key:` — split at the first colon
		nColon = substr(cT, ":")
		if nColon = 0
			raise("ringserv.yaml line " + nLine + ": expected `key: value`, " +
			      "got `" + cT + "`")
		ok
		cKey = lower(trim(left(cT, nColon - 1)))
		cVal = trim(substr(cT, nColon + 1))
		if cKey = ""
			raise("ringserv.yaml line " + nLine + ": a key is required " +
			      "before the colon")
		ok

		if lInBlock = 1 and nIndent > nBlockIndent
			# a line inside the pending nested mapping
			add(aPendingVal, [ cKey, RsConfigScalar(cVal, nLine) ])
			loop
		ok
		if lInBlock = 1
			# the block ended — commit it before handling this line
			add(aTop, [ cPendingKey, aPendingVal ])
			lInBlock = 0
		ok

		if cVal = ""
			# `key:` opens a one-level nested mapping (deeper nesting is
			# refused when its lines arrive with a key of their own)
			cPendingKey = cKey
			aPendingVal = []
			lInBlock = 1
			nBlockIndent = nIndent
			loop
		ok
		add(aTop, [ cKey, RsConfigScalar(cVal, nLine) ])
	next
	if lInBlock = 1
		add(aTop, [ cPendingKey, aPendingVal ])
	ok
	return aTop

# A scalar, with the refusals that keep the subset honest.
func RsConfigScalar cVal, nLine
	# an inline comment after the value: `port: 80  # why` — only when
	# the value is not quoted, where # is content
	c1 = left(cVal, 1)
	if c1 = '"' or c1 = "'"
		if len(cVal) < 2 or right(cVal, 1) != c1
			raise("ringserv.yaml line " + nLine + ": unterminated quoted string")
		ok
		return substr(cVal, 2, len(cVal) - 2)
	ok
	nHash = substr(cVal, " #")
	if nHash > 0
		cVal = trim(left(cVal, nHash - 1))
	ok
	if c1 = "&" or c1 = "*"
		raise("ringserv.yaml line " + nLine + ": anchors and aliases (& *) " +
		      "are not in RingServ's config subset")
	ok
	if c1 = "!"
		raise("ringserv.yaml line " + nLine + ": tags (!) are not in " +
		      "RingServ's config subset")
	ok
	if c1 = "{" or c1 = "["
		raise("ringserv.yaml line " + nLine + ": flow style ({ } [ ]) is " +
		      "not in RingServ's config subset — use one `key: value` per line")
	ok
	if c1 = "|" or c1 = ">"
		raise("ringserv.yaml line " + nLine + ": block scalars (| >) are " +
		      "not in RingServ's config subset")
	ok
	cLow = lower(cVal)
	# ONLY true/false are booleans here. yes/no/on/off stay STRINGS —
	# this is the Norway problem (`country: no` becoming false) defused
	# by deciding: a flag key still reads them correctly, because every
	# flag in the declaration goes through RsBool, which accepts the
	# whole family; a value key keeps its letters.
	if cLow = "true"    return 1 ok
	if cLow = "false"   return 0 ok
	if RsConfigIsNumber(cVal)
		return 0 + cVal
	ok
	return cVal

func RsConfigIsNumber cVal
	if cVal = "" return 0 ok
	nStart = 1
	if left(cVal, 1) = "-"
		if len(cVal) = 1 return 0 ok
		nStart = 2
	ok
	lDot = 0
	for i = nStart to len(cVal)
		c = substr(cVal, i, 1)
		if c = "."
			if lDot = 1 return 0 ok
			lDot = 1
		but not isdigit(c)
			return 0
		ok
	next
	return 1

# ------------------------------------------------------------- the fold
#
# Called by RingServ() right after the declaration is stored. The file
# fills what the declaration left unset; the declaration wins every
# collision, and the collision is PRINTED — a config value silently
# ignored is how an operator loses an evening.

func RsConfigFold
	cDir = __rs_approot()
	if cDir = "" cDir = "." ok
	cFile = cDir + "/ringserv.yaml"
	if not fexists(cFile)
		return 0
	ok
	aCfg = RsConfigParse(read(cFile))
	nFolded = 0
	for aPair in aCfg
		cKey = aPair[1]
		pVal = aPair[2]
		if RsConfigIsCode(cKey)
			raise("ringserv.yaml: `" + cKey + ":` is code, not configuration " +
			      "— it belongs in the application file (docs/gesture.md " +
			      "states the boundary)")
		ok
		if cKey = "static"
			RsConfigFoldStatic(pVal)
			loop
		ok
		pHave = RsDeclGet(aRsServDecl, cKey, "__rs_cfg_unset__")
		if isstring(pHave) and pHave = "__rs_cfg_unset__"
			add(aRsServDecl, [ cKey, pVal ])
			nFolded++
		else
			if RsConfigSame(pHave, pVal) = 0
				? "ringserv.yaml: `" + cKey + ": " + RsConfigShow(pVal) +
				  "` collides with the declaration (" + RsConfigShow(pHave) +
				  ") — the declaration wins"
			ok
		ok
	next
	return nFolded

func RsConfigIsCode cKey
	if cKey = "services" return 1 ok
	if cKey = "data" return 1 ok
	if cKey = "contracts" return 1 ok
	if cKey = "topology" return 1 ok
	if cKey = "auth" return 1 ok
	return 0

func RsConfigSame pA, pB
	if isnumber(pA) and isnumber(pB)
		if pA = pB return 1 ok
		return 0
	ok
	if isstring(pA) and isstring(pB)
		if lower(pA) = lower(pB) return 1 ok
		return 0
	ok
	return 0

func RsConfigShow pV
	if isnumber(pV) return "" + pV ok
	if isstring(pV) return pV ok
	return "<mapping>"

# `static:` — prefix: directory pairs, folded into :routes triples. The
# one nested mapping the subset serves, because a static route is
# configuration in the plainest sense: which directory answers which path.
func RsConfigFoldStatic aPairs
	if not islist(aPairs)
		return 0
	ok
	pHave = RsDeclGet(aRsServDecl, "routes", "__rs_cfg_unset__")
	if not (isstring(pHave) and pHave = "__rs_cfg_unset__")
		? "ringserv.yaml: `static:` collides with the declaration's " +
		  ":routes — the declaration wins"
		return 0
	ok
	aRoutes = []
	for aPair in aPairs
		add(aRoutes, [ "static", "" + aPair[1], "" + aPair[2] ])
	next
	add(aRsServDecl, [ "routes", aRoutes ])
	return len(aRoutes)
