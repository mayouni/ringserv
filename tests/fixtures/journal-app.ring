# Phase-9 fixture: the journaled store.
#
# Modelled on the germ this design comes from (RestoLean's Commons): orders
# advance through a monotonic state machine, and the per-day order NUMBER is
# derived from replay rather than stored — which is the property that makes
# a restart mid-service lose nothing.

# State the application owns. Rebuilt by replay at every boot; nothing here
# is ever written to a table.
aOrders  = []
nCounter = 0

RingServ([
	:port     = 8086,
	:workers  = 2,
	:database = sysget("RINGSERV_TEST_DB"),

	:services = [
		:orders = [
			# Every mutation goes through the journal. There is no second
			# write path, which is the whole of Law 1.
			:place = func aReq {
				aP = aReq[:payload]
				aRec = JournalAppend("ventes", [
					:type  = "passer_commande",
					:who   = "" + RsDeclGet(aP, "who", ""),
					:total = RsDeclGet(aP, "total", 0) ])
				return Reply(:ok, [ :seq = aRec[:seq], :hash = aRec[:hash],
						    :numero = nCounter ])
			},

			:advance = func aReq {
				aP = aReq[:payload]
				aRec = JournalAppend("ventes", [
					:type = "faire_avancer",
					:id   = RsDeclGet(aP, "id", 0),
					:etat = "" + RsDeclGet(aP, "etat", "") ])
				return Reply(:ok, [ :seq = aRec[:seq] ])
			},

			# State, read from memory — which exists only because replay
			# put it there.
			:state = func aReq {
				return Reply(:ok, [ :count = len(aOrders), :numero = nCounter ])
			}
		],

		# Read-only by construction: verify and read, never append.
		:journal = RsJournalService("ventes"),

		# A probe, so a gate can prove the refusal rather than trust the
		# source: compaction discards history and a journal exists to keep
		# it, so pointing one at the other must fail LOUDLY and by name.
		:probe = [
			:compact = func aReq {
				try
					SyncCompact("ventes", 1)
				catch
					return Reply(:ok, [ :refused = 1, :why = cCatchError ])
				done
				return Reply(:ok, [ :refused = 0, :why = "" ])
			},
			# Appending an event with no :type must be refused too — an
			# untyped record is one replay cannot dispatch.
			:untyped = func aReq {
				try
					JournalAppend("ventes", [ :who = "nobody" ])
				catch
					return Reply(:ok, [ :refused = 1, :why = cCatchError ])
				done
				return Reply(:ok, [ :refused = 0, :why = "" ])
			},
			:export = func aReq {
				return Reply(:ok, [ :text = JournalExport("ventes") ])
			}
		]
	]
])

Journal([
	:name  = "ventes",
	:apply = func aEvent {
		cType = "" + RsDeclGet(aEvent, "type", "")
		if cType = "passer_commande"
			nCounter++
			add(aOrders, [ :numero = nCounter,
				       :who = "" + RsDeclGet(aEvent, "who", ""),
				       :etat = "recue" ])
		but cType = "faire_avancer"
			nId = RsDeclGet(aEvent, "id", 0)
			if isnumber(nId) and nId >= 1 and nId <= len(aOrders)
				aOrders[nId][:etat] = "" + RsDeclGet(aEvent, "etat", "")
			ok
		ok
		return 1
	}
])
