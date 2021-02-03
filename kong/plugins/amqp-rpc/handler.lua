-- Grab pluginname from module name
-- local plugin_name = ({...})[1]:match("^kong%.plugins%.([^%.]+)")
local plugin_name = "amqp-rpc"

-- load the base plugin object and create a subclass
local plugin = require("kong.plugins.base_plugin"):extend()
local amqp = require "amqprpc"
local cjson = require("cjson")
local uuid = require("resty.uuid")
local inspect = require("inspect")
local rpc_response
  

local constants = require("kong.constants")

local function has_amqp_module()
    for _, v in pairs(constants.PROTOCOLS) do
        if v == "amqpr-pc" then
            ngx.log(ngx.DEBUG, "Kong already contains AMQP protocol!")
            return true
        end
    end
    return false
end

-- constructor
function plugin:new()
    plugin.super.new(self, plugin_name)

    if not has_amqp_module then
        kong.log.err("AMQP modulo was not installed! The amqp protocol will not works!")
    end
end

function plugin:init_worker() 
    plugin.super.init_worker(self) 
end

local function amqp_get_context(conf)
    local user = os.getenv("AMQP_USERNAME")
    if user == nil then
        user = conf.user
        kong.log.debug("using AMQP_USERNAME var")
    end

    local password = os.getenv("AMQP_PASSWORD")
    if password == nil then
        password = conf.password
        kong.log.debug("using AMQP_PASSWORD var")
    end

    local opts = {
        role = 'producer',
        exchange = conf.exchange,
        routing_key = conf.routingkey,
        ssl = kong.router.get_service().protocol == "https",
        user = user,
        password = password,
        no_ack = false,
        durable = true,
        auto_delete = true,
        consumer_tag = '',
        exclusive = false,
        properties = {}
    }

    if (conf.rpc == true) then    -- IF RPC
        opts.role = 'consumer'
        opts.queue = 'amq.rabbitmq.reply-to'
        opts.no_ack = true
    end   
    


    local ctx = amqp:new(opts)


    ngx.log(ngx.DEBUG, "AMQP context created successfully")

    return ctx
end

local function amqp_connect(ctx)
   
    ctx:connect(kong.router.get_service().host, kong.router.get_service().port)
    ctx:setup()

    ngx.log(
        ngx.DEBUG, 
        "AMQP connected successfully at: ",
        "amqp://",
        kong.router.get_service().host, ":", kong.router.get_service().port
    )

    return ctx
end

local function amqp_publish(ctx, message, uid, conf)
    
    local ok, err, properties

    if (conf.rpc == false) then    -- IF FF
        properties = {correlation_id = uid}
    else   
        --- RPC
        --
        -- Prepare to consume
        --
      
        ok, err = ctx:prepare_to_consume() -- this has to be right after setup()
      
        if not ok then
          kong.log('could not prepare to consume: '..err)
        end

        properties = { 
            reply_to = 'amq.rabbitmq.reply-to',
            content_type = 'application/json',
            content_encoding = 'utf-8',
            correlation_id = uid,
            delivery_mode = 2,
            headers = { 
                ['api-version'] = 1,
                correlation_id = uid 
            }
        }

    end
    
    ok, err = ctx:publish(cjson.encode(message), ctx.opts, properties)

    if err then
        ngx.log(ngx.ERR, "Internal server errror: ", err)
        ngx.say(cjson.encode({error = "Internal Server Error"}))

        ngx.ctx.status = ngx.HTTP_INTERNAL_SERVER_ERROR
        ngx.exit(ngx.ctx.status)
    end

    ngx.log(ngx.DEBUG, "Raw Body Published successfully")
end

local function amqp_get_message(conf)
    
    local message = {}

    if conf.forward_method == true then
        message.method = kong.request.get_method()
    end

    if conf.forward_path == true then
        message.path = kong.request.get_path()
    end

    if conf.forward_headers == true then
        message.headers = kong.request.get_headers()
    end

    if conf.forward_query == true then
        message.query = kong.request.get_query()
    end

    if conf.forward_body == true then
        message.body = kong.request.get_body()
    end

    return message
end



local function get_response(id, ctx, conf)
    
    local ltime = ngx.localtime()
    local resp
    local err = nil
    
    if (conf.rpc == false) then    -- IF FF
        resp = cjson.encode({uuid = id, ltime})
    else    
        -- RPC 
        ctx.opts.consume_noloop = true
        ctx.opts.heartbeat = 30
        ctx.opts.heartbeat_max_iterations = 1
        rpc_response = ctx:consume_loop()
        resp, err = cjson.encode({uuid = id, ltime, data = rpc_response})
    end

    ngx.log(ngx.DEBUG, "AMQP Response body generated with ID: ", id)

    return resp, err
end

function plugin:access(conf)
    plugin.super.access(self)
    local ctx = amqp_get_context(conf)
    local response, err
    amqp_connect(ctx)

    local uid = uuid.generate()
    amqp_publish(ctx, amqp_get_message(conf), uid, conf)

    local response, err = get_response(uid, ctx, conf)
    
    if err then
        ngx.log(ngx.ERR, "Internal server errror: ", err)
        ngx.say(cjson.encode({error = "Internal Server Error"}))

        ngx.ctx.status = ngx.HTTP_INTERNAL_SERVER_ERROR
        ngx.exit(ngx.ctx.status)
    end
    
    ngx.say(response)
    ctx:teardown()
    ctx:close()

    ngx.ctx.status = ngx.HTTP_CREATED
    ngx.exit(ngx.ctx.status)
end

function plugin:header_filter(plugin_conf)
    plugin.super.header_filter(self)

    ngx.header["Content-Type"] = "application/json"
end

-- set the plugin priority, which determines plugin execution order
plugin.PRIORITY = 1000

-- return our plugin object
return plugin

