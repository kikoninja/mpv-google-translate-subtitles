# MPV Translate Subtitles

An mpv script that automatically translates subtitles in real-time using Google Translate or a LibreTranslate instance, displaying the translations as an on-screen overlay while hiding the original subtitles.

## Features

- **Real-time subtitle translation** via Google Translate or a LibreTranslate instance
- **Pluggable backend** - switch between `google` and `libretranslate` in the config
- **Automatic caching** to avoid repeated API calls for the same subtitle text (the cache survives toggle off/on)
- **Configurable languages** for both input and output
- **Prefetch mode** that delays original subtitles to give time for translation requests
- **Keyboard toggle** to enable/disable translation on the fly
- **Configurable font size** for the overlay, with keyboard shortcuts to increase/decrease it (the adjusted size is saved to disk and restored on the next start, overriding the config default)
- **Customizable key binding** for toggling the feature
- **Request timeouts** (5s connect / 20s max) so a hung endpoint cannot stall the script
- **Circuit breaker** - after 5 consecutive failures, requests pause for 60s
- **Lightweight and efficient** - only translates visible subtitles

## Requirements

- mpv media player
- curl (for making HTTP requests to the translation backend)
- Lua support in mpv (included by default in most mpv builds)

## Installation

### Install script (Linux/macOS)

The easiest way is the installer, which copies the script, generates a config,
and adds an in-player context-menu item:

```bash
curl -fsSL https://raw.githubusercontent.com/kikoninja/mpv-translate-subtitles/master/install.sh | sh
```

With an interactive terminal it asks which backend to use (`google` or
`libretranslate`), the LibreTranslate URL and optional API key. With no
terminal it writes the defaults. Set `MPV_TRANSLATE_NONINTERACTIVE=1` to skip
the prompts explicitly.

The installer installs the **latest tagged version** by default. To install a
specific version:

```bash
MPV_TRANSLATE_SUBTITLES_REF=v0.3 sh -c 'curl -fsSL https://raw.githubusercontent.com/kikoninja/mpv-translate-subtitles/master/install.sh | sh'
```

or, from a checkout:

```bash
./install.sh --ref v0.3
```

The minimum supported version is **v0.2** (the first tag with the
`libretranslate` backend). Older tags are rejected.

What it does, per install:

1. Copies the script into `~/.config/mpv/scripts/` (uses the script layout
   of the chosen version: flat `.lua` for v0.2/v0.3, `scripts/translate-subtitles/`
   for v0.4+).
