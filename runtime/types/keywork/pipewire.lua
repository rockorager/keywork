---@meta keywork.pipewire

---@class keywork.pipewire.ConnectOptions
---@field realtime? boolean

---@class keywork.pipewire.GlobalEvent
---@field type        'global'
---@field id          integer
---@field permissions integer
---@field interface   string
---@field version     integer
---@field properties  table<string, string>

---@class keywork.pipewire.GlobalRemoveEvent
---@field type 'global_remove'
---@field id   integer

---@class keywork.pipewire.MetadataEvent
---@field type        'metadata'
---@field id          integer
---@field subject     integer
---@field key?        string
---@field value_type? string
---@field value?      string

---@class keywork.pipewire.NodePropsEvent
---@field type            'node_props'
---@field id              integer
---@field channel_volumes number[]
---@field muted?          boolean

---@class keywork.pipewire.NodeRouteEvent
---@field type          'node_route'
---@field id            integer
---@field device_id     integer
---@field route_device  integer
---@field route_managed boolean

---@class keywork.pipewire.RoutesResetEvent
---@field type 'routes_reset'
---@field id   integer

---@alias keywork.pipewire.Availability 'unknown' | 'no' | 'yes'

---@class keywork.pipewire.RouteEvent
---@field type            'route'
---@field id              integer
---@field device          integer
---@field availability    keywork.pipewire.Availability
---@field channel_volumes number[]
---@field muted?          boolean
---@field port_type?      string
---@field bus?            string

---@alias keywork.pipewire.Event keywork.pipewire.GlobalEvent | keywork.pipewire.GlobalRemoveEvent | keywork.pipewire.MetadataEvent | keywork.pipewire.NodePropsEvent | keywork.pipewire.NodeRouteEvent | keywork.pipewire.RoutesResetEvent | keywork.pipewire.RouteEvent

---@class keywork.pipewire.Connection
local Connection = {}

---@return keywork.pipewire.Event?
function Connection:next() end

---@return fun(): keywork.pipewire.Event?
function Connection:events() end

---@param node_id integer
---@param volume  number  Linear volume from 0 to 10.
---@return true? ok
---@return string? error
function Connection:set_volume(node_id, volume) end

---@param node_id integer
---@param muted   boolean
---@return true? ok
---@return string? error
function Connection:set_mute(node_id, muted) end

---@param key        string
---@param value_type string
---@param value      string
---@return true? ok
---@return string? error
function Connection:set_metadata(key, value_type, value) end

function Connection:close() end

---@return boolean
function Connection:closed() end

local M = {}

---@param options? keywork.pipewire.ConnectOptions
---@return keywork.pipewire.Connection? connection
---@return string? error
function M.connect(options) end

return M
