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
local gifLoadStart = 0

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

local function parseFfmpegDurations(stdout)
  local durations = {}
  local total = 0
  for line in stdout:gmatch("[^\r\n]+") do
    -- ffmpeg pts output is in seconds, e.g. "0.033333"
    local sec = tonumber(line)
    if sec then
      local ms = math.floor(sec * 1000)
      if ms <= 0 then
        ms = 33
      end
      table.insert(durations, ms)
      total = total + ms
    end
  end
  return durations, total
end

local function saveGifMetadata(cacheDir, frames, durations, totalDuration, extractor)
  local meta = {
    frames = frames,
    durations = durations,
    totalDuration = totalDuration,
    extractor = extractor or "unknown",
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

local function finalizeFrames(cacheDir, frameCount, durations, totalDuration, extractor)
  local frames = {}
  for i = 0, frameCount - 1 do
    table.insert(frames, string.format("frame-%03d.png", i))
  end
  saveGifMetadata(cacheDir, frames, durations, totalDuration, extractor)

  gifFrames = {}
  for _, name in ipairs(frames) do
    table.insert(gifFrames, cacheDir .. "/" .. name)
  end
  gifDurations = durations
  gifTotalDuration = totalDuration
  gifPath = gifPath or ""  -- will be set by caller
  gifStartTime = noctalia.nowMs()
  gifLoading = false
end

local function extractWithFfmpeg(path, cacheDir)
  -- ffmpeg starts output at frame-001.png; probe duration first.
  noctalia.runAsync({
    "ffprobe", "-v", "error", "-select_streams", "v:0",
    "-show_entries", "frame=pts_time", "-of",
    "csv=p=0", path
  }, function(probe)
    if probe.exitCode ~= 0 then
      noctalia.log("ffprobe failed: " .. (probe.stderr or ""))
      -- Fallback to magick.
      extractWithMagick(path, cacheDir)
      return
    end

    local durations, totalDuration = parseFfmpegDurations(probe.stdout)
    local frameCount = #durations
    if frameCount == 0 then
      durations = { 100 }
      totalDuration = 100
      frameCount = 1
    end

    -- Check cache.
    local cached = true
    for i = 1, frameCount do
      -- ffmpeg names frames 1-based.
      local framePath = string.format(cacheDir .. "/frame-%03d.png", i)
      if not noctalia.fileExists(framePath) then
        cached = false
        break
      end
    end

    if cached then
      -- Convert 1-based ffmpeg names to 0-based internal names.
      local frames = {}
      for i = 1, frameCount do
        table.insert(frames, string.format("frame-%03d.png", i))
      end
      saveGifMetadata(cacheDir, frames, durations, totalDuration, "ffmpeg")
      gifFrames = {}
      for _, name in ipairs(frames) do
        table.insert(gifFrames, cacheDir .. "/" .. name)
      end
      gifDurations = durations
      gifTotalDuration = totalDuration
      gifPath = path
      gifStartTime = noctalia.nowMs()
      gifLoading = false
      return
    end

    -- Extract resized frames with ffmpeg (much faster than ImageMagick).
    noctalia.runAsync({
      "ffmpeg", "-y", "-i", path,
      "-vf", "scale=320:-1:flags=lanczos",
      "-pix_fmt", "rgba",
      cacheDir .. "/frame-%03d.png"
    }, function(result)
      if result.exitCode ~= 0 then
        noctalia.log("ffmpeg extraction failed: " .. (result.stderr or ""))
        extractWithMagick(path, cacheDir)
        return
      end

      local frames = {}
      for i = 1, frameCount do
        table.insert(frames, string.format("frame-%03d.png", i))
      end
      saveGifMetadata(cacheDir, frames, durations, totalDuration, "ffmpeg")
      gifFrames = {}
      for _, name in ipairs(frames) do
        table.insert(gifFrames, cacheDir .. "/" .. name)
      end
      gifDurations = durations
      gifTotalDuration = totalDuration
      gifPath = path
      gifStartTime = noctalia.nowMs()
      gifLoading = false
    end)
  end)
end

local function extractWithMagick(path, cacheDir)
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

    if cached then
      finalizeFrames(cacheDir, frameCount, durations, totalDuration, "magick")
      gifPath = path
      return
    end

    -- Extract frames with ImageMagick, resizing to the widget display size.
    noctalia.runAsync({
      "magick", path, "-coalesce", "-resize", "320x320>", cacheDir .. "/frame-%03d.png"
    }, function(result)
      if result.exitCode ~= 0 then
        noctalia.log("GIF extraction failed: " .. (result.stderr or ""))
        gifLoading = false
        return
      end
      finalizeFrames(cacheDir, frameCount, durations, totalDuration, "magick")
      gifPath = path
    end)
  end)
end

local function extractGifFrames(path)
  if gifLoading then
    -- If loading has been stuck for too long, allow a retry.
    if noctalia.nowMs() - gifLoadStart < 30000 then
      return
    end
    noctalia.log("GIF extraction timed out, retrying")
  end

  gifLoading = true
  gifLoadStart = noctalia.nowMs()

  local cacheDir = gifCacheDir(path)
  noctalia.mkdirAll(cacheDir)

  -- Use cached metadata if available.
  if loadGifMetadata(cacheDir) then
    gifPath = path
    gifStartTime = noctalia.nowMs()
    gifLoading = false
    return
  end

  if noctalia.commandExists("ffmpeg") then
    extractWithFfmpeg(path, cacheDir)
  elseif noctalia.commandExists("magick") then
    extractWithMagick(path, cacheDir)
  else
    noctalia.log("ffmpeg or ImageMagick is required for GIF support")
    gifLoading = false
  end
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
  gifLoadStart = 0
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
