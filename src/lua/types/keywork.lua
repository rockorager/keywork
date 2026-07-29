---@meta keywork

---@alias keywork.Color integer
---@alias keywork.ColorRef keywork.Color|string
---@alias keywork.Backend 'cpu'|'vulkan'|'log'
---@alias keywork.ColorScheme 'light'|'dark'|'no-preference'
---@alias keywork.ResolvedColorScheme 'light'|'dark'
---@alias keywork.Alignment 'start'|'center'|'end'
---@alias keywork.CrossAxisAlignment keywork.Alignment|'stretch'|'baseline'|'cap_center'
---@alias keywork.MainAxisAlignment keywork.Alignment|'space_between'|'space_around'|'space_evenly'
---@alias keywork.CursorShape 'default'|'pointer'|'text'
---@alias keywork.PointerButton 'left'|'right'|'middle'|'back'|'forward'
---@alias keywork.ActivationMode 'release'|'press'
---@alias keywork.TextRole 'body'|'label'|'title'
---@alias keywork.TextOverflow 'ellipsis'|'clip'
---@alias keywork.LineBreakStrategy 'greedy'|'knuth_plass'
---@alias keywork.PopupEdge 'top'|'bottom'|'left'|'right'
---@alias keywork.ScrollAxes 'vertical'|'horizontal'|'both'
---@alias keywork.SeparatorAxis 'horizontal'|'vertical'
---@alias keywork.ImageFit 'fill'|'cover'|'contain'|'none'
---@alias keywork.ImageAlignment 'top_left'|'top_center'|'top_right'|'center_left'|'center'|'center_right'|'bottom_left'|'bottom_center'|'bottom_right'
---@alias keywork.ImageCache 'auto'|'frame'
---@alias keywork.ShortcutKey 'enter'|'space'|'backspace'|'tab'|'escape'|'up'|'down'
---@alias keywork.ResizeEdge 'top'|'bottom'|'left'|'right'|'top_left'|'top_right'|'bottom_left'|'bottom_right'|'top-left'|'top-right'|'bottom-left'|'bottom-right'
---@alias keywork.ThemeMetricRef number|string
---@alias keywork.ThemeScale table<integer|string, number>

---@class keywork.Widget

---@class keywork.Modifiers
---@field shift boolean
---@field ctrl  boolean
---@field alt   boolean
---@field super boolean

---@class keywork.TapEvent
---@field source    'pointer' | 'keyboard'
---@field button?   keywork.PointerButton
---@field x?        number
---@field y?        number
---@field window_x? number
---@field window_y? number
---@field modifiers keywork.Modifiers

---@class keywork.ScrollEvent
---@field x         number
---@field y         number
---@field window_x  number
---@field window_y  number
---@field dx        number
---@field dy        number
---@field modifiers keywork.Modifiers

---@class keywork.BuildContext
---@field window_width  number
---@field window_height number
---@field color_scheme  keywork.ColorScheme
---@field theme?        keywork.Theme

---@class keywork.Output
---@field name   string
---@field width  number
---@field height number
---@field scale  number

---@class keywork.WindowsContext
---@field outputs      keywork.Output[]    May be empty when no outputs are available.
---@field color_scheme keywork.ColorScheme

---@class keywork.EdgeInsets
---@field all?    number
---@field x?      number
---@field y?      number
---@field left?   number
---@field right?  number
---@field top?    number
---@field bottom? number

---@class keywork.ShadowLayer
---@field color?    keywork.Color Defaults to transparent.
---@field offset_x? number
---@field offset_y? number
---@field blur?     number
---@field spread?   number

---@class keywork.ThemeShadowLayer
---@field color?    keywork.ColorRef Defaults to transparent after resolution.
---@field offset_x? number
---@field offset_y? number
---@field blur?     number
---@field spread?   number

---@class keywork.ResolvedShadowLayer: keywork.ShadowLayer
---@field color?   keywork.Color
---@field offset_x number
---@field offset_y number
---@field blur     number
---@field spread   number

---@class keywork.TextStyle
---@field color?       keywork.Color
---@field size?        number
---@field font_size?   number
---@field line_height? number
---@field role?        keywork.TextRole
---@field max_lines?   integer                   Must be at least 1.
---@field overflow?    keywork.TextOverflow
---@field line_break?  keywork.LineBreakStrategy

---@class keywork.ThemeTextStyle
---@field color?       keywork.Color Theme text colors are not token-resolved.
---@field size?        number
---@field font_size?   number
---@field line_height? number

