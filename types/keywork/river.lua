---@meta keywork.river

---@alias keywork.river.BindingEvent 'pressed'|'released'|'stop_repeat'
---@alias keywork.river.PointerBindingEvent 'pressed'|'released'
---@alias keywork.river.PresentationMode 'vsync'|'async'
---@alias keywork.river.DecorationHint 'only_supports_csd'|'prefers_csd'|'prefers_ssd'|'no_preference'
---@alias keywork.river.LayerShellFocus 'exclusive'|'non_exclusive'|'none'

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

---@class keywork.river.Rectangle
---@field x      integer
---@field y      integer
---@field width  integer
---@field height integer

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
---@field id                  integer                 Stable for the lifetime of the manager process and never reused.
---@field wl_output?          integer                 Registry name of the corresponding wl_output global.
---@field x                   integer
---@field y                   integer
---@field width               integer
---@field height              integer
---@field non_exclusive_area? keywork.river.Rectangle Area remaining after layer-shell exclusive zones.

---@class keywork.river.Seat
---@field id                 integer                       Stable for the lifetime of the manager process and never reused.
---@field wl_seat?           integer                       Registry name of the corresponding wl_seat global.
---@field pointer_position?  keywork.river.Point
---@field modifiers?         integer                       River's current modifier bitmask.
---@field layer_shell_focus? keywork.river.LayerShellFocus

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

---@class keywork.river.LayerShellAreaEvent
---@field type   'layer_shell_non_exclusive_area'
---@field output integer
---@field x      integer
---@field y      integer
---@field width  integer
---@field height integer

---@class keywork.river.LayerShellFocusEvent
---@field type  'layer_shell_focus'
---@field seat  integer
---@field focus keywork.river.LayerShellFocus

---@alias keywork.river.Event keywork.river.SessionLockedEvent | keywork.river.SessionUnlockedEvent | keywork.river.WindowAddedEvent | keywork.river.WindowClosedEvent | keywork.river.OutputAddedEvent | keywork.river.OutputRemovedEvent | keywork.river.SeatAddedEvent | keywork.river.SeatRemovedEvent | keywork.river.SeatWindowEvent | keywork.river.PointerResizeRequestedEvent | keywork.river.ShowWindowMenuRequestedEvent | keywork.river.WindowRequestEvent | keywork.river.FullscreenRequestedEvent | keywork.river.SeatEvent | keywork.river.ModifiersUpdateEvent | keywork.river.OpDeltaEvent | keywork.river.LayerShellAreaEvent | keywork.river.LayerShellFocusEvent

---@class keywork.river.Context
---@field windows                   keywork.river.Window[]
---@field outputs                   keywork.river.Output[]
---@field seats                     keywork.river.Seat[]
---@field events                    keywork.river.Event[]  Events are populated only for a manage transaction.
---@field session_locked            boolean
---@field window_management_version integer                Negotiated `river_window_manager_v1` protocol version.
---@field xkb_bindings_version      integer                Negotiated `river_xkb_bindings_v1` protocol version.
---@field layer_shell_version       integer                Negotiated `river_layer_shell_v1` version, or zero when unavailable.

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

---@class keywork.river.SetLayerShellDefaultCommand
---@field [1]    'set_layer_shell_default'
---@field output integer

---@class keywork.river.ExitSessionCommand
---@field [1] 'exit_session'

---@alias keywork.river.ManageCommand keywork.river.CloseCommand | keywork.river.ProposeDimensionsCommand | keywork.river.WindowManageCommand | keywork.river.SetTiledCommand | keywork.river.SetCapabilitiesCommand | keywork.river.FullscreenCommand | keywork.river.SetDimensionBoundsCommand | keywork.river.FocusWindowCommand | keywork.river.SeatManageCommand | keywork.river.PointerWarpCommand | keywork.river.SetXcursorThemeCommand | keywork.river.SeatKeyCommand | keywork.river.ModifiersWatchCommand | keywork.river.SetLayerShellDefaultCommand | keywork.river.ExitSessionCommand

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

