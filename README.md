# Audio Reactive Sticker for Noctalia

A Noctalia desktop widget that shows a sticker image and fades it in and out
with real audio playback. A small PipeWire helper decides when something is
actually playing, so paused players do not keep the sticker on screen.

## What it does

- A `monitor` service builds `bin/noctalia-audio-monitor` from `native/` on the
  first run and keeps one copy alive per session.
- The helper watches PipeWire output stream node states: a stream that stays
  open but is not running (paused Brave, Spotify in `init`, ...) does not count.
- The `sticker` desktop widget fades between `idle_opacity` and
  `active_opacity`, and every instance shares the same monitor process.
- Supports static images (PNG, JPEG, WebP, SVG) and animated GIFs. GIF frames
  are decoded with `ffmpeg` and cached, so the first use takes a moment.

## Demo

The sticker fades in when audio starts playing and fades out when playback stops.

https://github.com/user-attachments/assets/84cb0612-8bdb-4727-a319-b5d509568e9a


## Requirements

- Noctalia 5.0.0-beta.9 or newer (plugin API 24)
- PipeWire with WirePlumber or any session manager that exposes output streams
  as `Stream/Output/Audio` nodes
- `cc`, `make`, `pkg-config` and the `libpipewire-0.3` development headers
- `ffmpeg` (it also provides `ffprobe`) for animated GIF stickers

On Arch: `base-devel pipewire libpipewire pkgconf ffmpeg`. On Debian/Ubuntu:
`build-essential pkg-config libpipewire-0.3-dev ffmpeg`.

## Build

```bash
make
```

Compiles `native/audio-monitor.c` into `bin/noctalia-audio-monitor`. You do not
need to run this by hand: the plugin service builds the helper the first time
the plugin is enabled, and shows an alert if the build fails.

## Install

### Local install (development)

```bash
make install
```

Copies the plugin to `~/.local/share/noctalia/plugins/audio-sticker/`, including
the compiled helper.

### Enable in Noctalia

```bash
noctalia msg plugins enable miixz/audio-sticker
```

Then add a widget of type `miixz/audio-sticker:sticker` from the widget editor,
or in `settings.toml`:

```toml
[desktop_widgets.widget.my-audio-sticker]
type     = "miixz/audio-sticker:sticker"
output   = "DP-2"
cx       = 1280.0
cy       = 720.0
box_width  = 256.0
box_height = 256.0
rotation = 0.0

    [desktop_widgets.widget.my-audio-sticker.settings]
    image_path     = "/path/to/sticker.png"
    active_opacity = 1.0
    idle_opacity   = 0.0
    fade_ms        = 300
```

## Testing

1. Pause all media. The sticker sits at `idle_opacity`, which is `0` by default,
   so it is invisible.
2. Start playback. It fades to `active_opacity`.
3. Pause. After `hysteresis_ms` it fades back to `idle_opacity`.

To watch the helper directly, stop the plugin first: while the service is
running, the pid lock makes a second copy exit immediately.

```bash
noctalia msg plugins disable miixz/audio-sticker
./bin/noctalia-audio-monitor --debug
noctalia msg plugins enable miixz/audio-sticker
```

## Settings

### Per-widget settings

| Setting | Type | Default | Description |
|---|---|---|---|
| `image_path` | file | `''` | Path to the sticker image (PNG, JPG, WebP, SVG, or animated GIF). |
| `active_opacity` | double | `1.0` | Opacity when audio is playing. |
| `idle_opacity` | double | `0.0` | Opacity when audio is silent. `0` hides the sticker. |
| `fade_ms` | int | `300` | Fade in/out duration in milliseconds. `0` switches instantly. |

### Plugin-level settings

These are shared by all widget instances and are found under **Settings →
Plugins → Audio Reactive Sticker**. Changes apply the next time the helper
starts (plugin reload).

| Setting | Type | Default | Description |
|---|---|---|---|
| `hysteresis_ms` | int | `500` | Delay before fading out after audio stops. |

The opacity settings apply to the whole image, including its transparency; they
are not a wallpaper mask.

## Notes

- `bin/` is generated locally and is not tracked in git.
- The helper locks `$XDG_RUNTIME_DIR/noctalia-audio-monitor.pid`, so one monitor
  runs per session, and exits when the shell that started it goes away. Plugin
  reloads therefore never leave an orphan behind.
- GIF frames live under Noctalia's plugin data directory in
  `gif-cache/<image>/` and are invalidated when the source file changes. They
  stay there until the plugin data directory is removed.
- The helper reads PipeWire node states only. It never opens a capture stream,
  so no audio is recorded, buffered or sent anywhere, and the plugin makes no
  network requests.

## Credits

- Background Music: "burger" by bbno$ (Cleared for creator use)

## Friendly Reminding

Also try Nisekoi :)

## License

MIT
