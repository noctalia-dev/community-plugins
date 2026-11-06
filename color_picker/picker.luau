--!nonstrict

local COLORSPACE = noctalia.getConfig("main-colorspace")
local color_utils = require("./color.luau")
local picker = {}

local function buildHyprpickerArgs()
  local args = { "hyprpicker", "-a" }

  if COLORSPACE ~= "hex" then
    table.insert(args, "-f")
    table.insert(args, COLORSPACE)
  end

  -- Off a TTY, hyprpicker prints through printf and swallows "% 9%" from its default hsl
  -- template ("240 5% 9%" -> "240 5%"). A template without "%" keeps the output intact.
  if COLORSPACE == "hsl" then
    table.insert(args, "-o")
    table.insert(args, "'{0} {1} {2}'")
  end

  if noctalia.getConfig("hyprpicker-cursor") then
    table.insert(args, "--cursor")
  end

  if noctalia.getConfig("hyprpicker-disable-preview") then
    table.insert(args, "--disable-preview")
  end

  if noctalia.getConfig("lowercase-hex") then
    table.insert(args, "--lowercase-hex")
  end

  if noctalia.getConfig("hyprpicker-no-zoom") then
    table.insert(args, "--no-zoom")
    return args
  end

  local scale = noctalia.getConfig("hyprpicker-scale")
  if scale ~= nil then
    table.insert(args, "--scale=" .. tostring(scale))
  end

  local radius = noctalia.getConfig("hyprpicker-radius")
  if radius ~= nil then
    table.insert(args, "--radius=" .. tostring(radius))
  end

  return args
end

function picker.runPicker(onResult)
  local tr_color_picker = noctalia.tr("color_picker")
  local tr = function(k, subst)
    if subst then
      return noctalia.tr(k, subst)
    end
    return noctalia.tr(k)
  end

  local selected_picker = noctalia.getConfig("picker_tool") or "hyprpicker"

  if selected_picker == "hyprpicker" then
    if not noctalia.commandExists("hyprpicker") then
      noctalia.notifyError(tr_color_picker, tr("tool_missing", { tool = "hyprpicker" }))
      onResult(nil, nil)
      return
    end

    local argv = table.concat(buildHyprpickerArgs(), " ")
    noctalia.log("[COLOR PICKER] hyprpicker args = " .. argv)

    noctalia.runAsync(argv, function(result)
      if result.exitCode ~= 0 then
        onResult(nil, nil)
        return
      end

      local color = color_utils.parsePickerOutput(result.stdout or "")
      if color == nil then
        noctalia.notifyError(tr_color_picker, tr("could_not_parse"))
        noctalia.log("[COLOR PICKER] hyprpicker stdout = " .. (result.stdout or ""))
        onResult(nil, nil)
        return
      end

      local copyText = color
      if COLORSPACE == "rgb" then
        copyText = color_utils.formatRgb(color, 1)
      elseif COLORSPACE == "hsl" then
        copyText = color_utils.formatHsl(color, 1)
      elseif noctalia.getConfig("lowercase-hex") then
        copyText = color:lower()
      end

      noctalia.copyToClipboard(copyText, "text/plain;charset=utf-8")
      onResult(color, copyText)
    end, 60000)
  elseif selected_picker == "grim_slurp" then
    local missing = {}
    if not noctalia.commandExists("grim") then
      table.insert(missing, "grim")
    end
    if not noctalia.commandExists("slurp") then
      table.insert(missing, "slurp")
    end

    if #missing > 0 then
      local toolStr = table.concat(missing, " and ")
      noctalia.notifyError(tr_color_picker, tr("tool_missing", { tool = toolStr }))
      onResult(nil, nil)
      return
    end

    -- Freeze screen with grim before slurp opens to prevent overlay artifacts.
    -- Click coordinates are mapped to the outputs' logical layout to extract 3 RGB bytes via od.
    -- Exit codes: 1 = slurp cancelled, 2 = grim failed.
    local minx, miny, maxx, maxy = math.huge, math.huge, -math.huge, -math.huge
    for _, o in ipairs(noctalia.outputs()) do
      minx, miny = math.min(minx, o.x), math.min(miny, o.y)
      maxx, maxy = math.max(maxx, o.x + o.width), math.max(maxy, o.y + o.height)
    end
    if minx == math.huge then
      noctalia.notifyError(tr_color_picker, tr("could_not_parse"))
      noctalia.log("[COLOR PICKER] grim+slurp: no outputs reported")
      onResult(nil, nil)
      return
    end

    local cmd = string.format("MINX=%d MINY=%d LW=%d LH=%d\n", minx, miny, maxx - minx, maxy - miny)
      .. [[
f=$(mktemp "${XDG_RUNTIME_DIR:-/tmp}/color-picker.XXXXXX") || exit 2
trap 'rm -f "$f"' EXIT INT TERM
grim -t ppm "$f" || exit 2
pos=$(slurp -b 00000000 -c 00000000 -p) || exit 1
x=${pos%%,*}; pos=${pos#*,}; y=${pos%% *}
size=$(head -n 2 "$f" | tail -n 1); w=${size% *}; h=${size#* }
hlen=$(head -n 3 "$f" | wc -c)
px=$(( (2 * (x - MINX) + 1) * w / (2 * LW) ))
py=$(( (2 * (y - MINY) + 1) * h / (2 * LH) ))
tail -c +$(( hlen + (py * w + px) * 3 + 1 )) "$f" | head -c 3 | od -An -tu1
]]

    noctalia.runAsync(cmd, function(result)
      if result.exitCode ~= 0 and result.exitCode ~= 2 then
        onResult(nil, nil)
        return
      end

      local r, g, b = (result.stdout or ""):match("(%d+)%s+(%d+)%s+(%d+)")
      if r then
        local hex = string.format(
          "#%02X%02X%02X",
          tonumber(r) :: number,
          tonumber(g) :: number,
          tonumber(b) :: number
        )

        local copyText = hex
        if COLORSPACE == "rgb" then
          copyText = color_utils.formatRgb(hex, 1)
        elseif COLORSPACE == "hsl" then
          copyText = color_utils.formatHsl(hex, 1)
        elseif noctalia.getConfig("lowercase-hex") then
          copyText = hex:lower()
        end

        noctalia.copyToClipboard(copyText, "text/plain;charset=utf-8")
        onResult(hex, copyText)
      else
        noctalia.notifyError(tr_color_picker, tr("could_not_parse"))
        noctalia.log(
          "[COLOR PICKER] grim+slurp failed, code="
            .. tostring(result.exitCode)
            .. " stdout="
            .. tostring(result.stdout)
            .. " stderr="
            .. tostring(result.stderr)
        )
        onResult(nil, nil)
      end
    end, 60000)
  end
end

return picker
