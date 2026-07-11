local storybook = {}

function storybook.story(options)
  assert(type(options) == "table", "storybook.story requires a table")
  options.type = "story"
  return options
end

function storybook.book(options)
  assert(type(options) == "table", "storybook.book requires a table")
  options.type = "storybook"
  options.stories = options.stories or {}
  return options
end

return storybook
