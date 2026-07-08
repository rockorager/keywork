import { createRequire } from 'node:module'

export type Color = number
export type HandlerId = number | bigint
export type Handler = HandlerId | ((payload?: unknown, event?: unknown) => void)
export type TextRole = 'body' | 'label' | 'title' | number
export type CrossAxisAlignment = 'start' | 'center' | 'end' | 'stretch' | number
export type MainAxisAlignment = 'start' | 'center' | 'end' | 'space-between' | 'space-around' | 'space-evenly' | 'space_between' | 'space_around' | 'space_evenly' | number
export type Alignment = 'start' | 'center' | 'end' | number
export type FlexFit = 'tight' | 'loose' | number
export type ScrollAxes = 'vertical' | 'horizontal' | 'both' | number
export type ClickActivation = 'press' | 'release'
export type ShortcutKey = 'enter' | 'space' | 'backspace' | 'escape' | 'up' | 'down' | number

export interface Insets {
  all?: number
  x?: number
  y?: number
  left?: number
  top?: number
  right?: number
  bottom?: number
}

interface BaseWidget {
  kind: string
  key?: string
}

export interface Text extends BaseWidget {
  kind: 'text'
  value: string
  color?: Color
  fontSize?: number
  font_size?: number
  role?: TextRole
}

export interface Children extends BaseWidget {
  kind: 'row' | 'column'
  children: Widget[]
  gap?: number
  spacing?: number
  align?: CrossAxisAlignment
  crossAlign?: CrossAxisAlignment
  cross_align?: CrossAxisAlignment
  mainAlign?: MainAxisAlignment
  main_align?: MainAxisAlignment
}

export interface Container extends BaseWidget {
  kind: 'container'
  child: Widget
  background?: Color
  border?: Color
  borderWidth?: number
  border_width?: number
  radius?: number
  minWidth?: number
  min_width?: number
  minHeight?: number
  min_height?: number
  horizontalAlign?: Alignment
  horizontal_align?: Alignment
  verticalAlign?: Alignment
  vertical_align?: Alignment
  align?: Alignment
  padding?: number | Insets
}

export interface Padding extends BaseWidget {
  kind: 'padding'
  child: Widget
  insets: number | Insets
}

export interface Spacer extends BaseWidget {
  kind: 'spacer'
  flex?: number
}

export interface Flexible extends BaseWidget {
  kind: 'flexible'
  child: Widget
  flex?: number
  fit?: FlexFit
}

export interface Center extends BaseWidget {
  kind: 'center'
  child: Widget
}

export interface SizedBox extends BaseWidget {
  kind: 'sized_box'
  child: Widget
  width?: number
  height?: number
  minWidth?: number
  min_width?: number
  minHeight?: number
  min_height?: number
  maxWidth?: number
  max_width?: number
  maxHeight?: number
  max_height?: number
}

export interface GestureDetector extends BaseWidget {
  kind: 'gesture_detector'
  id?: string
  handler?: Handler
  onTap?: Handler
  on_tap?: Handler
  onTapDown?: Handler
  on_tap_down?: Handler
  activation?: ClickActivation
  hoverBackground?: Color
  hover_background?: Color
  child: Widget
}

export interface FilledButton extends BaseWidget {
  kind: 'filled_button'
  id?: string
  handler?: Handler | null
  onTap?: Handler
  on_tap?: Handler
  onTapDown?: Handler
  on_tap_down?: Handler
  activation?: ClickActivation
  child: Widget
}

export interface Image extends BaseWidget {
  kind: 'image'
  resource: HandlerId
  width?: number
  height?: number
  tint?: Color
  color?: Color
}

export interface Icon extends BaseWidget {
  kind: 'icon'
  name: string
  size?: number
  color?: Color
}

export interface IconTheme extends BaseWidget {
  kind: 'icon_theme'
  color?: Color
  size?: number
  child: Widget
}

export interface DefaultTextStyle extends BaseWidget {
  kind: 'default_text_style'
  color?: Color
  fontSize?: number
  font_size?: number
  size?: number
  child: Widget
}

export interface Theme extends BaseWidget {
  kind: 'theme'
  data?: unknown
  child: Widget
}

export interface SingleChildScrollView extends BaseWidget {
  kind: 'single_child_scroll_view'
  id?: string
  axes?: ScrollAxes
  child: Widget
}

export interface Focus extends BaseWidget {
  kind: 'focus'
  id?: string
  child: Widget
  autofocus?: boolean
  skipTraversal?: boolean
  skip_traversal?: boolean
  canRequestFocus?: boolean
  can_request_focus?: boolean
  onFocusChange?: Handler
  on_focus_change?: Handler
}

export interface FocusScope extends BaseWidget {
  kind: 'focus_scope'
  id?: string
  child: Widget
  modal?: boolean
}

export interface TextField extends BaseWidget {
  kind: 'text_field'
  id?: string
  value?: string
  placeholder?: string
  onChanged?: Handler
  on_change?: Handler
  autofocus?: boolean
}

export interface ShortcutBinding {
  key: ShortcutKey
  handler: Handler
}

export interface Shortcuts extends BaseWidget {
  kind: 'shortcuts'
  bindings: ShortcutBinding[]
  child: Widget
}

export type Widget = string | number | Text | Children | Container | Padding | Spacer | Flexible | Center | SizedBox | GestureDetector | FilledButton | Image | Icon | IconTheme | DefaultTextStyle | Theme | SingleChildScrollView | Focus | FocusScope | TextField | Shortcuts

