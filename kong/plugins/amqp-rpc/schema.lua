return {
  no_consumer = false, -- this plugin is available on APIs as well as on Consumers,
  fields = {
    routingkey = { required = true, type = "string" },
    exchange = { default = "", type = "string" },
    user = { default = "guest", type = "string" },
    password = { default = "guest", type = "string" },
    rpc = { default = true, type = "boolean" },
    forward_method = { default = true, type = "boolean" },
    forward_headers = { default = true, type = "boolean" },
    forward_path = { default = true, type = "boolean" },
    forward_query = { default = true, type = "boolean" },
    forward_body = { default = true, type = "boolean" }
  },
  self_check = function(schema, plugin_t, dao, is_updating)
    -- perform any custom verification
    return true
  end
}

