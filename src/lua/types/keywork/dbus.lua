---@meta keywork.dbus

---@class keywork.dbus.TypedValue<T>
---@field __dbus_type string
---@field value       T
---@field signature?  string

---@class keywork.dbus.StringValue: keywork.dbus.TypedValue<string>
---@field __dbus_type 'string'

---@class keywork.dbus.ObjectPathValue: keywork.dbus.TypedValue<string>
---@field __dbus_type 'object_path'

---@class keywork.dbus.BooleanValue: keywork.dbus.TypedValue<boolean>
---@field __dbus_type 'boolean'

---@class keywork.dbus.Int32Value: keywork.dbus.TypedValue<integer>
---@field __dbus_type 'int32'

---@class keywork.dbus.UInt32Value: keywork.dbus.TypedValue<integer>
---@field __dbus_type 'uint32'

---@class keywork.dbus.DoubleValue: keywork.dbus.TypedValue<number>
---@field __dbus_type 'double'

---@class keywork.dbus.ArrayValue<T>: keywork.dbus.TypedValue<T>
---@field __dbus_type 'array'
---@field signature   string  Element signature.

---@class keywork.dbus.VariantValue<T>: keywork.dbus.TypedValue<T>
---@field __dbus_type 'variant'
---@field signature   string    Contained value signature.

---@alias keywork.dbus.Argument string | boolean | number | keywork.dbus.TypedValue<any>

---@class keywork.dbus.UnixFd
local UnixFd = {}

function UnixFd:close() end

---@return boolean
function UnixFd:closed() end

---@class keywork.dbus.Reply
---@field signature? string
---@field args       any[]  Signature-dependent decoded values.

---@class keywork.dbus.Signal
---@field sender?    string
---@field path?      string
---@field interface? string
---@field member?    string
---@field signature? string
---@field args       any[]  Signature-dependent decoded values.

---@class keywork.dbus.MethodCall
---@field sender?    string
---@field path?      string
---@field interface? string
---@field member?    string
---@field serial     integer

---@alias keywork.dbus.MethodHandler fun(call: keywork.dbus.MethodCall, ...: any): any...

---@class keywork.dbus.CallOptions
---@field destination string
---@field path        string
---@field interface   string
---@field member      string
---@field args?       keywork.dbus.Argument[]
---@field timeout_ms? integer

---@class keywork.dbus.SignalOptions
---@field path      string
---@field interface string
---@field member    string
---@field args?     keywork.dbus.Argument[]

---@class keywork.dbus.SubscribeOptions
---@field sender?         string
---@field path?           string
---@field path_namespace? string
---@field interface?      string
---@field member?         string

---@class keywork.dbus.RequestNameOptions
---@field allow_replacement? boolean
---@field replace_existing?  boolean
---@field do_not_queue?      boolean

---@class keywork.dbus.PropertyOptions
---@field destination string
---@field path        string
---@field interface   string
---@field name        string
---@field timeout_ms? integer

---@class keywork.dbus.SetPropertyOptions: keywork.dbus.PropertyOptions
---@field value      keywork.dbus.Argument Plain scalars are inferred as `s`, `b`, or `d`; use a typed value for other signatures.
---@field signature? string                Required when the value's D-Bus type cannot be inferred.

---@class keywork.dbus.ProxyOptions
---@field timeout_ms? integer

---@class keywork.dbus.Proxy
---@field bus         keywork.dbus.Bus
---@field destination string
---@field path        string
---@field interface   string
---@field [string]    any              Unknown fields become remote method-call functions.

---@class keywork.dbus.ObserveOptions
---@field destination string
---@field path        string
---@field interface   string
---@field timeout_ms? integer

---@class keywork.dbus.Change
---@field props     table<string, any> Signature-dependent decoded values.
---@field changed   table<string, any> Signature-dependent decoded values.
---@field available boolean

---@class keywork.dbus.Observer
---@field bus         keywork.dbus.Bus
---@field destination string
---@field path        string
---@field interface   string
local Observer = {}

---@return fun(): keywork.dbus.Change?
function Observer:changes() end

