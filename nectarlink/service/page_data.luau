--!nonstrict
-- Validation and projections of untrusted page replies.
local M = {}

---@alias NectarLinkSection "messages"|"calls"|"photos"|"apps"|"deck"

---@class NectarLinkPageItem
---@field id string
---@field thumbnailPath string?
---@field iconPath string?
---@field title string?

---@class NectarLinkPageData
---@field items NectarLinkPageItem[]
---@field albums table[]?
---@field photoDetailsIncomplete boolean?

local pageText = { "notice", "appScope" }
local pageFlags = {
  "more", "reply", "dial", "control", "smsIncomplete", "localChatsIncomplete", "photoDetailsIncomplete",
}
local itemText = { "title", "subtitle", "kind", "number", "thumbnailPath", "iconPath", "appScope" }
local itemNumbers = { "date", "size", "duration" }
local itemFlags = { "outgoing" }
local albumText = { "name" }
local callText = { "id", "name", "number" }
local previewFields = { photos = "thumbnailPath", apps = "iconPath" }

---@param value unknown
---@return boolean
local function safeNumber(value)
  return type(value) == "number" and value >= -9007199254740991 and value <= 9007199254740991
end

local function optionalFields(row, keys, expected)
  for _, key in ipairs(keys) do
    local field = row[key]
    if field ~= nil and (type(field) ~= expected or (expected == "number" and not safeNumber(field))) then
      return false
    end
  end
  return true
end

---@param values unknown
---@param validItem fun(value: unknown): boolean
---@return boolean
local function validArray(values, validItem)
  if type(values) ~= "table" then return false end
  local length, count = #values, 0
  for index, value in pairs(values) do
    if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > length or not validItem(value) then
      return false
    end
    count = count + 1
  end
  return count == length
end

local function isString(value)
  return type(value) == "string"
end

local function validItem(item)
  return type(item) == "table"
    and type(item.id) == "string"
    and optionalFields(item, itemText, "string")
    and optionalFields(item, itemNumbers, "number")
    and optionalFields(item, itemFlags, "boolean")
    and (item.size == nil or item.size >= 0)
    and (item.duration == nil or item.duration >= 0)
    and (item.addresses == nil or validArray(item.addresses, isString))
end

local function validAlbum(album)
  return type(album) == "table" and type(album.id) == "string" and optionalFields(album, albumText, "string")
end

local function validCall(call)
  return type(call) == "table" and type(call.state) == "string" and optionalFields(call, callText, "string")
    and (call.state == "ended" or type(call.id) == "string")
end

--- Reject malformed fields before a reply can replace a working cache entry.
---@param data unknown
---@return boolean
function M.valid(data)
  return type(data) == "table"
    and optionalFields(data, pageText, "string")
    and optionalFields(data, pageFlags, "boolean")
    and validArray(data.items, validItem)
    and (data.albums == nil or validArray(data.albums, validAlbum))
    and (data.active == nil or validCall(data.active))
end

---@generic K, V
---@param value table<K, V>
---@return table<K, V>
local function shallowCopy(value)
  local result = {}
  for key, field in pairs(value) do result[key] = field end
  return result
end

--- Strip missing images only from the visible projection, not the cache.
---@param data NectarLinkPageData
---@param section NectarLinkSection
---@param fileExists (fun(path: string): boolean)?
---@return NectarLinkPageData, boolean
function M.previews(data, section, fileExists)
  local field = previewFields[section]
  if not field or not fileExists then return data, true end
  local items
  for index, row in ipairs(data.items) do
    local path = row[field]
    if type(path) == "string" and not fileExists(path) then
      items = items or shallowCopy(data.items)
      local displayRow = shallowCopy(row)
      displayRow[field] = nil
      items[index] = displayRow
    end
  end
  if not items then return data, true end
  local display = shallowCopy(data)
  display.items = items
  return display, false
end

--- Return the IDs that still need a photo preview.
---@param data NectarLinkPageData
---@return string[]
function M.missingThumbnails(data)
  local ids = {}
  for _, row in ipairs(data.items) do
    if not row.thumbnailPath then ids[#ids + 1] = row.id end
  end
  return ids
end

--- Merge the second photo reply without editing rows shared with an earlier view.
---@param data NectarLinkPageData
---@param details NectarLinkPageData
---@return NectarLinkPageData, boolean
function M.mergePhotoDetails(data, details)
  local paths = {}
  for _, row in ipairs(details.items) do paths[row.id] = row.thumbnailPath end
  local merged = shallowCopy(data)
  merged.albums = details.albums or data.albums
  merged.items = {}
  local complete = merged.albums ~= nil and details.photoDetailsIncomplete ~= true
  for index, row in ipairs(data.items) do
    local path = paths[row.id]
    if path and path ~= row.thumbnailPath then
      row = shallowCopy(row)
      row.thumbnailPath = path
    end
    merged.items[index] = row
    if not row.thumbnailPath then complete = false end
  end
  return merged, complete
end

return M
