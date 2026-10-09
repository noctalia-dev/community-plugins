--!strict

-- like / unlike endpoints.

local logger = require("../utils/log.luau")
local log = logger.module("ytapi", "likes")

local helpers = require("../utils/helpers.luau")
local sanitize = helpers.sanitize

local const = require("./constants.luau")
local CONTEXT = const.CONTEXT

local it = require("./innerTube.luau")
local innerTube = it.innerTube

local EXPO = {}

function EXPO.like_video(video_id: string?, callback: ((boolean) -> ())?)
	if type(video_id) ~= "string" or video_id == "" then
		if callback then
			callback(false)
		end
		return
	end
	local safe_id = sanitize(video_id)
	innerTube("like/like", { context = CONTEXT.context, target = { videoId = safe_id } }, function(data, err)
		local ok = data ~= nil
		if not ok then
			log("like_video FAILED for id=" .. tostring(video_id) .. " err=" .. tostring(err))
		end
		if callback then
			callback(ok)
		end
	end)
end

function EXPO.unlike_video(video_id: string?, callback: ((boolean) -> ())?)
	if type(video_id) ~= "string" or video_id == "" then
		if callback then
			callback(false)
		end
		return
	end
	local safe_id = sanitize(video_id)
	innerTube("like/removelike", { context = CONTEXT.context, target = { videoId = safe_id } }, function(data, err)
		local ok = data ~= nil
		if not ok then
			log("unlike_video FAILED for id=" .. tostring(video_id) .. " err=" .. tostring(err))
		end
		if callback then
			callback(ok)
		end
	end)
end

return EXPO