---@alias keywork.river.InputDeviceType 'keyboard'|'pointer'|'touch'|'tablet'
---@alias keywork.river.BinaryState 'disabled'|'enabled'
---@alias keywork.river.TapButtonMap 'lrm'|'lmr'
---@alias keywork.river.DragLockState 'disabled'|'enabled_timeout'|'enabled_sticky'
---@alias keywork.river.ThreeFingerDragState 'disabled'|'enabled_3fg'|'enabled_4fg'
---@alias keywork.river.AccelProfile 'none'|'flat'|'adaptive'|'custom'
---@alias keywork.river.AccelType 'fallback'|'motion'|'scroll'
---@alias keywork.river.ClickMethod 'none'|'button_areas'|'clickfinger'
---@alias keywork.river.ScrollMethod 'no_scroll'|'two_finger'|'edge'|'on_button_down'
---@alias keywork.river.SendEventsMode 'enabled'|'disabled'|'disabled_on_external_mouse'
---@alias keywork.river.KeymapFormat 'text_v1'|'text_v2'
---@alias keywork.river.KeymapState 'pending'|'ready'|'failed'
---@alias keywork.river.LibinputResultStatus 'success'|'unsupported'|'invalid'

---@class keywork.river.InputValue<T>
---@field support? boolean | integer River's raw support flag, finger count, or enum bitmask when the option has a support event.
---@field default? T
---@field current? T

---@class keywork.river.LibinputState
---@field send_events            keywork.river.InputValue<integer>                            Raw River send-events mode/bitmask values.
---@field tap                    keywork.river.InputValue<keywork.river.BinaryState>
---@field tap_button_map         keywork.river.InputValue<keywork.river.TapButtonMap>
---@field drag                   keywork.river.InputValue<keywork.river.BinaryState>
---@field drag_lock              keywork.river.InputValue<keywork.river.DragLockState>
---@field three_finger_drag      keywork.river.InputValue<keywork.river.ThreeFingerDragState>
---@field calibration_matrix     keywork.river.InputValue<number[]>
---@field accel_profile          keywork.river.InputValue<keywork.river.AccelProfile>
---@field accel_speed            keywork.river.InputValue<number>
---@field natural_scroll         keywork.river.InputValue<keywork.river.BinaryState>
---@field left_handed            keywork.river.InputValue<keywork.river.BinaryState>
---@field click_method           keywork.river.InputValue<keywork.river.ClickMethod>
---@field clickfinger_button_map keywork.river.InputValue<keywork.river.TapButtonMap>
---@field middle_emulation       keywork.river.InputValue<keywork.river.BinaryState>
---@field scroll_method          keywork.river.InputValue<keywork.river.ScrollMethod>
---@field scroll_button          keywork.river.InputValue<integer>
---@field scroll_button_lock     keywork.river.InputValue<keywork.river.BinaryState>
---@field dwt                    keywork.river.InputValue<keywork.river.BinaryState>
---@field dwtp                   keywork.river.InputValue<keywork.river.BinaryState>
---@field rotation               keywork.river.InputValue<integer>

---@class keywork.river.KeyboardState
---@field layout_index? integer
---@field layout_name?  string
---@field capslock?     boolean
---@field numlock?      boolean

---@class keywork.river.InputDevice
---@field id        integer                       Stable for this input-app process and never reused.
---@field type?     keywork.river.InputDeviceType
---@field name?     string
---@field libinput? keywork.river.LibinputState   Present only when River exposes a libinput facet for the device.
---@field keyboard? keywork.river.KeyboardState   Present only when River exposes an XKB facet for the device.

---@class keywork.river.InputOutput
---@field id            integer Stable for this input-app process and never reused.
---@field registry_name integer wl_output registry name.
---@field name?         string  Stable wl_output name when version 4 is available.

---@class keywork.river.InputKeymap
---@field id     string
---@field state  keywork.river.KeymapState
---@field error? string

---@class keywork.river.InputAccelConfig
---@field id      string
---@field profile keywork.river.AccelProfile

