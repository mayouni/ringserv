# Load-anchor fixture: three levels of NESTED relative `load`, each written
# relative to the directory of the file that contains it -- exactly how a
# multi-file Ring library is authored. No dependency on any external library,
# so this guard survives a machine without stzlib.
load "lib/a.ring"

see "app: " + a_ok() + nl
