local PLAYERCTL = "/run/current-system/sw/bin/playerctl"


------------------------------------------------------------
-- FILE PATHS
------------------------------------------------------------

local LYRICS_DIR =
    "$HOME/.cache/noctalia/lyrics"

local LYRICS_FILE_1 =
    "$HOME/.cache/noctalia/lyrics/lyrics_1.lrc"

local LYRICS_FILE_2 =
    "$HOME/.cache/noctalia/lyrics/lyrics_2.lrc"


------------------------------------------------------------
-- SLOTS
------------------------------------------------------------

local slots = {
    {
        id = 1,
        file = LYRICS_FILE_1,

        player = "",
        title = "",
        artist = "",

        ------------------------------------------------
        -- OFFICIAL MPRIS POSITION
        ------------------------------------------------

        position = 0,

        ------------------------------------------------
        -- POSITION USED BY THE LYRIC RENDERER
        --
        -- This is corrected by MPRIS queries and
        -- progresses continuously through onFrameTick().
        ------------------------------------------------

        displayPosition = nil,

        videoTime = nil,
        lastVideoTime = nil,

        referenceTime = nil,

        seekCandidateTime = nil,
        seekCandidateCount = 0,

        lastResolvedLine = 0,
        lastResolvedVideoTime = nil,

        displayCenter = 0,

        visibleLyrics = {},
        lyrics = {},

        hasTimedLyrics = false,

        loaded = false,
        loading = false,

        state = "no_player",

        seek = "não",

        ------------------------------------------------
        -- DEAD ZONE DURING RELOAD.
        ------------------------------------------------

        seekReloading = false,

        ------------------------------------------------
        -- RECOVERY THROUGH A PHYSICAL PAUSE/PLAY.
        --
        -- When a seek is detected:
        --
        -- 1. wait for the pause/play cycle;
        -- 2. ignore positions during the transition;
        -- 3. wait for a new Playing state;
        -- 4. use that reading as the new reference.
        ------------------------------------------------

        quickPauseRecovery = false,
        quickPauseCommandRunning = false,

        ------------------------------------------------
        -- IDENTIFIES THE CURRENT SESSION.
        ------------------------------------------------

        sessionId = 0,

        lastLookupKey = "",
    },

    {
        id = 2,
        file = LYRICS_FILE_2,

        player = "",
        title = "",
        artist = "",

        position = 0,

        displayPosition = nil,

        videoTime = nil,
        lastVideoTime = nil,

        referenceTime = nil,

        seekCandidateTime = nil,
        seekCandidateCount = 0,

        lastResolvedLine = 0,
        lastResolvedVideoTime = nil,

        displayCenter = 0,

        visibleLyrics = {},
        lyrics = {},

        hasTimedLyrics = false,

        loaded = false,
        loading = false,

        state = "no_player",

        seek = "não",

        seekReloading = false,

        quickPauseRecovery = false,
        quickPauseCommandRunning = false,

        sessionId = 0,

        lastLookupKey = "",
    },
}


------------------------------------------------------------
-- ACTIVE SLOT
------------------------------------------------------------

local activeSlot = 1


------------------------------------------------------------
-- PLAYERCTL CONTROL
------------------------------------------------------------

local playerctlInFlight = false


------------------------------------------------------------
-- SETTINGS
------------------------------------------------------------

local LYRICS_OFFSET = 0


------------------------------------------------------------
-- SEEK DETECTION TOLERANCE
------------------------------------------------------------

local SEEK_THRESHOLD = 3.0

------------------------------------------------------------
-- MPRIS CLOCK CORRECTION
--
-- Pequenas diferenças entre MPRIS e o relógio local
-- NÃO devem reposicionar a letra.
--
-- O relógio local continua andando pelo onFrameTick().
------------------------------------------------------------

local CLOCK_CORRECTION_THRESHOLD = 1.0


------------------------------------------------------------
-- QUICK PAUSE DURING SEEK
------------------------------------------------------------

local SEEK_PAUSE_SECONDS = 0.01


------------------------------------------------------------
-- POSITION CACHE
------------------------------------------------------------

local MAX_POSITION_CACHE = 3

local positionCache = {}
local positionCacheOrder = {}


------------------------------------------------------------
-- LRC PARSER
------------------------------------------------------------

local function parseLrc(text)

    local result = {}

    for line in text:gmatch(
        "[^\r\n]+"
    ) do

        for minutes,
            seconds,
            hundredths,
            lyric
            in line:gmatch(
                "%[(%d+):(%d+)%.(%d+)%]%s*(.*)"
            ) do

            local time =
                tonumber(minutes) * 60
                + tonumber(seconds)
                + tonumber(hundredths) / 100

            table.insert(
                result,
                {
                    time = time,
                    text = lyric,
                }
            )
        end
    end


    table.sort(
        result,

        function(a, b)
            return a.time < b.time
        end
    )


    return result
end


------------------------------------------------------------
-- PLAIN TEXT PARSER
------------------------------------------------------------

local function parsePlain(text)

    local result = {}

    for line in text:gmatch(
        "[^\r\n]+"
    ) do

        if line ~= "" then

            table.insert(
                result,
                {
                    time = nil,
                    text = line,
                }
            )
        end
    end


    return result
end


------------------------------------------------------------
-- SHELL QUOTE
------------------------------------------------------------

local function shellQuote(value)

    value =
        tostring(value or "")

    return "'"
        .. value:gsub(
            "'",
            "'\\''"
        )
        .. "'"
end


------------------------------------------------------------
-- NORMALIZE MPRIS POSITION
------------------------------------------------------------