2. Prompts for the backend and (for LibreTranslate) the URL and API key, then
   writes `~/.config/mpv/script-opts/translate-subtitles.conf` (named after
   the version's script name). If that file already exists it is left untouched.
3. Adds an in-player "Translate" item to the mpv context menu
   (`~/.config/mpv/menu.conf`). If `menu.conf` is missing or empty, it is
   generated from mpv's default menu (via a throwaway headless mpv instance);
   otherwise the item is injected into the existing file. The original is
   backed up to `menu.conf.bak` on first modification. Menu injection requires
   v0.4+ (the `toggle-translate` binding) — older versions skip this step with
   a warning.

The installer never touches system directories and never runs with sudo.

### Manual installation

1. Locate your mpv scripts directory:
   - **Linux/macOS**: `~/.config/mpv/scripts/`
   - **Windows**: `%APPDATA%\mpv\scripts\`

2. Copy the script directory:
   ```bash
   cp -r scripts/translate-subtitles ~/.config/mpv/scripts/
   ```

   The script is a directory packaged for mpv: `main.lua` is the entry point and
   the `ts_*.lua` modules next to it hold the options, state, display and
   translation logic. You only need to copy the directory, not individual files.
   (For v0.2/v0.3 the script is a flat `.lua` file instead — copy it directly.)

3. Copy the configuration file:
   ```bash
   cp script-opts/translate-subtitles.conf ~/.config/mpv/script-opts/
   ```

   If the directories don't exist, create them:
   ```bash
   mkdir -p ~/.config/mpv/scripts
   mkdir -p ~/.config/mpv/script-opts
   ```

## Configuration

Edit `~/.config/mpv/script-opts/translate-subtitles.conf` to customize the behavior:

```ini
# Input language (source language of subtitles)
# Use 'auto' for automatic detection
input_lang=en

# Output language (language to translate to)
# Use language codes like: en, es, fr, de, it, ja, zh, mk, etc.
output_lang=id

# Number of seconds to prefetch translations before subtitle appears
# Increase if translations take too long to arrive
prefetch_seconds=5

# Keyboard shortcut to toggle translation on/off
toggle_key=Ctrl+t

# Overlay font size for translated subtitles (in pixels)
# This is the default used when no saved font size exists, or it is invalid.
# Adjusting the size with the keyboard shortcuts saves it to
# <config-dir>/script-state/translate-subtitles.json, which overrides this value
# on subsequent starts (delete that file to go back to the config default).
font_size=55

# Amount the font size changes per increase/decrease key press
font_size_step=5

# Keyboard shortcuts for increasing/decreasing the overlay font size
# (set to empty string to disable a binding)
increase_font_size_key=Ctrl+up
decrease_font_size_key=Ctrl+down

# Path to curl executable
curl_command=/usr/bin/curl

# Which translation backend to use: "google" or "libretranslate"
translation_backend=libretranslate

# LibreTranslate endpoint (only used with translation_backend=libretranslate)
libretranslate_url=https://libretranslate.com/translate

# Optional LibreTranslate API key. Leave empty for anonymous usage.
# A placeholder value ("replace-with-your-api-key") is ignored with a warning.
libretranslate_api_key=
```

### Rate limits

The script issues one request per unique subtitle line and caches results in memory,
so repeated lines are never re-translated. It deliberately does **not** throttle or
delay requests — subtitle display timing depends on the line schedule, so rate
limiting would break it. Users deploying LibreTranslate with rate limits should
run their own instance or a known API key; against the public LibreTranslate
endpoint, expect intermittent failures.

After 5 consecutive failures the script opens a 60-second circuit breaker and skips
further requests until the cooldown expires (each failure is logged).

### Language Codes

Common language codes supported by the translation backends:
- `en` - English
- `es` - Spanish
- `fr` - French
- `de` - German
- `it` - Italian
- `pt` - Portuguese
- `ru` - Russian
- `ja` - Japanese
- `zh` - Chinese (Simplified)
- `ko` - Korean
- `mk` - Macedonian
- `auto` - Auto-detect (only valid for `input_lang`)

For a complete list of supported languages, see [Google Translate language codes](https://cloud.google.com/translate/docs/languages).

## Usage

1. Open a video with subtitles in mpv
2. Press the toggle key (default: `Ctrl+t`) to enable translation
   - Original subtitles will be hidden
   - Translations will appear as an overlay at the bottom of the screen
3. Press the toggle key again to disable translation and show original subtitles
4. Press the font-size keys (default: `Ctrl+up` / `Ctrl+down`) to increase or
   decrease the overlay font size — the adjusted size is saved to
   `~/.config/mpv/script-state/translate-subtitles.json` and restored on the
   next start, overriding `font_size` from the config
5. The script will display an info message in mpv's console when enabling/disabling

## How It Works

- When enabled, the script intercepts subtitle text as it appears
- Each subtitle line is sent to the chosen translation backend via curl
- Translations are cached in memory to avoid redundant API calls
- Original subtitles are hidden, and translations are displayed as an overlay
- A configurable delay is applied to give the API time to respond
- When disabled, everything returns to normal subtitle display

## Troubleshooting

### Translations not appearing
- Check that curl is installed and the path is correct in the config
- Ensure you have internet connectivity
- Try increasing `prefetch_seconds` in the configuration

### "subprocess init failed" errors
- Verify the `curl_command` path is correct for your system
- Check that mpv has subprocess support enabled

### Wrong language detected
- Set `input_lang` to the correct language code instead of `auto`
- Some language pairs work better than others with the translation backends

## Limitations

- Requires an internet connection for each translation
- Depends on the chosen translation backend's stability and availability
- Translation quality varies by language pair
- Network latency may cause slight delays in subtitle display

## License

Copyright (C) 2026 Kristijan Antovski

This project is licensed under the GNU General Public License v3.0 or
(at your option) any later version. See the [COPYING.md](COPYING.md) file
for the full license text.

## Contributing

Feel free to submit issues or improvements!