---@class keywork.ThemeSchemeOverride
---@field colors? table<string, keywork.ColorRef>
---@field shadow? table<integer, keywork.ThemeShadowLayer[]>

---@class keywork.ThemeScheme
---@field colors table<string, keywork.ColorRef>
---@field shadow table<integer, keywork.ThemeShadowLayer[]>

---@class keywork.ButtonAppearanceRecipeSource
---@field background? keywork.ColorRef
---@field foreground? keywork.ColorRef
---@field hover_background? keywork.ColorRef
---@field pressed_background? keywork.ColorRef

---@class keywork.ButtonSizeRecipeSource
---@field target?      keywork.ThemeMetricRef
---@field icon_size?   keywork.ThemeMetricRef
---@field font_size?   number
---@field line_height? number
---@field gap?         keywork.ThemeMetricRef
---@field padding_x?   keywork.ThemeMetricRef

---@class keywork.ButtonRecipeSource
---@field radius?         keywork.ThemeMetricRef
---@field focused_border? keywork.ColorRef
---@field sizes?          table<string, keywork.ButtonSizeRecipeSource>
---@field appearances?    table<string, keywork.ButtonAppearanceRecipeSource>
---@field selected?       keywork.ButtonAppearanceRecipeSource
---@field disabled?       keywork.ButtonAppearanceRecipeSource
---@field tones?          table<string, keywork.ButtonToneRecipeSource>

---@class keywork.ButtonToneRecipeSource
---@field foreground?         keywork.ColorRef
---@field background?         keywork.ColorRef
---@field hover_background?   keywork.ColorRef
---@field pressed_background? keywork.ColorRef
---@field on_background?      keywork.ColorRef

---@class keywork.TextFieldRecipeSource
---@field padding_x?      keywork.ThemeMetricRef
---@field padding_y?      keywork.ThemeMetricRef
---@field radius?         keywork.ThemeMetricRef
---@field font_size?      number
---@field line_height?    number
---@field background?     keywork.ColorRef
---@field foreground?     keywork.ColorRef
---@field placeholder?    keywork.ColorRef
---@field border?         keywork.ColorRef
---@field focused_border? keywork.ColorRef

---@class keywork.TokenRecipeSource
---@field padding_x?   keywork.ThemeMetricRef
---@field padding_y?   keywork.ThemeMetricRef
---@field radius?      keywork.ThemeMetricRef
---@field target?      keywork.ThemeMetricRef
---@field font_size?   number
---@field line_height? number
---@field icon_size?   keywork.ThemeMetricRef
---@field gap?         keywork.ThemeMetricRef
---@field background?  keywork.ColorRef
---@field foreground?  keywork.ColorRef

---@class keywork.ThemeMenuItemSource
---@field padding_x?                 keywork.ThemeMetricRef
---@field padding_y?                 keywork.ThemeMetricRef
---@field min_height?                keywork.ThemeMetricRef
---@field radius?                    keywork.ThemeMetricRef
---@field font_size?                 number
---@field line_height?               number
---@field foreground?                keywork.ColorRef
---@field disabled_foreground?       keywork.ColorRef
---@field hover_background?          keywork.ColorRef
---@field pressed_background?        keywork.ColorRef
---@field selected_background?       keywork.ColorRef
---@field selected_hover_background? keywork.ColorRef
---@field selected_pressed_background? keywork.ColorRef

---@class keywork.ThemeMenuLabelSource
---@field padding_x?   keywork.ThemeMetricRef
---@field padding_y?   keywork.ThemeMetricRef
---@field min_height?  keywork.ThemeMetricRef
---@field font_size?   number
---@field line_height? number
---@field foreground?  keywork.ColorRef

---@class keywork.ThemeMenuSeparatorSource
---@field color?     keywork.ColorRef
---@field thickness? number
---@field margin?    keywork.ThemeMetricRef
---@field inset?     keywork.ThemeMetricRef

---@class keywork.ThemeMenuSource
---@field background?   keywork.ColorRef
---@field border?       keywork.ColorRef
---@field border_width? number
---@field radius?       keywork.ThemeMetricRef
---@field padding?      keywork.ThemeMetricRef
---@field shadow?       integer | keywork.ShadowLayer[]  An integer selects a scheme shadow level.
---@field item?         keywork.ThemeMenuItemSource
---@field label?        keywork.ThemeMenuLabelSource
---@field separator?    keywork.ThemeMenuSeparatorSource

