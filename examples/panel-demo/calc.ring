# calc.ring -- the phase-10 gesture: plain functions, served as-is.

func hello name
	return "Hello, " + name + "!"

func add a, b
	return a + b

func fib n
	if n < 2 return n ok
	a = 0 b = 1
	for i = 2 to n
		c = a + b
		a = b
		b = c
	next
	return b
