-- Grab pluginname from module name
-- local plugin_name = ({...})[1]:match("^kong%.plugins%.([^%.]+)")
local plugin_name = "amqp"

-- load the base plugin object and create a subclass
local plugin = require("kong.plugins.base_plugin"):extend()
local amqp = require "amqp"
local cjson = require("cjson")
local uuid = require("resty.uuid")

local constants = require("kong.constants")

local function has_amqp_module()
    for _, v in pairs(constants.PROTOCOLS) do
        if v == "amqp" then
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

    local ctx = amqp:new({
        role = 'producer',
        exchange = conf.exchange,
        routing_key = conf.routingkey,
        ssl = kong.router.get_service().protocol == "https",
        user = user,
        password = password,
        no_ack = false,
        durable = true,
        auto_delete = true,
        exclusive = false,
        properties = {}
    })

    ngx.log(ngx.DEBUG, "AMQP context created successfully")

    return ctx
end

local function amqp_connect(ctx)
    ctx:connect(kong.router.get_service().host, kong.router.get_service().port)
    ctx:setup()

    ngx.log(ngx.DEBUG, "AMQP connected successfully at: ", "amqp://",
            kong.router.get_service().host, ":", kong.router.get_service().port)

    return ctx
end

local function amqp_publish(ctx, message, uid)
    local ok, err = ctx:publish(message, {}, {correlation_id = uid})

    if err then
        ngx.log(ngx.ERR, "Internal server errror: ", err)
        ngx.say(cjson.encode({error = "Internal Server Error"}))

        ngx.ctx.status = ngx.HTTP_INTERNAL_SERVER_ERROR
        ngx.exit(ngx.ctx.status)
    end

    ngx.log(ngx.DEBUG, "Raw Body Published successfully")
end

local function get_response(id)
    local resp = cjson.encode({uuid = id, time = ngx.localtime()})

    ngx.log(ngx.DEBUG, "AMQP Response body generated with ID: ", id)

    return resp
end

function plugin:access(conf)
    plugin.super.access(self)

    local ctx = amqp_get_context(conf)
    amqp_connect(ctx)

    local uid = uuid.generate()
    amqp_publish(ctx, kong.request.get_raw_body(), uid)

    local response = get_response(uid)
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