export interface EncodedDocument {
  bytes: Uint8Array
  callbacks: Map<bigint, NonNullable<Extract<Handler, Function>>>
}

const textEncoder = new TextEncoder()
const HEADER_SIZE = 48
const WIDGET_SIZE = 80
const BINDING_SIZE = 16
const KEY_FLAG = 0x8000

const textRoles = { body: 0, label: 1, title: 2 } as const
const crossAlignments = { start: 0, center: 1, end: 2, stretch: 3 } as const
const mainAlignments = { start: 0, center: 1, end: 2, 'space-between': 3, space_between: 3, 'space-around': 4, space_around: 4, 'space-evenly': 5, space_evenly: 5 } as const
const alignments = { start: 0, center: 1, end: 2 } as const
const flexFits = { tight: 0, loose: 1 } as const
const scrollAxes = { vertical: 0, horizontal: 1, both: 2 } as const
const shortcutKeys = { enter: 0, space: 1, backspace: 2, escape: 3, up: 4, down: 5 } as const

function enumValue(map: Record<string, number>, value: string | number | undefined, fallback = 0): number {
  if (value == null) return fallback
  if (typeof value === 'number') return value
  const result = map[value]
  if (result == null) throw new Error(`unknown enum value: ${value}`)
  return result
}

function option<T>(options: Record<string, T | undefined>, snakeName: string, camelName: string): T | undefined {
  return options[snakeName] ?? options[camelName]
}

function childFromArgs<T extends Record<string, unknown>>(options: T | Widget | undefined, child?: Widget): [T, Widget] {
  if (child !== undefined) return [(options ?? {}) as T, child]
  if (options && typeof options === 'object' && !Array.isArray(options) && !('kind' in options) && 'child' in options) {
    return [options as T, (options as T & { child: Widget }).child]
  }
  return [{} as T, options as Widget]
}

function childArray(children: Widget[] | undefined): Widget[] {
  return Array.isArray(children) ? children : []
}

function insets(value: number | Insets | undefined): [number, number, number, number] {
  if (typeof value === 'number') return [value, value, value, value]
  const source = value ?? {}
  const all = source.all ?? 0
  const x = source.x ?? all
  const y = source.y ?? all
  return [source.left ?? x, source.top ?? y, source.right ?? x, source.bottom ?? y]
}

function argb(a: number, r: number, g: number, b: number): Color {
  return (((a & 0xff) << 24) >>> 0) + ((r & 0xff) << 16) + ((g & 0xff) << 8) + (b & 0xff)
}

function widget<T extends BaseWidget>(kind: T['kind'], fields: Omit<T, 'kind'>): T {
  return { ...fields, kind } as T
}

