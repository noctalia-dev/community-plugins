--!nonstrict
-- Panel. Shows only what is configured on the system:
--   * Proton VPN card + protection card, when the CLI is installed and signed in
--   * one row per NetworkManager WireGuard connection
--   * a "missing X" notice when only one of the two is configured
--   * a single "control only" note when neither is
-- The panel height follows the content (manifest: height = "content").

local STATE_KEY = "pw.state"
local CMD_KEY = "pw.cmd"

local s = noctalia.state.get(STATE_KEY) or {}
local tr = noctalia.tr

local favs = noctalia.getConfig("favorite_countries")
if type(favs) ~= "table" then
	favs = {}
end

local function send(op, value)
	noctalia.state.set(CMD_KEY, { op = op, value = value, n = noctalia.nowMs() })
end

local function isOn(v)
	return v == true or v == "true"
end

-- ── Building blocks ───────────────────────────────────────────────────────

local function card(highlight, children)
	return ui.column({
		padding = 12,
		radius = 12,
		gap = 10,
		align = "stretch",
		fill = if highlight then "primary/0.12" else "on_surface/0.05",
	}, children)
end

local function sectionLabel(text)
	return ui.label({ text = text, fontSize = 11, fontWeight = "semibold", color = "on_surface_variant" })
end

local function infoRow(glyph, active, title, desc, control, key)
	local texts = { ui.label({ text = title, fontSize = 13, fontWeight = "semibold", maxLines = 1 }) }
	if desc and desc ~= "" then
		table.insert(texts, ui.label({ text = desc, fontSize = 11, color = "on_surface_variant" }))
	end
	local children = {
		ui.glyph({ name = glyph, size = 18, color = if active then "primary" else "on_surface_variant" }),
		ui.column({ flexGrow = 1, gap = 2 }, texts),
	}
	if control then
		table.insert(children, control)
	end
	return ui.row({ key = key, align = "center", gap = 10 }, children)
end

local function notice(kind, text)
	local isError = kind == "error"
	return ui.row({
		align = "center",
		gap = 8,
		padding = 8,
		radius = 8,
		fill = if isError then "error/0.15" else "on_surface/0.05",
	}, {
		ui.glyph({
			name = if isError then "alert-triangle" else "info-circle",
			size = 16,
			color = if isError then "error" else "on_surface_variant",
		}),
		ui.label({ text = text, fontSize = 11, flexGrow = 1, color = if isError then "error" else "on_surface_variant" }),
	})
end

-- "Proton VPN is not set up" / "No WireGuard connections" card.
local function missingCard(title, hint, button)
	local children = {
		infoRow("alert-triangle", false, title, hint, button),
	}
	return ui.column({
		padding = 12,
		radius = 12,
		gap = 8,
		align = "stretch",
		fill = "tertiary/0.12",
	}, children)
end

-- ── Proton ────────────────────────────────────────────────────────────────

local function protonCard()
	local p = s.proton or {}
	local busy = p.busy == true
	local children = {}

	local statusText
	if busy then
		statusText = tr(if p.action == "disconnecting" then "status.disconnecting" else "status.connecting")
	else
		statusText = tr(if p.up then "status.connected" else "status.disconnected")
	end

	table.insert(children, infoRow(
		if p.up then "shield-check" else "shield",
		p.up,
		tr("proton.title"),
		statusText,
		ui.button({
			text = tr(if p.up then "proton.disconnect" else "proton.connect"),
			glyph = if p.up then "player-stop" else "bolt",
			variant = if p.up then "outline" else "primary",
			controlSize = "sm",
			enabled = not busy,
			onClick = function()
				send(if p.up then "disconnect" else "connect")
			end,
		})
	))

	if p.up then
		local where = p.server or ""
		if (p.location or "") ~= "" then
			where = `{where} · {p.location}`
		end
		local details = {}
		if (p.ip or "") ~= "" then
			table.insert(details, `IP {p.ip}`)
		end
		if (p.load or "") ~= "" then
			table.insert(details, tr("proton.load", { load = p.load }))
		end
		if (p.protocol or "") ~= "" then
			table.insert(details, p.protocol)
		end
		local lines = { ui.label({ text = where, fontSize = 13, color = "primary", fontWeight = "semibold" }) }
		if #details > 0 then
			table.insert(lines, ui.label({ text = table.concat(details, "  ·  "), fontSize = 11, color = "on_surface_variant" }))
		end
		table.insert(children, ui.column({ gap = 2 }, lines))
	end

	if (p.error or "") ~= "" and not p.up and not busy then
		table.insert(children, notice("error", p.error))
	end

	-- Favourite countries
	local current = tostring(p.server or ""):sub(1, 2):upper()
	local favButtons = {}
	for _, code in ipairs(favs) do
		local cc = noctalia.string.trim(tostring(code)):upper()
		if cc:match("^%u%u$") then
			local selected = p.up and current == cc
			table.insert(favButtons, ui.button({
				key = `fav-{cc}`,
				text = cc,
				variant = if selected then "primary" else "outline",
				controlSize = "sm",
				flexGrow = 1,
				enabled = not busy and not selected,
				onClick = function()
					send("connect", cc)
				end,
			}))
		end
	end

	local countries = s.countries or {}
	if #favButtons > 0 or #countries > 0 then
		table.insert(children, sectionLabel(tr("proton.quick")))
	end
	if #favButtons > 0 then
		table.insert(children, ui.row({ gap = 6 }, favButtons))
	end

	-- Any other country. The first option doubles as the placeholder.
	if #countries > 0 then
		local names = { tr("proton.other_country") }
		for _, c in ipairs(countries) do
			table.insert(names, `{c.name} ({c.code})`)
		end
		table.insert(children, ui.select({
			key = "country-select",
			options = names,
			selectedIndex = 0,
			controlSize = "sm",
			enabled = not busy,
			onChange = function(index)
				local c = countries[tonumber(index) or 0]
				if c then
					send("connect", c.code)
				end
			end,
		}))
	end

	return card(p.up, children)
