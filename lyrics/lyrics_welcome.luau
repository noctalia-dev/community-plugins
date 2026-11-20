--!nonstrict

local M = {}
local commands = { "playerctl", "python3", "cp", "chmod", "timeout" }
local distributions = { "arch", "debian", "fedora", "nixos", "other" }
local instructions = {
  arch = "sudo pacman -S playerctl python coreutils",
  debian = "sudo apt install playerctl python3 coreutils",
  fedora = "sudo dnf install playerctl python3 coreutils",
  nixos = "environment.systemPackages = with pkgs; [ playerctl python3 coreutils ];",
}
local availability = {}
local ssl = "checking"
local generation = 0
local distro
local copied = false

local function tr(key)
  return noctalia.tr("welcome." .. key)
end

local function detectDistribution()
  local release = noctalia.readFile("/etc/os-release") or ""
  local families = {}
  for line in release:gmatch("[^\r\n]+") do
    local key, value = line:match("^(%u[%u_]*)=(.*)$")
    if key == "ID" or key == "ID_LIKE" then
      for word in value:gmatch("[%w_-]+") do families[word] = true end
    end
  end
  if families.nixos then return "nixos" end
  if families.arch or families.archlinux then return "arch" end
  if families.debian or families.ubuntu then return "debian" end
  if families.fedora then return "fedora" end
  return "other"
end

function M.check(onChange)
  generation += 1
  local current = generation
  distro = distro or detectDistribution()
  copied = false
  for _, command in ipairs(commands) do
    availability[command] = noctalia.commandExists(command) == true
  end
  if not availability.python3 then
    ssl = "unavailable"
    return
  end
  ssl = "checking"
  local started = noctalia.runAsync("python3 -c 'import ssl'", function(result)
    if current ~= generation then return end
    ssl = result.exitCode == 0 and "ready" or "missing"
    onChange()
  end, 3000)
  if not started then ssl = "unavailable" end
end

function M.ready()
  if ssl ~= "ready" then return false end
  for _, command in ipairs(commands) do
    if not availability[command] then return false end
  end
  return true
end

function M.view(onChange)
  local ready = M.ready()
  local cards = {}
  local function dependency(name, status)
    local missing = status == "missing"
    local readyColor = status == "ready" and "primary" or "on_surface_variant"
    local color = missing and "error" or readyColor
    cards[#cards + 1] = ui.column({ gap = 5, flexGrow = 1, width = 148 }, {
      ui.label({ text = name, fontSize = 12, fontWeight = "semibold" }),
      ui.row({
        height = 35,
        gap = 6,
        align = "center",
        justify = "center",
        radius = 10,
        fill = "surface_container",
        border = missing and "error" or "outline_variant",
        borderWidth = missing and 2 or 1,
      }, {
        ui.glyph({ name = missing and "circle-alert" or (status == "ready" and "check" or "minus"),
          size = 14, color = color }),
        ui.label({ text = tr(status), fontSize = 11, color = color }),
      }),
    })
  end
  for _, command in ipairs(commands) do
    dependency(command, availability[command] and "ready" or "missing")
  end
  dependency("Python SSL", ssl)
  local items = {
    ui.row({ gap = 12 }, { cards[1], cards[2], cards[3] }),
    ui.row({ gap = 12 }, { cards[4], cards[5], cards[6] }),
  }

  if ready then
    items[#items + 1] = ui.label({ text = tr("next_steps"), maxLines = 4 })
  else
    items[#items + 1] = ui.label({ text = tr("install"), color = "on_surface_variant", maxLines = 2 })
    local choices = {}
    for _, id in ipairs(distributions) do
      choices[#choices + 1] = ui.button({ text = tr(id), controlSize = "sm",
        variant = id == distro and "primary" or "ghost", onClick = function()
          distro = id
          copied = false
          onChange()
        end })
    end
    items[#items + 1] = ui.row({ gap = 3 }, choices)
    local command = instructions[distro]
    if command then
      items[#items + 1] = ui.row({ gap = 8, align = "center", padding = 10, radius = 10, fill = "surface_container" }, {
        ui.label({ text = command, fontSize = 12, maxLines = 3, flexGrow = 1 }),
        ui.button({ text = tr(copied and "copied" or "copy"), controlSize = "sm", onClick = function()
          if noctalia.copyToClipboard(command, "text/plain") then copied = true end
          onChange()
        end }),
      })
    end
    items[#items + 1] = ui.label({ text = tr(distro == "nixos" and "apply_nixos" or "recheck_hint"),
      color = "on_surface_variant", fontSize = 11, maxLines = 3 })
  end
  return ui.scroll({ key = "setup", flexGrow = 1, gap = 9, align = "stretch" }, items)
end

return M
