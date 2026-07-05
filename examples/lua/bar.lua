local ui = require("ui")

local colors = {
  background = 0xff202024,
  foreground = 0xffffffff,
  muted = 0xffc8c5d0,
  accent = 0xff9b86ff,
}

local function label(value, color)
  return ui.text(value, { color = color or colors.foreground })
end

local function icon(name, color)
  return ui.icon(name, 24, color or colors.foreground)
end

local function pill(id, child)
  return ui.clickable(id,
    ui.box({ background = 0xff2b2b30 },
      ui.padding(2, child)
    ),
    function()
      print("clicked " .. id)
    end
  )
end

return function(state)
  local time = os.date("%a %H:%M")
  local left = ui.row({
    ui.svg_icon("examples/lua/icons/bolt.svg", 18, colors.accent),
    label("Keywork"),
    label(state.color_scheme, colors.muted),
  }, 10)

  local center = label(time, colors.foreground)

  local right = ui.row({
    pill("network", icon("network-wireless-signal-excellent")),
    pill("audio", icon("audio-volume-high")),
    pill("power", icon("battery-level-90")),
  }, 8)

  return ui.box({ background = colors.background },
    ui.padding(8,
      ui.row({
        left,
        ui.spacer(),
        center,
        ui.spacer(),
        right,
      }, 12)
    )
  )
end
