# A file of plain functions -- the phase-10 gesture. No declarations.

func hello name
	return "Hello, " + name + "!"

func add a, b
	return a + b

func stats xs
	nSum = 0
	for x in xs
		nSum += x
	next
	return [ :count = len(xs), :sum = nSum ]

func _secret
	return "never exposed"
