# bangalo-server — a RingServ PROFILE, not a coupling.
#
# The vision names two hosts for a Bangalo agent: a dedicated server on
# RingServ, for simplicity, and stzAppServer, for enterprise. stzAppServer's
# half already exists — HostAgents()/AdoptAgentHost() pump an stzAgentHost
# inside the server's OWN reactor (stzlib/libraries/stzlib/base/appserver/
# stzAppServer.ring:616). This file is RingServ's half of the same idea,
# built the way prompts/40 asked: as something an app MAY adopt, never as
# something RingServ's core depends on. `load` below is the ONLY line in
# this file that names stzlib; delete this file and RingServ does not
# notice stzlib exists.
#
# STATUS, STATED PLAINLY RATHER THAN IMPLIED: this profile is designed and
# code-complete against stzlib's real agentic API, but IT DOES NOT RUN YET.
# `load` two lines down fails today, for a reason that lives in RingServ's
# OWN loader, not in this file or in stzlib. README.md in this folder has
# the full finding, the exact repro, and why the fix is out of a profile's
# reach. Read it before assuming this file is broken Ring.

# ---------------------------------------------------------------- adopt it
#
# EDIT THIS PATH to your own stzlib checkout before anything else here can
# work. Ring's `load` is a compile-time directive -- it takes a literal
# string, never a variable -- so there is no environment variable to set
# instead; this line IS the configuration.
load "D:/GitHub/stzlib/libraries/stzlib/stzLib.ring"

# ------------------------------------------------------------- the pump
#
# ONE HOST PER WORKER PROCESS, not one host for the deployment. RingServ's
# own architecture (docs/WORKERS.md) gives every worker thread its OWN
# resident Ring VM, and evaluates this whole file again in EACH ONE at
# boot (src/serve.zig workerMain -> bridge.rs_eval(g_app_source), once per
# worker). An stzAgentHost built here is therefore built AGAIN per worker,
# with its OWN copy of every supervised agent and its OWN tick counts --
# :workers > 1 would not scale one Bangalo host, it would silently RUN N
# UNCOORDINATED ONES answering the same /api/v1. For "a dedicated server,
# for simplicity" that is never what is wanted, so this profile pins
# :workers = 1 and says why here rather than leaving a reader to
# rediscover it the way this file's author did.
oBangaloAgentHost = new stzAgentHost()

# THE FOLDER IS THE DEPLOYMENT (stzlib's own phrase for it). Drop a .pia
# or a Ring-defined agent in agents/ next to this file, and UseAgentsFrom
# mounts it on its own declared schedule -- nothing else in this file
# changes. Refusals are never swallowed: AgentLoadRefusals() below is
# exactly what a caller would get from stzAppServer's own folder, because
# it is the SAME folder class.
oBangaloAgentHost.UseAgentsFrom("agents")

# A Ring-defined agent (agents/*.ring) is DISCOVERED by the folder above
# but not EXECUTED by it (stzAgentFolder's own documented asymmetry: a
# .ring file is a program, and the folder does not eval source). An app
# that drops one in agents/ must `load` it here, once, the same way this
# file loads stzlib itself:
#
#   load "agents/some-agent.ring"

# --------------------------------------------------------- the RingServ app
#
# Everything RingServ itself needs to know: port, workers, and one
# service. No :data table -- this profile carries no business data of its
# own; an app built ON this profile adds its own services and tables
# beside :agents exactly as fieldnotes/app.ring adds :notes beside
# :report.
RingServ([
	:port    = 8200,
	:workers = 1,     # see "the pump" above -- one host, one worker, always

	:services = [
		:agents = [
			# GET-shaped, over RingServ's one generic wire door
			# (POST /api/v1 {service:"agents", action:"..."}).
			# stzAppServer owns its own HTTP listener and can add a
			# bespoke `GET /agents` route to it; RingServ's Zig core
			# does not let an app declare new routes (serve.zig's
			# router is fixed at five paths plus :static), and adding
			# one would mean editing serve.zig -- core, not profile.
			# So the read-only surface mirrors stzAppServer's SHAPE
			# (names, kinds, states, last tick, refusals) through the
			# door RingServ already gives every app, rather than
			# through a path RingServ does not have. See README.md
			# "the /agents surface" for the boundary this follows.
			:list = func aReq {
				oBangaloAgentHost.TickDue()
				aOut = []
				nN = oBangaloAgentHost.NumberOfAgents()
				for i = 1 to nN
					cName = oBangaloAgentHost.NameAt(i)
					add(aOut, BangaloAgentRow(cName))
				next
				return Reply(:ok, [
					:agents   = aOut,
					:refusals = oBangaloAgentHost.AgentLoadRefusals()
				])
			},

			:trace = func aReq {
				oBangaloAgentHost.TickDue()
				return Reply(:ok, [ :trace = oBangaloAgentHost.Trace() ])
			},

			:get = func aReq {
				oBangaloAgentHost.TickDue()
				cName = RsDeclGet(aReq[:payload], "name", "")
				if not oBangaloAgentHost.IsSupervising(cName)
					return RsRefuse(404, "no agent '" + cName + "'")
				ok
				return Reply(:ok, BangaloAgentRow(cName))
			}
		]
	]
])

# ------------------------------------------------------------------ helpers
#
# One agent's row, the shape GET /agents and GET /agents/<name> answer on
# stzAppServer (name, active, retired, ticks, channel), plus the two this
# profile's ask named that stzAppServer's own wire shape does not carry:
# `kind` (the folder's notation for the file that declared it -- "pia" or
# "ring") and `lastTick` (the trace's own timestamp, read rather than
# tracked twice -- the host is the one source of truth for it).
func BangaloAgentRow cName
	cKind = ""
	oFolder = oBangaloAgentHost.AgentFolderQ()
	if oFolder != "" and oFolder.Has(cName)
		cKind = oFolder.NotationOf(cName)
	ok
	return [
		:name     = cName,
		:kind     = cKind,
		:active   = oBangaloAgentHost.IsActive(cName),
		:retired  = oBangaloAgentHost.IsRetired(cName),
		:ticks    = oBangaloAgentHost.TicksOf(cName),
		:channel  = oBangaloAgentHost.ChannelOf(cName),
		:lastTick = BangaloLastTickOf(cName)
	]

# The trace's last entry for this agent, or 0 -- Trace() is [ [at, name,
# acted, why], ... ] in tick order (stzAgentHost.ring), so the last match
# scanning from the end IS the last tick. No agent has ticked yet answers
# 0, which is honest: it is not "unknown", it is "never".
func BangaloLastTickOf cName
	aT = oBangaloAgentHost.Trace()
	for i = len(aT) to 1 step -1
		if aT[i][2] = cName
			return aT[i][1]
		ok
	next
	return 0