---@class keywork.river.InputDeviceEvent
---@field type   'device_added' | 'device_removed' | 'state_changed'
---@field device integer

---@class keywork.river.InputOutputEvent
---@field type   'output_added' | 'output_removed'
---@field output integer

---@class keywork.river.KeymapReadyEvent
---@field type   'keymap_ready'
---@field keymap string

---@class keywork.river.KeymapFailedEvent
---@field type   'keymap_failed'
---@field keymap string
---@field error  string

---@class keywork.river.LibinputResultEvent
---@field type          'libinput_result'
---@field device?       integer
---@field accel_config? string
---@field operation     string
---@field status        keywork.river.LibinputResultStatus

---@alias keywork.river.InputEvent keywork.river.InputDeviceEvent | keywork.river.InputOutputEvent | keywork.river.KeymapReadyEvent | keywork.river.KeymapFailedEvent | keywork.river.LibinputResultEvent

---@class keywork.river.InputContext
---@field devices                  keywork.river.InputDevice[]
---@field outputs                  keywork.river.InputOutput[]
---@field keymaps                  keywork.river.InputKeymap[]
---@field accel_configs            keywork.river.InputAccelConfig[]
---@field events                   keywork.river.InputEvent[]
---@field input_management_version integer
---@field libinput_config_version  integer
---@field xkb_config_version       integer

---@class keywork.river.InputSeatCommand
---@field [1]  'create_seat' | 'destroy_seat'
---@field name string

---@class keywork.river.AssignToSeatCommand
---@field [1]    'assign_to_seat'
---@field device integer
---@field name   string

---@class keywork.river.SetRepeatInfoCommand
---@field [1]    'set_repeat_info'
---@field device integer
---@field rate   integer           Non-negative; zero disables repeat.
---@field delay  integer           Non-negative milliseconds.

---@class keywork.river.SetScrollFactorCommand
---@field [1]    'set_scroll_factor'
---@field device integer
---@field factor number              Non-negative.

---@class keywork.river.MapToOutputCommand
---@field [1]     'map_to_output'
---@field device  integer
---@field output? integer         Omit to clear the output mapping.

---@class keywork.river.MapToRectangleCommand
---@field [1]    'map_to_rectangle'
---@field device integer
---@field x      integer
---@field y      integer
---@field width  integer            Non-negative; zero clears the rectangle mapping.
---@field height integer            Non-negative; zero clears the rectangle mapping.

---@class keywork.river.CreateKeymapCommand
---@field [1]     'create_keymap'
---@field id      string
---@field text    string
---@field format? keywork.river.KeymapFormat Defaults to text_v1.

---@class keywork.river.KeymapIdCommand
---@field [1] 'destroy_keymap'
---@field id  string

---@class keywork.river.SetKeymapCommand
---@field [1]    'set_keymap'
---@field device integer
---@field keymap string       Must refer to a ready keymap.

---@class keywork.river.SetLayoutIndexCommand
---@field [1]    'set_layout_by_index'
---@field device integer
---@field index  integer

---@class keywork.river.SetLayoutNameCommand
---@field [1]    'set_layout_by_name'
---@field device integer
---@field name   string

---@class keywork.river.InputBoolCommand
---@field [1]     'set_capslock' | 'set_numlock' | 'set_natural_scroll' | 'set_left_handed' | 'set_middle_emulation' | 'set_scroll_button_lock' | 'set_dwt' | 'set_dwtp'
---@field device  integer
---@field enabled boolean

---@class keywork.river.CreateAccelConfigCommand
---@field [1]     'create_accel_config'
---@field id      string
---@field profile keywork.river.AccelProfile

---@class keywork.river.AccelConfigIdCommand
---@field [1] 'destroy_accel_config'
---@field id  string

---@class keywork.river.SetAccelPointsCommand
---@field [1]    'set_accel_points'
---@field config string
---@field type   keywork.river.AccelType
---@field step   number
---@field points number[]

