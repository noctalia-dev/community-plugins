local theme = require("../../utils/theme.luau")
local state = require("../state.luau")
local request = require("../actions.luau")
local common = require("../common.luau")
local rerender = require("../rerender.luau")
local QueueOrder = require("../../utils/queueorder.luau")

local DRAG_TYPE = "yt-music.queue.track"
local function on_track_dropped(payload, value)
    local from, to = tonumber(payload), tonumber(value)
    if not from or not to then
        return
    end
    local player = state.data.player
    local insert_at = QueueOrder.move(player.queue, from, to)
    if insert_at == nil then
        return
    end
    player.index = QueueOrder.follow(player.index, from, insert_at)
    state.view.hover_key.track = nil
    rerender.call()
    request("move_queue_item", { from = from, to = to })
end

local function insertion_zone(slot)
    return ui.dropZone({
        key = "q-gap-" .. slot,
        accepts = { DRAG_TYPE },
        value = tostring(slot),
        onDrop = "onQueueTrackDropped",
        height = 4,
        radius = 6,
        expandOnDrag = true,
        hitSlop = 48,
    })
end

local function build_queue()
    local player = state.data.player
    local view = state.view
    local child = {}
    local PAGE_SIZE = 50

	table.insert(
		child,
		ui.row({ key = "queue-head", align = "center", justify = "space_between", radius = theme.radius }, {
			ui.column({ gap = 4, radius = theme.radius }, {
				ui.label({ text = "QUEUE", fontSize = theme.fontHero, fontWeight = "bold", color = "on_surface" }),
				ui.label({
					text = #player.queue == 0 and "No tracks in queue" or (#player.queue .. " tracks in queue"),
					fontSize = theme.fontTitle,
					color = "on_surface_variant",
				}),
			}),
		})
	)
	table.insert(child, ui.row({ key = "spacer-queue-1", height = 8, borderWidth = 0, radius = theme.radius }))

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
                table.insert(rows, insertion_zone(idx))
                table.insert(rows, common.media_row(item, idx, function()
                    request("play_queue_index", { index = idx })
                end, is_current, { drag_type = DRAG_TYPE, payload = idx, enabled = total > 1 }))
            end
        end
        table.insert(rows, insertion_zone(page_end + 1))

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

        -- catch-all: a drop anywhere on the list goes to the bottom of the page
        table.insert(child, ui.dropZone({
            key = "queue-track-list",
            accepts = { DRAG_TYPE },
            value = tostring(page_end + 1),
            onDrop = "onQueueTrackDropped",
            gap = 0,
            borderWidth = 0,
            radius = theme.radius,
        }, rows))
        table.insert(child, ui.row({
            key = "q-pagination",
            align = "center",
            justify = "center",
            gap = 12,
            padding = 10,
            borderWidth = 0,
            radius = theme.radius
        }, page_controls))
    end

    return child
end

return { build = build_queue, on_track_dropped = on_track_dropped }
