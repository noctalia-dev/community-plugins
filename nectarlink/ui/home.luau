--!nonstrict
-- Home: device card, actions, notifications and timeline.
local palette = require("./palette.luau")
local installCommand =
  "curl -fsSL https://github.com/vladikchi/nectarlink-noctalia/releases/latest/download/install.sh | sh"
local M = {}
function M.new(model, components, actions, controls, frame)
  local geometry = require("./components.luau").layout
  local activeSession = components.activeSession
  local setting = components.setting
  local preview = components.preview
  local label = components.label
  local badge = components.badge
  local tile = components.tile
  local send = actions.send
  local render = actions.render
  local controlsCard = controls.render
  local ringerCard = controls.ringer
  local renderFrame = frame.render
  local function timeline(phone)
    local rows = {
      ui.row({
        key = "timeline-header",
        align = "center",
        gap = 8,
        width = 244,
        height = 20,
      }, {
        ui.column({ width = 184, height = 20, justify = "center", align = "start" }, {
          ui.label({
            text = noctalia.tr("home.timeline"),
            fontFamily = "sans-serif",
            fontSize = 13,
            fontWeight = "bold",
            maxWidth = 184,
            maxLines = 1,
          }),
        }),
        ui.row({
          key = "timeline-more",
          width = 52,
          gap = 4,
          align = "center",
          justify = "end",
          height = 20,
          tooltip = noctalia.tr("home.open_timeline"),
          onClick = function()
            send("timeline")
          end,
        }, {
          label(noctalia.tr("common.all"), 11, "primary"),
          ui.glyph({ name = "arrow-up-right", size = 14, color = "primary" }),
        }),
      }),
    }
    local count = 0
    local glyphs = { clipboard = "clipboard", file = "file", photo = "photo", link = "link" }
    if model.snapshot.timelineState == "ready" then
      for _, item in ipairs(model.snapshot.timeline or {}) do
        if
          phone
          and item.deviceId == phone.id
          and count < (#model.snapshot.devices > 1 and 1 or 2)
        then
          count = count + 1
          table.insert(
            rows,
            ui.row({
              key = "event-" .. tostring(item.id),
              width = 244,
              gap = 8,
              height = 32,
              align = "center",
            }, {
              ui.column({ width = 20, height = 32, align = "center", justify = "center" }, {
                ui.glyph({ name = glyphs[item.kind] or "history", size = 18, color = "primary" }),
              }),
              ui.column({
                key = "event-text-" .. tostring(item.id),
                width = 216,
                height = 32,
                gap = 0,
                align = "start",
              }, {
                ui.column({ width = 216, height = 18, align = "start", justify = "center" }, {
                  ui.label({
                    text = preview(
                      type(item.title) == "string" and item.title or noctalia.tr("home.event"),
                      28
                    ),
                    fontFamily = "sans-serif",
                    fontSize = 12,
                    fontWeight = "bold",
                    maxWidth = 216,
                    maxLines = 1,
                  }),
                }),
                ui.column({ width = 216, height = 14, align = "start", justify = "center" }, {
                  ui.label({
                    text = item.direction == "incoming" and noctalia.tr("home.received")
                      or noctalia.tr("home.sent"),
                    fontFamily = "sans-serif",
                    fontSize = 10,
                    color = "on_surface_variant",
                    maxWidth = 216,
                    maxLines = 1,
                  }),
                }),
              }),
            })
          )
        end
      end
    end
    if count == 0 then
      local text = model.snapshot.timelineState == "ready" and noctalia.tr("home.no_events")
        or (
          model.snapshot.timelineState == "offline" and noctalia.tr("home.events_failed")
          or noctalia.tr("home.events_loading")
        )
      table.insert(rows, label(text, 12, "on_surface_variant"))
    end
    return ui.column({
      key = "timeline",
      width = 260,
      gap = 6,
      padding = 8,
      radius = 10,
      height = count > 0 and (36 + count * 38) or 64,
      fill = palette("card", 0.65),
      border = palette("muted_border", 0.35),
      borderWidth = 1,
    }, rows)
  end

  local function renderHomePage(context)
    local phone = context.phone
    local online = context.online
    local ready = context.ready
    local session = context.session
    local canSession = context.canSession
    local unavailable = context.unavailable
    local notices = context.notices
    local showControls = context.showControls
    local showTimeline = context.showTimeline
    local sidebar = context.sidebar
    local mainWidth = context.mainWidth
    local header = context.header
    local body = {}
    -- First connection needs instructions, not a dashboard of disabled actions.
    -- Known offline phones still use the normal dashboard below.
    if ready and phone then
      model.connectedOnce = true
    end
    if (not ready and not model.connectedOnce) or (ready and not phone) then
      local width = geometry.panelWidth
        - geometry.hostPadding * 2
        - geometry.framePadding * 2
        - (setting("panel_navigation") and geometry.navigationSpace or 0)
      local reason = ready and "no_devices" or model.snapshot.error or "api_unavailable"
      local known = {
        credentials_missing = true,
        credentials_invalid = true,
        api_unavailable = true,
        unauthorized = true,
        auth_changed = true,
        unsupported = true,
        invalid_response = true,
        permission = true,
        timeout = true,
      }
      if reason ~= "no_devices" and not known[reason] then
        reason = "api_unavailable"
      end
      local rows = {
        label(noctalia.tr("setup.title"), 18, "on_surface", true, width - 32),
        ui.label({
          text = noctalia.tr("setup.intro"),
          fontSize = 12,
          maxWidth = width - 32,
          maxLines = 2,
          height = 36,
          color = "on_surface_variant",
        }),
      }
      for _, key in ipairs({ "install", "api", "pair" }) do
        table.insert(
          rows,
          ui.label({
            text = noctalia.tr("setup." .. key),
            fontSize = 13,
            maxWidth = width - 32,
            maxLines = 2,
            height = 30,
          })
        )
        if key == "install" then
          table.insert(rows, ui.row({
            key = "setup-install-command",
            width = width - 32,
            height = 38,
            gap = 6,
            align = "center",
          }, {
            ui.label({
              text = installCommand,
              fontFamily = "monospace",
              fontSize = 10,
              maxWidth = width - 70,
              maxLines = 2,
              tooltip = installCommand,
            }),
            ui.button({
              key = "copy-install-command",
              glyph = model.installCopyStatus == "copied" and "check" or "copy",
              width = 32,
              height = 32,
              variant = "ghost",
              tooltip = noctalia.tr("setup." .. (model.installCopyStatus or "copy")),
              onClick = function()
                local copied = noctalia.copyToClipboard(installCommand, "text/plain")
                model.installCopyStatus = copied and "copied" or "copy_failed"
                render()
              end,
            }),
          }))
        end
      end
      table.insert(
        rows,
        ui.label({
          key = "setup-status",
          text = noctalia.tr("setup." .. reason),
          fontSize = 12,
          color = "primary",
          maxWidth = width - 32,
          maxLines = 2,
          height = 38,
        })
      )
      -- Keep a technical reason available without making it the main explanation.
      if not ready then
        local title, text = components.failure(model.snapshot.error or "api_unavailable")
        table.insert(
          rows,
          ui.label({
            key = "connection-error",
            text = title,
            tooltip = text,
            fontSize = 10,
            color = "on_surface_variant",
            maxWidth = width - 32,
            maxLines = 1,
          })
        )
      end
      table.insert(rows, ui.spacer({ flexGrow = 1 }))
      table.insert(
        rows,
        ui.row({ gap = 8, height = 32 }, {
          components.smallButton(noctalia.tr("setup.instructions"), function()
            send("open_fork")
          end),
          components.smallButton(noctalia.tr("setup.open"), function()
            send("open")
          end),
          components.smallButton(noctalia.tr("setup.check"), function()
            send("refresh")
          end),
        })
      )
      table.insert(
        rows,
        ui.label({
          text = noctalia.tr("setup.source_note"),
          fontSize = 10,
          color = "on_surface_variant",
          maxWidth = width - 32,
          maxLines = 2,
          height = 30,
        })
      )
      renderFrame(
        header,
        {
          ui.column(
            {
              key = "connection-setup",
              width = width,
              height = geometry.pageHeight,
              padding = 16,
              gap = 6,
              radius = 12,
              fill = palette("card"),
            },
            rows
          ),
        }
      )
      return
    end
    if not ready then
      local title, text = components.failure(model.snapshot.error or "api_unavailable")
      table.insert(
        body,
        ui.label({
          key = "connection-error",
          text = title .. "\n" .. text,
          tooltip = text,
          fontSize = 12,
          maxLines = 3,
          maxWidth = mainWidth,
          height = 52,
          color = "on_surface_variant",
        })
      )
    end
    local battery = phone and phone.battery
    local level = battery and tonumber(battery.level)
    if level then
      level = math.max(0, math.min(100, level))
    end
    local powerVisible = setting("panel_battery")
    local powerColor = online
        and (level and level <= 20 and not battery.charging and "error" or "primary")
      or "on_surface_variant"
    -- Stylized device silhouette, not a fabricated screenshot of the real phone.
    local devicePreview = {
      ui.row(
        { width = 44, height = 5, align = "center", justify = "center" },
        { ui.box({ width = 14, height = 3, radius = 2, fill = "on_surface_variant/0.65" }) }
      ),
      ui.column({
        key = "phone-preview-screen",
        width = 44,
        height = 62,
        padding = 6,
        gap = 4,
        radius = 7,
        fill = "primary/0.12",
        align = "center",
        justify = "center",
      }, {
        ui.row(
          { width = 32, height = 24, align = "center", justify = "center" },
          { ui.glyph({ name = "hexagon", size = 24, color = "primary" }) }
        ),
        ui.box({ width = 22, height = 3, radius = 2, fill = "primary/0.6" }),
        ui.box({ width = 14, height = 2, radius = 1, fill = "primary/0.3" }),
      }),
      ui.box({ width = 14, height = 2, radius = 1, fill = "on_surface_variant/0.45" }),
    }
    local infoWidth = mainWidth - 24 - 56 - 10 - (powerVisible and 130 or 0)
    local info = {
      label(
        phone and phone.name or noctalia.tr("common.disconnected"),
        16,
        "on_surface",
        true,
        infoWidth
      ),
      label(
        phone and type(phone.platform) == "string" and phone.platform or "NectarLink",
        12,
        "on_surface_variant",
        false,
        infoWidth
      ),
      ui.row({ gap = 6, justify = "start" }, {
        badge(
          online
              and (({
                lan = noctalia.tr("connection.lan"),
                usb = "USB",
                relay = noctalia.tr("connection.relay"),
              })[phone.link] or noctalia.tr("connection.connected"))
            or noctalia.tr("connection.offline"),
          online and "link" or "unlink",
          infoWidth
        ),
      }),
    }
    if powerVisible then
      table.insert(
        info,
        ui.row({ justify = "start" }, {
          badge(
            level
                and (not online and noctalia.tr("battery.last_known") or (battery.charging and noctalia.tr(
                  "battery.charging"
                ) or noctalia.tr("battery.discharging")))
              or noctalia.tr("battery.unknown"),
            battery and battery.charging and "battery-charging" or "battery",
            infoWidth
          ),
        })
      )
    end
    if #model.snapshot.devices > 1 then
      local devices, ids, index = {}, {}, 0
      for i, d in ipairs(model.snapshot.devices) do
        table.insert(devices, d.name)
        table.insert(ids, d.id)
        if d.id == model.selected then
          index = i - 1
        end
      end
      info[1] = ui.select({
        key = "device-picker",
        options = devices,
        selectedIndex = index,
        controlSize = "sm",
        onChange = function(value)
          local i = tonumber(value)
          if i and ids[i + 1] then
            model.selected = ids[i + 1]
            render()
          end
        end,
      })
    end
    local deviceCard = {
      ui.column({
        key = "phone-preview",
        gap = 4,
        width = 56,
        height = 92,
        padding = 5,
        radius = 12,
        opacity = online and 1 or 0.55,
        fill = palette("raised"),
        border = "primary/0.5",
        borderWidth = 1,
        align = "center",
        justify = "center",
      }, devicePreview),
      ui.column({
        key = "phone-info",
        gap = 3,
        flexGrow = 1,
        align = "start",
        justify = "center",
      }, info),
    }
    if powerVisible then
      local power = {
        ui.row({ width = 108, height = 18, align = "center", justify = "center" }, {
          ui.glyph({
            name = battery and battery.charging and "battery-charging" or "battery",
            size = 18,
            color = powerColor,
          }),
        }),
        ui.column({
          key = "battery-value",
          width = 108,
          height = 30,
          align = "center",
          justify = "center",
        }, { label(level and (tostring(level) .. "%") or "—", 21, powerColor, true, 108) }),
      }
      if level then
        table.insert(
          power,
          ui.progress({ progress = level / 100, width = 108, height = 4, fill = powerColor })
        )
      end
      table.insert(
        power,
        ui.column({ width = 108, height = 14, align = "center", justify = "center" }, {
          label(
            online and noctalia.tr("battery.phone") or noctalia.tr("common.last_known"),
            10,
            "on_surface_variant",
            false,
            108
          ),
        })
      )
      table.insert(
        deviceCard,
        ui.column({
          key = "phone-battery",
          gap = 4,
          width = 120,
          height = 92,
          padding = 6,
          radius = 12,
          fill = palette("card", 0.6),
          align = "center",
          justify = "center",
        }, power)
      )
    end
    table.insert(
      body,
      ui.row({
        key = "device",
        width = mainWidth,
        gap = 10,
        padding = 12,
        radius = 16,
        height = 126,
        align = "center",
        fill = "primary/0.12",
      }, deviceCard)
    )
    local single = #model.snapshot.devices == 1
    local transfer = online and single
    local transferReason = not online and unavailable or noctalia.tr("home.select_recipient")
    if setting("panel_actions") then
      table.insert(
        body,
        ui.row({ gap = 10 }, {
          tile(
            "screen",
            activeSession(session, "screen") and noctalia.tr("home.stop_screen")
              or noctalia.tr("home.screen"),
            "devices-pc",
            "session",
            canSession("screen"),
            noctalia.tr("home.screen_hint"),
            model.selected,
            { kind = "screen", on = not activeSession(session, "screen") },
            activeSession(session, "screen")
          ),
          tile(
            "files",
            noctalia.tr("home.files"),
            "send",
            "files",
            transfer,
            transfer and noctalia.tr("home.files_hint") or transferReason
          ),
          tile(
            "clipboard",
            noctalia.tr("home.clipboard"),
            "clipboard",
            "clipboard",
            transfer,
            transfer and noctalia.tr("home.clipboard_hint") or transferReason
          ),
          tile(
            "ring",
            model.snapshot.ringBusy and noctalia.tr("common.sending")
              or (
                phone and phone.ringing and noctalia.tr("home.stop_ring")
                or noctalia.tr("home.find_phone")
              ),
            phone and phone.ringing and "player-stop" or "bell",
            "ring",
            online and not model.snapshot.ringBusy and type(phone.ringing) == "boolean",
            not online and unavailable
              or (
                model.snapshot.ringBusy and noctalia.tr("home.waiting")
                or (type(phone.ringing) ~= "boolean" and noctalia.tr("home.update_app") or nil)
              ),
            model.selected,
            not (phone and phone.ringing),
            phone and phone.ringing
          ),
        })
      )
      if activeSession(session, "keyboard") then
        local id = model.selected
        local function submit()
          if not model.snapshot.typeBusy and model.drafts[id] and model.drafts[id] ~= "" then
            model.sentDrafts[id] = model.drafts[id]
            send("type_text", id, model.drafts[id])
          end
        end
        table.insert(
          body,
          ui.column({
            key = "typing-form",
            gap = 5,
            padding = 8,
            radius = 12,
            height = 124,
            fill = palette("card"),
          }, {
            ui.input({
              key = "draft-" .. id .. "-" .. tostring(model.draftRevisions[id] or 0),
              value = model.drafts[id] or "",
              placeholder = noctalia.tr("home.type_placeholder"),
              controlSize = "sm",
              enabled = not model.snapshot.typeBusy,
              onChange = function(value)
                model.drafts[id] = value
                render()
              end,
              onSubmit = submit,
            }),
            ui.row({ gap = 6 }, {
              ui.button({
                text = model.snapshot.typeBusy and noctalia.tr("common.sending")
                  or noctalia.tr("common.send"),
                controlSize = "sm",
                variant = "secondary",
                enabled = not model.snapshot.typeBusy and (model.drafts[id] or "") ~= "",
                onClick = submit,
              }),
              ui.button({
                text = noctalia.tr("common.clear"),
                controlSize = "sm",
                variant = "ghost",
                enabled = not model.snapshot.typeBusy,
                onClick = function()
                  model.drafts[id] = ""
                  model.draftRevisions[id] = (model.draftRevisions[id] or 0) + 1
                  render()
                end,
              }),
              ui.button({
                text = noctalia.tr("home.stop_typing"),
                controlSize = "sm",
                variant = "ghost",
                enabled = not model.snapshot.sessionBusy,
                onClick = function()
                  send("session", id, { kind = "keyboard", on = false })
                end,
              }),
            }),
            ui.label({
              text = noctalia.tr("home.transport_only"),
              maxWidth = mainWidth - 16,
              fontFamily = "sans-serif",
              fontSize = 9,
              color = "on_surface_variant",
              visible = not model.snapshot.typeBusy
                and model.snapshot.typeDeliveryDevice == id
                and model.drafts[id] == model.sentDrafts[id],
              maxLines = 2,
            }),
          })
        )
      else
        table.insert(
          body,
          ui.row({ gap = 10 }, {
            tile(
              "camera",
              model.snapshot.cameraBusy and noctalia.tr("common.starting")
                or noctalia.tr("home.camera"),
              "camera",
              "camera",
              online and not model.snapshot.cameraBusy,
              not online and unavailable or noctalia.tr("home.camera_hint"),
              model.selected,
              nil,
              false,
              math.floor((mainWidth - 20) / 3)
            ),
            tile(
              "webcam",
              activeSession(session, "webcam") and noctalia.tr("home.stop_webcam")
                or noctalia.tr("home.webcam"),
              "video",
              "session",
              canSession("webcam"),
              noctalia.tr("home.webcam_hint"),
              model.selected,
              { kind = "webcam", on = not activeSession(session, "webcam") },
              activeSession(session, "webcam"),
              math.floor((mainWidth - 20) / 3)
            ),
            tile(
              "typing",
              noctalia.tr("home.typing"),
              "keyboard",
              "session",
              canSession("keyboard"),
              noctalia.tr("home.typing_hint"),
              model.selected,
              { kind = "keyboard", on = true },
              false,
              math.floor((mainWidth - 20) / 3)
            ),
          })
        )
      end
    end
    local side = {}
    if showControls then
      table.insert(side, controlsCard(phone, online))
    end
    if showControls and not model.confirmWifi and not model.hotspotMenu then
      table.insert(side, ringerCard(phone, online))
    end
    if #notices > 0 and not activeSession(session, "keyboard") then
      local cards = {
        ui.row({ gap = 6, align = "center", height = 18 }, {
          ui.label({
            text = noctalia.tr("home.notifications", { count = #notices }),
            maxWidth = mainWidth - 110,
            maxLines = 1,
            fontFamily = "sans-serif",
            fontSize = 13,
            fontWeight = "bold",
            flexGrow = 1,
          }),
          ui.row({
            gap = 4,
            align = "center",
            tooltip = noctalia.tr("home.notifications_hint"),
            onClick = function()
              send("open")
            end,
          }, {
            label(noctalia.tr("common.show_all"), 11, "primary", false, 90),
            ui.glyph({ name = "external-link", size = 13, color = "primary" }),
          }),
        }),
      }
      for i, item in ipairs(notices) do
        if i > 1 then
          break
        end
        table.insert(
          cards,
          ui.column({
            key = "notice-" .. tostring(item.key),
            gap = 2,
            padding = 8,
            height = 80,
            radius = 12,
            fill = palette("card"),
          }, {
            label(
              preview(
                type(item.appName) == "string" and item.appName or noctalia.tr("common.phone"),
                48
              ),
              10,
              "primary",
              false,
              mainWidth - 16
            ),
            label(
              preview(
                type(item.title) == "string" and item.title or noctalia.tr("home.notification"),
                60
              ),
              12,
              "on_surface",
              true,
              mainWidth - 16
            ),
            ui.label({
              text = preview(item.text, 96),
              fontFamily = "sans-serif",
              fontSize = 11,
              height = 28,
              maxLines = 2,
              maxWidth = mainWidth - 16,
              color = "on_surface_variant",
            }),
          })
        )
      end
      table.insert(body, ui.spacer({ key = "notifications-spacer", flexGrow = 1 }))
      table.insert(body, ui.column({ key = "notifications", gap = 6, height = 104 }, cards))
    end
    if showTimeline and not model.confirmWifi and not model.hotspotMenu then
      table.insert(side, ui.spacer({ key = "timeline-spacer", flexGrow = 1 }))
      table.insert(side, timeline(phone))
    end
    local content = {
      ui.column(
        { key = "content", gap = 8, width = mainWidth, height = geometry.pageHeight },
        body
      ),
    }
    if sidebar then
      table.insert(
        content,
        ui.column({ key = "sidebar", width = 260, height = geometry.pageHeight, gap = 8 }, side)
      )
    end
    renderFrame(header, content)
  end
  return { render = renderHomePage }
end
return M
