# The site, served by the thing it documents.
#
#   ringserv run site/serve.ring
#
# Not a build step, not a static-site generator: RingServ already serves
# static files, so the project's own page is one declaration. If this
# ever stops working, the front page says something the binary cannot do.

RingServ([
	:port   = 8060,   # NOT 8090: tests/jsserv-gates.js uses that one,
	                 # and a preview server squatting on a gate's port
	                 # makes the gate fail somewhere else entirely
	:routes = [ [ :static, "/", "." ] ]
])