export const ui = {
  argb,

  text(value: string | number, options: Partial<Omit<Text, 'kind' | 'value'>> = {}): Text {
    return widget<Text>('text', {
      value: String(value ?? ''),
      key: options.key,
      color: options.color,
      font_size: options.font_size ?? options.fontSize,
      role: options.role,
    })
  },

  label(value: string | number, options: Partial<Omit<Text, 'kind' | 'value'>> = {}): Text {
    return ui.text(value, { ...options, role: options.role ?? 'label' })
  },

  row(options: Partial<Omit<Children, 'kind' | 'children'>> & { children?: Widget[] } | Widget[] = {}): Children {
    const source = Array.isArray(options) ? { children: options } : options
    return widget<Children>('row', {
      key: source.key,
      children: source.children ?? [],
      gap: source.gap ?? source.spacing,
      cross_align: source.cross_align ?? source.crossAlign ?? source.align,
      main_align: source.main_align ?? source.mainAlign,
    })
  },

  column(options: Partial<Omit<Children, 'kind' | 'children'>> & { children?: Widget[] } | Widget[] = {}): Children {
    const source = Array.isArray(options) ? { children: options } : options
    return widget<Children>('column', {
      key: source.key,
      children: source.children ?? [],
      gap: source.gap ?? source.spacing,
      cross_align: source.cross_align ?? source.crossAlign ?? source.align,
      main_align: source.main_align ?? source.mainAlign,
    })
  },

  container(options: Partial<Omit<Container, 'kind' | 'child'>> | Widget = {}, child?: Widget): Container {
    const [source, actualChild] = childFromArgs<Partial<Omit<Container, 'kind' | 'child'>>>(options, child)
    return widget<Container>('container', {
      key: source.key,
      child: actualChild,
      background: source.background,
      border: source.border,
      border_width: source.border_width ?? source.borderWidth,
      radius: source.radius,
      min_width: source.min_width ?? source.minWidth,
      min_height: source.min_height ?? source.minHeight,
      horizontal_align: source.horizontal_align ?? source.horizontalAlign ?? source.align,
      vertical_align: source.vertical_align ?? source.verticalAlign ?? source.align,
      padding: source.padding,
    })
  },

  padding(options: Partial<Omit<Padding, 'kind' | 'child' | 'insets'>> & { insets?: number | Insets; padding?: number | Insets } | Widget, child?: Widget): Padding {
    const [source, actualChild] = childFromArgs<Partial<Omit<Padding, 'kind' | 'child' | 'insets'>> & { insets?: number | Insets; padding?: number | Insets }>(options, child)
    return widget<Padding>('padding', { key: source.key, insets: source.insets ?? source.padding ?? 0, child: actualChild })
  },

  center(options: Partial<Omit<Center, 'kind' | 'child'>> | Widget, child?: Widget): Center {
    const [source, actualChild] = childFromArgs<Partial<Omit<Center, 'kind' | 'child'>>>(options, child)
    return widget<Center>('center', { key: source.key, child: actualChild })
  },

  spacer(options: Partial<Omit<Spacer, 'kind'>> | number = {}): Spacer {
    const source = typeof options === 'number' ? { flex: options } : options
    return widget<Spacer>('spacer', { key: source.key, flex: source.flex ?? 1 })
  },

  flexible(options: Partial<Omit<Flexible, 'kind' | 'child'>> | Widget, child?: Widget): Flexible {
    const [source, actualChild] = childFromArgs<Partial<Omit<Flexible, 'kind' | 'child'>>>(options, child)
    return widget<Flexible>('flexible', { key: source.key, child: actualChild, flex: source.flex ?? 1, fit: source.fit })
  },

  expanded(options: Partial<Omit<Flexible, 'kind' | 'child'>> | Widget, child?: Widget): Flexible {
    const [source, actualChild] = childFromArgs<Partial<Omit<Flexible, 'kind' | 'child'>>>(options, child)
    return ui.flexible({ ...source, fit: source.fit ?? 'tight' }, actualChild)
  },

  sizedBox(options: Partial<Omit<SizedBox, 'kind' | 'child'>> | Widget, child?: Widget): SizedBox {
    const [source, actualChild] = childFromArgs<Partial<Omit<SizedBox, 'kind' | 'child'>>>(options, child)
    return widget<SizedBox>('sized_box', {
      key: source.key,
      child: actualChild,
      width: source.width,
      height: source.height,
      min_width: source.min_width ?? source.minWidth,
      min_height: source.min_height ?? source.minHeight,
      max_width: source.max_width ?? source.maxWidth,
      max_height: source.max_height ?? source.maxHeight,
    })
  },

  filledButton(options: Partial<Omit<FilledButton, 'kind' | 'child'>> | Widget, child?: Widget): FilledButton {
    const [source, actualChild] = childFromArgs<Partial<Omit<FilledButton, 'kind' | 'child'>>>(options, child)
    const onTap = source.on_tap ?? source.onTap
    const onTapDown = source.on_tap_down ?? source.onTapDown
    return widget<FilledButton>('filled_button', {
      key: source.key,
      id: source.id,
      handler: source.handler ?? onTap ?? onTapDown ?? null,
      activation: source.activation ?? (onTap ? 'release' : 'press'),
      child: actualChild,
    })
  },

  gestureDetector(options: Partial<Omit<GestureDetector, 'kind' | 'child'>> | Widget, child?: Widget): GestureDetector {
    const [source, actualChild] = childFromArgs<Partial<Omit<GestureDetector, 'kind' | 'child'>>>(options, child)
    const onTap = source.on_tap ?? source.onTap
    const onTapDown = source.on_tap_down ?? source.onTapDown
    return widget<GestureDetector>('gesture_detector', {
      key: source.key,
      id: source.id,
      handler: source.handler ?? onTap ?? onTapDown,
      activation: source.activation ?? (onTapDown ? 'press' : 'release'),
      hover_background: source.hover_background ?? source.hoverBackground,
      child: actualChild,
    })
  },

  image(options: Partial<Omit<Image, 'kind'>>): Image {
    return widget<Image>('image', { ...options, tint: options.tint ?? options.color, resource: options.resource ?? 0 })
  },

  icon(name: string, options: Partial<Omit<Icon, 'kind' | 'name'>> = {}): Icon {
    return widget<Icon>('icon', { key: options.key, name, size: options.size, color: options.color })
  },

  iconTheme(options: Omit<IconTheme, 'kind'>): IconTheme {
    return widget<IconTheme>('icon_theme', options)
  },

  defaultTextStyle(options: Partial<Omit<DefaultTextStyle, 'kind' | 'child'>> | Widget, child?: Widget): DefaultTextStyle {
    const [source, actualChild] = childFromArgs<Partial<Omit<DefaultTextStyle, 'kind' | 'child'>>>(options, child)
    return widget<DefaultTextStyle>('default_text_style', { key: source.key, color: source.color, font_size: source.font_size ?? source.fontSize ?? source.size, child: actualChild })
  },

  theme(options: Omit<Theme, 'kind'>): Theme {
    return widget<Theme>('theme', options)
  },

  singleChildScrollView(options: Partial<Omit<SingleChildScrollView, 'kind' | 'child'>> | Widget, child?: Widget): SingleChildScrollView {
    const [source, actualChild] = childFromArgs<Partial<Omit<SingleChildScrollView, 'kind' | 'child'>>>(options, child)
    return widget<SingleChildScrollView>('single_child_scroll_view', { key: source.key, id: source.id, axes: source.axes, child: actualChild })
  },

  focus(options: Partial<Omit<Focus, 'kind' | 'child'>> | Widget, child?: Widget): Focus {
    const [source, actualChild] = childFromArgs<Partial<Omit<Focus, 'kind' | 'child'>>>(options, child)
    return widget<Focus>('focus', {
      key: source.key,
      id: source.id,
      child: actualChild,
      autofocus: source.autofocus,
      skip_traversal: source.skip_traversal ?? source.skipTraversal,
      can_request_focus: source.can_request_focus ?? source.canRequestFocus,
      on_focus_change: source.on_focus_change ?? source.onFocusChange,
    })
  },

  focusScope(options: Partial<Omit<FocusScope, 'kind' | 'child'>> | Widget, child?: Widget): FocusScope {
    const [source, actualChild] = childFromArgs<Partial<Omit<FocusScope, 'kind' | 'child'>>>(options, child)
    return widget<FocusScope>('focus_scope', { key: source.key, id: source.id, child: actualChild, modal: source.modal })
  },

  textField(options: Partial<Omit<TextField, 'kind'>> = {}): TextField {
    return widget<TextField>('text_field', { key: options.key, id: options.id, value: options.value ?? '', placeholder: options.placeholder ?? '', on_change: options.on_change ?? options.onChanged, autofocus: options.autofocus })
  },

  shortcuts(options: Omit<Shortcuts, 'kind'>): Shortcuts {
    return widget<Shortcuts>('shortcuts', options)
  },
}

