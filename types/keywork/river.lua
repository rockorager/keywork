---@meta keywork.river

---@alias keywork.river.BindingEvent 'pressed'|'released'|'stop_repeat'
---@alias keywork.river.PointerBindingEvent 'pressed'|'released'
---@alias keywork.river.PresentationMode 'vsync'|'async'
---@alias keywork.river.DecorationHint 'only_supports_csd'|'prefers_csd'|'prefers_ssd'|'no_preference'

---@class keywork.river.Point
---@field x integer
---@field y integer

---@class keywork.river.Dimensions
---@field width  integer
---@field height integer

---@class keywork.river.DimensionsHint
---@field min_width  integer Zero means no preference.
---@field min_height integer Zero means no preference.
---@field max_width  integer Zero means no preference.
---@field max_height integer Zero means no preference.

---@class keywork.river.Edges
---@field top?    boolean
---@field bottom? boolean
---@field left?   boolean
---@field right?  boolean

---@class keywork.river.Modifiers
---@field shift?   boolean
---@field ctrl?    boolean `control` is accepted as an alias.
---@field control? boolean Alias for `ctrl`.
---@field alt?     boolean
---@field mod1?    boolean Alias for `alt`.
---@field mod3?    boolean
---@field super?   boolean
---@field mod4?    boolean Alias for `super`.
---@field mod5?    boolean

---@class keywork.river.Window
---@field id                 integer                        Stable for the lifetime of the manager process and never reused.
---@field title?             string
---@field app_id?            string
---@field identifier?        string                         River's globally unique, non-reused window identifier.
---@field parent?            integer                        Parent window ID.
---@field dimensions?        keywork.river.Dimensions       Actual content dimensions reported by the window.
---@field dimensions_hint?   keywork.river.DimensionsHint
---@field decoration_hint?   keywork.river.DecorationHint
---@field unreliable_pid?    integer                        Never use this value for security decisions.
---@field presentation_hint? keywork.river.PresentationMode

---@class keywork.river.Output
---@field id         integer Stable for the lifetime of the manager process and never reused.
---@field wl_output? integer Registry name of the corresponding wl_output global.
---@field x          integer
---@field y          integer
---@field width      integer
---@field height     integer

---@class keywork.river.Seat
---@field id                integer             Stable for the lifetime of the manager process and never reused.
---@field wl_seat?          integer             Registry name of the corresponding wl_seat global.
---@field pointer_position? keywork.river.Point
---@field modifiers?        integer             River's current modifier bitmask.

---@class keywork.river.SessionLockedEvent
---@field type 'session_locked'

---@class keywork.river.SessionUnlockedEvent
---@field type 'session_unlocked'

---@class keywork.river.WindowAddedEvent
---@field type   'window_added'
---@field window integer

---@class keywork.river.WindowClosedEvent
---@field type   'window_closed'
---@field window integer

---@class keywork.river.OutputAddedEvent
---@field type   'output_added'
---@field output integer

---@class keywork.river.OutputRemovedEvent
---@field type   'output_removed'
---@field output integer

---@class keywork.river.SeatAddedEvent
---@field type 'seat_added'
---@field seat integer

---@class keywork.river.SeatRemovedEvent
---@field type 'seat_removed'
---@field seat integer

---@class keywork.river.SeatWindowEvent
---@field type   'pointer_move_requested' | 'pointer_enter' | 'window_interaction'
---@field seat   integer
---@field window integer

---@class keywork.river.PointerResizeRequestedEvent
---@field type   'pointer_resize_requested'
---@field seat   integer
---@field window integer
---@field edges  keywork.river.Edges

---@class keywork.river.ShowWindowMenuRequestedEvent
---@field type   'show_window_menu_requested'
---@field window integer
---@field x      integer
---@field y      integer

---@class keywork.river.WindowRequestEvent
---@field type   'maximize_requested' | 'unmaximize_requested' | 'exit_fullscreen_requested' | 'minimize_requested'
---@field window integer

---@class keywork.river.FullscreenRequestedEvent
---@field type    'fullscreen_requested'
---@field window  integer
---@field output? integer                Optional output hint.

