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
