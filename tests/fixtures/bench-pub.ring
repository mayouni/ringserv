# The fixture behind docs/BENCHMARKS.md.
#
# Deliberately ORDINARY: a generic table service, one hand-written
# service, one JS service. Nothing here is tuned for the benchmark,
# because a benchmark against a fixture nobody would write measures a
# server nobody is running.

RingServ([
	:port     = 8096,
	:workers  = 4,
	:database = sysget("RINGSERV_TEST_DB"),

	:data = [
		:notes = [ :title = :text, :body = :text, :weight = :number ]
	],

	:services = [
		:notes = [ :table = "notes" ],

		:bench = [
			# The floor: dispatch with no work behind it, so every other
			# number can be read as "this much MORE than nothing".
			:noop = func aReq { return Reply(:ok, [ :ok = 1 ]) }
		],

		:jsbench = [ :js = "jssvc/bench.js" ]
	]
])
