# ===========================================================================
#  RingServ — the RingPM package manifest
# ===========================================================================
#      ringpm install ringserv from mayouni
#      ringpm run ringserv
#
#  WHY THIS PACKAGE SHIPS NO BINARY, unlike its sister RingScript.
#
#  RingScript's package carries its servers because they are ~40 KB each.
#  RingServ's binaries are ~7 MB each, five platforms — about 35 MB that
#  would sit in git history forever, for every clone, for every future
#  version. This repository decided against that in phase 4 and says so
#  in build.zig and the readme; a package manifest is not the place to
#  quietly reverse it.
#
#  So the package is small, and `:setup` fetches the ONE binary for the
#  machine doing the installing, from the tagged GitHub release, with the
#  checksums published beside it. That is also exactly the install story
#  the front page tells everyone else: download one file and run it.
#
#  A machine with no network at install time still gets a working
#  package — `ringpm run ringserv` then prints where to put the binary
#  and the URL to fetch, rather than failing mysteriously.
# ===========================================================================

aPackageInfo = [
	:name = "RingServ",
	:description = "A modern server for Ring apps and web services: one static binary with a web server, SQLite, a JavaScript engine and the Ring VM inside. Zero dependencies.",
	:folder = "ringserv",
	:developer = "Mansour Ayouni",
	:email = "kalidianow@gmail.com",
	:license = "MIT License",
	:version = "0.9.0",
	:ringversion = "1.27",
	:versions = 	[
		[
			:version = "0.9.0",
			:branch = "main"
		]
	],
	:libs = 	[
		[
			:name = "",
			:version = "",
			:providerusername = ""
		]
	],
	:files = 	[
		# Entry points
		"main.ring",
		"lib.ring",
		"package.ring",
		"readme.md",
		"LICENSE",

		# The example applications: both run under the installed binary,
		# and both are how the guides teach.
		"examples/fieldnotes/app.ring",
		"examples/fieldnotes/contracts.ring",
		"examples/fieldnotes/topology.ring",
		"examples/fieldnotes/public/index.html",
		"examples/fieldnotes/services/digest.js",
		"examples/fieldnotes/tests/notes-test.ring",
		"examples/fieldnotes/README.md",

		"examples/comptoir/app.ring",
		"examples/comptoir/ringserv.yaml",
		"examples/comptoir/public/index.html",
		"examples/comptoir/services/receipt.js",
		"examples/comptoir/services/money.js",
		"examples/comptoir/tools/tip.ring",
		"examples/comptoir/README.md",

		# Documentation — the reading order the tutorial sets
		"docs/README.md",
		"docs/TUTORIAL.md",
		"docs/getting-started.md",
		"docs/gesture.md",
		"docs/fieldnotes-app.md",
		"docs/services.md",
		"docs/DATA.md",
		"docs/WRITES.md",
		"docs/COMMONS.md",
		"docs/JS.md",
		"docs/topology.md",
		"docs/FAMILY.md",
		"docs/CHECK.md",
		"docs/cli.md",
		"docs/panel.md",
		"docs/TLS.md",
		"docs/BENCHMARKS.md",
		"docs/architecture.md",
		"docs/WORKERS.md",
		"docs/landscape.md",
		"docs/VISION.md",
		"docs/roadmap.md",
		"docs/PLAN.md",
		"docs/GATES.md"
	],
	:ringfolderfiles = 	[

	],
	# No binaries in the package — see the header. `:setup` fetches the one
	# this machine needs.
	:windowsfiles = 	[

	],
	:linuxfiles = 	[

	],
	:ubuntufiles = 	[

	],
	:fedorafiles = 	[

	],
	:macosfiles = 	[

	],
	:windowsringfolderfiles = 	[

	],
	:linuxringfolderfiles = 	[

	],
	:ubunturingfolderfiles = 	[

	],
	:fedoraringfolderfiles = 	[

	],
	:macosringfolderfiles = 	[

	],
	:run = "ring main.ring",
	:windowsrun = "",
	:linuxrun = "",
	:macosrun = "",
	:ubunturun = "",
	:fedorarun = "",

	# Fetch the one binary this machine needs, from the tagged release.
	# Failure is not fatal: `ringpm run ringserv` reports what is missing
	# and prints the URL, because a package that half-installed and said
	# nothing is worse than one that says what to do next.
	:setup = "",
	:windowssetup = "powershell -NoProfile -Command ""New-Item -ItemType Directory -Force bin | Out-Null; try { Invoke-WebRequest -Uri 'https://github.com/mayouni/ringserv/releases/latest/download/ringserv-windows-x64.exe' -OutFile 'bin/ringserv.exe' } catch { Write-Host 'RingServ: could not download the binary; run ringpm run ringserv for instructions' }""",
	:linuxsetup = "mkdir -p bin && (curl -fsSL https://github.com/mayouni/ringserv/releases/latest/download/ringserv-linux-x64 -o bin/ringserv && chmod +x bin/ringserv) || echo 'RingServ: could not download the binary; run ringpm run ringserv for instructions'",
	:ubuntusetup = "mkdir -p bin && (curl -fsSL https://github.com/mayouni/ringserv/releases/latest/download/ringserv-linux-x64 -o bin/ringserv && chmod +x bin/ringserv) || echo 'RingServ: could not download the binary; run ringpm run ringserv for instructions'",
	:fedorasetup = "mkdir -p bin && (curl -fsSL https://github.com/mayouni/ringserv/releases/latest/download/ringserv-linux-x64 -o bin/ringserv && chmod +x bin/ringserv) || echo 'RingServ: could not download the binary; run ringpm run ringserv for instructions'",
	:macossetup = "mkdir -p bin && (curl -fsSL https://github.com/mayouni/ringserv/releases/latest/download/ringserv-macos-arm64 -o bin/ringserv && chmod +x bin/ringserv) || echo 'RingServ: could not download the binary; run ringpm run ringserv for instructions'",

	:remove = "",
	:windowsremove = "",
	:linuxremove = "",
	:macosremove = "",
	:ubunturemove = "",
	:fedoraremove = ""
]