---@class keywork.ThemeSeparatorSource
---@field color?     keywork.ColorRef
---@field thickness? number

---@class keywork.ThemeScrollbarSource
---@field track? keywork.ColorRef
---@field thumb? keywork.ColorRef

---@class keywork.ThemeComponentsSource
---@field button?     keywork.ButtonRecipeSource
---@field text_field? keywork.TextFieldRecipeSource
---@field tag?        keywork.TokenRecipeSource
---@field badge?      keywork.TokenRecipeSource
---@field menu?       keywork.ThemeMenuSource
---@field separator?  keywork.ThemeSeparatorSource
---@field scrollbar?  keywork.ThemeScrollbarSource

---@class keywork.ThemeOverrides
---@field schemes?     table<string, keywork.ThemeSchemeOverride>
---@field text?        table<string, keywork.ThemeTextStyle>
---@field space?       keywork.ThemeScale
---@field font_size?   keywork.ThemeScale
---@field line_height? keywork.ThemeScale
---@field radius?      keywork.ThemeScale
---@field shadow?      table<integer, keywork.ThemeShadowLayer[]>
---@field components?  keywork.ThemeComponentsSource

---@class keywork.ThemeData
---@field schemes     table<string, keywork.ThemeScheme>
---@field text        table<string, keywork.ThemeTextStyle>
---@field space       keywork.ThemeScale
---@field font_size   keywork.ThemeScale
---@field line_height keywork.ThemeScale
---@field radius      keywork.ThemeScale
---@field shadow?     table<integer, keywork.ThemeShadowLayer[]>
---@field components  keywork.ThemeComponentsSource

---@class keywork.ThemeWidgetMenuItem
---@field padding_x?                 number
---@field padding_y?                 number
---@field min_height?                number
---@field radius?                    number
---@field font_size?                 number
---@field line_height?               number
---@field hover_background?          keywork.Color
---@field pressed_background?        keywork.Color
---@field selected_background?       keywork.Color
---@field selected_hover_background? keywork.Color
---@field selected_pressed_background? keywork.Color

---@class keywork.ThemeWidgetMenuLabel
---@field padding_x?   number
---@field padding_y?   number
---@field min_height?  number
---@field font_size?   number
---@field line_height? number
---@field foreground?  keywork.Color

---@class keywork.ThemeWidgetMenuSeparator
---@field color?     keywork.Color
---@field thickness? number
---@field margin?    number
---@field inset?     number

---@class keywork.ThemeWidgetMenu
---@field background?   keywork.Color
---@field border?       keywork.Color
---@field border_width? number
---@field radius?       number
---@field padding?      number
---@field shadow?       keywork.ShadowLayer[]
---@field item?         keywork.ThemeWidgetMenuItem
---@field label?        keywork.ThemeWidgetMenuLabel
---@field separator?    keywork.ThemeWidgetMenuSeparator

---@class keywork.ThemeWidgetSeparator
---@field color?     keywork.Color
---@field thickness? number

---@class keywork.ThemeWidgetScrollbar
---@field track? keywork.Color
---@field thumb? keywork.Color

---@class keywork.ThemeWidgetComponents
---@field button?     keywork.ButtonRecipe
---@field text_field? keywork.TextFieldRecipe
---@field tag?        keywork.TokenRecipe
---@field badge?      keywork.TokenRecipe
---@field menu?       keywork.ThemeWidgetMenu
---@field separator?  keywork.ThemeWidgetSeparator
---@field scrollbar?  keywork.ThemeWidgetScrollbar

---@class keywork.ButtonAppearanceRecipe
---@field background         keywork.Color
---@field foreground         keywork.Color
---@field hover_background?  keywork.Color
---@field pressed_background? keywork.Color

---@class keywork.ButtonSizeRecipe
---@field target      number
---@field icon_size   number
---@field font_size   number
---@field line_height number
---@field gap         number
---@field padding_x   number

---@class keywork.ButtonRecipe
---@field radius         number
---@field focused_border keywork.Color
---@field sizes          table<string, keywork.ButtonSizeRecipe>
---@field appearances    table<string, keywork.ButtonAppearanceRecipe>
---@field selected       keywork.ButtonAppearanceRecipe
---@field disabled       keywork.ButtonAppearanceRecipe
---@field tones          table<string, keywork.ButtonToneRecipe>