local function normalizePosition(value)

    local n =
        tonumber(value)

    if not n then
        return nil
    end


    if n > 100000 then

        return n / 1000000
    end


    return n
end


------------------------------------------------------------
-- POSITION CACHE
------------------------------------------------------------

local function cachePosition(
    key,
    position
)

    positionCache[key] =
        position


    for i, cachedKey in ipairs(
        positionCacheOrder
    ) do

        if cachedKey == key then

            table.remove(
                positionCacheOrder,
                i
            )

            break
        end
    end


    table.insert(
        positionCacheOrder,
        key
    )


    while #positionCacheOrder
        > MAX_POSITION_CACHE do

        local oldestKey =
            table.remove(
                positionCacheOrder,
                1
            )

        positionCache[oldestKey] =
            nil
    end
end


local function clearCachedPosition(
    key
)

    positionCache[key] =
        nil


    for i, cachedKey in ipairs(
        positionCacheOrder
    ) do

        if cachedKey == key then

            table.remove(
                positionCacheOrder,
                i
            )

            break
        end
    end
end


------------------------------------------------------------
-- BUILD VISUAL LYRICS LIST
------------------------------------------------------------

local function buildVisibleLyrics(
    slot
)

    slot.visibleLyrics =
        {}


    local visualIndex =
        0


    for i = 1, #slot.lyrics do

        local line =
            slot.lyrics[i]


        if line.text
            and line.text:match("%S") then

            visualIndex =
                visualIndex + 1


            line.visualIndex =
                visualIndex


            table.insert(
                slot.visibleLyrics,

                {
                    originalIndex = i,
                    line = line,
                }
            )
        end
    end
end


------------------------------------------------------------
-- CREATE DIRECTORY AND FILES
------------------------------------------------------------

local function ensureLyricsFiles(
    callback
)

    local command =
        "mkdir -p \"$HOME/.cache/noctalia/lyrics\""
        .. " && touch "
        .. "\"$HOME/.cache/noctalia/lyrics/lyrics_1.lrc\" "
        .. "\"$HOME/.cache/noctalia/lyrics/lyrics_2.lrc\""


    noctalia.runAsync(
        command,

        function(result)

            if result
                and result.exitCode == 0 then

                callback(true)

                return
            end


            callback(false)
        end
    )
end


------------------------------------------------------------
-- SAVE LYRICS
------------------------------------------------------------

local function saveLyricsFile(
    slot,
    text,
    callback
)

    local filename

    if slot.id == 1 then

        filename =
            "lyrics_1.lrc"

    else

        filename =
            "lyrics_2.lrc"
    end


    local sessionId =
        slot.sessionId


    local command =
        "mkdir -p \"$HOME/.cache/noctalia/lyrics\""
        .. " && printf '%s' "
        .. shellQuote(text)
        .. " > "
        .. "\"$HOME/.cache/noctalia/lyrics/"
        .. filename
        .. "\""


    noctalia.runAsync(
        command,

        function(result)

            if slot.sessionId
                ~= sessionId then

                return
            end


            if result
                and result.exitCode == 0 then

                callback(true)

                return
            end


            callback(false)
        end
    )
end


------------------------------------------------------------
-- LOAD LYRICS
------------------------------------------------------------

local function loadLyricsFile(
    slot,
    callback
)

    local filename

    if slot.id == 1 then

        filename =
            "lyrics_1.lrc"

    else

        filename =
            "lyrics_2.lrc"
    end


    local sessionId =
        slot.sessionId


    local command =
        "cat "
        .. "\"$HOME/.cache/noctalia/lyrics/"
        .. filename
        .. "\""


    noctalia.runAsync(
        command,

        function(result)

            if slot.sessionId
                ~= sessionId then

                return
            end


            if not result
                or result.exitCode ~= 0
                or not result.stdout then

                callback(false)

                return
            end


            local text =
                result.stdout


            if text == "" then

                callback(false)

                return
            end


            ------------------------------------------------
            -- LRC
            ------------------------------------------------

            local parsed =
                parseLrc(text)


            if #parsed > 0 then

                slot.lyrics =
                    parsed

                slot.loaded =
                    true

                slot.loading =
                    false

                slot.state =
                    "lyrics"

                slot.hasTimedLyrics =
                    true

                slot.lastResolvedLine =
                    0

                slot.lastResolvedVideoTime =
                    nil

                slot.displayCenter =
                    0

                buildVisibleLyrics(
                    slot
                )


                callback(true)

                return
            end


            ------------------------------------------------
            -- PLAIN
            ------------------------------------------------

            parsed =
                parsePlain(text)


            if #parsed > 0 then

                slot.lyrics =
                    parsed

                slot.loaded =
                    true

                slot.loading =
                    false

                slot.state =
                    "lyrics"

                slot.hasTimedLyrics =
                    false

                slot.lastResolvedLine =
                    1

                slot.lastResolvedVideoTime =
                    nil

                slot.displayCenter =
                    1

                buildVisibleLyrics(
                    slot
                )


                callback(true)

                return
            end


            slot.loaded =
                false

            slot.loading =
                false

            slot.hasTimedLyrics =
                false


            callback(false)
        end
    )
end


------------------------------------------------------------
-- SAVE AND THEN LOAD LYRICS
------------------------------------------------------------

