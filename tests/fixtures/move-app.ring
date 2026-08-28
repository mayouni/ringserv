# The one-word-move fixture.
#
# ONE WORD differs between the two configurations this fixture can be in,
# and it is a word in the *topology*, never in the application:
#
#   RINGSERV_TEST_SITE=server   →  :notes = [ :site = :server ]
#   RINGSERV_TEST_SITE=local    →  :notes = [ :site = :local, :authority = :server ]
#
# Both are answered by this server — the second predicts in the page and
# decides here — so the same tests must pass against both, byte for byte.
# If they ever stop doing so, "moving a service is a one-word deployment
# decision, not a refactor" has become marketing.

cSite = sysget("RINGSERV_TEST_SITE")
if cSite = "" cSite = "server" ok

if cSite = "local"
	aNotesPlacement = [ :site = :local, :authority = :server ]
else
	aNotesPlacement = [ :site = :server ]
ok

RingServ([
	:port     = 8214,
	:workers  = 2,
	:database = sysget("RINGSERV_TEST_DB"),

	:data = [
		:notes = [ :title = :text, :body = :text, :weight = :number ]
	],

	:services = [
		:notes = [ :table = "notes" ],
		:sum   = [
			:total = func aReq {
				aRows = DataQuery("select count(*) as n from notes", [])
				return Reply(:ok, [ :n = aRows[1][:n] ])
			}
		]
	]
])

Topology([
	:app = "move-fixture",
	:data     = [ :notes = [ :store = :local, :sync = :onreconnect ] ],
	:services = [
		:notes = aNotesPlacement,
		:sum   = [ :site = :server ]
	]
])