export const Text = ui.text
export const Row = ui.row
export const Column = ui.column
export const Container = ui.container
export const Padding = ui.padding
export const Center = ui.center
export const Spacer = ui.spacer
export const Flexible = ui.flexible
export const Expanded = ui.expanded
export const SizedBox = ui.sizedBox
export const FilledButton = ui.filledButton
export const GestureDetector = ui.gestureDetector
export const ImageWidget = ui.image
export const Icon = ui.icon
export const IconTheme = ui.iconTheme
export const DefaultTextStyle = ui.defaultTextStyle
export const Theme = ui.theme
export const SingleChildScrollView = ui.singleChildScrollView
export const Focus = ui.focus
export const FocusScope = ui.focusScope
export const TextField = ui.textField
export const Shortcuts = ui.shortcuts

interface RecordFields {
  tag?: number
  flags?: number
  firstChild?: number
  childCount?: number
  keyOffset?: number
  keyLen?: number
  primaryOffset?: number
  primaryLen?: number
  id0?: HandlerId
  a?: number
  b?: number
  c?: number
  d?: number
  color0?: number
  color1?: number
  extra0?: number
  extra1?: number
  extra2?: number
  extra3?: number
}

class Encoder {
  private widgets: RecordFields[] = []
  private children: number[] = []
  private bindings: { key: number; handler: bigint }[] = []
  private strings: Uint8Array[] = []
  private stringSize = 0
  private callbacks = new Map<bigint, NonNullable<Extract<Handler, Function>>>()
  private nextHandler = 1n

  encode(root: Widget): EncodedDocument {
    const rootIndex = this.encodeNode(root)
    const widgetCount = this.widgets.length
    const childCount = this.children.length
    const bindingCount = this.bindings.length
    const childOffset = HEADER_SIZE + widgetCount * WIDGET_SIZE
    const bindingOffset = childOffset + childCount * 4
    const stringOffset = bindingOffset + bindingCount * BINDING_SIZE
    const totalSize = stringOffset + this.stringSize
    const bytes = new Uint8Array(totalSize)
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)

    bytes.set([0x4b, 0x57, 0x57, 0x30], 0)
    view.setUint16(4, 0, true)
    view.setUint16(6, HEADER_SIZE, true)
    view.setUint32(8, totalSize, true)
    view.setUint32(12, rootIndex, true)
    view.setUint32(16, widgetCount, true)
    view.setUint32(20, childCount, true)
    view.setUint32(24, bindingCount, true)
    view.setUint32(28, this.stringSize, true)

    for (const [index, record] of this.widgets.entries()) {
      const offset = HEADER_SIZE + index * WIDGET_SIZE
      view.setUint16(offset, record.tag ?? 0, true)
      view.setUint16(offset + 2, record.flags ?? 0, true)
      view.setUint32(offset + 4, record.firstChild ?? 0, true)
      view.setUint32(offset + 8, record.childCount ?? 0, true)
      view.setUint32(offset + 12, record.keyOffset ?? 0, true)
      view.setUint32(offset + 16, record.keyLen ?? 0, true)
      view.setUint32(offset + 20, record.primaryOffset ?? 0, true)
      view.setUint32(offset + 24, record.primaryLen ?? 0, true)
      view.setBigUint64(offset + 28, toU64(record.id0 ?? 0), true)
      this.setF32(view, offset + 36, record.a)
      this.setF32(view, offset + 40, record.b)
      this.setF32(view, offset + 44, record.c)
      this.setF32(view, offset + 48, record.d)
      view.setUint32(offset + 52, record.color0 ?? 0, true)
      view.setUint32(offset + 56, record.color1 ?? 0, true)
      view.setUint32(offset + 60, record.extra0 ?? 0, true)
      view.setUint32(offset + 64, record.extra1 ?? 0, true)
      view.setUint32(offset + 68, record.extra2 ?? 0, true)
      view.setUint32(offset + 72, record.extra3 ?? 0, true)
    }

    for (const [index, child] of this.children.entries()) view.setUint32(childOffset + index * 4, child, true)
    for (const [index, binding] of this.bindings.entries()) {
      const offset = bindingOffset + index * BINDING_SIZE
      view.setUint32(offset, binding.key, true)
      view.setBigUint64(offset + 8, binding.handler, true)
    }

    let writeOffset = stringOffset
    for (const chunk of this.strings) {
      bytes.set(chunk, writeOffset)
      writeOffset += chunk.length
    }