local function saveAndLoadLyrics(
    slot,
    text
)

    local sessionId =
        slot.sessionId


    slot.loading =
        true

    slot.state =
        "searching"


    if not slot.seekReloading then

        render()
    end


    saveLyricsFile(
        slot,
        text,

        function(saved)

            if slot.sessionId
                ~= sessionId then

                return
            end


            if not saved then

                slot.lyrics =
                    {}

                slot.visibleLyrics =
                    {}

                slot.loaded =
                    false

                slot.loading =
                    false

                slot.state =
                    "not_found"

                slot.hasTimedLyrics =
                    false

                slot.seekReloading =
                    false

                slot.seek =
                    "não"

                render()

                return
            end


            loadLyricsFile(
                slot,

                function(loaded)

                    if slot.sessionId
                        ~= sessionId then

                        return
                    end


                    if loaded then

                        if slot.videoTime
                            ~= nil then

                            resolveCurrentLine(
                                slot
                            )
                        end


                        render()

                        return
                    end


                    slot.lyrics =
                        {}

                    slot.visibleLyrics =
                        {}

                    slot.loaded =
                        false

                    slot.loading =
                        false

                    slot.state =
                        "not_found"

                    slot.hasTimedLyrics =
                        false

                    slot.seekReloading =
                        false

                    slot.seek =
                        "não"

                    render()
                end
            )
        end
    )
end


------------------------------------------------------------
-- FALLBACK SEARCH
------------------------------------------------------------

local function searchLyricsFallback(
    slot,
    title,
    artist
)

    local sessionId =
        slot.sessionId


    local query =
        noctalia.string.urlEncode(
            title
            .. " "
            .. artist
        )


    noctalia.http(
        {
            url =
                "https://lrclib.net/api/search?q="
                .. query,

            method = "GET",

            headers = {
                "User-Agent: Noctalia-Lyrics/1.0",
                "Accept: application/json",
            },
        },

        function(response)

            if slot.sessionId
                ~= sessionId then

                return
            end


            if not response
                or not response.ok
                or not response.body then

                slot.lyrics =
                    {}

                slot.loading =
                    false

                slot.state =
                    "not_found"

                slot.seekReloading =
                    false

                slot.seek =
                    "não"

                render()

                return
            end


            local ok, results =
                pcall(
                    noctalia.json.decode,
                    response.body
                )


            if not ok
                or type(results) ~= "table" then

                slot.lyrics =
                    {}

                slot.loading =
                    false

                slot.state =
                    "not_found"

                slot.seekReloading =
                    false

                slot.seek =
                    "não"

                render()

                return
            end


            ------------------------------------------------
            -- SYNCHRONIZED LYRICS
            ------------------------------------------------

            for _, item in ipairs(
                results
            ) do

                if item.syncedLyrics
                    and item.syncedLyrics ~= "" then

                    saveAndLoadLyrics(
                        slot,
                        item.syncedLyrics
                    )

                    return
                end
            end


            ------------------------------------------------
            -- PLAIN LYRICS
            ------------------------------------------------

            for _, item in ipairs(
                results
            ) do

                if item.plainLyrics
                    and item.plainLyrics ~= "" then

                    saveAndLoadLyrics(
                        slot,
                        item.plainLyrics
                    )

                    return
                end
            end


            slot.lyrics =
                {}

            slot.loading =
                false

            slot.state =
                "not_found"

            slot.seekReloading =
                false

            slot.seek =
                "não"

            render()
        end
    )
end


------------------------------------------------------------
-- LRCLIB SEARCH
------------------------------------------------------------

local function searchLyrics(
    slot,
    title,
    artist
)

    local sessionId =
        slot.sessionId


    local encodedTitle =
        noctalia.string.urlEncode(
            title
        )


    local encodedArtist =
        noctalia.string.urlEncode(
            artist
        )


    local url =
        "https://lrclib.net/api/get?track_name="
        .. encodedTitle
        .. "&artist_name="
        .. encodedArtist


    noctalia.http(
        {
            url = url,

            method = "GET",

            headers = {
                "User-Agent: Noctalia-Lyrics/1.0",
                "Accept: application/json",
            },
        },

        function(response)

            if slot.sessionId
                ~= sessionId then

                return
            end


            if response
                and response.ok
                and response.body then

                local ok, data =
                    pcall(
                        noctalia.json.decode,
                        response.body
                    )


                if ok and data then

                    ------------------------------------------------
                    -- SYNCHRONIZED LYRICS
                    ------------------------------------------------

                    if data.syncedLyrics
                        and data.syncedLyrics ~= "" then

                        saveAndLoadLyrics(
                            slot,
                            data.syncedLyrics
                        )

                        return
                    end


                    ------------------------------------------------
                    -- PLAIN LYRICS
                    ------------------------------------------------

                    if data.plainLyrics
                        and data.plainLyrics ~= "" then

                        saveAndLoadLyrics(
                            slot,
                            data.plainLyrics
                        )

                        return
                    end
                end
            end


            searchLyricsFallback(
                slot,
                title,
                artist
            )
        end
    )
end


------------------------------------------------------------
-- FIND SLOT FOR PLAYER
------------------------------------------------------------

local function findSlotForPlayer(
    player
)

    for _, slot in ipairs(
        slots
    ) do

        if slot.player == player
            and player ~= "" then

            return slot
        end
    end


    for _, slot in ipairs(
        slots
    ) do

        if slot.player == "" then

            return slot
        end
    end


    return slots[1]
end


------------------------------------------------------------
-- FULL RESTART
--
-- KEPT IN THE CODE.
--
-- THE NEW SEEK SYSTEM DOES NOT USE THIS FUNCTION.
------------------------------------------------------------

local function restartPluginFromScratch()

    for _, slot in ipairs(
        slots
    ) do

        slot.sessionId =
            slot.sessionId + 1
    end


    clearAllSlots()


    positionCache =
        {}

    positionCacheOrder =
        {}


    activeSlot =
        1


    local command =
        "rm -f "
        .. "\"$HOME/.cache/noctalia/lyrics/lyrics_1.lrc\" "
        .. "\"$HOME/.cache/noctalia/lyrics/lyrics_2.lrc\""


    noctalia.runAsync(
        command,

        function(result)

            if result
                and result.exitCode ~= 0 then

                return
            end


            ensureLyricsFiles(
                function(success)

                    if not success then

                        render()

                        return
                    end


                    render()

                    runPlayerctl()
                end
            )
        end
    )