--- Requests a fresh Properties.GetAll snapshot.
function Observer:refresh() end

function Observer:cancel() end

---@class keywork.dbus.MethodSpec
---@field in_signature?  string
---@field out_signature? string
---@field call           keywork.dbus.MethodHandler Receives the method-call table followed by decoded D-Bus arguments; returned values form the reply.

---@class keywork.dbus.SignalSpec
---@field signature? string

---@alias keywork.dbus.PropertyAccess 'read' | 'write' | 'readwrite'

---@class keywork.dbus.PropertySpec
---@field signature string
---@field access?   keywork.dbus.PropertyAccess
---@field get?      fun(): any
---@field set?      fun(value: any)

---@class keywork.dbus.InterfaceSpec
---@field methods?    table<string, keywork.dbus.MethodSpec>
---@field signals?    table<string, keywork.dbus.SignalSpec>
---@field properties? table<string, keywork.dbus.PropertySpec>

---@alias keywork.dbus.ExportSpec table<string, keywork.dbus.InterfaceSpec>

---@class keywork.dbus.Subscription
local Subscription = {}

---@return keywork.dbus.Signal?
function Subscription:next() end

---@return fun(): keywork.dbus.Signal?
function Subscription:events() end

function Subscription:cancel() end

---@class keywork.dbus.OwnedName
local OwnedName = {}

function OwnedName:release() end

---@class keywork.dbus.ExportedObject
local ExportedObject = {}

function ExportedObject:unexport() end

---@class keywork.dbus.Bus
local Bus = {}

---@param options keywork.dbus.SubscribeOptions
---@return keywork.dbus.Subscription
function Bus:subscribe(options) end

--- Calls a remote method. Must be called from a loop coroutine.
---@param options keywork.dbus.CallOptions
---@return keywork.dbus.Reply? reply
---@return string? error
function Bus:call(options) end

---@param name     string
---@param options? keywork.dbus.RequestNameOptions
---@return keywork.dbus.OwnedName? owned_name
---@return string? error
function Bus:request_name(name, options) end

---@param name string
function Bus:release_name(name) end

---@param path string
---@param spec keywork.dbus.ExportSpec
---@return keywork.dbus.ExportedObject
function Bus:export(path, spec) end

---@param options keywork.dbus.SignalOptions
function Bus:emit(options) end

function Bus:close() end

---@return boolean
function Bus:closed() end

---@return string? unique_name
---@return string? error
function Bus:unique_name() end

---@param options keywork.dbus.PropertyOptions
---@return any value     Signature-dependent decoded value.
---@return string? error
function Bus:get_property(options) end

---@param options keywork.dbus.SetPropertyOptions
---@return true? ok
---@return string? error
function Bus:set_property(options) end

---@param destination string
---@param path        string
---@param interface   string
---@param options?    keywork.dbus.ProxyOptions
---@return keywork.dbus.Proxy
function Bus:proxy(destination, path, interface, options) end

---@param options keywork.dbus.ObserveOptions
---@return keywork.dbus.Observer
function Bus:observe(options) end

local M = {}

---@return keywork.dbus.Bus? bus
---@return string? error
function M.session() end

---@return keywork.dbus.Bus? bus
---@return string? error
function M.system() end

---@param value string
---@return keywork.dbus.StringValue
function M.string(value) end

---@param value string
---@return keywork.dbus.ObjectPathValue
function M.object_path(value) end

---@param value boolean
---@return keywork.dbus.BooleanValue
function M.boolean(value) end

---@param value integer
---@return keywork.dbus.Int32Value
function M.int32(value) end

---@param value integer
---@return keywork.dbus.UInt32Value
function M.uint32(value) end

---@param value number
---@return keywork.dbus.DoubleValue
function M.double(value) end

---@generic T
---@param element_signature string
---@param value             T
---@return keywork.dbus.ArrayValue<T>
function M.array(element_signature, value) end

---@generic T
---@param signature string
---@param value     T
---@return keywork.dbus.VariantValue<T>
function M.variant(signature, value) end

return M
