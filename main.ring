# ===========================================================================
#  RingServ — the command run by `ringpm run ringserv`
# ===========================================================================
#      ringpm run ringserv                    what is installed, and what next
#      ring main.ring version                 the binary's own version
#      ring main.ring serve <file.ring>       host a file of plain functions
#      ring main.ring run <app.ring>          run a declared application
#      ring main.ring example comptoir        run a bundled example
#      ring main.ring panel                   the admin panel, in a browser
#      ring main.ring where                   the binary and the examples
#
#  Self-locating, like RingScript's: it finds its own folder and loads
#  lib.ring from there at runtime, so it works whether RingPM ran it from
#  the package folder or you called it by absolute path from your own
#  project directory.
# ===========================================================================

func main
	cHome = RingServHomeEarly()
	# Runtime load (not the compile-time `load`), so the path can be
	# computed. Ring string literals have no escape sequences, so Windows
	# backslashes in the path need no special handling.
	eval('load "' + cHome + 'lib.ring"')
	RingServCLI()

func RingServHomeEarly
	cFile = filename()
	for i = len(cFile) to 1 step -1
		c = substr(cFile, i, 1)
		if c = "/" or c = char(92)
			return left(cFile, i)
		ok
	next
	return "." + "/"

func RingServCLI
	aArgs = sysargv
	# `ring main.ring <verb> ...` — drop the interpreter and the script.
	aRest = []
	nStart = 3
	if len(aArgs) >= nStart
		for i = nStart to len(aArgs)
			add(aRest, aArgs[i])
		next
	ok

	cVerb = ""
	if len(aRest) > 0
		cVerb = lower(aRest[1])
	ok

	if cVerb = "" or cVerb = "help"
		RingServGreeting()
		return
	ok

	if cVerb = "where"
		RingServWhere()
		return
	ok

	if cVerb = "example"
		cName = "comptoir"
		if len(aRest) > 1 cName = aRest[2] ok
		cPath = RingServExample(cName)
		if cPath = ""
			? "RingServ: no bundled example named `" + cName + "`."
			? "Bundled: " + RingServJoin(RingServExamples(), ", ")
			return
		ok
		if RingServNeedBinary() = 0 return ok
		? "Running the " + cName + " example. Ctrl-C to stop."
		RingServRun('run "' + RingServNative(cPath) + '"')
		return
	ok

	# Everything else is passed to the binary verbatim, so the package
	# never has to grow a second, drifting copy of the CLI.
	if RingServNeedBinary() = 0 return ok
	RingServRun(RingServJoin(aRest, " "))

func RingServGreeting
	? "RingServ — a modern server for Ring apps and web services"
	? ""
	cBin = RingServBinary()
	if cBin = ""
		RingServMissing()
		return
	ok
	? "  binary:   " + cBin
	RingServRun("version")
	? ""
	? "  Try one of these:"
	? "    ring main.ring example comptoir      a whole application, running"
	? "    ring main.ring panel .               start/stop your apps in a browser"
	? "    ring main.ring serve myfile.ring     host a file of plain functions"
	? ""
	? "  The tutorial is docs/TUTORIAL.md in this folder;"
	? "  everything else is at https://mayouni.github.io/ringserv/"

func RingServWhere
	? "  package:  " + RingServHome()
	cBin = RingServBinary()
	if cBin = ""
		? "  binary:   NOT INSTALLED"
	else
		? "  binary:   " + cBin
	ok
	? "  examples: " + RingServJoin(RingServExamples(), ", ")

# The binary is fetched at install time by :setup. When that could not
# happen — no network, a proxy, a machine behind a firewall — say exactly
# what is missing and how to finish, rather than failing later and
# somewhere else.
func RingServNeedBinary
	if RingServBinary() != ""
		return 1
	ok
	RingServMissing()
	return 0

func RingServMissing
	? "  The RingServ binary is not in this package yet."
	? ""
	? "  It is downloaded at install time rather than carried in the"
	? "  package: one file is about 7 MB, and five platforms of it would"
	? "  live in git history forever."
	? ""
	? "  Fetch it for this machine:"
	? "    " + RingServDownloadUrl()
	? ""
	? "  Save it as:"
	cName = "ringserv"
	if isWindows() cName = "ringserv.exe" ok
	? "    " + RingServHome() + "bin/" + cName
	if not isWindows()
		? "  ...then: chmod +x " + RingServHome() + "bin/" + cName
	ok

func RingServJoin aList, cSep
	cOut = ""
	for x in aList
		if cOut != "" cOut += cSep ok
		cOut += x
	next
	return cOut