end


------------------------------------------------------------
-- QUICK PAUSE/PLAY TO FORCE AN MPRIS UPDATE
------------------------------------------------------------

local function triggerQuickPause(
    slot
)

    if not slot then

        return false
    end


    if not slot.player
        or slot.player == "" then

        return false
    end


    if slot.quickPauseCommandRunning then

        return false
    end


    local quotedPlayer =
        shellQuote(
            slot.player
        )


    local command =
        PLAYERCTL
        .. " -p "
        .. quotedPlayer
        .. " pause"
        .. " && "
        .. "sleep "
        .. string.format(
            "%.3f",
            SEEK_PAUSE_SECONDS
        )
        .. " && "
        .. PLAYERCTL
        .. " -p "
        .. quotedPlayer
        .. " play"


    slot.quickPauseCommandRunning =
        true


    noctalia.runAsync(
        command,

        function(result)

            slot.quickPauseCommandRunning =
                false


            if result
                and result.exitCode == 0 then

                return
            end


            ------------------------------------------------
            -- Allow a future query to detect the seek again.
            ------------------------------------------------

            slot.quickPauseRecovery =
                false

            slot.seek =
                "não"
        end
    )


    return true
end


------------------------------------------------------------
-- UPDATE MPRIS REFERENCE
------------------------------------------------------------

local function updateReferenceTime(
    slot,
    mprisPosition,
    status
)

    if mprisPosition == nil then

        return nil
    end


    ------------------------------------------------
    -- RECOVERY AFTER SEEK
    --
    -- The old reference has already been discarded.
    --
    -- No position is accepted until a Playing state
    -- is received again.
    ------------------------------------------------

    if slot.quickPauseRecovery then

        ------------------------------------------------
        -- THE PHYSICAL PAUSE WAS OBSERVED.
        --
        -- Do not use this position.
        ------------------------------------------------

        if status == "Paused" then

            return nil
        end


        ------------------------------------------------
        -- FIRST PLAYING STATE AFTER THE PAUSE.
        --
        -- THIS becomes the new reference.
        ------------------------------------------------

        if status == "Playing" then

            slot.referenceTime =
                mprisPosition

            slot.position =
                mprisPosition

            slot.displayPosition =
                mprisPosition

            slot.videoTime =
                mprisPosition

            slot.lastVideoTime =
                mprisPosition

            slot.seek =
                "não"

            slot.seekCandidateTime =
                nil

            slot.seekCandidateCount =
                0

            slot.lastResolvedVideoTime =
                nil

            slot.quickPauseRecovery =
                false


            return slot.referenceTime
        end


        ------------------------------------------------
        -- ANY OTHER STATE.
        ------------------------------------------------

        return nil
    end


    ------------------------------------------------
    -- NEW NORMAL SESSION
    ------------------------------------------------

    if slot.referenceTime == nil then

        slot.referenceTime =
            mprisPosition

        slot.position =
            mprisPosition

        slot.displayPosition =
            mprisPosition

        slot.videoTime =
            mprisPosition

        slot.lastVideoTime =
            mprisPosition

        slot.seek =
            "não"

        slot.seekCandidateTime =
            nil

        slot.seekCandidateCount =
            0


        return slot.referenceTime
    end


    ------------------------------------------------
    -- NORMAL PAUSED STATE
    --
    -- DO NOT change the reference.
    --
    -- This prevents a potentially unreliable MPRIS
    -- position while paused from destroying sync.
    ------------------------------------------------

    if status == "Paused" then

        slot.position =
            mprisPosition

        slot.seek =
            "não"

        slot.seekCandidateTime =
            nil

        slot.seekCandidateCount =
            0


        return slot.referenceTime
    end


    ------------------------------------------------
    -- OLD RELOAD DEAD ZONE
    --
    -- Kept to preserve the previous behavior.
    ------------------------------------------------

    if slot.seekReloading then

        return slot.referenceTime
    end


    ------------------------------------------------
    -- DIFFERENCE FROM REFERENCE
    ------------------------------------------------

    local difference =
        mprisPosition
        - slot.referenceTime


    local absoluteDifference =
        math.abs(
            difference
        )


    ------------------------------------------------
-- NORMAL PLAYING
------------------------------------------------

if absoluteDifference
    < SEEK_THRESHOLD then

    ------------------------------------------------
    -- MPRIS remains the external reference.
    ------------------------------------------------

    slot.position =
        mprisPosition

    ------------------------------------------------
    -- IMPORTANT:
    --
    -- Do NOT continuously replace displayPosition.
    --
    -- The display clock is already advancing through
    -- onFrameTick().
    --
    -- Small MPRIS fluctuations are ignored so the
    -- lyric cannot jump backward/forward every query.
    ------------------------------------------------

    if absoluteDifference
        >= CLOCK_CORRECTION_THRESHOLD then

        slot.displayPosition =
            mprisPosition

        slot.videoTime =
            mprisPosition

        slot.lastVideoTime =
            mprisPosition

    end

    ------------------------------------------------
    -- Reference follows the external player position.
    --
    -- This is used only for detecting a real seek.
    ------------------------------------------------

    slot.referenceTime =
        mprisPosition

    slot.seek =
        "não"

    slot.seekCandidateTime =
        nil

    slot.seekCandidateCount =
        0

    return slot.referenceTime
