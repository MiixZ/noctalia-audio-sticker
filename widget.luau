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
  safe = safe:gsub("%.gif$", "") -- avoid a directory name ending in .gif
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
  -- ffprobe outputs absolute PTS per frame in seconds.
  -- Convert those into per-frame durations by differencing consecutive PTS values.
  local durations = {}
  local total = 0
  local lastMs = 0
  for line in stdout:gmatch("[^\r\n]+") do
    local sec = tonumber(line)
    if sec then
      local ms = math.floor(sec * 1000)
      local dur = ms - lastMs
      lastMs = ms
      if dur <= 0 then
        dur = 33
      end
      table.insert(durations, dur)
      total = total + dur
    end
  end
  return durations, total
end

local CACHE_VERSION = 1

local function saveGifMetadata(cacheDir, frames, durations, totalDuration, extractor, sourceMtime, sourceSize)
  local meta = {
    frames = frames,
    durations = durations,
    totalDuration = totalDuration,
    extractor = extractor or "unknown",
    sourceMtime = sourceMtime,
    sourceSize = sourceSize,
    cacheVersion = CACHE_VERSION,
  }
  local ok, encoded = pcall(noctalia.json.encode, meta)
  if ok then
    noctalia.writeFile(cacheDir .. "/metadata.json", encoded)
  end
end

local function loadGifMetadata(cacheDir, path)
  local raw = noctalia.readFile(cacheDir .. "/metadata.json")
  if not raw then
    return false
  end
  local ok, meta = pcall(noctalia.json.decode, raw)
  if not ok or not meta or not meta.frames then
    return false
  end

  -- Invalidate cache if the source file has changed, or if the cache format
  -- has been updated (e.g. to fix transparency handling).
  -- Also invalidate legacy caches that lack source metadata.
  if meta.cacheVersion ~= CACHE_VERSION then
    return false
  end
  if path then
    if meta.sourceMtime == nil or meta.sourceSize == nil then
      return false
    end
    local info = noctalia.fileInfo(path)
    if info then
      if meta.sourceMtime ~= info.mtime or meta.sourceSize ~= info.size then
        return false
      end
    end
  end

  gifFrames = {}
  for _, name in ipairs(meta.frames) do
    table.insert(gifFrames, cacheDir .. "/" .. name)
  end
  gifDurations = meta.durations
  gifTotalDuration = meta.totalDuration or 0
  return true
end

local function finalizeFrames(cacheDir, frameCount, startIndex, durations, totalDuration, extractor, sourceMtime, sourceSize)
  local frames = {}
  for i = 0, frameCount - 1 do
    table.insert(frames, string.format("frame-%03d.png", startIndex + i))
  end
  saveGifMetadata(cacheDir, frames, durations, totalDuration, extractor, sourceMtime, sourceSize)

  gifFrames = {}
  for _, name in ipairs(frames) do
    table.insert(gifFrames, cacheDir .. "/" .. name)
  end
  gifDurations = durations
  gifTotalDuration = totalDuration
  gifStartTime = noctalia.nowMs()
  gifLoading = false
end

local function extractWithMagick(path, cacheDir, sourceMtime, sourceSize)
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
      finalizeFrames(cacheDir, frameCount, 0, durations, totalDuration, "magick", sourceMtime, sourceSize)
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
      finalizeFrames(cacheDir, frameCount, 0, durations, totalDuration, "magick", sourceMtime, sourceSize)
    end)
  end)
end

local function extractWithFfmpeg(path, cacheDir, sourceMtime, sourceSize)
  -- ffmpeg starts output at frame-001.png; probe duration first.
  noctalia.runAsync({
    "ffprobe", "-v", "error", "-select_streams", "v:0",
    "-show_entries", "frame=pts_time", "-of",
    "csv=p=0", path
  }, function(probe)
    if probe.exitCode ~= 0 then
      noctalia.log("ffprobe failed: " .. (probe.stderr or ""))
      extractWithMagick(path, cacheDir, sourceMtime, sourceSize)
      return
    end

    local durations, totalDuration = parseFfmpegDurations(probe.stdout)
    local frameCount = #durations
    if frameCount == 0 then
      durations = { 100 }
      totalDuration = 100
      frameCount = 1
    end

    -- ffmpeg names frames 1-based.
    local cached = true
    for i = 1, frameCount do
      local framePath = string.format(cacheDir .. "/frame-%03d.png", i)
      if not noctalia.fileExists(framePath) then
        cached = false
        break
      end
    end

    if cached then
      finalizeFrames(cacheDir, frameCount, 1, durations, totalDuration, "ffmpeg", sourceMtime, sourceSize)
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
        extractWithMagick(path, cacheDir, sourceMtime, sourceSize)
        return
      end
      finalizeFrames(cacheDir, frameCount, 1, durations, totalDuration, "ffmpeg", sourceMtime, sourceSize)
    end)
  end)
end

local function detectTransparency(path, callback)
  if not noctalia.commandExists("magick") then
    callback(false)
    return
  end
  noctalia.runAsync({
    "magick", "identify", "-format", "%[opaque]\n", path
  }, function(result)
    if result.exitCode ~= 0 then
      callback(true)
      return
    end
    callback(trim(result.stdout) ~= "True")
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

  local sourceInfo = noctalia.fileInfo(path)
  local sourceMtime = sourceInfo and sourceInfo.mtime or 0
  local sourceSize = sourceInfo and sourceInfo.size or 0

  -- Use cached metadata if available and the source file has not changed.
  if loadGifMetadata(cacheDir, path) then
    gifPath = path
    gifStartTime = noctalia.nowMs()
    gifLoading = false
    return
  end

  -- ffmpeg is fast but loses transparent backgrounds on many GIFs.
  -- Use ImageMagick for transparent GIFs so the alpha channel is preserved.
  detectTransparency(path, function(isTransparent)
    if isTransparent and noctalia.commandExists("magick") then
      extractWithMagick(path, cacheDir, sourceMtime, sourceSize)
    elseif noctalia.commandExists("ffmpeg") then
      extractWithFfmpeg(path, cacheDir, sourceMtime, sourceSize)
    elseif noctalia.commandExists("magick") then
      extractWithMagick(path, cacheDir, sourceMtime, sourceSize)
    else
      noctalia.log("ffmpeg or ImageMagick is required for GIF support")
      gifLoading = false
    end
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
          fit = "contain",
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
      fit = "contain",
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
  -- Do NOT reset gifStartTime here; setActive is called on every config
  -- update and would restart the GIF loop prematurely while audio is active.
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
  -- Initialise the animation start time only once on first load while audio is active.
  if active and gifPath and gifStartTime == 0 then
    gifStartTime = noctalia.nowMs()
  end
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
    -- Restart the GIF loop only when transitioning from idle to active.
    if active and gifPath then
      gifStartTime = noctalia.nowMs()
    end
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
