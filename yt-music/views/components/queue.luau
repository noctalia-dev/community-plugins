local theme = require("../../utils/theme.luau")
local state = require("../state.luau")
local request = require("../actions.luau")
local common = require("../common.luau")
local rerender = require("../rerender.luau")

local function build_queue()
    local player = state.data.player
    local view = state.view
    local child = {}
    local PAGE_SIZE = 50

	table.insert(
		child,
		ui.row({ key = "queue-head", align = "center", justify = "space_between" }, {
			ui.column({ gap = 4 }, {
				ui.label({ text = "QUEUE", fontSize = theme.fontHero, fontWeight = "bold", color = "on_surface" }),
				ui.label({
					text = #player.queue == 0 and "No tracks in queue" or (#player.queue .. " tracks in queue"),
					fontSize = theme.fontTitle,
					color = "on_surface_variant",
				}),
			}),
		})
	)
	table.insert(child, ui.row({ key = "spacer-queue-1", height = 8, borderWidth = 0 }))

    if #player.queue == 0 then
        table.insert(child, ui.label({
            text = "Nothing queued yet.",
            fontSize = theme.fontTitle,
            color = "on_surface_variant"
        }))
    else
        local total = #player.queue
        local total_pages = math.max(1, math.ceil(total / PAGE_SIZE))
        if view.queue_view_page >= total_pages then
            view.queue_view_page = math.max(0, total_pages - 1)
        end
        local page_start = view.queue_view_page * PAGE_SIZE + 1
        local page_end = math.min(page_start + PAGE_SIZE - 1, total)

        local rows = {}
        for idx = page_start, page_end do
            local item = player.queue[idx]
            if item then
                local is_current = (idx == player.index)
                table.insert(rows, common.media_row(item, idx, function()
                    request("play_queue_index", { index = idx })
                end, is_current))
            end
        end

        local has_prev = (view.queue_view_page > 0)
        local has_next = (view.queue_view_page < total_pages - 1)

        local page_controls = {}
        if has_prev then
            table.insert(page_controls, ui.button({
                key = "q-prev-page",
                text = "← Previous",
                variant = "outline",
                controlSize = "sm",
                onClick = function()
                    view.queue_view_page = view.queue_view_page - 1
                    rerender.call()
                end
            }))
        end

        table.insert(page_controls, ui.label({
            text = page_start .. "–" .. page_end .. " of " .. total,
            fontSize = theme.fontBody,
            fontWeight = "medium",
            color = "on_surface_variant"
        }))

        if has_next then
            table.insert(page_controls, ui.button({
                key = "q-next-page",
                text = "Next →",
                variant = "outline",
                controlSize = "sm",
                onClick = function()
                    view.queue_view_page = view.queue_view_page + 1
                    rerender.call()
                end
            }))
        end

        table.insert(child, ui.column({ key = "queue-track-list", gap = 0, borderWidth = 0 }, rows))
        table.insert(child, ui.row({
            key = "q-pagination",
            align = "center",
            justify = "center",
            gap = 12,
            padding = 10,
            borderWidth = 0
        }, page_controls))
    end

    return child
end

return { build = build_queue }