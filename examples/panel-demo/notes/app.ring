# notes -- a small declarative application, hosted beside the gesture.
RingServ([
	:port = 8096,
	:workers = 2,
	:services = [
		:notes = [
			:table = "notes"
		]
	],
	:data = [
		:notes = [ :title = :string, :body = :string ]
	]
])
