# fieldnotes — deployment truth, separate from application truth.
# Move a service between page and server by editing one word here.

Topology([
    :app = "fieldnotes",

    :data = [
        :notes = [ :store = :local, :sync = :onreconnect ]
    ],

    :services = [
        :notes  = :both,       # instant local reads; server is the authority
        :report = :server      # heavy, needs the full dataset
    ]
])
