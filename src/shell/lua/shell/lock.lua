local kw = require("keywork")
local clock = require("shell.clock")

local M = {}

local function avatar(theme, path)
    if path then
        return kw.sized_box({
            width = 96,
            height = 96,
            child = kw.image({ path = path, fit = "cover" }),
        })
    end

    return kw.icon({ name = "avatar-default", size = 96, color = theme.colors.text_secondary })
end

M.View = kw.stateful({
    init = function(self)
        if self.props.time and self.props.date then
            return
        end
        self.timestamp = clock.use(self.scope, function(timestamp)
            self.timestamp = timestamp
            self:set_state()
        end) or os.time()
    end,

    build = function(self, context)
        local theme = context.theme
        local status = self.props.status
        local message = status or "Enter your password to unlock"
        local message_color = status and theme.colors.danger or theme.colors.text_secondary
        local timestamp = self.timestamp or os.time()
        local time = self.props.time or clock.format_time(timestamp)
        local date = self.props.date or clock.format_date(timestamp)

        local clock_view = kw.column({
            align = "center",
            spacing = theme.space[1],
            children = {
                kw.text(date, {
                    color = theme.colors.text_secondary,
                    font_size = theme.font_size[4],
                    line_height = theme.line_height[4],
                    role = "label",
                }),
                kw.text(time, {
                    font_size = theme.font_size[9],
                    line_height = theme.line_height[9],
                }),
            },
        })

        local card = kw.sized_box({
            width = 360,
            child = kw.container({
                background = theme.colors.surface,
                border = theme.colors.border,
                border_width = 1,
                radius = theme.radius[4],
                padding = theme.space[5],
                child = kw.column({
                    align = "stretch",
                    spacing = theme.space[3],
                    children = {
                        kw.center({ child = avatar(theme, self.props.avatar_path) }),
                        kw.center({
                            child = kw.text(self.props.username or "User", {
                                role = "title",
                            }),
                        }),
                        kw.text_field({
                            id = "password",
                            placeholder = "Password",
                            autofocus = self.props.autofocus ~= false,
                            obscured = true,
                            clear_on_submit = true,
                            on_submit = self.props.on_submit,
                        }),
                        kw.center({
                            child = kw.text(message, {
                                color = message_color,
                                role = "label",
                            }),
                        }),
                    },
                }),
            }),
        })

        return kw.container({
            background = theme.colors.background,
            child = kw.center({
                child = kw.column({
                    align = "center",
                    children = {
                        kw.expanded({
                            child = kw.column({
                                align = "center",
                                children = {
                                    kw.spacer(2),
                                    clock_view,
                                    kw.spacer(),
                                },
                            }),
                        }),
                        card,
                        kw.expanded({ child = kw.spacer() }),
                    },
                }),
            }),
        })
    end,
})

return M
