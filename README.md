# Audio Reactive Sticker for Noctalia

A Noctalia desktop widget that shows a sticker image and fades it in/out based on real audio playback.

## What it does

- Monitors PipeWire output streams using a small C helper.
- Detects when any output stream is actually running (not just open).
- Fades the sticker to `active_opacity` when audio is playing.
- Fades the sticker to `idle_opacity` after all audio has stopped for the hysteresis window.
- Supports static images (PNG, JPEG, WebP, SVG) and **animated GIFs**.

## Demo

The sticker fades in when audio starts playing and fades out when playback stops.

https://github.com/user-attachments/assets/84cb0612-8bdb-4727-a319-b5d509568e9a


## Requirements

- Noctalia shell (plugin API 32 or later)
- PipeWire with the default sink metadata (`pipewire` + `wireplumber`)
- `gcc`, `make`, `pkg-config`, `libpipewire-0.3` headers
- `ffmpeg` (recommended) or `magick` (ImageMagick) if you want animated GIF support

## Build

```bash
make
```

This compiles `audio-monitor/noctalia-audio-monitor` and copies it to `bin/`.

## Install

### Local install (development)

```bash
make install
```

This copies the plugin to `~/.local/share/noctalia/plugins/audio-sticker/`.

### Enable in Noctalia

```bash
noctalia msg plugins enable miixz/audio-sticker
```

Then add a desktop widget of type `miixz/audio-sticker:sticker` via the desktop widgets editor, or by editing `settings.toml`:

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
    image_path     = "/home/calvo/Pictures/Chitoge Stickers/chitoge.png"
    active_opacity = 1.0
    idle_opacity   = 0.0
    fade_ms        = 300
```

## Settings

### Per-widget settings

| Setting | Type | Default | Description |
|---|---|---|---|
| `image_path` | file | `''` | Path to the sticker image (PNG, JPG, WebP, SVG, or animated GIF). |
| `active_opacity` | double | `1.0` | Opacity when audio is playing. |
| `idle_opacity` | double | `0.0` | Opacity when audio is silent. |
| `fade_ms` | int | `300` | Fade in/out duration in milliseconds. |

### Plugin-level settings

These are shared by all widget instances and are found under **Settings → Plugins → Audio Reactive Sticker**.

| Setting | Type | Default | Description |
|---|---|---|---|
| `hysteresis_ms` | int | `500` | Delay before fading out after audio stops. |

## Testing

1. Make sure music or a video is paused.
2. The sticker should be at `idle_opacity`.
3. Start playback.
4. The sticker should fade to `active_opacity`.
5. Pause playback.
6. After `hysteresis_ms`, the sticker should fade back to `idle_opacity`.

You can also run the monitor directly to debug:

```bash
./bin/noctalia-audio-monitor --debug
```

## Limitations

- The C helper must be built for the target machine; the plugin will show an error if `bin/noctalia-audio-monitor` is missing.
- Animated GIFs are extracted to a cache folder. Very large/high-resolution GIFs may take longer to process; `ffmpeg` is used automatically when available because it is much faster than ImageMagick for this task.

### Credits
- Background Music: "burger" by bbno$ (Cleared for creator use)

## Friendly Reminding

Also try Nisekoi :)
