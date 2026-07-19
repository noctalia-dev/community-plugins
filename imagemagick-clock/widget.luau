local CMDLINE_TEMPLATE = noctalia.getConfig("command_line")
local IMAGE_WIDTH = noctalia.getConfig("image_width")
local IMAGE_HEIGHT = noctalia.getConfig("image_height")

local OUTPUT_DIR = noctalia.pluginDataDir()
local CURRENT_CLOCK_FACE_PATH = OUTPUT_DIR .. "/current.png"
local NEXT_CLOCK_FACE_PATH = OUTPUT_DIR .. "/next.png"

local generatingClockFace = false
local movingClockFace = false
local nextClockFaceReady = false
local nextClockFaceTimestamp = nil

local function drawClockFace(timestamp)
  if generatingClockFace then
    return
  end

  generatingClockFace = true

  local cmdline = string.gsub(CMDLINE_TEMPLATE, "%%output_file", NEXT_CLOCK_FACE_PATH)
  cmdline = os.date(cmdline, timestamp)
  -- print("Running command: " .. cmdline)

  noctalia.runAsync(cmdline, function(result)
    generatingClockFace = false
    nextClockFaceTimestamp = timestamp
    if result.exitCode == 0 then
      nextClockFaceReady = true
    else
      print("Error generating clock face: " .. result.stderr .. " (command: " .. cmdline .. ") " .. "output: " .. result.stdout)
      nextClockFaceReady = false
    end
  end)
end

local function drawNextClockFace()
  local timestamp = os.time()
  local time = os.date("*t", timestamp)
  local nextTimestamp = timestamp - time.sec + 60
  -- print("Drawing next clock face at " .. os.date("%H:%M:%S", nextTimestamp))
  drawClockFace(nextTimestamp)
end

function update()
  if generatingClockFace or movingClockFace or (nextClockFaceTimestamp and os.time() < nextClockFaceTimestamp) then
    return
  end

  if nextClockFaceReady then
    nextClockFaceReady = false
    movingClockFace = true
    noctalia.runAsync("mv -f '" .. NEXT_CLOCK_FACE_PATH .. "' '" .. CURRENT_CLOCK_FACE_PATH .. "'", function(result)
      movingClockFace = false
      if result.exitCode == 0 then
        barWidget.setImage(CURRENT_CLOCK_FACE_PATH, true, IMAGE_WIDTH, IMAGE_HEIGHT)
      else
        print("Error moving new clock face: " .. result.stderr .. " (command: mv -f " .. NEXT_CLOCK_FACE_PATH .. " " .. CURRENT_CLOCK_FACE_PATH .. ") " .. "output: " .. result.stdout)
      end
      drawNextClockFace()
    end)
  else
    drawNextClockFace()
  end
end

function onClick()
  noctalia.runAsync("noctalia msg panel-toggle control-center calendar", function(result)
    if result.exitCode ~= 0 then
      print("Error toggling calendar panel: " .. result.stderr .. " (command: noctalia msg panel-toggle control-center calendar) " .. "output: " .. result.stdout)
    end
  end)
end

noctalia.setUpdateInterval(1000)
drawClockFace(os.time())