---@class keywork.river.SeatEvent
---@field type 'pointer_leave' | 'op_release' | 'ate_unbound_key'
---@field seat integer

---@class keywork.river.ModifiersUpdateEvent
---@field type 'modifiers_update'
---@field seat integer
---@field old  integer            Previous active modifier bitmask.
---@field new  integer            New active modifier bitmask.

---@class keywork.river.OpDeltaEvent
---@field type 'op_delta'
---@field seat integer
---@field dx   integer    Cumulative horizontal displacement.
---@field dy   integer    Cumulative vertical displacement.

---@alias keywork.river.Event keywork.river.SessionLockedEvent | keywork.river.SessionUnlockedEvent | keywork.river.WindowAddedEvent | keywork.river.WindowClosedEvent | keywork.river.OutputAddedEvent | keywork.river.OutputRemovedEvent | keywork.river.SeatAddedEvent | keywork.river.SeatRemovedEvent | keywork.river.SeatWindowEvent | keywork.river.PointerResizeRequestedEvent | keywork.river.ShowWindowMenuRequestedEvent | keywork.river.WindowRequestEvent | keywork.river.FullscreenRequestedEvent | keywork.river.SeatEvent | keywork.river.ModifiersUpdateEvent | keywork.river.OpDeltaEvent

---@class keywork.river.Context
---@field windows                   keywork.river.Window[]
---@field outputs                   keywork.river.Output[]
---@field seats                     keywork.river.Seat[]
---@field events                    keywork.river.Event[]  Events are populated only for a manage transaction.
---@field session_locked            boolean
---@field window_management_version integer                Negotiated `river_window_manager_v1` protocol version.
---@field xkb_bindings_version      integer                Negotiated `river_xkb_bindings_v1` protocol version.

---@class keywork.river.CloseCommand
---@field [1]    'close'
---@field window integer

---@class keywork.river.ProposeDimensionsCommand
---@field [1]    'propose_dimensions'
---@field window integer
---@field width  integer              Non-negative; zero lets the window choose.
---@field height integer              Non-negative; zero lets the window choose.

---@class keywork.river.WindowManageCommand
---@field [1]    'use_csd' | 'use_ssd' | 'inform_resize_start' | 'inform_resize_end' | 'inform_maximized' | 'inform_unmaximized' | 'inform_fullscreen' | 'inform_not_fullscreen' | 'exit_fullscreen'
---@field window integer

---@class keywork.river.SetTiledCommand
---@field [1]    'set_tiled'
---@field window integer
---@field edges  keywork.river.Edges

---@class keywork.river.SetCapabilitiesCommand
---@field [1]          'set_capabilities'
---@field window       integer
---@field window_menu? boolean
---@field maximize?    boolean
---@field fullscreen?  boolean
---@field minimize?    boolean

---@class keywork.river.FullscreenCommand
---@field [1]    'fullscreen'
---@field window integer
---@field output integer

---@class keywork.river.SetDimensionBoundsCommand
---@field [1]        'set_dimension_bounds'
---@field window     integer
---@field max_width  integer                Non-negative; zero means no bound.
---@field max_height integer                Non-negative; zero means no bound.

---@class keywork.river.FocusWindowCommand
---@field [1]    'focus_window'
---@field seat   integer
---@field window integer

---@class keywork.river.SeatManageCommand
---@field [1]  'clear_focus' | 'op_start_pointer' | 'op_end'
---@field seat integer

---@class keywork.river.PointerWarpCommand
---@field [1]  'pointer_warp'
---@field seat integer
---@field x    integer
---@field y    integer

---@class keywork.river.SetXcursorThemeCommand
---@field [1]  'set_xcursor_theme'
---@field seat integer
---@field name string
---@field size integer

---@class keywork.river.SeatKeyCommand
---@field [1]  'ensure_next_key_eaten' | 'cancel_ensure_next_key_eaten'
---@field seat integer

---@class keywork.river.ModifiersWatchCommand
---@field [1]       'modifiers_watch'
---@field seat      integer
---@field modifiers keywork.river.Modifiers

---@class keywork.river.ExitSessionCommand
---@field [1] 'exit_session'

