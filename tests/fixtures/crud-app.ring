# Phase-3 part-2 fixture: generic table services and contracts.

cDb = sysget("RINGSERV_TEST_DB")
if cDb = "" cDb = ":memory:" ok

RingServ([
	:port     = 8095,
	:workers  = 3,
	:database = cDb,

	:data = [
		:notes = [ :title = :string, :body = :string, :weight = :number ],
		:tags  = [ :label = :string ]
	],

	:services = [
		# All five generic actions, nothing written.
		:notes = [ :table = "notes" ],

		# A service that only exists to be governed by contracts.
		:rules = [
			:check = func aReq { return Reply(:ok, [ :seen = 1 ]) }
		],

		# Restricted set + an override: create is ours, list/get generic,
		# update/delete not offered at all.
		:tags = [
			:table   = "tags",
			:actions = [ :list, :get, :create ],
			:create  = func aReq {
				cLabel = aReq[:payload][:label]
				DataExec("insert into tags (label) values (?)", [ upper(cLabel) ])
				return Reply(:ok, [ :id = DataInsertId(), :shouted = 1 ])
			}
		]
	]
])

# Contracts govern the generic actions too — they are enforced before
# dispatch, so they apply whoever answers.
Contract(:notes, [
	:create = [
		:in = [
			:title  = [ :type = :string, :required = true, :maxlen = 20 ],
			:weight = [ :type = :number, :min = 0, :max = 100 ],
			:body   = [ :type = :string ]
		],
		:out = [ :id = :number ]
	],
	:get = [
		:in = [ :id = [ :type = :number, :required = true ] ]
	]
])

# Every remaining rule the validator implements, so none ships untested:
# :of (element type), :int, :bool, :minlen.
Contract(:rules, [
	:check = [
		:in = [
			:scores = [ :type = :list, :of = :number ],
			:count  = [ :type = :int ],
			:flag   = [ :type = :bool ],
			:code   = [ :type = :string, :minlen = 3 ],
			:tags   = [ :type = :list, :min = 1, :max = 3 ]
		]
	]
])