---@class keywork.ButtonToneRecipe
---@field foreground         keywork.Color
---@field background         keywork.Color
---@field hover_background   keywork.Color
---@field pressed_background keywork.Color
---@field on_background      keywork.Color

---@class keywork.TextFieldRecipe
---@field padding_x      number
---@field padding_y      number
---@field radius         number
---@field font_size      number
---@field line_height    number
---@field background     keywork.Color
---@field foreground     keywork.Color
---@field placeholder    keywork.Color
---@field border         keywork.Color
---@field focused_border keywork.Color

---@class keywork.TokenRecipe
---@field padding_x   number
---@field padding_y?  number
---@field radius      number
---@field target      number
---@field font_size   number
---@field line_height number
---@field icon_size   number
---@field gap         number
---@field background  keywork.Color
---@field foreground  keywork.Color

---@class keywork.ThemeMenuItem
---@field padding_x                 number
---@field padding_y                 number
---@field min_height                number
---@field radius                    number
---@field font_size                 number
---@field line_height               number
---@field foreground                keywork.Color
---@field disabled_foreground       keywork.Color
---@field hover_background          keywork.Color
---@field pressed_background        keywork.Color
---@field selected_background       keywork.Color
---@field selected_hover_background keywork.Color
---@field selected_pressed_background keywork.Color

---@class keywork.ThemeMenuLabel
---@field padding_x   number
---@field padding_y   number
---@field min_height  number
---@field font_size   number
---@field line_height number
---@field foreground  keywork.Color

---@class keywork.ThemeMenuSeparator
---@field color     keywork.Color
---@field thickness number
---@field margin    number
---@field inset     number

---@class keywork.ThemeMenu
---@field background   keywork.Color
---@field border       keywork.Color
---@field border_width number
---@field radius       number
---@field padding      number
---@field shadow?      keywork.ResolvedShadowLayer[]
---@field item         keywork.ThemeMenuItem
---@field label        keywork.ThemeMenuLabel
---@field separator    keywork.ThemeMenuSeparator

---@class keywork.ThemeSeparator
---@field color     keywork.Color
---@field thickness number

---@class keywork.ThemeScrollbar
---@field track keywork.Color
---@field thumb keywork.Color

---@class keywork.ThemeComponents
---@field button     keywork.ButtonRecipe
---@field text_field keywork.TextFieldRecipe
---@field tag        keywork.TokenRecipe
---@field badge      keywork.TokenRecipe
---@field menu       keywork.ThemeMenu
---@field separator  keywork.ThemeSeparator
---@field scrollbar  keywork.ThemeScrollbar

--- Resolved theme-shaped data accepted by `keywork.theme`. The native bridge
--- supplies defaults for omitted fields, but descendants that read
--- `context.theme` should be given a complete `Theme`. Unlike `ThemeOverrides`,
--- string token references are not resolved.
---@class keywork.ThemeWidgetData
---@field color_scheme? keywork.ResolvedColorScheme
---@field colors?       table<string, keywork.Color>
---@field text?         table<string, keywork.ThemeTextStyle>
---@field space?        keywork.ThemeScale
---@field font_size?    keywork.ThemeScale
---@field line_height?  keywork.ThemeScale
---@field radius?       keywork.ThemeScale
---@field shadow?       table<integer, keywork.ResolvedShadowLayer[]>
---@field components?   keywork.ThemeWidgetComponents

--- Fully resolved themes returned from the default theme or a `ThemeData`
--- produced by `theme_data`. Hand-built `ThemeData` must provide complete
--- component values to uphold these required fields.
---@class keywork.Theme: keywork.ThemeWidgetData
---@field color_scheme keywork.ResolvedColorScheme
---@field colors       table<string, keywork.Color>
---@field text         table<string, keywork.ThemeTextStyle>
---@field space        keywork.ThemeScale
---@field font_size    keywork.ThemeScale
---@field line_height  keywork.ThemeScale
---@field radius       keywork.ThemeScale
---@field shadow       table<integer, keywork.ResolvedShadowLayer[]>
---@field components   keywork.ThemeComponents

---@class keywork.LayerShellMargin
---@field top?    integer
---@field right?  integer
---@field bottom? integer
---@field left?   integer

---@class keywork.LayerShellOptions
---@field layer?          'background' | 'bottom' | 'top' | 'overlay'
---@field anchor?         ('top' | 'bottom' | 'left' | 'right')[]
---@field exclusive_zone? integer
---@field margin?         keywork.LayerShellMargin
---@field keyboard?       'none' | 'exclusive' | 'on-demand' | 'on_demand'
---@field pointer?        'auto' | 'none'