    return { bytes, callbacks: this.callbacks }
  }

  private setF32(view: DataView, offset: number, value: number | undefined): void {
    if (value == null) return
    view.setFloat32(offset, value, true)
  }

  private string(value: unknown): [number, number] {
    if (value == null) return [0, 0]
    const bytes = textEncoder.encode(String(value))
    const offset = this.stringSize
    this.strings.push(bytes)
    this.stringSize += bytes.length
    return [offset, bytes.length]
  }

  private handler(value: Handler | null | undefined, optional = false): bigint {
    if (value == null) {
      if (optional) return 0n
      throw new Error('widget requires a handler')
    }
    if (typeof value === 'function') {
      const id = this.nextHandler
      this.nextHandler += 1n
      this.callbacks.set(id, value as NonNullable<Extract<Handler, Function>>)
      return id
    }
    return toU64(value)
  }

  private record(tag: number, fields: RecordFields = {}): [number, RecordFields] {
    const index = this.widgets.length
    const record = { ...fields, tag }
    this.widgets.push(record)
    return [index, record]
  }

  private withKey(node: BaseWidget, record: RecordFields): void {
    if (node.key == null) return
    record.flags = (record.flags ?? 0) | KEY_FLAG
    const [offset, length] = this.string(node.key)
    record.keyOffset = offset
    record.keyLen = length
  }

  private childrenRange(nodes: Widget[], context: EncodeContext = {}): [number, number] {
    const direct = nodes.map((node) => this.encodeNode(node, context))
    const first = this.children.length
    this.children.push(...direct)
    return [first, direct.length]
  }

  private oneChild(node: Widget | undefined, context: EncodeContext = {}): [number, number] {
    if (node == null) throw new Error('widget requires a child')
    return this.childrenRange([node], context)
  }

  private encodeNode(input: Widget, context: EncodeContext = {}): number {
    const node = normalize(input)
    if (node.kind === 'theme') return this.encodeNode(node.child, context)
    if (node.kind === 'icon_theme') return this.encodeNode(node.child, { iconColor: node.color ?? context.iconColor, iconSize: node.size ?? context.iconSize })

    let index: number
    let record: RecordFields

    switch (node.kind) {
      case 'text': {
        ;[index, record] = this.record(1, { extra0: enumValue(textRoles, node.role, 0) })
        const [offset, length] = this.string(node.value)
        record.primaryOffset = offset
        record.primaryLen = length
        if (node.color != null) {
          record.flags = (record.flags ?? 0) | 1
          record.color0 = node.color
        }
        const fontSize = node.font_size ?? node.fontSize
        if (fontSize != null) {
          record.flags = (record.flags ?? 0) | 2
          record.a = fontSize
        }
        break
      }
      case 'row':
      case 'column': {
        ;[index, record] = this.record(node.kind === 'row' ? 2 : 3, {
          a: node.gap ?? node.spacing ?? 0,
          extra0: enumValue(crossAlignments, node.cross_align ?? node.crossAlign ?? node.align, 0),
          extra1: enumValue(mainAlignments, node.main_align ?? node.mainAlign, 0),
        })
        ;[record.firstChild, record.childCount] = this.childrenRange(childArray(node.children), context)
        break
      }
      case 'container': {
        let child = node.child
        if (node.padding != null) child = ui.padding({ padding: node.padding }, child)
        ;[index, record] = this.record(4, {
          color0: node.background ?? 0,
          a: node.border_width ?? node.borderWidth ?? 1,
          b: node.radius ?? 0,
          c: node.min_width ?? node.minWidth ?? 0,
          d: node.min_height ?? node.minHeight ?? 0,
          extra0: enumValue(alignments, node.horizontal_align ?? node.horizontalAlign ?? node.align, 0),
          extra1: enumValue(alignments, node.vertical_align ?? node.verticalAlign ?? node.align, 0),
        })
        if (node.border != null) {
          record.flags = (record.flags ?? 0) | 1
          record.color1 = node.border
        }
        ;[record.firstChild, record.childCount] = this.oneChild(child, context)
        break
      }
      case 'padding': {
        const [left, top, right, bottom] = insets(node.insets)
        ;[index, record] = this.record(5, { a: left, b: top, c: right, d: bottom })
        ;[record.firstChild, record.childCount] = this.oneChild(node.child, context)
        break
      }
      case 'spacer': {
        ;[index, record] = this.record(6, { a: node.flex ?? 1 })
        break
      }
      case 'flexible': {
        ;[index, record] = this.record(7, { a: node.flex ?? 1, extra0: enumValue(flexFits, node.fit, 0) })
        ;[record.firstChild, record.childCount] = this.oneChild(node.child, context)
        break
      }
      case 'gesture_detector': {
        const handler = node.handler ?? node.on_tap ?? node.onTap ?? node.on_tap_down ?? node.onTapDown
        ;[index, record] = this.record(8, { id0: this.handler(handler), flags: node.activation === 'press' ? 2 : 0 })
        const [offset, length] = this.string(node.id ?? `gesture-detector-${record.id0}`)
        record.primaryOffset = offset
        record.primaryLen = length
        const hoverBackground = node.hover_background ?? node.hoverBackground
        if (hoverBackground != null) {
          record.flags = (record.flags ?? 0) | 1
          record.color0 = hoverBackground
        }
        ;[record.firstChild, record.childCount] = this.oneChild(node.child, context)
        break
      }
      case 'center': {
        ;[index, record] = this.record(9)
        ;[record.firstChild, record.childCount] = this.oneChild(node.child, context)
        break
      }
      case 'sized_box': {
        ;[index, record] = this.record(10, { c: node.min_width ?? node.minWidth ?? 0, d: node.min_height ?? node.minHeight ?? 0 })
        if (node.width != null) {
          record.flags = (record.flags ?? 0) | 1
          record.a = node.width
        }
        if (node.height != null) {
          record.flags = (record.flags ?? 0) | 2
          record.b = node.height
        }
        const maxWidth = node.max_width ?? node.maxWidth
        const maxHeight = node.max_height ?? node.maxHeight
        if (maxWidth != null) {
          record.flags = (record.flags ?? 0) | 4
          record.extra0 = f32Bits(maxWidth)
        }
        if (maxHeight != null) {
          record.flags = (record.flags ?? 0) | 8
          record.extra1 = f32Bits(maxHeight)
        }
        ;[record.firstChild, record.childCount] = this.oneChild(node.child, context)
        break
      }
      case 'image': {
        ;[index, record] = this.record(11, { id0: node.resource })
        if (node.width != null) {
          record.flags = (record.flags ?? 0) | 1
          record.a = node.width
        }
        if (node.height != null) {
          record.flags = (record.flags ?? 0) | 2
          record.b = node.height
        }
        const tint = node.tint ?? node.color
        if (tint != null) {
          record.flags = (record.flags ?? 0) | 4
          record.color0 = tint
        }
        break
      }
      case 'icon': {
        ;[index, record] = this.record(12, { a: node.size ?? context.iconSize ?? 16 })
        const [offset, length] = this.string(node.name)
        record.primaryOffset = offset
        record.primaryLen = length
        const color = node.color ?? context.iconColor
        if (color != null) {
          record.flags = (record.flags ?? 0) | 1
          record.color0 = color
        }
        break
      }
      case 'single_child_scroll_view': {
        ;[index, record] = this.record(13, { extra0: enumValue(scrollAxes, node.axes, 0) })
        const [offset, length] = this.string(node.id ?? 'scroll')
        record.primaryOffset = offset
        record.primaryLen = length
        ;[record.firstChild, record.childCount] = this.oneChild(node.child, context)
        break
      }
      case 'focus': {
        let flags = 0
        if (node.autofocus) flags |= 1
        if (node.skip_traversal ?? node.skipTraversal) flags |= 2
        if (node.can_request_focus ?? node.canRequestFocus ?? true) flags |= 4
        ;[index, record] = this.record(14, { flags, id0: this.handler(node.on_focus_change ?? node.onFocusChange, true) })
        const [offset, length] = this.string(node.id ?? 'focus')
        record.primaryOffset = offset
        record.primaryLen = length
        ;[record.firstChild, record.childCount] = this.oneChild(node.child, context)
        break
      }
      case 'focus_scope': {
        ;[index, record] = this.record(15, { flags: node.modal ? 1 : 0 })
        const [offset, length] = this.string(node.id ?? 'scope')
        record.primaryOffset = offset
        record.primaryLen = length
        ;[record.firstChild, record.childCount] = this.oneChild(node.child, context)
        break
      }
      case 'text_field': {
        ;[index, record] = this.record(16, { flags: node.autofocus ? 1 : 0, id0: this.handler(node.on_change ?? node.onChanged, true) })
        const [offset, length] = this.string(node.id ?? 'input')
        record.primaryOffset = offset
        record.primaryLen = length
        ;[record.extra0, record.extra1] = this.string(node.value ?? '')
        ;[record.extra2, record.extra3] = this.string(node.placeholder ?? '')
        break
      }
      case 'shortcuts': {
        const first = this.bindings.length
        for (const binding of node.bindings ?? []) {
          this.bindings.push({ key: enumValue(shortcutKeys, binding.key, 0), handler: this.handler(binding.handler) })
        }
        ;[index, record] = this.record(17, { extra0: first, extra1: this.bindings.length - first })
        ;[record.firstChild, record.childCount] = this.oneChild(node.child, context)
        break
      }
      case 'default_text_style': {
        ;[index, record] = this.record(18)
        if (node.color != null) {
          record.flags = (record.flags ?? 0) | 1
          record.color0 = node.color
        }
        const fontSize = node.font_size ?? node.fontSize ?? node.size
        if (fontSize != null) {
          record.flags = (record.flags ?? 0) | 2
          record.a = fontSize
        }
        ;[record.firstChild, record.childCount] = this.oneChild(node.child, context)
        break
      }
      case 'filled_button': {
        const handler = node.handler ?? node.on_tap ?? node.onTap ?? node.on_tap_down ?? node.onTapDown
        ;[index, record] = this.record(19, { id0: this.handler(handler, true), flags: node.activation === 'release' ? 1 : 0 })
        const [offset, length] = this.string(node.id ?? `filled-button-${record.id0}`)
        record.primaryOffset = offset
        record.primaryLen = length
        ;[record.firstChild, record.childCount] = this.oneChild(node.child, context)
        break
      }
      default:
        throw new Error(`unknown widget kind: ${(node as BaseWidget).kind}`)
    }

    this.withKey(node, record)
    return index
  }
}

