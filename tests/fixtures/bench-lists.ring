# The A/B for the vendored #1642 accessor patch (ringvm/src/rlist.c).
#
# Run the SAME file against two builds differing in nothing else:
#   zig build                     -> patch ON
#   zig build -Dno-arraycache     -> patch OFF
#   ringserv run tests/fixtures/bench-lists.ring
#
# Three shapes, because the patch is a trade and each side has to be
# measured on its own terms:
#
#   MIXED   append and read the SAME list, interleaved. This is what
#           upstream rejected the patch over: every append frees the
#           array, every read rebuilds it.
#   RANDOM  build once, then read by a permuted index. This is what the
#           patch exists for -- the "sort a table, then walk the rows"
#           shape that was O(n^2) without it.
#   SERVER  RingServ's own response path: query rows out of SQLite and
#           encode them. The only one of the three that decides anything
#           here, because it is the workload this server actually runs.

see "--- MIXED: append and read the same list (the upstream objection)" + nl

for nN in [ 2000, 10000, 20000 ]
	aL = []
	t1 = clock()
	for i = 1 to nN
		add(aL, i)
		# Read a position the sequential cursor cannot serve, so the
		# accessor takes its random-access path on every iteration.
		nX = aL[ floor(len(aL) / 2) + 1 ]
	next
	t2 = clock()
	Bench("mixed add+read, n=" + nN, t1, t2)
next

see nl + "--- RANDOM: build once, then read by a permuted index (the win)" + nl

for nN in [ 2000, 10000, 20000 ]
	aL = []
	for i = 1 to nN  add(aL, i)  next
	# A permuted read order: no two consecutive reads are adjacent, so
	# the cursor cache never helps.
	aIdx = []
	for i = 1 to nN  add(aIdx, ((i * 7919) % nN) + 1)  next
	t1 = clock()
	nSum = 0
	for i = 1 to nN  nSum += aL[ aIdx[i] ]  next
	t2 = clock()
	Bench("permuted read, n=" + nN, t1, t2)
next

see nl + "--- SERVER: RingServ's own response path" + nl

Data([ :bench = [ :title = :string, :body = :string, :weight = :number ] ])

for nN in [ 500, 2000 ]
	DataExec("delete from bench", [])
	for i = 1 to nN
		DataExec("insert into bench (title,body,weight) values (?,?,?)",
		         [ "r" + i, "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", i ])
	next

	t1 = clock()
	for k = 1 to 10
		aRows = DataQuery("select * from bench", [])
	next
	t2 = clock()
	Bench("query+build rows x10, n=" + nN, t1, t2)

	t1 = clock()
	for k = 1 to 10
		cJson = JsonEncode(aRows)
	next
	t2 = clock()
	Bench("JsonEncode rows x10, n=" + nN, t1, t2)

	# What a generic list action does: walk the rows and pick a field
	# out of each -- a read of a nested list, per row.
	t1 = clock()
	for k = 1 to 10
		nTot = 0
		for aRow in aRows
			nTot += aRow[:weight]
		next
	next
	t2 = clock()
	Bench("walk rows and read a field x10, n=" + nN, t1, t2)
next

see nl + "done" + nl

# Defined last on purpose: in Ring, statements after a func definition
# belong to that function, so a helper declared first swallows the file.
func Bench cName, nStart, nEnd
	see "  " + cName + ": " + (nEnd - nStart) + "ms" + nl