end


    ------------------------------------------------
    -- SEEK DETECTED
    --
    -- DO NOT restart the plugin.
    -- DO NOT delete the lyrics.
    -- DO NOT reload LRCLIB.
    --
    -- Only force:
    --
    -- Playing
    --    ↓
    -- Paused
    --    ↓
    -- Playing
    --
    -- and wait for a new MPRIS position.
    ------------------------------------------------

    ------------------------------------------------
    -- DISCARD THE OLD REFERENCE.
    ------------------------------------------------

    slot.referenceTime =
        nil

    slot.videoTime =
        nil

    slot.position =
        0

    slot.displayPosition =
        nil

    slot.lastVideoTime =
        nil

    slot.lastResolvedVideoTime =
        nil

    slot.seekCandidateTime =
        nil

    slot.seekCandidateCount =
        0

    slot.seek =
        "sim"


    ------------------------------------------------
    -- ENTER RECOVERY MODE.
    ------------------------------------------------

    slot.quickPauseRecovery =
        true


    ------------------------------------------------
    -- TRIGGER PAUSE → PLAY.
    ------------------------------------------------

    local triggered =
        triggerQuickPause(
            slot
        )


    if not triggered then

        slot.quickPauseRecovery =
            false

        slot.seek =
            "não"

        return nil
    end


    return nil
end


------------------------------------------------------------
-- PROCESS PLAYER
------------------------------------------------------------

local function processPlayer(
    status,
    title,
    artist,
    position,
    player
)

    if not title
        or title == "" then

        return
    end


    local slot =
        findSlotForPlayer(
            player or ""
        )


    local previousPlayer =
        slot.player


    local lookupKey =
        (artist or "")
        .. "|"
        .. (title or "")


    local previousLookupKey =
        slot.lastLookupKey


    local mprisPosition =
        normalizePosition(
            position
        )


    ------------------------------------------------
    -- IDENTITY
    ------------------------------------------------

    slot.player =
        player or ""

    slot.title =
        title or ""

    slot.artist =
        artist or ""


    ------------------------------------------------
    -- NEW SONG / NEW PLAYER
    ------------------------------------------------

    if lookupKey ~= previousLookupKey
        or previousPlayer ~= slot.player then

        slot.sessionId =
            slot.sessionId + 1


        slot.lastLookupKey =
            lookupKey

        slot.lyrics =
            {}

        slot.visibleLyrics =
            {}

        slot.loaded =
            false

        slot.loading =
            true

        slot.state =
            "searching"

        slot.position =
            mprisPosition
            or 0

        slot.displayPosition =
            mprisPosition

        slot.videoTime =
            mprisPosition

        slot.lastVideoTime =
            mprisPosition

        slot.referenceTime =
            mprisPosition

        slot.seekCandidateTime =
            nil

        slot.seekCandidateCount =
            0

        slot.lastResolvedLine =
            0

        slot.lastResolvedVideoTime =
            nil

        slot.displayCenter =
            0

        slot.hasTimedLyrics =
            false

        slot.seek =
            "não"

        slot.seekReloading =
            false

        slot.quickPauseRecovery =
            false

        slot.quickPauseCommandRunning =
            false


        searchLyrics(
            slot,
            slot.title,
            slot.artist
        )


    else

        ------------------------------------------------
        -- SAME SONG
        ------------------------------------------------

        if mprisPosition ~= nil then

            local result =
                updateReferenceTime(
                    slot,
                    mprisPosition,
                    status
                )


            ------------------------------------------------
            -- PAUSE/PLAY RECOVERY
            ------------------------------------------------

            if result == nil
                and slot.quickPauseRecovery then

                return
            end
        end
    end


    ------------------------------------------------
    -- OLD DEAD ZONE
    ------------------------------------------------

    if slot.seekReloading then

        return
    end


    ------------------------------------------------
    -- CURRENT POSITION
    --
    -- videoTime follows the independent display clock.
    ------------------------------------------------

    if slot.displayPosition ~= nil then

        slot.videoTime =
            slot.displayPosition
    end


    ------------------------------------------------
    -- STATUS
    ------------------------------------------------

    if status == "Playing" then

        slot.state =
            "lyrics"

    elseif status == "Paused" then

        slot.state =
            "paused"

    end


    ------------------------------------------------
    -- ACTIVE SLOT
    ------------------------------------------------

    if status == "Playing" then

        activeSlot =
            slot.id

    elseif activeSlot == slot.id then

        activeSlot =
            slot.id
    end


    ------------------------------------------------
    -- RESOLVE LYRICS
    ------------------------------------------------

    if slot.loaded
        and slot.videoTime ~= nil then

        resolveCurrentLine(
            slot
        )
    end
end


------------------------------------------------------------
-- CLEAR ALL SLOTS
------------------------------------------------------------

function clearAllSlots()

    for _, slot in ipairs(
        slots
    ) do

        slot.sessionId =
            slot.sessionId + 1

        slot.state =
            "no_player"

        slot.lyrics =
            {}

        slot.visibleLyrics =
            {}

        slot.loaded =
            false

        slot.loading =
            false

        slot.player =
            ""

        slot.title =
            ""

        slot.artist =
            ""

        slot.position =
            0

        slot.displayPosition =
            nil

        slot.videoTime =
            nil

        slot.lastVideoTime =
            nil

        slot.referenceTime =
            nil

        slot.seekCandidateTime =
            nil

        slot.seekCandidateCount =
            0

        slot.lastResolvedLine =
            0

        slot.lastResolvedVideoTime =
            nil

        slot.displayCenter =
            0

        slot.hasTimedLyrics =
            false

        slot.seek =
            "não"

        slot.seekReloading =
            false

        slot.quickPauseRecovery =
            false

        slot.quickPauseCommandRunning =
            false

        slot.lastLookupKey =
            ""
    end
