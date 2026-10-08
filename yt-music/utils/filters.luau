--!strict
local EXPO = {}

EXPO.LIBRARY =
	[[{ playlists: [.. | select(.musicTwoRowItemRenderer? != null) | .musicTwoRowItemRenderer | { id: (.navigationEndpoint.browseEndpoint.browseId // ""), title: (.title.runs[0].text // ""), subtitle: ([.subtitle.runs[]?.text] | join("")) , thumbnail_url: (.thumbnailRenderer.musicThumbnailRenderer.thumbnail.thumbnails[-1].url // "")} | select(.id != "" and .title != "")] | unique_by(.id) }]]

EXPO.PLAYLIST_PAGE =
	[[{ tracks: [.. | .musicResponsiveListItemRenderer? | select(. != null) | { id: (.playlistItemData.videoId // .navigationEndpoint.watchEndpoint.videoId // ""), title: (.flexColumns[0].musicResponsiveListItemFlexColumnRenderer.text.runs[0].text // ""), artist: (.flexColumns[1].musicResponsiveListItemFlexColumnRenderer.text.runs[0].text // ""), duration_text: (.fixedColumns[0].musicResponsiveListItemFixedColumnRenderer.text.runs[0].text // ""), thumbnail_url: (.thumbnail.musicThumbnailRenderer.thumbnail.thumbnails[-1].url // "") } | select(.id != "")], count_text: ([.. | .musicResponsiveHeaderRenderer? | select(. != null) | (.subtitle?.runs // []) + (.secondSubtitle?.runs // []) | .[]?.text | select(. != null and test("song|track"))] | .[0] // null), next_token: ([.. | (.continuationCommand?.token // .nextContinuationData?.continuation) | select(. != null and . != "")] | .[0] // null) }]]

EXPO.ARTIST_PAGE =
	[[{ tracks: [.. | .musicResponsiveListItemRenderer? | select(. != null) | { id: (.playlistItemData.videoId // .overlay.musicItemThumbnailOverlayRenderer.content.musicPlayButtonRenderer.playNavigationEndpoint.watchEndpoint.videoId // ""), title: (.flexColumns[0].musicResponsiveListItemFlexColumnRenderer.text.runs[0].text // ""), artist: (.flexColumns[1].musicResponsiveListItemFlexColumnRenderer.text.runs | map(select(.text != null).text) | join("") // ""), duration_text: (.fixedColumns[0].musicResponsiveListItemFixedColumnRenderer.text.runs[0].text // ""), thumbnail_url: (.thumbnail.musicThumbnailRenderer.thumbnail.thumbnails[-1].url // "") } | select(.id != "" and .title != "")] | unique_by(.id) | .[0:30], related: [.. | .musicTwoRowItemRenderer? | select(. != null) | { id: (.navigationEndpoint.browseEndpoint.browseId // ""), title: (.title.runs[0].text // ""), artist: (.subtitle.runs[0].text // ""), thumbnail_url: (.thumbnailRenderer.musicThumbnailRenderer.thumbnail.thumbnails[-1].url // .thumbnail.musicThumbnailRenderer.thumbnail.thumbnails[-1].url // "") } | select(.id != "" and .title != "" and ((.id | startswith("MPRE")) or (.id | startswith("VL"))))] | unique_by(.id) | .[0:8] }]]

EXPO.QUICK_PICKS =
	[[{ tracks: [.. | select(.musicResponsiveListItemRenderer? != null) | .musicResponsiveListItemRenderer | { id: (.playlistItemData.videoId // .navigationEndpoint.watchEndpoint.videoId // ""), title: (.flexColumns[0].musicResponsiveListItemFlexColumnRenderer.text.runs[0].text // ""), artist: (.flexColumns[1].musicResponsiveListItemFlexColumnRenderer.text.runs[0].text // ""), duration_text: (.fixedColumns[0].musicResponsiveListItemFixedColumnRenderer.text.runs[0].text // ""), thumbnail_url: (.thumbnail.musicThumbnailRenderer.thumbnail.thumbnails[-1].url // "") } | select(.id != "" and .title != "")] | unique_by(.id) | .[0:15], mixes: [.. | select(.musicTwoRowItemRenderer? != null) | .musicTwoRowItemRenderer | { id: (.navigationEndpoint.browseEndpoint.browseId // .navigationEndpoint.watchEndpoint.playlistId // ""), title: (.title.runs[0].text // ""), subtitle: (.subtitle.runs[0].text // ""), videoId: (.navigationEndpoint.watchEndpoint.videoId // ""), thumbnail_url: (.thumbnailRenderer.musicThumbnailRenderer.thumbnail.thumbnails[-1].url // .thumbnail.musicThumbnailRenderer.thumbnail.thumbnails[-1].url // "") } | select(.id != "" and .title != "" and .videoId == "" and (.id | test("^(VL)?RD")) and (.subtitle != "Album") and (.subtitle != "Playlist") and (.subtitle != "Song") and (.subtitle != "Single") and (.subtitle | endswith("subscribers") | not))] | unique_by(.id) | .[0:60] }]]

EXPO.SEARCH_PLAYLISTS = [[{
  playlists: [.. | select(.musicResponsiveListItemRenderer? != null) | .musicResponsiveListItemRenderer |
    # pageType must be read off the RAW row; past the object pipe it no longer exists.
    (.navigationEndpoint.browseEndpoint.browseEndpointContextSupportedConfigs.browseEndpointContextMusicConfig.pageType // "") as $pt |
    {
    id: (.navigationEndpoint.browseEndpoint.browseId // ""),
    title: (.flexColumns[0].musicResponsiveListItemFlexColumnRenderer.text.runs[0].text // ""),
    artist: (.flexColumns[1].musicResponsiveListItemFlexColumnRenderer.text.runs | map(select(.text != null).text) | join("") // ""),
    thumbnail_url: (.thumbnail.musicThumbnailRenderer.thumbnail.thumbnails[-1].url // "")
  } | select(
      (.id != "" and .title != "")
      and ($pt == "MUSIC_PAGE_TYPE_PLAYLIST")
  )],
  token: ([.. | objects | select(has("nextContinuationData")) | .nextContinuationData.continuation] | last // "")
}]]

EXPO.SEARCH_TOP =
	[[  ([.. | objects | select(has("musicCardShelfRenderer")) | .musicCardShelfRenderer] | .[0] // null) as $rawcard
  |
  ([
    .. | objects | select(has("musicCardShelfRenderer")) | .musicCardShelfRenderer |
    .contents[]? |
    .. | objects | select(has("musicResponsiveListItemRenderer")) |
    .musicResponsiveListItemRenderer |
    (.playlistItemData.videoId // "")
  ] | map(select(. != ""))) as $skip
  |
  # Artist identity lives on the card TITLE navigation only; scanning the
  # whole subtree would catch per-row "Go to artist" menus of song cards.
  ([$rawcard.title.runs[]? | select((.navigationEndpoint.browseEndpoint.browseEndpointContextSupportedConfigs.browseEndpointContextMusicConfig.pageType // "") == "MUSIC_PAGE_TYPE_ARTIST") | .navigationEndpoint.browseEndpoint.browseId] | .[0] // null) as $card_artist_id
  |
  ([$rawcard | select(((.onTap.watchEndpoint.videoId // "") != "") or ($card_artist_id != null)) | {
    id: ((.onTap.watchEndpoint.videoId // $card_artist_id) // ""),
    kind: (if (.onTap.watchEndpoint.videoId // "") != "" then "song" elif ($card_artist_id != null) then "artist" else "song" end),
    title: (.title.runs[0].text // ""),
    artist: ([.subtitle.runs[].text] | join("")),
    thumbnail_url: (.thumbnail.musicThumbnailRenderer.thumbnail.thumbnails[-1].url // "")
  }] | .[0] // null) as $card
  |
  {
    results: reduce (
      ($card // empty),
      (.. | select(.musicResponsiveListItemRenderer? != null) | .musicResponsiveListItemRenderer |
        ((.playlistItemData.videoId // "") as $vid |
         (.navigationEndpoint.browseEndpoint.browseId // "") as $bid |
         (.navigationEndpoint.browseEndpoint.browseEndpointContextSupportedConfigs.browseEndpointContextMusicConfig.pageType // "") as $pt |
         select($vid != "" or $bid != "") |
         select(($skip | index($vid)) == null) |
         {
           id: (if $vid != "" then $vid else $bid end),
           kind: (if $vid != "" then "song" elif $pt == "MUSIC_PAGE_TYPE_ALBUM" or ($bid | test("^MPREb")) then "album" elif $pt == "MUSIC_PAGE_TYPE_PLAYLIST" or ($bid | test("^(VL|RD|PL)")) then "playlist" elif $pt == "MUSIC_PAGE_TYPE_ARTIST" or ($bid | test("^UC")) then "artist" else "other" end),
           title: (.flexColumns[0].musicResponsiveListItemFlexColumnRenderer.text.runs[0].text // ""),
           artist: (.flexColumns[1].musicResponsiveListItemFlexColumnRenderer.text.runs | map(select(.text != null).text) | join("") // ""),
           album: (.flexColumns[2].musicResponsiveListItemFlexColumnRenderer.text.runs[0].text // ""),
           duration_text: (.fixedColumns[0].musicResponsiveListItemFixedColumnRenderer.text.runs[0].text // ""),
           thumbnail_url: (.thumbnail.musicThumbnailRenderer.thumbnail.thumbnails[-1].url // "")
         }))
    ) as $it ([]; if (map(.id) | index($it.id)) then . else . + [$it] end)
  }]]

EXPO.SEARCH_TRACKS = [[{
  tracks: [.. | select(.musicResponsiveListItemRenderer? != null) | .musicResponsiveListItemRenderer | {
    id: (.playlistItemData.videoId // .navigationEndpoint.browseEndpoint.browseId // .overlay.musicItemThumbnailOverlayRenderer.content.musicPlayButtonRenderer.playNavigationEndpoint.watchEndpoint.videoId // .doubleTapCommand.watchEndpoint.videoId // ""),
    kind: (
      (.playlistItemData.videoId // "") as $vid |
      (.navigationEndpoint.browseEndpoint.browseId // "") as $bid |
      (.navigationEndpoint.browseEndpoint.browseEndpointContextSupportedConfigs.browseEndpointContextMusicConfig.pageType // "") as $pt |
      if $vid != "" then "song"
      elif $pt == "MUSIC_PAGE_TYPE_ARTIST" or ($bid | test("^UC")) then "artist"
      elif $pt == "MUSIC_PAGE_TYPE_ALBUM" or ($bid | test("^MPREb")) then "album"
      elif ($bid | test("^(VL|RD|PL)")) then "playlist"
      else "song"
      end
    ),
    title: (.flexColumns[0].musicResponsiveListItemFlexColumnRenderer.text.runs[0].text // ""),
    artist: (.flexColumns[1].musicResponsiveListItemFlexColumnRenderer.text.runs | map(select(.text != null).text) | join("") // ""),
    album: (.flexColumns[2].musicResponsiveListItemFlexColumnRenderer.text.runs[0].text // ""),
    duration_text: (.fixedColumns[0].musicResponsiveListItemFixedColumnRenderer.text.runs[0].text // ""),
    thumbnail_url: (.thumbnail.musicThumbnailRenderer.thumbnail.thumbnails[-1].url // "")
  } | select(.id != "" and .title != "")] | unique_by(.id)
}]]

return EXPO