---@class keywork.WindowOptions
---@field id           string
---@field title?       string
---@field width?       number
---@field height?      number | 'content'
---@field output?      string                    Output name from `context.outputs`.
---@field layer_shell? keywork.LayerShellOptions
---@field background_blur? boolean                Blur content behind the full surface when supported.
---@field on_close?    fun()
---@field child        keywork.Widget

---@class keywork.AppBaseOptions
---@field app_id?       string
---@field title?        string
---@field backend?      keywork.Backend
---@field width?        number
---@field height?       number
---@field decorations?  'server' | 'client'
---@field layer_shell?  keywork.LayerShellOptions
---@field background_blur? boolean                Default for windows and their popups.
---@field session_lock? boolean
---@field start?        fun()
---@field stop?         fun()

---@class keywork.AppChildOptions: keywork.AppBaseOptions
---@field child    keywork.Widget
---@field windows? fun(context: keywork.WindowsContext): keywork.WindowOptions[]

---@class keywork.AppWindowsOptions: keywork.AppBaseOptions
---@field windows fun(context: keywork.WindowsContext): keywork.WindowOptions[]
---@field child?  keywork.Widget

---@alias keywork.AppOptions keywork.AppChildOptions | keywork.AppWindowsOptions

---@class keywork.StatefulState<P: table>
---@field props     P
---@field scope     keywork.loop.Scope                                                                 Lifecycle scope, created on first access.
---@field set_state fun(self: keywork.StatefulState<P>, update?: fun(state: keywork.StatefulState<P>))
---@field [string]  any                                                                                State initialization may add arbitrary fields and methods.

---@class keywork.StatefulBuildContext: keywork.BuildContext
---@field theme keywork.Theme

---@class keywork.StatefulSpec<P: table>
---@field init?    fun(self: keywork.StatefulState<P>, props: P)
---@field update?  fun(self: keywork.StatefulState<P>, props: P)
---@field build    fun(self: keywork.StatefulState<P>, context: keywork.StatefulBuildContext): keywork.Widget
---@field dispose? fun(self: keywork.StatefulState<P>)

---@class keywork.StatefulFactory<P: table>
---@operator call(P?): keywork.Widget

---@class keywork.ThemeWidgetOptions
---@field data?  keywork.ThemeWidgetData
---@field theme? keywork.ThemeWidgetData
---@field child  keywork.Widget

---@class keywork.DefaultTextStyleOptions
---@field color?       keywork.Color
---@field size?        number
---@field font_size?   number
---@field line_height? number
---@field child        keywork.Widget

---@class keywork.IconThemeOptions
---@field color?    keywork.Color
---@field size?     number
---@field symbolic? boolean
---@field child     keywork.Widget

---@class keywork.BoxOptions
---@field background?       keywork.Color
---@field border?           keywork.Color
---@field border_width?     number
---@field radius?           number
---@field shadow?           keywork.ShadowLayer[]
---@field min_width?        number
---@field min_height?       number
---@field align?            keywork.Alignment
---@field horizontal_align? keywork.Alignment
---@field vertical_align?   keywork.Alignment

---@class keywork.ContainerStyleOptions: keywork.BoxOptions
---@field padding? number | keywork.EdgeInsets

---@class keywork.ContainerOptions: keywork.ContainerStyleOptions
---@field child keywork.Widget

---@class keywork.GestureDetectorOptions
---@field id?               string
---@field child             keywork.Widget
---@field cursor?           keywork.CursorShape
---@field buttons?          'any' | keywork.PointerButton[]
---@field on_pointer_down?  fun(event: keywork.TapEvent)
---@field on_pointer_up?    fun(event: keywork.TapEvent)
---@field on_pointer_cancel? fun(event: keywork.TapEvent)
---@field on_hover?         fun(hovered: boolean)
---@field on_scroll?        fun(event: keywork.ScrollEvent)

