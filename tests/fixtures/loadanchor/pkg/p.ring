# relative to pkg/ -- reached through `load package`, which opens a custom
# global scope; the anchoring must still be this file's own directory.
load "q.ring"

func p_ok
	return "p(" + q_ok() + ")"