end

local function protectionCard()
	local cfg = s.config or {}
	local ksOn = cfg.killSwitch == "standard"
	local ns = cfg.netshield or "off"

	local function nsButton(value, labelKey)
		return ui.button({
			key = `ns-{value}`,
			text = tr(labelKey),
			variant = if ns == value then "primary" else "outline",
			controlSize = "sm",
			flexGrow = 1,
			onClick = function()
				send("netshield", value)
			end,
		})
	end

	return card(false, {
		sectionLabel(tr("protection.title")),
		infoRow("shield-lock", ksOn, tr("protection.killswitch"), tr("protection.killswitch_desc"), ui.toggle({
			checked = ksOn,
			onChange = function(v)
				send("killswitch", if isOn(v) then "standard" else "off")
			end,
		})),
		infoRow("filter", ns ~= "off", tr("protection.netshield"), tr("protection.netshield_desc"), nil),
		ui.row({ gap = 6 }, {
			nsButton("off", "protection.netshield_off"),
			nsButton("malware-only", "protection.netshield_malware"),
			nsButton("malware-ads-trackers", "protection.netshield_all"),
		}),
	})
end

-- ── WireGuard ─────────────────────────────────────────────────────────────

local function wireguardCard()
	local conns = (s.wg and s.wg.connections) or {}
	local p = s.proton or {}
	local dns = s.dns or {}
	local anyUp = false
	local children = { sectionLabel("WIREGUARD") }

	for _, c in ipairs(conns) do
		local up = c.state == "activated"
		anyUp = anyUp or up
		local status
		if c.busy or c.state == "activating" or c.state == "deactivating" then
			status = tr("status.working")
		elseif up then
			status = tr("status.connected")
			if (c.device or "") ~= "" and c.device ~= c.name then
				status = `{status} · {c.device}`
			end
		else
			status = tr("status.disconnected")
		end
		local uuid = c.uuid
		table.insert(children, infoRow("network", up, c.name, status, ui.toggle({
			checked = up,
			enabled = not c.busy,
			onChange = function(v)
				send(if isOn(v) then "wg_up" else "wg_down", uuid)
			end,
		}), `wg-{uuid}`))
	end

	if p.up and anyUp then
		local host = dns.host or ""
		if host == "" then
			table.insert(children, notice("info", tr("wg.dns_hint")))
		elseif dns.checked and dns.ok == false then
			table.insert(children, notice("error", tr("wg.dns_fail", { host = host })))
		elseif dns.checked then
			table.insert(children, notice("info", tr("wg.dns_ok", { host = host })))
		end
	end

	return card(anyUp, children)
end

-- ── Render ────────────────────────────────────────────────────────────────

local function render()
	local p = s.proton or {}
	local wg = s.wg or {}
	local conns = wg.connections or {}

	local protonReady = p.installed == true and p.signedIn == true
	local wgReady = #conns > 0
	local loading = not (p.checked and wg.checked)

	local body = {}
	if loading then
		table.insert(body, ui.label({ text = tr("panel.loading"), fontSize = 12, color = "on_surface_variant" }))
	elseif not protonReady and not wgReady then
		table.insert(body, notice("info", tr("panel.control_only")))
	else
		if protonReady then
			table.insert(body, protonCard())
			table.insert(body, protectionCard())
		else
			local button = nil
			local hint = tr("missing.proton_install")
			if p.installed then
				hint = tr("missing.proton_signin")
				button = ui.button({
					text = tr("proton.signin"),
					glyph = "login",
					variant = "primary",
					controlSize = "sm",
					onClick = function()
						send("signin")
					end,
				})
			end
			table.insert(body, missingCard(tr("missing.proton"), hint, button))
		end

		if wgReady then
			table.insert(body, wireguardCard())
		else
			local hint = if wg.available then tr("missing.wireguard_hint") else tr("missing.nmcli")
			table.insert(body, missingCard(tr("missing.wireguard"), hint, nil))
		end
	end

	panel.render(ui.column({ gap = 10, align = "stretch" }, {
		ui.row({ align = "center", gap = 8 }, {
			ui.glyph({ name = "shield-lock", size = 20, color = "primary" }),
			ui.label({ text = tr("title"), fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
			ui.button({
				glyph = "refresh",
				variant = "ghost",
				controlSize = "sm",
				tooltip = tr("panel.refresh"),
				onClick = function()
					send("refresh")
				end,
			}),
		}),
		ui.column({ gap = 10, align = "stretch" }, body),
	}))
end

noctalia.state.watch(STATE_KEY, function(value)
	if type(value) == "table" then
		s = value
		render()
	end
end)

function onOpen()
	send("refresh")
	render()
end

render()
