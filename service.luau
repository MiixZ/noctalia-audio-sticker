local pluginDir = noctalia.pluginDir() or ""
local helperPath = pluginDir .. "/bin/noctalia-audio-monitor"

local function startMonitor()
  local threshold = noctalia.getConfig("threshold") or 0.001
  local hysteresis = noctalia.getConfig("hysteresis_ms") or 500

  -- Run the C helper directly (argument-array form, no shell parsing).
  noctalia.runStream(
    { helperPath, "--threshold", tostring(threshold), "--hysteresis-ms", tostring(hysteresis) },
    function(line)
      local active = (line == "active")
      noctalia.state.set("audio_active", active)
    end
  )
end

function update()
  -- Services get update() once at startup.
  if noctalia.fileExists(helperPath) then
    startMonitor()
  else
    noctalia.notifyError(
      "Audio Reactive Sticker",
      "Monitor binary not found at " .. helperPath .. ". Build with `make audio-monitor`."
    )
  end
end
