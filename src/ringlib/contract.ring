# Contracts — typed, declarative, governed.
#
#   Contract(:orders, [
#       :place = [
#           :in = [
#               :customer = [ :type = :string, :required = true ],
#               :items    = [ :type = :list,   :of = :number, :min = 1 ],
#               :notes    = [ :type = :string, :maxlen = 500 ]
#           ],
#           :out  = [ :id = :number ]
#       ]
#   ])
#
# The runtime enforces :in at the door: a violation is a 422 envelope
# listing every failure, and the action never runs. (:out is declared
# for the docs and the static checker; it is not enforced at runtime —
# a server should not refuse to answer because its own reply drifted.)

aRsContracts = []

func Contract cService, aActions
	if not isstring(cService) or not islist(aActions)
		raise("Contract(): expects a service name and a list of actions")
	ok
	add(aRsContracts, [ lower(cService), aActions ])
	return len(aRsContracts)

# The :in spec for one service.action, or "" when none is declared.
func RsContractIn cService, cAction
	for aEntry in aRsContracts
		if aEntry[1] != lower(cService)
			loop
		ok
		aSpec = RsDeclGet(aEntry[2], cAction, "")
		if islist(aSpec)
			aIn = RsDeclGet(aSpec, "in", "")
			if islist(aIn)
				return aIn
			ok
		ok
	next
	return ""

# "" when the payload satisfies the contract, else a human list of
# every failure — all of them, not just the first: a client fixing one
# field at a time is a bad afternoon.
func RsContractCheck cService, cAction, pPayload
	aIn = RsContractIn(cService, cAction)
	if not islist(aIn)
		return ""
	ok
	aFails = []
	for aField in aIn
		if not (islist(aField) and len(aField) = 2 and isstring(aField[1]))
			loop
		ok
		cName = aField[1]
		aRule = aField[2]
		pVal  = RsDeclGet(pPayload, cName, "__rs_absent")

		if isstring(pVal) and pVal = "__rs_absent"
			if RsDeclGet(aRule, "required", 0) = 1
				add(aFails, cName + " is required")
			ok
			loop
		ok

		cType = RsDeclGet(aRule, "type", "")
		if isstring(cType) and cType != ""
			cBad = RsTypeFail(cName, cType, pVal)
			if cBad != ""
				add(aFails, cBad)
				loop                # a wrong type makes the limits moot
			ok
		ok

		# Limits. :min/:max bound a number, or the length of a list.
		nMin = RsDeclGet(aRule, "min", "")
		nMax = RsDeclGet(aRule, "max", "")
		if isnumber(nMin) or isnumber(nMax)
			nMeasure = 0
			if isnumber(pVal)
				nMeasure = pVal
			but islist(pVal)
				nMeasure = len(pVal)
			ok
			if isnumber(nMin) and nMeasure < nMin
				add(aFails, cName + " must be at least " + nMin)
			ok
			if isnumber(nMax) and nMeasure > nMax
				add(aFails, cName + " must be at most " + nMax)
			ok
		ok

		nMaxLen = RsDeclGet(aRule, "maxlen", "")
		if isnumber(nMaxLen) and isstring(pVal) and len(pVal) > nMaxLen
			add(aFails, cName + " must be at most " + nMaxLen + " characters")
		ok
		nMinLen = RsDeclGet(aRule, "minlen", "")
		if isnumber(nMinLen) and isstring(pVal) and len(pVal) < nMinLen
			add(aFails, cName + " must be at least " + nMinLen + " characters")
		ok

		# :of types every element of a list.
		cOf = RsDeclGet(aRule, "of", "")
		if isstring(cOf) and cOf != "" and islist(pVal)
			for pItem in pVal
				cBad = RsTypeFail(cName + " item", cOf, pItem)
				if cBad != ""
					add(aFails, cBad)
					exit
				ok
			next
		ok
	next

	if len(aFails) = 0
		return ""
	ok
	return RsJoin(aFails, "; ")

func RsTypeFail cName, cType, pVal
	switch lower(cType)
	on "string"
		if not isstring(pVal) return cName + " must be a string" ok
	on "number"
		if not isnumber(pVal) return cName + " must be a number" ok
	on "int"
		if not isnumber(pVal) or floor(pVal) != pVal
			return cName + " must be a whole number"
		ok
	on "list"
		if not islist(pVal) return cName + " must be a list" ok
	on "bool"
		if not (isnumber(pVal) and (pVal = 0 or pVal = 1))
			return cName + " must be true or false"
		ok
	off
	return ""