interface EncodeContext {
  iconColor?: Color
  iconSize?: number
}

function normalize(input: Widget): Exclude<Widget, string | number> {
  if (typeof input === 'string' || typeof input === 'number') return ui.text(input)
  if (!input || typeof input !== 'object' || !('kind' in input)) throw new Error('expected widget')
  return input
}

function toU64(value: HandlerId): bigint {
  const result = typeof value === 'bigint' ? value : BigInt(value)
  if (result < 0n || result > 0xffff_ffff_ffff_ffffn) throw new Error(`u64 out of range: ${value}`)
  return result
}

const f32Scratch = new ArrayBuffer(4)
const f32View = new DataView(f32Scratch)
function f32Bits(value: number): number {
  f32View.setFloat32(0, value, true)
  return f32View.getUint32(0, true)
}

export function encode(root: Widget): EncodedDocument {
  return new Encoder().encode(root)
}

export const EventKind = {
  handler: 1,
  configured: 2,
  closed: 3,
  appearanceChanged: 4,
  documentRetired: 5,
} as const

export type EventKindValue = (typeof EventKind)[keyof typeof EventKind]
export type Backend = 'auto' | 'cpu' | 'shm' | 'wayland_shm' | 'vulkan' | 'headless' | number
export type Layer = 'background' | 'bottom' | 'top' | 'overlay' | number
export type LayerAnchor = 'top' | 'bottom' | 'left' | 'right'
export type KeyboardInteractivity = 'none' | 'exclusive' | 'on_demand' | 'on-demand' | number

