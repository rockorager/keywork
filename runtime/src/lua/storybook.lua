local storybook = {}

function storybook.story(options)
    assert(type(options) == "table", "storybook.story requires a table")
    if options.viewport and options.viewport.height ~= nil then
        assert(
            type(options.viewport.height) == "number" or options.viewport.height == "content",
            "storybook viewport height must be a number or 'content'"
        )
    end
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
