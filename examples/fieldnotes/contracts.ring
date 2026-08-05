# fieldnotes — contracts: typed, governed, and the source of the docs

Contract(:notes, [
    :create = [
        :in = [
            :title = [ :type = :string, :required = true, :maxlen = 120 ],
            :body  = [ :type = :string ],
            :tags  = [ :type = :list, :of = :string ]
        ],
        :out  = [ :id = :number ],
        :auth = :required
    ],
    :list = [
        :in  = [ :tag = [ :type = :string ] ],
        :out = [ :notes = :list ]
    ]
])

Contract(:report, [
    :build = [
        :in   = [],
        :out  = [ :count = :number, :tags = :list ],
        :auth = :required
    ]
])
