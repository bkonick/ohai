require_plugin 'v7message'

provides 'messages'

messages Mash.new
messages[:v7message] = v7message
