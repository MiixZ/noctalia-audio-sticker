<!-- noctalia-pr-template:v1 -->

## Plugin

- **Id:** `miixz/audio-sticker`
- **Version:** {{VERSION}}
- [{{NEW}}] New plugin
- [{{UPDATE}}] Update to an existing plugin (version bumped in `plugin.toml`)

## What it does

A desktop sticker: an image that fades in while audio is playing and fades back
out when playback stops, so the desktop stays clean during silence.

The plugin ships two entries. The `monitor` service builds a small PipeWire
helper from `native/audio-monitor.c` on first run (`make -C native`, output in
`bin/`) and keeps one copy alive. The helper watches output stream node states
and prints `active` / `idle` on transitions; the service republishes those as
plugin state. The `sticker` desktop widget reads that state and animates
opacity, with per-widget image, active/idle opacity and fade duration. Several
sticker instances therefore share a single monitor process.

Paused players do not count: the helper looks at the PipeWire node state, not at
whether an output stream exists. Animated GIFs are decoded with ffmpeg and
cached, and only animate while the sticker is visible.

## External dependencies

- `cc`, `make`, `pkg-config`, `libpipewire-0.3` — compile
  `native/audio-monitor.c` on first run. No prebuilt binary is shipped.
- `ffmpeg` (including `ffprobe`) — decode animated GIF stickers into cached PNG
  frames.
- PipeWire at runtime — the helper connects to the registry as a normal client
  and reads `Stream/Output/Audio` node states. It never opens a capture stream.

Every dependency is declared in `dependencies` in `plugin.toml` and documented
in `README.md`.

## Testing

- [ ] Tested on Niri
- [x] Tested on Hyprland
- [ ] Tested on Sway
- [ ] Tested on another compositor:
- **Noctalia version tested against:** 5.3.0
- **Plugin API level:** 24 (`runAsync` with argument arrays; `nowMs` needs 12)

What was exercised:

- The plugin is installed and enabled on the author's Hyprland session with
  Noctalia 5.3.0. The `monitor` service owns the helper and follows playback;
  the demo video below shows the fade in and out on that setup.
- The native helper was built with `make -C native` (`-Wall -Wextra`, no
  warnings) and run against the live PipeWire session: it printed `idle`, then
  `active` while a `pw-play` test tone played, then `idle` again after the
  hysteresis window.
- PID lock and parent-death handling: a second copy exits immediately, and
  killing the shell that started the helper terminates it and removes the pid
  file.
- Fade in/out, GIF frame timing from cached metadata, error rendering, the
  generated retry loop and the build-failure path were exercised with a mocked
  Noctalia API (Lua 5.1 harness).
- `luac -p` parses both entries, and the repository validator passes.

## Screenshots / Videos

Demo on Hyprland (sticker fades in with playback, out on pause):

https://github.com/user-attachments/assets/84cb0612-8bdb-4727-a319-b5d509568e9a

The thumbnail was generated with the official
[thumbnail generator](https://assets.noctalia.dev/plugins/thumbnail-generator.html)
from a frame of that video.

## Checklist

- [x] The directory name matches the part of `id` after the `/` in `plugin.toml` exactly.
- [x] It ships `plugin.toml`, `README.md`, `thumbnail.webp`, and `translations/en.json`.
- [x] `README.md` follows the
      [README template](https://github.com/noctalia-dev/community-plugins/blob/main/README_TEMPLATE.md), documents
      every entry id and dependency, and includes exact panel IPC commands and launcher prefixes where applicable.
- [x] `thumbnail.webp` is present and relevant; for a new plugin I created it with the [thumbnail generator](https://assets.noctalia.dev/plugins/thumbnail-generator.html), and for an update I regenerated it with the generator if the visual identity or user-facing appearance changed.
- [x] `version` follows semver and is bumped in this PR; `plugin_api` is the oldest API level this plugin requires.
- [x] Every non-English translation in this PR uses a locale supported by Noctalia core, and I can read, write, and
      understand that language well enough to review and maintain it (no unreviewed machine/LLM translations).
- [x] I did not edit `catalog.toml`; CI generates it.
- [x] This PR touches exactly one plugin directory.

## Code review attestation

- [x] The code is readable and not obfuscated, minified, or generated.
- [x] It does not download and execute remote code.
- [x] Every network call, filesystem write, and spawned process is something the description above accounts for.
- [x] I have the right to publish this code under the `license` declared in `plugin.toml`.
