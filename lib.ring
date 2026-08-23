# ===========================================================================
#  RingServ — library file (RingPM)
# ===========================================================================
#  Helpers a Ring developer can use after `ringpm install ringserv`.
#  From inside the package folder:
#
#      load "lib.ring"
#      ? RingServBinary()             where the binary is, or "" if absent
#      ? RingServDownloadUrl()        the release file for THIS machine
#      RingServRun("run app.ring")    run the binary with any arguments
#      RingServExample("comptoir")    the path of a bundled example
#
#  Everything here answers rather than assumes: a machine that installed
#  without a network has no binary yet, and each function says so plainly
#  instead of failing somewhere later.
# ===========================================================================

# The folder holding this file, with its trailing separator. Computed the
# same way RingScript's package does, and for the same reason: RingPM may
# run the script from anywhere.
func RingServHome
	cFile = filename()
	for i = len(cFile) to 1 step -1
		c = substr(cFile, i, 1)
		if c = "/" or c = char(92)
			return left(cFile, i)
		ok
	next
	return "." + "/"

# Which release file this machine needs. Names match the release assets.
func RingServAssetName
	if isWindows()
		return "ringserv-windows-x64.exe"
	ok
	if isMacOSX()
		# Apple Silicon is the common case; an Intel Mac wants
		# ringserv-macos-x64 from the same release.
		return "ringserv-macos-arm64"
	ok
	return "ringserv-linux-x64"

func RingServDownloadUrl
	return "https://github.com/mayouni/ringserv/releases/latest/download/" +
	       RingServAssetName()

# The installed binary's path, or "" when the download did not happen.
func RingServBinary
	cName = "ringserv"
	if isWindows()
		cName = "ringserv.exe"
	ok
	cPath = RingServHome() + "bin/" + cName
	if fexists(cPath)
		return cPath
	ok
	return ""

# Run the binary with arguments; answers 0 when it could not be found, so
# a caller can report rather than crash.
func RingServRun cArgs
	cBin = RingServBinary()
	if cBin = ""
		return 0
	ok
	cCmd = '"' + RingServNative(cBin) + '" ' + cArgs
	if isWindows()
		# cmd.exe strips the FIRST and LAST quote of the line it is
		# given, so a command with two quoted tokens — the program and a
		# path — loses one quote from each and becomes nonsense
		# («'.iningserv.exe" run ".' n'est pas reconnu»). Wrapping
		# the whole line in one more pair is the documented cure, and it
		# is why this is not simply system(cCmd).
		cCmd = '"' + cCmd + '"'
	ok
	system(cCmd)
	return 1

# A path in the shell's OWN separator. Found by running this package on
# native Ring under Windows: `"./bin/ringserv.exe" version` made cmd
# answer «'.' n'est pas reconnu...», because cmd will not execute a
# program named with forward slashes. Ring is happy either way; the
# shell is not, and the shell is who runs this.
func RingServNative cPath
	if not isWindows()
		return cPath
	ok
	cOut = ""
	for i = 1 to len(cPath)
		c = substr(cPath, i, 1)
		if c = "/"
			cOut += char(92)
		else
			cOut += c
		ok
	next
	return cOut

# The path of a bundled example application, or "".
func RingServExample cName
	cPath = RingServHome() + "examples/" + cName + "/app.ring"
	if fexists(cPath)
		return cPath
	ok
	return ""

func RingServExamples
	return [ "fieldnotes", "comptoir" ]
