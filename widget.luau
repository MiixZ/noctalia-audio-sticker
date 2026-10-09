local pluginDir = noctalia.pluginDir() or ""
local helperPath = pluginDir .. "/bin/noctalia-audio-monitor"
local dataDir = noctalia.pluginDataDir() or ("/tmp/noctalia-audio-sticker-" .. tostring(os.time()))
local stateFile = dataDir .. "/monitor-state.txt"

local opacity = 0.0
local targetOpacity = 0.0
local currentOpacity = 0.0
local previousState = nil

-- GIF animation state
local gifPath = nil
local gifFrames = nil
local gifDurations = nil
local gifTotalDuration = 0
local gifStartTime = 0
local gifLoading = false

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

local function isGif(path)
  return path:lower():match("%.gif$") ~= nil
end

local function gifCacheDir(path)
  local safe = path:gsub("[^a-zA-Z0-9_.-]", "_")
  return dataDir .. "/gif-cache/" .. safe
end

local function parseGifDurations(stdout)
  local durations = {}
  local total = 0
  for line in stdout:gmatch("[^\r\n]+") do
    local ticks = tonumber(line) or 10
    -- ImageMagick %T reports delay in hundredths of a second by default.
    local ms = math.floor(ticks * 10)
    if ms <= 0 then
      ms = 100
    end
    table.insert(durations, ms)
    total = total + ms
  end
  return durations, total
end

local function saveGifMetadata(cacheDir, frames, durations, totalDuration)
  local meta = {
    frames = frames,
    durations = durations,
    totalDuration = totalDuration,
  }
  local ok, encoded = pcall(noctalia.json.encode, meta)
  if ok then
    noctalia.writeFile(cacheDir .. "/metadata.json", encoded)
  end
end

local function loadGifMetadata(cacheDir)
  local raw = noctalia.readFile(cacheDir .. "/metadata.json")
  if not raw then
    return false
  end
  local ok, meta = pcall(noctalia.json.decode, raw)
  if not ok or not meta or not meta.frames then
    return false
  end

  gifFrames = {}
  for _, name in ipairs(meta.frames) do
    table.insert(gifFrames, cacheDir .. "/" .. name)
  end
  gifDurations = meta.durations
  gifTotalDuration = meta.totalDuration or 0
  return true
end

local function extractGifFrames(path)
  if gifLoading then
    return
  end
  if not noctalia.commandExists("magick") then
    noctalia.log("ImageMagick is required for GIF support")
    return
  end

  gifLoading = true
  local cacheDir = gifCacheDir(path)
  noctalia.mkdirAll(cacheDir)

  -- Use cached frames if already extracted.
  if loadGifMetadata(cacheDir) then
    gifPath = path
    gifStartTime = noctalia.nowMs()
    gifLoading = false
    return
  end

  -- Read frame durations first; this also tells us how many frames exist.
  noctalia.runAsync({
    "magick", "identify", "-format", "%T\n", path
  }, function(identify)
    if identify.exitCode ~= 0 then
      noctalia.log("GIF identify failed: " .. (identify.stderr or ""))
      gifLoading = false
      return
    end

    local durations, totalDuration = parseGifDurations(identify.stdout)
    local frameCount = #durations
    if frameCount == 0 then
      durations = { 100 }
      totalDuration = 100
      frameCount = 1
    end

    -- Check whether the cached frames already match this count.
    local cached = true
    for i = 0, frameCount - 1 do
      local framePath = string.format(cacheDir .. "/frame-%03d.png", i)
      if not noctalia.fileExists(framePath) then
        cached = false
        break
      end
    end

    local function finalizeFrames()
      local frames = {}
      for i = 0, frameCount - 1 do
        table.insert(frames, string.format("frame-%03d.png", i))
      end
      saveGifMetadata(cacheDir, frames, durations, totalDuration)

      gifFrames = {}
      for _, name in ipairs(frames) do
        table.insert(gifFrames, cacheDir .. "/" .. name)
      end
      gifDurations = durations
      gifTotalDuration = totalDuration
      gifPath = path
      gifStartTime = noctalia.nowMs()
      gifLoading = false
    end

    if cached then
      finalizeFrames()
      return
    end

    -- Extract frames with ImageMagick.
    noctalia.runAsync({
      "magick", path, "-coalesce", cacheDir .. "/frame-%03d.png"
    }, function(result)
      if result.exitCode ~= 0 then
        noctalia.log("GIF extraction failed: " .. (result.stderr or ""))
        gifLoading = false
        return
      end
      finalizeFrames()
    end)
  end)
end

local function currentGifFrame()
  if not gifFrames or #gifFrames == 0 then
    return nil
  end
  if gifTotalDuration <= 0 then
    return gifFrames[1]
  end

  local elapsed = noctalia.nowMs() - gifStartTime
  elapsed = elapsed % gifTotalDuration

  local t = 0
  for i, dur in ipairs(gifDurations) do
    t = t + dur
    if elapsed < t then
      return gifFrames[i]
    end
  end
  return gifFrames[#gifFrames]
end

local function renderImage(path)
  if isGif(path) then
    if gifPath ~= path then
      extractGifFrames(path)
    end

    local frame = currentGifFrame()
    if frame then
      desktopWidget.render(
        ui.image({
          path = frame,
          width = 320,
          height = 320,
          opacity = opacity,
          fit = "cover",
        })
      )
      return
    end

    -- Still extracting frames.
    desktopWidget.render(
      ui.column({ align = "center", justify = "center" }, {
        ui.label({ text = "Loading GIF...", color = "on_surface_variant" }),
      })
    )
    return
  end

  desktopWidget.render(
    ui.image({
      path = path,
      width = 320,
      height = 320,
      opacity = opacity,
      fit = "cover",
    })
  )
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

  renderImage(path)
end

local function resetGif()
  gifPath = nil
  gifFrames = nil
  gifDurations = nil
  gifTotalDuration = 0
  gifStartTime = 0
  gifLoading = false
end

local function setActive(active)
  targetOpacity = active
    and (noctalia.getConfig("active_opacity") or 1.0)
    or  (noctalia.getConfig("idle_opacity") or 0.0)

  if active and gifPath then
    gifStartTime = noctalia.nowMs()
  end
end

local function startMonitor()
  if not noctalia.fileExists(helperPath) then
    return
  end

  local hysteresis = noctalia.getConfig("hysteresis_ms") or 500

  local cmd = table.concat({
    "nohup",
    helperPath,
    "--hysteresis-ms", tostring(hysteresis),
    "--state-file", stateFile,
    ">/dev/null",
    "2>/dev/null",
    "&",
  }, " ")

  noctalia.runAsync({"/usr/bin/bash", "-c", cmd})
end

startMonitor()

function update()
  desktopWidget.setNeedsFrameTick(true)

  local active = readState()
  setActive(active == true)
  currentOpacity = targetOpacity
  opacity = targetOpacity
  previousState = active

  local path = noctalia.getConfig("image_path") or ""
  if not isGif(path) then
    resetGif()
  elseif gifPath ~= path then
    extractGifFrames(path)
  end

  render()
end

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

  local needsRender = false
  if math.abs(currentOpacity - opacity) > 0.001 then
    opacity = currentOpacity
    needsRender = true
  end

  -- GIFs need continuous frame updates whenever visible.
  local path = noctalia.getConfig("image_path") or ""
  if isGif(path) and opacity > 0 then
    needsRender = true
  end

  if needsRender then
    render()
  end
end