end


------------------------------------------------------------
-- PLAYERCTL
------------------------------------------------------------

function runPlayerctl()

    if playerctlInFlight then

        return
    end


    playerctlInFlight =
        true


    local command =
        "timeout 3s "
        .. PLAYERCTL
        .. " -a metadata --format '{{status}}|{{title}}|{{artist}}|{{position}}|{{playerName}}'"


    noctalia.runAsync(

        command,

        function(result)

            playerctlInFlight =
                false


            if not result then

                clearAllSlots()

                render()

                return
            end


            if result.exitCode ~= 0
                or not result.stdout then

                clearAllSlots()

                render()

                return
            end


            local output =
                result.stdout:gsub(
                    "%s+$",
                    ""
                )


            if output == "" then

                clearAllSlots()

                render()

                return
            end


            local seenPlayers =
                {}


            for line in output:gmatch(
                "[^\r\n]+"
            ) do

                local status,
                    title,
                    artist,
                    position,
                    player =

                    line:match(
                        "([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)"
                    )


                if title
                    and title ~= "" then

                    player =
                        player or ""


                    seenPlayers[player] =
                        true


                    processPlayer(
                        status,
                        title,
                        artist,
                        position,
                        player
                    )
                end
            end


            ------------------------------------------------
            -- CLEAR DISAPPEARED PLAYERS
            ------------------------------------------------

            for _, slot in ipairs(
                slots
            ) do

                if slot.player ~= ""
                    and not seenPlayers[
                        slot.player
                    ] then

                    slot.sessionId =
                        slot.sessionId + 1

                    slot.player =
                        ""

                    slot.title =
                        ""

                    slot.artist =
                        ""

                    slot.position =
                        0

                    slot.displayPosition =
                        nil

                    slot.videoTime =
                        nil

                    slot.lastVideoTime =
                        nil

                    slot.referenceTime =
                        nil

                    slot.seekCandidateTime =
                        nil

                    slot.seekCandidateCount =
                        0

                    slot.lastResolvedLine =
                        0

                    slot.lastResolvedVideoTime =
                        nil

                    slot.displayCenter =
                        0

                    slot.hasTimedLyrics =
                        false

                    slot.visibleLyrics =
                        {}

                    slot.lyrics =
                        {}

                    slot.loaded =
                        false

                    slot.loading =
                        false

                    slot.state =
                        "no_player"

                    slot.seek =
                        "não"

                    slot.seekReloading =
                        false

                    slot.quickPauseRecovery =
                        false

                    slot.quickPauseCommandRunning =
                        false

                    slot.lastLookupKey =
                        ""
                end
            end


            render()
        end,

        2000
    )
end


------------------------------------------------------------
-- GET TEMPORAL VISUAL LINE
------------------------------------------------------------

local function getVisualLine(
    slot,
    visualIndex
)

    if visualIndex < 1
        or visualIndex > #slot.visibleLyrics then

        return nil
    end


    local entry =
        slot.visibleLyrics[
            visualIndex
        ]


    if not entry then
        return nil
    end


    return entry.line
end


------------------------------------------------------------
-- ABSOLUTE BINARY SEARCH
------------------------------------------------------------

local function resolveAbsolute(
    slot,
    syncPosition
)

    local lyrics =
        slot.lyrics

    local count =
        #lyrics


    if count == 0 then
        return nil
    end


    local low =
        1

    local high =
        count

    local best =
        0


    while low <= high do

        local middle =
            math.floor(
                (low + high) / 2
            )


        local line =
            lyrics[middle]


        if line.time ~= nil
            and line.time <= syncPosition then

            best =
                middle

            low =
                middle + 1

        else

            high =
                middle - 1
        end
    end


    if best == 0 then

        return {
            current = nil,
            previous = nil,
            next = lyrics[1],
            index = 0,
        }
    end


    local currentIndex =
        best


    while currentIndex >= 1 do

        local line =
            lyrics[currentIndex]


        if line.time ~= nil
            and line.time <= syncPosition
            and line.text
            and line.text:match("%S") then

            break
        end


        currentIndex =
            currentIndex - 1
    end


    if currentIndex < 1 then
        currentIndex = 0
    end


    local nextLine =
        nil

    local nextSearchIndex =
        best + 1


    while nextSearchIndex <= count do

        local line =
            lyrics[nextSearchIndex]


        if line.time ~= nil
            and line.time > syncPosition then

            nextLine =
                line

            break
        end


        nextSearchIndex =
            nextSearchIndex + 1
    end


    local currentLine =
        nil


    if currentIndex > 0 then
        currentLine =
            lyrics[currentIndex]
    end


    local previousLine =
        nil


    if currentIndex > 1 then

        local previousSearchIndex =
            currentIndex - 1


        while previousSearchIndex >= 1 do

            local line =
                lyrics[previousSearchIndex]


            if line.time ~= nil
                and line.text
                and line.text:match("%S") then

                previousLine =
                    line

                break
            end


            previousSearchIndex =
                previousSearchIndex - 1
        end
    end


    return {
        current = currentLine,
        previous = previousLine,
        next = nextLine,
        index = currentIndex,
    }
end


------------------------------------------------------------
-- GET VISUAL INDEX FROM LINE
------------------------------------------------------------

local function getVisualIndexFromLine(
    line
)

    if not line then
        return 0
    end


    return line.visualIndex
        or 0
end


------------------------------------------------------------
-- RESOLVE TEMPORAL LINE
------------------------------------------------------------