---@alias keywork.river.ManageCommand keywork.river.CloseCommand | keywork.river.ProposeDimensionsCommand | keywork.river.WindowManageCommand | keywork.river.SetTiledCommand | keywork.river.SetCapabilitiesCommand | keywork.river.FullscreenCommand | keywork.river.SetDimensionBoundsCommand | keywork.river.FocusWindowCommand | keywork.river.SeatManageCommand | keywork.river.PointerWarpCommand | keywork.river.SetXcursorThemeCommand | keywork.river.SeatKeyCommand | keywork.river.ModifiersWatchCommand | keywork.river.ExitSessionCommand

---@class keywork.river.WindowRenderCommand
---@field [1]    'hide' | 'show' | 'place_top' | 'place_bottom'
---@field window integer

---@class keywork.river.SetPositionCommand
---@field [1]    'set_position'
---@field window integer
---@field x      integer
---@field y      integer

---@class keywork.river.StackCommand
---@field [1]    'place_above' | 'place_below'
---@field window integer
---@field other  integer

---@class keywork.river.Color
---@field r integer Unsigned 32-bit normalized component.
---@field g integer Unsigned 32-bit normalized component.
---@field b integer Unsigned 32-bit normalized component.
---@field a integer Unsigned 32-bit normalized component.

---@class keywork.river.SetBordersCommand
---@field [1]    'set_borders'
---@field window integer
---@field edges  keywork.river.Edges
---@field width  integer             Non-negative.
---@field color  keywork.river.Color Premultiplied RGBA.

---@class keywork.river.ClipCommand
---@field [1]    'set_clip_box' | 'set_content_clip_box'
---@field window integer
---@field x      integer
---@field y      integer
---@field width  integer                                 Non-negative; zero disables clipping.
---@field height integer                                 Non-negative; zero disables clipping.

---@class keywork.river.SetPresentationModeCommand
---@field [1]    'set_presentation_mode'
---@field output integer
---@field mode   keywork.river.PresentationMode

---@alias keywork.river.RenderCommand keywork.river.WindowRenderCommand | keywork.river.SetPositionCommand | keywork.river.StackCommand | keywork.river.SetBordersCommand | keywork.river.ClipCommand | keywork.river.SetPresentationModeCommand

---@alias keywork.river.BindingCallback fun(seat: integer, event: keywork.river.BindingEvent)

---@class keywork.river.BindingHandlers
---@field pressed?     keywork.river.BindingCallback
---@field released?    keywork.river.BindingCallback
---@field stop_repeat? keywork.river.BindingCallback

---@class keywork.river.BindingOptions: keywork.river.BindingHandlers
---@field layout? integer Zero-indexed XKB layout override; omitted bindings use the active layout.

---@alias keywork.river.Binding keywork.river.BindingCallback | keywork.river.BindingOptions

---@alias keywork.river.PointerBindingCallback fun(seat: integer, event: keywork.river.PointerBindingEvent)

---@class keywork.river.PointerBinding
---@field id         string
---@field modifiers? keywork.river.Modifiers
---@field button     integer                              Linux input event button code.
---@field pressed?   keywork.river.PointerBindingCallback
---@field released?  keywork.river.PointerBindingCallback

---@class keywork.river.WindowManagerOptions
---@field bindings?         table<string, keywork.river.Binding>                               Keys use forms such as `Super+Shift+Return`. Function shorthand handles presses only.
---@field pointer_bindings? keywork.river.PointerBinding[]                                     Pointer bindings are matched by modifiers and Linux input event button code.
---@field manage            fun(context: keywork.river.Context): keywork.river.ManageCommand[] Called once per River manage transaction.
---@field render            fun(context: keywork.river.Context): keywork.river.RenderCommand[] May be called multiple times after one manage transaction.

---@class keywork.river.WindowManager

---@class keywork.river.AppOptions
---@field manager keywork.river.WindowManager
---@field start?  fun()
---@field stop?   fun()

---@class keywork.river.App

local M = {}

---@param options keywork.river.WindowManagerOptions
---@return keywork.river.WindowManager
function M.window_manager(options) end

---@param options keywork.river.AppOptions
---@return keywork.river.App
function M.app(options) end

return M
