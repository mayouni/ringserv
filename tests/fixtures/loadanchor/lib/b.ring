# relative to lib/ -- a CHILD directory of this file's own directory
load "deep/c.ring"

func b_ok
	return "b(" + c_ok() + ")"