function resolveCurrentLine(
    slot
)

    if not slot.loaded
        or #slot.lyrics == 0 then

        return
    end


    ------------------------------------------------
    -- PLAIN LYRICS
    ------------------------------------------------

    if not slot.hasTimedLyrics then

        slot.lastResolvedLine =
            1

        slot.displayCenter =
            1

        return
    end


    ------------------------------------------------
    -- VIDEO TIME
    ------------------------------------------------

    local videoTime =
        slot.videoTime


    if videoTime == nil then
        return
    end


    ------------------------------------------------
    -- LRC POSITION
    --
    -- displayPosition is already the continuously
    -- progressing player clock.
    ------------------------------------------------

    local syncPosition =
        videoTime
        + LYRICS_OFFSET


    ------------------------------------------------
    -- DO NOT RESOLVE TWICE
    ------------------------------------------------

    if slot.lastResolvedVideoTime ~= nil
        and math.abs(
            syncPosition
            - slot.lastResolvedVideoTime
        ) < 0.001 then

        return
    end


    local currentLine =
        nil

    local previousLine =
        nil

    local nextLine =
        nil

    local currentIndex =
        slot.lastResolvedLine


    local resolutionMode =
        "INCREMENTAL"


    ------------------------------------------------
    -- FIRST RESOLUTION
    ------------------------------------------------

    if slot.displayCenter == 0
        or slot.lastResolvedLine == 0 then

        resolutionMode =
            "FIRST RESOLUTION"


        local resolved =
            resolveAbsolute(
                slot,
                syncPosition
            )


        if resolved then

            currentLine =
                resolved.current

            previousLine =
                resolved.previous

            nextLine =
                resolved.next

            currentIndex =
                resolved.index
        end


    ------------------------------------------------
    -- INCREMENTAL MODE
    ------------------------------------------------

    else

        local currentVisualIndex =
            slot.displayCenter


        local currentVisualLine =
            getVisualLine(
                slot,
                currentVisualIndex
            )


        if not currentVisualLine then

            resolutionMode =
                "ABSOLUTE RECOVERY"


            local resolved =
                resolveAbsolute(
                    slot,
                    syncPosition
                )


            if resolved then

                currentLine =
                    resolved.current

                previousLine =
                    resolved.previous

                nextLine =
                    resolved.next

                currentIndex =
                    resolved.index
            end

        else

            currentLine =
                currentVisualLine


            ------------------------------------------------
            -- MOVE FORWARD
            ------------------------------------------------

            while true do

                local nextVisualIndex =
                    currentVisualIndex + 1

                local nextVisualLine =
                    getVisualLine(
                        slot,
                        nextVisualIndex
                    )


                if not nextVisualLine
                    or nextVisualLine.time == nil then

                    break
                end


                if nextVisualLine.time
                    <= syncPosition then

                    currentVisualIndex =
                        nextVisualIndex

                    currentVisualLine =
                        nextVisualLine

                    currentLine =
                        currentVisualLine

                else

                    nextLine =
                        nextVisualLine

                    break
                end
            end


            ------------------------------------------------
            -- MOVE BACKWARD
            ------------------------------------------------

            while currentLine
                and currentLine.time
                and syncPosition < currentLine.time do

                local previousVisualIndex =
                    currentVisualIndex - 1

                local previousVisualLine =
                    getVisualLine(
                        slot,
                        previousVisualIndex
                    )


                if not previousVisualLine
                    or previousVisualLine.time == nil then

                    break
                end


                currentVisualIndex =
                    previousVisualIndex

                currentLine =
                    previousVisualLine
            end


            ------------------------------------------------
            -- ORIGINAL INDEX
            ------------------------------------------------

            if currentLine then

                currentIndex =
                    currentLine.visualIndex
                    and slot.visibleLyrics[
                        currentLine.visualIndex
                    ].originalIndex
                    or currentIndex

            else

                currentIndex =
                    0
            end


            ------------------------------------------------
            -- PREVIOUS LINE
            ------------------------------------------------

            if currentVisualIndex > 1 then

                previousLine =
                    getVisualLine(
                        slot,
                        currentVisualIndex - 1
                    )
            end


            ------------------------------------------------
            -- NEXT LINE
            ------------------------------------------------

            if not nextLine then

                nextLine =
                    getVisualLine(
                        slot,
                        currentVisualIndex + 1
                    )
            end
        end
    end


    ------------------------------------------------
    -- UPDATE INDICES
    ------------------------------------------------

    if currentLine == nil then

        slot.lastResolvedLine =
            0

        slot.displayCenter =
            0

    else

        slot.lastResolvedLine =
            currentIndex


        slot.displayCenter =
            getVisualIndexFromLine(
                currentLine
            )
    end


    slot.lastResolvedVideoTime =
        syncPosition
end


------------------------------------------------------------
-- RENDER
------------------------------------------------------------

