-- ----------------------------------------------------------------------------
-- Shared data shapes (mirrored from api.luau parsers + service.luau snapshot)
-- Fields the parsers always produce are required; conditional ones are '?'.
-- ----------------------------------------------------------------------------

export type Track = {
    id: string,
    title: string,
    artist: string,
    album: string?,
    duration: number?,
    duration_text: string?,
    thumbnail_url: string?,
    thumb_path: string?,
}

-- Library rows (browse.luau) carry count; search playlist rows carry artist.
-- Tracks are NOT nested on the playlist object; use playlist_page's result for those.
export type Playlist = {
    id: string,
    title: string,
    count: number?,
    artist: string?,
    thumbnail_url: string?,
    thumb_path: string?,
}

export type PlaylistPageResult = {
    tracks: { Track },
    next_token: string?,
    total_count: number?,
}

-- Search results mix song rows (Track, no type) and playlist rows
-- (type = "playlist", matching Playlist with an explicit discriminator).
export type SearchResult = Track | (Playlist & { type: string? })

export type Player = {
    status: string,
    title: string,
    artist: string,
    id: string,
    position: number,
    duration: number,
    volume: number,
    index: number,
    shuffle: boolean,
    repeat_mode: string,
    queue: { Track },
    thumbnail_url: string?,
    thumb_path: string?,
    codec_fetched: boolean?,
    bitrate: number?,
    codec: string?,
    samplerate: number?,
    views: number?,
    likes: number?,
}

return {}