---@class keywork.river.ApplyAccelConfigCommand
---@field [1]    'apply_accel_config'
---@field device integer
---@field config string

---@class keywork.river.SetSendEventsCommand
---@field [1]    'set_send_events'
---@field device integer
---@field mode   keywork.river.SendEventsMode

---@class keywork.river.InputStateCommand
---@field [1]    'set_tap' | 'set_drag'
---@field device integer
---@field state  keywork.river.BinaryState

---@class keywork.river.SetTapButtonMapCommand
---@field [1]    'set_tap_button_map' | 'set_clickfinger_button_map'
---@field device integer
---@field map    keywork.river.TapButtonMap

---@class keywork.river.SetDragLockCommand
---@field [1]    'set_drag_lock'
---@field device integer
---@field state  keywork.river.DragLockState

---@class keywork.river.SetThreeFingerDragCommand
---@field [1]    'set_three_finger_drag'
---@field device integer
---@field state  keywork.river.ThreeFingerDragState

---@class keywork.river.SetCalibrationMatrixCommand
---@field [1]    'set_calibration_matrix'
---@field device integer
---@field matrix number[]                 Exactly six native floating-point values.

---@class keywork.river.SetAccelProfileCommand
---@field [1]     'set_accel_profile'
---@field device  integer
---@field profile keywork.river.AccelProfile

---@class keywork.river.SetAccelSpeedCommand
---@field [1]    'set_accel_speed'
---@field device integer
---@field speed  number            In the inclusive range -1 through 1.

---@class keywork.river.SetClickMethodCommand
---@field [1]    'set_click_method'
---@field device integer
---@field method keywork.river.ClickMethod

---@class keywork.river.SetScrollMethodCommand
---@field [1]    'set_scroll_method'
---@field device integer
---@field method keywork.river.ScrollMethod

---@class keywork.river.SetScrollButtonCommand
---@field [1]    'set_scroll_button'
---@field device integer
---@field button integer             Linux input event button code.

---@class keywork.river.SetRotationCommand
---@field [1]    'set_rotation'
---@field device integer
---@field angle  integer        In the range 0 through 359.

---@alias keywork.river.InputCommand keywork.river.InputSeatCommand | keywork.river.AssignToSeatCommand | keywork.river.SetRepeatInfoCommand | keywork.river.SetScrollFactorCommand | keywork.river.MapToOutputCommand | keywork.river.MapToRectangleCommand | keywork.river.CreateKeymapCommand | keywork.river.KeymapIdCommand | keywork.river.SetKeymapCommand | keywork.river.SetLayoutIndexCommand | keywork.river.SetLayoutNameCommand | keywork.river.InputBoolCommand | keywork.river.CreateAccelConfigCommand | keywork.river.AccelConfigIdCommand | keywork.river.SetAccelPointsCommand | keywork.river.ApplyAccelConfigCommand | keywork.river.SetSendEventsCommand | keywork.river.InputStateCommand | keywork.river.SetTapButtonMapCommand | keywork.river.SetDragLockCommand | keywork.river.SetThreeFingerDragCommand | keywork.river.SetCalibrationMatrixCommand | keywork.river.SetAccelProfileCommand | keywork.river.SetAccelSpeedCommand | keywork.river.SetClickMethodCommand | keywork.river.SetScrollMethodCommand | keywork.river.SetScrollButtonCommand | keywork.river.SetRotationCommand

---@class keywork.river.InputAppOptions
---@field update fun(context: keywork.river.InputContext): keywork.river.InputCommand[] Called with a coherent snapshot after initial enumeration, hot reload, or a protocol event.
---@field start? fun()
---@field stop?  fun()

---@class keywork.river.InputApp

local M = {}

---@param options keywork.river.WindowManagerOptions
---@return keywork.river.WindowManager
function M.window_manager(options) end

---@param options keywork.river.AppOptions
---@return keywork.river.App
function M.app(options) end

---@param options keywork.river.InputAppOptions
---@return keywork.river.InputApp
function M.input_app(options) end

return M
