local opacity = 0.0
local targetOpacity = 0.0
local currentOpacity = 0.0

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

function update()
  desktopWidget.setNeedsFrameTick(true)

  -- Seed initial target from the current shared state.
  local active = noctalia.state.get("audio_active") == true
  targetOpacity = active
    and (noctalia.getConfig("active_opacity") or 1.0)
    or  (noctalia.getConfig("idle_opacity") or 0.0)
  currentOpacity = targetOpacity
  opacity = targetOpacity

  -- React to changes published by the service.
  noctalia.state.watch("audio_active", function(value)
    local isActive = value == true
    targetOpacity = isActive
      and (noctalia.getConfig("active_opacity") or 1.0)
      or  (noctalia.getConfig("idle_opacity") or 0.0)
  end)

  render()
end

function onFrameTick(deltaMs)
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