export interface Margin {
  all?: number
  x?: number
  y?: number
  left?: number
  top?: number
  right?: number
  bottom?: number
}

export interface LayerShellOptions {
  namespace?: string
  layer?: Layer
  anchor?: LayerAnchor[]
  exclusiveZone?: number
  exclusive_zone?: number
  margin?: Margin
  keyboardInteractivity?: KeyboardInteractivity
  keyboard_interactivity?: KeyboardInteractivity
}

export interface SurfaceOptions {
  backend?: Backend
  title?: string
  appId?: string
  app_id?: string
  width?: number
  height?: number
  layerShell?: boolean | LayerShellOptions
  layer_shell?: boolean | LayerShellOptions
}

export interface KeyworkEvent {
  kind: EventKindValue | number
  surfaceId: bigint
  documentId: bigint
  handlerId: bigint
  payloadKind: number
  payload?: unknown
  width: number
  height: number
}

export interface ThemeColors {
  colorScheme: number
  primary: Color
  onPrimary: Color
  primaryContainer: Color
  onPrimaryContainer: Color
  surface: Color
  onSurface: Color
  onSurfaceVariant: Color
  surfaceContainerLow: Color
  surfaceContainer: Color
  surfaceContainerHigh: Color
  error: Color
  onError: Color
  errorContainer: Color
  onErrorContainer: Color
  outline: Color
  outlineVariant: Color

  color_scheme?: number
  on_primary?: Color
  primary_container?: Color
  on_primary_container?: Color
  on_surface?: Color
  on_surface_variant?: Color
  surface_container_low?: Color
  surface_container?: Color
  surface_container_high?: Color
  on_error?: Color
  error_container?: Color
  on_error_container?: Color
  outline_variant?: Color
}

export interface ResolvedTheme {
  colorScheme: 'no-preference' | 'dark' | 'light' | 'unknown'
  color_scheme: 'no-preference' | 'dark' | 'light' | 'unknown'
  colors: ThemeColors
}

interface NativeAddon {
  abiVersion(): number
  widgetVersion(): number
  createContext(): unknown
  contextDestroy(context: unknown): void
  contextEventFd(context: unknown): number
  contextDispatch(context: unknown): void
  contextNextEvent(context: unknown): KeyworkEvent | null
  contextGetColorScheme(context: unknown): number
  contextGetThemeColors(context: unknown): ThemeColors
  contextSetIconTheme(context: unknown, themeName: string): void
  contextCreateImageRgba8(context: unknown, width: number, height: number, strideBytes: number, pixels: Uint8Array): bigint
  contextCreateAlphaMaskA8(context: unknown, width: number, height: number, strideBytes: number, pixels: Uint8Array): bigint
  contextReleaseResource(context: unknown, resourceId: HandlerId): void
  contextCreateSurface(context: unknown, options?: SurfaceOptions): unknown
  surfaceId(surface: unknown): bigint
  surfaceSubmit(surface: unknown, bytes: Uint8Array): bigint
  surfaceInvalidate(surface: unknown): void
  surfaceDestroy(surface: unknown): void
  watchContext(context: unknown, callback: (status: number, events: number) => void): unknown
  watchClose(watch: unknown): void
}

const requireNative = createRequire(import.meta.url)
let nativeAddon: NativeAddon | undefined

function native(): NativeAddon {
  nativeAddon ??= requireNative('../build/keywork_node.node') as NativeAddon
  return nativeAddon
}

const colorSchemeNames: Record<number, ResolvedTheme['colorScheme']> = {
  0: 'no-preference',
  1: 'dark',
  2: 'light',
}

function withThemeAliases(colors: ThemeColors): ThemeColors {
  return {
    ...colors,
    color_scheme: colors.colorScheme,
    on_primary: colors.onPrimary,
    primary_container: colors.primaryContainer,
    on_primary_container: colors.onPrimaryContainer,
    on_surface: colors.onSurface,
    on_surface_variant: colors.onSurfaceVariant,
    surface_container_low: colors.surfaceContainerLow,
    surface_container: colors.surfaceContainer,
    surface_container_high: colors.surfaceContainerHigh,
    on_error: colors.onError,
    error_container: colors.errorContainer,
    on_error_container: colors.onErrorContainer,
    outline_variant: colors.outlineVariant,
  }
}

export function abiVersion(): number {
  return native().abiVersion()
}

export function widgetVersion(): number {
  return native().widgetVersion()
}

export class Watch {
  private nativeWatch?: unknown

  constructor(nativeWatch: unknown) {
    this.nativeWatch = nativeWatch
  }

  close(): void {
    if (this.nativeWatch == null) return
    native().watchClose(this.nativeWatch)
    this.nativeWatch = undefined
  }
}

export class Context {
  private nativeContext?: unknown
  private surfaces = new Map<string, Surface>()
  private cachedTheme?: ResolvedTheme

