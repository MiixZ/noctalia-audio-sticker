local pluginDir = noctalia.pluginDir() or ""
local helperPath = pluginDir .. "/bin/noctalia-audio-monitor"
local dataDir = noctalia.pluginDataDir() or ("/tmp/noctalia-audio-sticker-" .. tostring(os.time()))
local stateFile = dataDir .. "/monitor-state.txt"

local opacity = 0.0
local targetOpacity = 0.0
local currentOpacity = 0.0
local previousState = nil

local function trim(s)
  return (s:gsub("^%s*(.-)%s*$", "%1"))
end

local function readState()
  local content = noctalia.readFile(stateFile)
  if not content then
    return nil
  end
  content = trim(content)
  if content == "active" then
    return true
  elseif content == "idle" then
    return false
  end
  return nil
end

local function render()
  local path = noctalia.getConfig("image_path") or ""
  if path == "" then
    desktopWidget.render(
      ui.column({ align = "center", justify = "center", gap = 8 }, {
        ui.glyph({ name = "photo", size = 48, color = "on_surface_variant" }),
        ui.label({ text = "Select an image", color = "on_surface_variant" }),
      })
    )
    return
  end

  desktopWidget.render(
    ui.image({
      path = path,
      opacity = opacity,
      fit = "contain",
    })
  )
end

local function setActive(active)
  targetOpacity = active
    and (noctalia.getConfig("active_opacity") or 1.0)
    or  (noctalia.getConfig("idle_opacity") or 0.0)
end

-- Start the helper in the background. It uses an internal flock-based
-- single-instance guard, so starting it again is harmless if one is already
-- running from a previous widget load.
local function startMonitor()
  if not noctalia.fileExists(helperPath) then
    return
  end

  local threshold = noctalia.getConfig("threshold") or 0.001
  local hysteresis = noctalia.getConfig("hysteresis_ms") or 500

  local cmd = table.concat({
    "nohup",
    helperPath,
    "--threshold", tostring(threshold),
    "--hysteresis-ms", tostring(hysteresis),
    "--state-file", stateFile,
    ">/dev/null",
    "2>/dev/null",
    "&",
  }, " ")

  noctalia.runAsync({"/usr/bin/bash", "-c", cmd})
end

startMonitor()

-- Seed initial opacity.
local active = readState()
setActive(active == true)
currentOpacity = targetOpacity
opacity = targetOpacity
render()

desktopWidget.setNeedsFrameTick(true)

function onFrameTick(deltaMs)
  local active = readState()
  if active ~= nil and active ~= previousState then
    previousState = active
    setActive(active)
  end

  local fadeMs = noctalia.getConfig("fade_ms") or 300
  if fadeMs <= 0 then
    currentOpacity = targetOpacity
  else
    local t = math.min(1.0, deltaMs / fadeMs)
    currentOpacity = currentOpacity + (targetOpacity - currentOpacity) * t
  end

  if math.abs(currentOpacity - opacity) > 0.001 then
    opacity = currentOpacity
    render()
  end
end

function update()
  -- Kept in case Noctalia calls it; no periodic work needed.
end