---@class keywork.PressableOptions
---@field id                    string
---@field child                 keywork.Widget
---@field action?               string
---@field disabled?             boolean
---@field hover_background?     keywork.Color
---@field pressed_background?   keywork.Color
---@field focused_border?       keywork.Color
---@field focused_border_width? number
---@field cursor?               keywork.CursorShape
---@field buttons?              'any' | keywork.PointerButton[]
---@field activation?           keywork.ActivationMode Defaults to `release`.
---@field on_activate?          fun(event: keywork.TapEvent)
---@field on_press_start?       fun(event: keywork.TapEvent)
---@field on_press_end?         fun(event: keywork.TapEvent)
---@field on_press_cancel?      fun(event: keywork.TapEvent)
---@field on_hover?             fun(hovered: boolean)
---@field on_scroll?            fun(event: keywork.ScrollEvent)

---@class keywork.PopoverPlacement
---@field edge?      keywork.PopupEdge
---@field alignment? keywork.Alignment
---@field gap?       number

---@class keywork.PopoverOptions
---@field id        string
---@field anchor    keywork.Widget
---@field open?     boolean
---@field placement? keywork.PopoverPlacement
---@field width?    number
---@field height?   number
---@field content   keywork.Widget | fun(context: keywork.BuildContext): keywork.Widget
---@field shadow?   keywork.ShadowLayer[]
---@field on_close? fun()

---@class keywork.FocusOptions
---@field id                 string
---@field child              keywork.Widget
---@field autofocus?         boolean
---@field skip_traversal?    boolean
---@field can_request_focus? boolean
---@field on_focus_change?   fun(focused: boolean)

---@class keywork.FocusScopeOptions
---@field id     string
---@field child  keywork.Widget
---@field modal? boolean

---@class keywork.EditableTextOptions
---@field id                 string
---@field placeholder        string
---@field value?             string
---@field on_change?         fun(value: string)
---@field on_submit?         fun(value: string)
---@field obscured?          boolean
---@field clear_on_submit?   boolean
---@field autofocus?         boolean
---@field background?        keywork.Color
---@field foreground?        keywork.Color
---@field placeholder_color? keywork.Color
---@field border?            keywork.Color
---@field focused_border?    keywork.Color
---@field padding_x?         number
---@field padding_y?         number
---@field radius?            number
---@field font_size?         number
---@field line_height?       number

---@class keywork.TextFieldOptions
---@field id                string
---@field placeholder?      string
---@field value?            string
---@field on_change?        fun(value: string)
---@field on_submit?        fun(value: string)
---@field obscured?         boolean
---@field clear_on_submit?  boolean
---@field autofocus?        boolean

---@class keywork.ScrollViewOptions
---@field id    string
---@field child keywork.Widget
---@field axes? keywork.ScrollAxes

---@class keywork.ListViewOptions
---@field id           string
---@field item_count?  integer                             Defaults to zero.
---@field item_extent? number                              Fixed item height. Omit to lazily measure variable-height items.
---@field reveal_index? integer                            One-based index to reveal.
---@field follow_end?  boolean                             Follow appends while already scrolled to the end.
---@field build_item   fun(index: integer): keywork.Widget

---@class keywork.LinearOptions
---@field children    keywork.Widget[]
---@field spacing?    number
---@field align?      keywork.CrossAxisAlignment
---@field main_align? keywork.MainAxisAlignment

---@class keywork.SizedStyleOptions
---@field width?      number
---@field height?     number
---@field min_width?  number
---@field min_height? number
---@field max_width?  number
---@field max_height? number

---@class keywork.SizedOptions: keywork.SizedStyleOptions
---@field child keywork.Widget

---@class keywork.SeparatorOptions
---@field color?     keywork.Color
---@field thickness? number
---@field axis?      keywork.SeparatorAxis
---@field margin?    number

---@class keywork.ProgressRingOptions
---@field size?      number
---@field color?     keywork.Color
---@field period_ms? integer

---@class keywork.SvgIconOptions
---@field path   string
---@field size?  number
---@field color? keywork.Color

---@class keywork.ImageStyleOptions
---@field size?  number
---@field fit?   keywork.ImageFit
---@field align? keywork.ImageAlignment
---@field cache? keywork.ImageCache

---@class keywork.FileImageOptions: keywork.ImageStyleOptions
---@field path      string
---@field width?    integer Preferred logical width; preserves aspect ratio when height is absent.
---@field height?   integer Preferred logical height; preserves aspect ratio when width is absent.
---@field revision? integer Non-negative cache-busting revision for same-path content changes.

---@class keywork.PixelImageOptions: keywork.ImageStyleOptions
---@field pixels  string | integer[] ARGB32 pixels as native-endian bytes or integers.
---@field width   integer
---@field height  integer
---@field format? 'argb32'

