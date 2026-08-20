# The other two load FORMS, both of which reach ring_state_runfile by a
# different route than a plain `load`: a custom global scope, and a reload
# that bypasses the already-loaded check. Each nested load below is written
# relative to the file that contains it, exactly as in app.ring.
load package "pkg/p.ring"
load again "lib/deep/c.ring"

see "forms: " + p_ok() + " " + c_ok() + nl
