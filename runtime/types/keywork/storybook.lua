---@meta keywork.storybook

---@class keywork.storybook.Viewport
---@field width?  number
---@field height? number | 'content'
---@field scale?  number

---@class keywork.storybook.StoryOptions
---@field id            string
---@field group?        string
---@field name          string
---@field viewport?     keywork.storybook.Viewport
---@field color_scheme? 'light' | 'dark'
---@field render        fun(context: keywork.BuildContext): keywork.Widget

---@class keywork.storybook.Story: keywork.storybook.StoryOptions
---@field type 'story'

---@class keywork.storybook.BookOptions
---@field title?   string
---@field stories? keywork.storybook.Story[]

---@class keywork.storybook.Book
---@field type    'storybook'
---@field title?  string
---@field stories keywork.storybook.Story[]

local M = {}

---@param options keywork.storybook.StoryOptions
---@return keywork.storybook.Story
function M.story(options) end

---@param options keywork.storybook.BookOptions
---@return keywork.storybook.Book
function M.book(options) end

return M