  constructor(nativeContext = native().createContext()) {
    this.nativeContext = nativeContext
  }

  createSurface(options: SurfaceOptions = {}): Surface {
    const handle = native().contextCreateSurface(this.requireHandle(), options)
    const surface = new Surface(this, handle)
    this.surfaces.set(surface.id.toString(), surface)
    return surface
  }

  create_surface(options: SurfaceOptions = {}): Surface {
    return this.createSurface(options)
  }

  eventFd(): number {
    return native().contextEventFd(this.requireHandle())
  }

  event_fd(): number {
    return this.eventFd()
  }

  dispatch(): void {
    native().contextDispatch(this.requireHandle())
  }

  nextEvent(): KeyworkEvent | null {
    return native().contextNextEvent(this.requireHandle())
  }

  next_event(): KeyworkEvent | null {
    return this.nextEvent()
  }

  drainEvents(callback?: (event: KeyworkEvent) => void): void {
    while (true) {
      const event = this.nextEvent()
      if (event == null) break

      if (event.kind === EventKind.handler) {
        const surface = this.surfaces.get(event.surfaceId.toString())
        const document = surface?.callbacks.get(event.documentId.toString())
        const handler = document?.get(event.handlerId)
        handler?.(event.payload, event)
      } else if (event.kind === EventKind.appearanceChanged) {
        this.cachedTheme = undefined
      } else if (event.kind === EventKind.documentRetired) {
        const surface = this.surfaces.get(event.surfaceId.toString())
        surface?.callbacks.delete(event.documentId.toString())
      }

      callback?.(event)
    }
  }

  drain_events(callback?: (event: KeyworkEvent) => void): void {
    this.drainEvents(callback)
  }

  watch(callback?: (event: KeyworkEvent) => void): Watch {
    const handle = native().watchContext(this.requireHandle(), (status) => {
      if (status < 0) throw new Error(`Keywork event watch failed: ${status}`)
      this.dispatch()
      this.drainEvents(callback)
    })
    return new Watch(handle)
  }

  colorScheme(): number {
    return native().contextGetColorScheme(this.requireHandle())
  }

  color_scheme(): number {
    return this.colorScheme()
  }

  theme(): ResolvedTheme {
    if (this.cachedTheme != null) return this.cachedTheme
    const colors = withThemeAliases(native().contextGetThemeColors(this.requireHandle()))
    const colorScheme = colorSchemeNames[colors.colorScheme] ?? 'unknown'
    this.cachedTheme = { colorScheme, color_scheme: colorScheme, colors }
    return this.cachedTheme
  }

  setIconTheme(themeName: string): void {
    native().contextSetIconTheme(this.requireHandle(), themeName)
  }

  set_icon_theme(themeName: string): void {
    this.setIconTheme(themeName)
  }

  createImageRgba8(width: number, height: number, strideBytes: number, pixels: Uint8Array): bigint {
    return native().contextCreateImageRgba8(this.requireHandle(), width, height, strideBytes, pixels)
  }

  create_image_rgba8(width: number, height: number, strideBytes: number, pixels: Uint8Array): bigint {
    return this.createImageRgba8(width, height, strideBytes, pixels)
  }

  createAlphaMaskA8(width: number, height: number, strideBytes: number, pixels: Uint8Array): bigint {
    return native().contextCreateAlphaMaskA8(this.requireHandle(), width, height, strideBytes, pixels)
  }

  create_alpha_mask_a8(width: number, height: number, strideBytes: number, pixels: Uint8Array): bigint {
    return this.createAlphaMaskA8(width, height, strideBytes, pixels)
  }

  releaseResource(resourceId: HandlerId): void {
    native().contextReleaseResource(this.requireHandle(), resourceId)
  }

  release_resource(resourceId: HandlerId): void {
    this.releaseResource(resourceId)
  }

  destroy(): void {
    if (this.nativeContext == null) return
    native().contextDestroy(this.nativeContext)
    this.nativeContext = undefined
    this.surfaces.clear()
    this.cachedTheme = undefined
  }

  removeSurface(surface: Surface): void {
    this.surfaces.delete(surface.id.toString())
  }

  nativeHandle(): unknown {
    return this.requireHandle()
  }

  private requireHandle(): unknown {
    if (this.nativeContext == null) throw new Error('Keywork context is destroyed')
    return this.nativeContext
  }
}

export class Surface {
  readonly id: bigint
  callbacks = new Map<string, Map<bigint, NonNullable<Extract<Handler, Function>>>>()
  private readonly context: Context
  private nativeSurface?: unknown

  constructor(context: Context, nativeSurface: unknown) {
    this.context = context
    this.nativeSurface = nativeSurface
    this.id = native().surfaceId(nativeSurface)
  }

  submit(root: Widget): bigint {
    const document = encode(root)
    const documentId = native().surfaceSubmit(this.requireHandle(), document.bytes)
    this.callbacks.set(documentId.toString(), document.callbacks)
    return documentId
  }

  invalidate(): void {
    native().surfaceInvalidate(this.requireHandle())
  }

  destroy(): void {
    if (this.nativeSurface == null) return
    native().surfaceDestroy(this.nativeSurface)
    this.nativeSurface = undefined
    this.callbacks.clear()
    this.context.removeSurface(this)
  }

  nativeHandle(): unknown {
    return this.requireHandle()
  }

  private requireHandle(): unknown {
    if (this.nativeSurface == null) throw new Error('Keywork surface is destroyed')
    return this.nativeSurface
  }
}

export function context(): Context {
  return new Context()
}
