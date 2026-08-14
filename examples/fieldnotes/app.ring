# fieldnotes — services, declared once, placed by topology.ring

RingServ([
    :port = 8080,

    :data = [
        :notes = [ :id = :number, :title = :string, :body = :string,
                   :tags = :list, :updated = :string ]
    ],

    :services = [

        # CRUD over the notes table — a generic table service:
        # list/get/create/update/delete come from the declaration.
        :notes = [ :table = "notes" ],

        # A real computation — placed :server by the topology,
        # because it is heavy and needs the whole dataset.
        :report = [
            :build = func oReq {
                aNotes = DataQuery("select * from notes", [])
                aByTag = []
                for oNote in aNotes
                    for cTag in oNote[:tags]
                        aByTag[cTag] = aByTag[cTag] + 1
                    next
                next
                return Reply(:ok, [
                    :count = len(aNotes),
                    :tags  = aByTag
                ])
            }
        ]
    ],

    :routes = [
        [ :static, "/", "public/" ]
    ]
])