function render()

    local rows =
        {}


    local slot =
        slots[activeSlot]


    local widthSetting =
        tonumber(
            noctalia.getConfig(
                "width"
            )
        )
        or 700


    local currentFontSize =
        tonumber(
            noctalia.getConfig(
                "current_font_size"
            )
        )
        or 36


    local secondaryFontSize =
        tonumber(
            noctalia.getConfig(
                "secondary_font_size"
            )
        )
        or 27


    local currentOpacity =
        (
            tonumber(
                noctalia.getConfig(
                    "current_opacity"
                )
            )
            or 100
        )
        / 100


    local secondaryOpacity =
        (
            tonumber(
                noctalia.getConfig(
                    "secondary_opacity"
                )
            )
            or 73
        )
        / 100


    local linesAboveSetting =
        tonumber(
            noctalia.getConfig(
                "lines_above"
            )
        )
        or 2


    local linesBelowSetting =
        tonumber(
            noctalia.getConfig(
                "lines_below"
            )
        )
        or 2


    local widgetWidth =
        300
        + (widthSetting / 1000)
        * 900


    ------------------------------------------------
    -- DEAD ZONE
    ------------------------------------------------

    if slot.seekReloading then

        return
    end


    ------------------------------------------------
    -- NO PLAYER
    ------------------------------------------------

    if slot.state == "no_player" then

        table.insert(
            rows,

            ui.label({
                text =
                    "♪ Nenhum player",

                fontSize =
                    secondaryFontSize,

                color =
                    "secondary",

                maxLines = 1,

                textAlign =
                    "center",

                opacity =
                    secondaryOpacity,
            })
        )


    ------------------------------------------------
    -- SEARCHING
    ------------------------------------------------

    elseif slot.state == "searching"
        or slot.loading then

        table.insert(
            rows,

            ui.label({
                text =
                    "♪ Buscando letra...",

                fontSize =
                    secondaryFontSize,

                color =
                    "secondary",

                maxLines = 1,

                textAlign =
                    "center",

                opacity =
                    secondaryOpacity,
            })
        )


    ------------------------------------------------
    -- NOT FOUND
    ------------------------------------------------

    elseif slot.state == "not_found" then

        table.insert(
            rows,

            ui.label({
                text =
                    "♪ Sem letra disponível",

                fontSize =
                    secondaryFontSize,

                color =
                    "secondary",

                maxLines = 1,

                textAlign =
                    "center",

                opacity =
                    secondaryOpacity,
            })
        )


    ------------------------------------------------
    -- LYRICS / PAUSED
    ------------------------------------------------

    elseif slot.state == "lyrics"
        or slot.state == "paused" then

        local displayCenter =
            slot.displayCenter


        if displayCenter == 0
            and slot.videoTime ~= nil
            and slot.loaded then

            resolveCurrentLine(
                slot
            )

            displayCenter =
                slot.displayCenter
        end


        ------------------------------------------------
        -- DIRECT RENDERING
        ------------------------------------------------

        for offset =
            -linesAboveSetting,
            linesBelowSetting do

            local index =
                displayCenter
                + offset


            local visualEntry =
                nil


            if displayCenter > 0
                and index >= 1
                and index <= #slot.visibleLyrics then

                visualEntry =
                    slot.visibleLyrics[index]
            end


            local line =
                visualEntry
                and visualEntry.line
                or nil


            local text =
                " "


            if line
                and line.text
                and line.text:match("%S") then

                text =
                    line.text
            end


            local isCurrent =
                displayCenter > 0
                and offset == 0
                and line ~= nil


            table.insert(
                rows,

                ui.label({
                    key =
                        "lyric-"
                        .. tostring(offset),

                    text =
                        text,

                    fontSize =
                        isCurrent
                        and currentFontSize
                        or secondaryFontSize,

                    fontWeight =
                        isCurrent
                        and "bold"
                        or "normal",

                    baseline =
                        "textFixedHeight",

                    color =
                        isCurrent
                        and (
                            noctalia.getConfig(
                                "current_color"
                            )
                            or "primary"
                        )
                        or (
                            noctalia.getConfig(
                                "secondary_color"
                            )
                            or "secondary"
                        ),

                    opacity =
                        isCurrent
                        and currentOpacity
                        or secondaryOpacity,

                    maxLines = 1,

                    textAlign =
                        "center",
                })
            )
        end
    end


    ------------------------------------------------
    -- WIDGET
    ------------------------------------------------

    desktopWidget.render(

        ui.column(
            {
                width =
                    widgetWidth,

                gap =
                    10,

                align =
                    "center",

                minHeight =
                    100,
            },

            rows
        )
    )
end


------------------------------------------------------------
-- FRAME TICK
--
-- MPRIS is the authoritative clock correction.
-- displayPosition is the continuously progressing clock.
--
-- We do NOT advance the clock while paused or while
-- recovering from a seek.
------------------------------------------------------------

function onFrameTick(deltaMs)

    local slot =
        slots[activeSlot]


    if not slot then
        return
    end


    if slot.quickPauseRecovery then
        return
    end


    if slot.state ~= "lyrics"
        and slot.state ~= "paused" then

        return
    end


    if slot.displayPosition == nil then
        return
    end


    ------------------------------------------------
    -- Only Playing advances the display clock.
    ------------------------------------------------

    if slot.state == "lyrics" then

        local deltaSeconds =
            tonumber(deltaMs or 0)
            / 1000


        if deltaSeconds > 0
            and deltaSeconds < 1 then

            slot.displayPosition =
                slot.displayPosition
                + deltaSeconds


            slot.videoTime =
                slot.displayPosition


            ------------------------------------------------
            -- Resolve directly from the local LRC.
            --
            -- No playerctl query is needed for every frame.
            ------------------------------------------------

            if slot.loaded then

                resolveCurrentLine(
                    slot
                )

                render()
            end
        end
    end
end


------------------------------------------------------------
-- ENABLE FRAME TICK
------------------------------------------------------------

desktopWidget.setNeedsFrameTick(
    true
)


------------------------------------------------------------
-- UPDATE INTERVAL
------------------------------------------------------------

noctalia.setUpdateInterval(
    500
)


function update()

    runPlayerctl()
end


------------------------------------------------------------
-- INITIALIZATION
------------------------------------------------------------

local function initialize()

    ensureLyricsFiles(
        function(success)

            if not success then

                render()

                return
            end


            render()

            update()
        end
    )
end


------------------------------------------------------------
-- START
------------------------------------------------------------

render()

initialize()
