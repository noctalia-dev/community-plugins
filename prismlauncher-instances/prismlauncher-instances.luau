--!nonstrict

local function getPrismPath()
    local prismPath = noctalia.getConfig("prism_path")
    return noctalia.expandPath(prismPath)
end

local function getInstancesDir()
    local prismPath = getPrismPath()

    local configuredInstanceDir = getCfgValue(prismPath .. "/prismlauncher.cfg", "InstanceDir")

    local instances
    if configuredInstanceDir == nil then -- default path
        instances = prismPath .. "/instances"
    elseif configuredInstanceDir:sub(1, 1) == "/" then -- absolute path
        instances = configuredInstanceDir
    else -- relative path
        instances = prismPath .. "/" .. configuredInstanceDir
    end
    return instances
end

local function loadInstances()
    local instances = {}
    local list = noctalia.listDir(getInstancesDir())
      if list ~= nil then
        for _, name in ipairs(list) do
            local instanceDir = getInstancesDir() .. "/" .. name
            if name ~= "" and noctalia.fileExists(instanceDir .. "/instance.cfg") then -- same check as prism to only show instance dirs
                table.insert(instances, name)
            end
        end
      end
    return instances
end

local function instanceName(path)
  local instanceCfg = getInstancesDir() .. "/" .. path .. "/instance.cfg"
  local configuredName = getCfgValue(instanceCfg, "name")
  if configuredName ~= nil then
      return configuredName
  end
  return path:match("([^/]+)$") or path
end

local function filterInstances(instances, query)
  if query == "" then return instances end
  local results = {}
  for _, path in instances do
    local insName = instanceName(path)
    if insName:lower():find(query:lower(), 1, true) then
      table.insert(results, path)
    end
  end
  return results
end

local function makeRows(instances)
  local rows = {}
  for _, path in instances do
    table.insert(rows, {
      id = path,
      title = instanceName(path),
      subtitle = path,
      icon = getIcon(path),
      glyph = "nut",
    })
  end
  return rows
end

local function showResults(query, instances, filter)
  local filtered = filterInstances(instances, filter)
  if #filtered == 0 then
    launcher.setResults(query, {
        { id = "", title = noctalia.tr("no_instances.title"), subtitle = filter ~= "" and noctalia.tr("no_instances.subtitle") .. filter, glyph = "folder-x" }
    })
  else
    launcher.setResults(query, makeRows(filtered))
  end
end

function onQuery(query)
  local filter = noctalia.string.trim(query)
  showResults(query,  loadInstances(), filter)
end

local function shellQuote(s)
  return "'" .. s:gsub("'", "'\"'\"'") .. "'"
end

function onActivate(id)
  if id == "" then return end
  noctalia.runAsync(string.format("prismlauncher --launch %s &>/dev/null", shellQuote(id)))
end

-- doesn't handle icons that were changed to different default icon, rest is fine
-- never change icons since creating instance => OK
-- change icon to manually provided icon or to icon from mod provider => OK
-- change icon to different default icon baked into prism binary => NOK, old icon will be shown because <instance>/minecraft/icon.png isn't updated
function getIcon(instancePath)
    local instanceFullPath = getInstancesDir() .. "/" .. instancePath
    local defaultIcon =  instanceFullPath .. "/minecraft/icon.png"
    local cfgPath = instanceFullPath .. "/instance.cfg"
    local iconVal = getCfgValue(cfgPath, "iconKey")
    if (iconVal == nil) then
        return defaultIcon
    end

    local iconDir = getPrismPath() .. "/icons/"
    local bestIcon = findBestIconIn(iconDir, iconVal)

    if (bestIcon == nil) then
        return defaultIcon
    end
    return bestIcon
end



-- https://github.com/PrismLauncher/PrismLauncher/blob/d2fa7cf7f7aa8fa5e3d4f5f7b474621c732cd525/launcher/icons/IconUtils.cpp
local validIconExtensions = { "svg", "png", "ico", "gif", "jpg", "jpeg", "webp" }

local function isIconSuffix(suffix)
    for _, ext in ipairs(validIconExtensions) do
        if ext == suffix then
            return true
        end
    end
    return false
end

local function splitNameAndSuffix(filename)
    local dotIndex = filename:find("%.[^.]*$")
    if not dotIndex then
        return filename, ""
    end
    local base = filename:sub(1, dotIndex - 1)
    local suffix = filename:sub(dotIndex + 1)
    return base, suffix
end

function findBestIconIn(folder, iconKey)
    local entries = noctalia.listDir(folder)
    if not entries then
        return nil
    end

    for _, filename in ipairs(entries) do
        local baseName, suffix = splitNameAndSuffix(filename)
        if (baseName == iconKey or filename == iconKey) and isIconSuffix(suffix) then
            local sep = folder:sub(-1) == "/" and "" or "/"
            return folder .. sep .. filename
        end
    end

    return nil
end



function getCfgValue(cfgPath, key) -- naive INI value fetcher, doesn't handle sections, it's enough for this usecase
    local content, err = noctalia.readFile(cfgPath)
    if not content then
        noctalia.log("Failed to read file ".. cfgPath .. " : " .. tostring(err))
        return nil
    end

    for line in content:gmatch("[^\r\n]+") do
        if line:sub(1, #key + 1) == key .. "=" then
            return line:sub(#key + 2)
        end
    end

    return nil
end
