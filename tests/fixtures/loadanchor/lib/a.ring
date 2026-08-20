# relative to lib/ -- a SIBLING of this file, not of app.ring
load "b.ring"

func a_ok
	return "a(" + b_ok() + ")"
