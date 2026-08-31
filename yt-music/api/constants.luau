--!strict

-- Shared YT Music API constants.
-- Scope: api/* only. service.luau / panel.luau never touch these directly.

local XDG_CACHE = noctalia.getenv("XDG_CACHE_HOME")
local CACHE_ROOT = noctalia.expandPath(XDG_CACHE and XDG_CACHE ~= "" and XDG_CACHE or "~/.cache") .. "/yt-music"

local EXPO = {}

EXPO.KEY = "AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30"
EXPO.CLIENT_VERSION = "1.20240813.01.00"
EXPO.BASE = "https://music.youtube.com/youtubei/v1/"
EXPO.ORIGIN = "https://music.youtube.com"

EXPO.CACHE_DIR = CACHE_ROOT
EXPO.COOKIE_PATH = CACHE_ROOT .. "/cookies.txt"
EXPO.LIBRARY_CACHE_PATH = CACHE_ROOT .. "/library.json"
EXPO.RECENT_PLAYLISTS_CACHE_PATH = CACHE_ROOT .. "/recent_playlists.json"
EXPO.PLAYLISTS_CACHE_DIR = CACHE_ROOT .. "/playlists"
EXPO.SESSION_CACHE_PATH = CACHE_ROOT .. "/session.json"
EXPO.QUICK_PICKS_CACHE_PATH = CACHE_ROOT .. "/quick_picks.json"
EXPO.THUMB_DIR = CACHE_ROOT .. "/thumbnails"
EXPO.STREAMS_CACHE_DIR = CACHE_ROOT .. "/streams"
EXPO.AUDIO_DIR = CACHE_ROOT .. "/audio"
EXPO.STATS_CACHE_PATH = CACHE_ROOT .. "/stats.json"
EXPO.OFFLINE_META_PATH = CACHE_ROOT .. "/offline_meta.json"

EXPO.CONTEXT = {
	context = {
		client = {
			clientName = "WEB_REMIX",
			clientVersion = EXPO.CLIENT_VERSION,
			hl = "en",
		},
	},
}

return EXPO