---@alias keywork.ImageOptions keywork.FileImageOptions | keywork.PixelImageOptions

---@class keywork.IconOptions
---@field name      string
---@field size?     number
---@field color?    keywork.Color
---@field symbolic? boolean

---@class keywork.TagOptions
---@field icon?     string
---@field label?    string

---@class keywork.BadgeOptions
---@field icon?  string
---@field label? string

---@class keywork.MenuSurfaceOptions
---@field child keywork.Widget

---@class keywork.MenuItemOptions
---@field id           string
---@field child        keywork.Widget
---@field selected?    boolean
---@field disabled?    boolean
---@field action?      string
---@field on_activate? fun(event: keywork.TapEvent)
---@field on_hover?    fun(hovered: boolean)

---@class keywork.MenuLabelOptions
---@field text?       string
---@field child?      keywork.Widget
---@field color?      keywork.Color
---@field min_height? number
---@field padding?    number | keywork.EdgeInsets

---@class keywork.MenuSeparatorOptions
---@field color?     keywork.Color
---@field thickness? number
---@field margin?    number
---@field inset?     number
---@field axis?      keywork.SeparatorAxis

---@class keywork.PaddingOptions: keywork.EdgeInsets
---@field insets?  number | keywork.EdgeInsets
---@field padding? number | keywork.EdgeInsets
---@field child    keywork.Widget

---@class keywork.ButtonBaseOptions
---@field id          string
---@field size?       'small' | 'medium'
---@field appearance? 'primary' | 'secondary' | 'subtle'
---@field tone?       'danger'
---@field disabled?   boolean
---@field activation? keywork.ActivationMode Defaults to `release`.
---@field action?     string
---@field on_activate? fun(event: keywork.TapEvent)
---@field on_hover?   fun(hovered: boolean)

---@class keywork.ButtonOptions: keywork.ButtonBaseOptions
---@field icon?  string
---@field label? string

---@class keywork.IconButtonOptions: keywork.ButtonBaseOptions
---@field icon string

---@class keywork.ToggleButtonOptions: keywork.ButtonBaseOptions
---@field icon?    string
---@field label?   string
---@field selected boolean

---@class keywork.FlexibleOptions
---@field child keywork.Widget
---@field flex? number

---@class keywork.CenterOptions
---@field child keywork.Widget

---@class keywork.AlignOptions
---@field alignment keywork.Alignment
---@field child keywork.Widget

---@class keywork.ActionsOptions
---@field bindings table<string, fun()>
---@field child    keywork.Widget

---@class keywork.ShortcutsOptions
---@field bindings table<keywork.ShortcutKey, string>
---@field child    keywork.Widget

---@class keywork.App: keywork.AppBaseOptions
---@field type     'app'
---@field child?   keywork.Widget
---@field windows? fun(context: keywork.WindowsContext): keywork.WindowOptions[]

---@class keywork.ActivationTokenOptions
---@field app_id? string

---@class keywork.AppNamespace
---@field quit       fun()
---@field reload     fun()
---@field invalidate fun() Rebuild the window set and all retained window content.
---@field reconcile  fun() Rebuild only the window set, preserving retained content in existing windows.
---@operator call(keywork.AppOptions): keywork.App

---@class keywork.WindowNamespace
---@field start_move               fun(): true?, string?
---@field start_resize             fun(edge: keywork.ResizeEdge): true?, string?
---@field request_activation_token fun(options?: keywork.ActivationTokenOptions): string?, string?
---@operator call(keywork.WindowOptions): keywork.WindowOptions

---@class keywork.ClipboardNamespace
local Clipboard = {}

--- Reads text from the clipboard. Nil without an error means no text is available.
---@return string? text
---@return string? error
function Clipboard.read() end

--- Claims the clipboard selection. Call from an input handler.
---@param text string
---@return true? ok
---@return string? error
function Clipboard.write(text) end

---@class keywork.SessionLockNamespace
local SessionLock = {}

---@return true? ok
---@return string? error
function SessionLock.unlock() end

---@return boolean? locked
---@return string? error
function SessionLock.locked() end

local M = {}

---@type keywork.AppNamespace
M.app = {}

---@type keywork.WindowNamespace
M.window = {}

---@type keywork.ClipboardNamespace
M.clipboard = Clipboard

---@type keywork.SessionLockNamespace
M.session_lock = SessionLock

---@param options? keywork.ThemeOverrides
---@return keywork.ThemeData
function M.theme_data(options) end

