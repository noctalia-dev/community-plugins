--!nonstrict
-- Bar widget entry for Antigravity AGY launcher

local function resolveDir(rawDir: string): string
  local target = noctalia.expandPath(rawDir)
  if noctalia.fileExists(target) then
    return target
  end
  local fallback = noctalia.expandPath("~/Proyectos/agy")
  if noctalia.fileExists(fallback) then
    return fallback
  end
  return noctalia.getenv("HOME") or "/"
end

local function launch(dir: string)
  if not noctalia.commandExists("alacritty") then
    noctalia.notifyError("Antigravity AGY", "alacritty was not found on PATH.")
    return
  end
  if not noctalia.commandExists("agy") then
    noctalia.notifyError("Antigravity AGY", "agy CLI was not found on PATH. Install Antigravity CLI first.")
    return
  end
  noctalia.runAsync({
    "alacritty",
    "--class", "agy-terminal",
    "-T", "Antigravity AGY",
    "--working-directory", resolveDir(dir),
    "-e", "agy",
  })
end

local function render()
  local showLabel = noctalia.getConfig("show_label") ~= false
  barWidget.setGlyph("sparkles")
  if showLabel and not barWidget.isVertical() then
    barWidget.setText("AGY")
  else
    barWidget.setText("")
  end
  barWidget.setTooltip(noctalia.tr("bar.tooltip"))
end

function update()
  render()
end

function onClick()
  launch(noctalia.getConfig("project_dir") or "~/Proyectos/agy")
end

function onRightClick()
  launch("~")
end

render()