---@param theme?           keywork.ThemeData
---@param state_or_scheme? keywork.BuildContext | keywork.ColorScheme
---@return keywork.Theme
function M.resolve_theme(theme, state_or_scheme) end

---@param state  keywork.BuildContext
---@param theme? keywork.ThemeData
---@return keywork.Theme
function M.theme_for(state, theme) end

---@param value  string | number
---@param style? keywork.TextStyle
---@return keywork.Widget
function M.text(value, style) end

---@param key   string
---@param child keywork.Widget
---@return keywork.Widget
function M.keyed(key, child) end

---@generic P: table
---@param spec keywork.StatefulSpec<P>
---@return keywork.StatefulFactory<P>
function M.stateful(spec) end

---@param options keywork.ThemeWidgetOptions
---@return keywork.Widget
function M.theme(options) end

---@param options keywork.DefaultTextStyleOptions
---@return keywork.Widget
function M.default_text_style(options) end

---@param options keywork.IconThemeOptions
---@return keywork.Widget
function M.icon_theme(options) end

---@param options keywork.ContainerOptions
---@return keywork.Widget
function M.container(options) end

---@param options keywork.GestureDetectorOptions
---@return keywork.Widget
function M.gesture_detector(options) end

---@param options keywork.PressableOptions
---@return keywork.Widget
function M.pressable(options) end

---@param options keywork.PopoverOptions
---@return keywork.Widget
function M.popover(options) end

---@param options keywork.FocusOptions
---@return keywork.Widget
function M.focus(options) end

---@param options keywork.FocusScopeOptions
---@return keywork.Widget
function M.focus_scope(options) end

---@param options keywork.EditableTextOptions
---@return keywork.Widget
function M.editable_text(options) end

---@param options keywork.TextFieldOptions
---@return keywork.Widget
function M.text_field(options) end

---@param options keywork.ScrollViewOptions
---@return keywork.Widget
function M.scroll_view(options) end

---@param options keywork.ListViewOptions
---@return keywork.Widget
function M.list_view(options) end

---@param options keywork.LinearOptions
---@return keywork.Widget
function M.column(options) end

---@param options keywork.LinearOptions
---@return keywork.Widget
function M.row(options) end

---@param options keywork.FlexibleOptions
---@return keywork.Widget
function M.expanded(options) end

---@param options keywork.FlexibleOptions
---@return keywork.Widget
function M.flexible(options) end

---@param options keywork.SizedOptions
---@return keywork.Widget
function M.sized_box(options) end

---@param options? keywork.SeparatorOptions
---@return keywork.Widget
function M.separator(options) end

---@param flex? number
---@return keywork.Widget
function M.spacer(flex) end

---@param options? keywork.ProgressRingOptions
---@return keywork.Widget
function M.progress_ring(options) end

---@param options keywork.SvgIconOptions
---@return keywork.Widget
function M.svg_icon(options) end

---@param options keywork.ImageOptions
---@return keywork.Widget
function M.image(options) end

---@param options keywork.IconOptions
---@return keywork.Widget
function M.icon(options) end

---@param options keywork.MenuSurfaceOptions
---@return keywork.Widget
function M.menu_surface(options) end

---@param options keywork.MenuItemOptions
---@return keywork.Widget
function M.menu_item(options) end

---@param options keywork.MenuLabelOptions
---@return keywork.Widget
function M.menu_label(options) end

---@param options? keywork.MenuSeparatorOptions
---@return keywork.Widget
function M.menu_separator(options) end

---@param options keywork.IconButtonOptions
---@return keywork.Widget
function M.icon_button(options) end

---@param options keywork.PaddingOptions
---@return keywork.Widget
function M.padding(options) end

---@param options keywork.CenterOptions
---@return keywork.Widget
function M.center(options) end

---@param options keywork.AlignOptions
---@return keywork.Widget
function M.align(options) end

---@param options keywork.ButtonOptions
---@return keywork.Widget
function M.button(options) end

---@param options keywork.ToggleButtonOptions
---@return keywork.Widget
function M.toggle_button(options) end

---@param options keywork.TagOptions
---@return keywork.Widget
function M.tag(options) end

---@param options keywork.BadgeOptions
---@return keywork.Widget
function M.badge(options) end

---@param options keywork.ActionsOptions
---@return keywork.Widget
function M.actions(options) end

---@param options keywork.ShortcutsOptions
---@return keywork.Widget
function M.shortcuts(options) end

return M
