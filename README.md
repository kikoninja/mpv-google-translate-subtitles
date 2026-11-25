# MPV Google Translate Subtitles

An mpv script that automatically translates subtitles in real-time using Google Translate or a LibreTranslate instance, displaying the translations as an on-screen overlay while hiding the original subtitles.

## Features

- **Real-time subtitle translation** via Google Translate or a LibreTranslate instance
- **Pluggable backend** - switch between `google` and `libretranslate` in the config
- **Automatic caching** to avoid repeated API calls for the same subtitle text (the cache survives toggle off/on)
- **Configurable languages** for both input and output
- **Prefetch mode** that delays original subtitles to give time for translation requests
- **Keyboard toggle** to enable/disable translation on the fly
- **Customizable key binding** for toggling the feature
- **Request timeouts** (5s connect / 20s max) so a hung endpoint cannot stall the script
- **Circuit breaker** - after 5 consecutive failures, requests pause for 60s
- **Lightweight and efficient** - only translates visible subtitles

## Requirements

- mpv media player
- curl (for making HTTP requests to the translation backend)
- Lua support in mpv (included by default in most mpv builds)

## Installation

1. Locate your mpv scripts directory:
   - **Linux/macOS**: `~/.config/mpv/scripts/`
   - **Windows**: `%APPDATA%\mpv\scripts\`

2. Copy the script file:
   ```bash
   cp google-translate-subtitles.lua ~/.config/mpv/scripts/
   ```

3. Copy the configuration file:
   ```bash
   cp google-translate-subtitles.conf ~/.config/mpv/script-opts/
   ```

   If the directories don't exist, create them:
   ```bash
   mkdir -p ~/.config/mpv/scripts
   mkdir -p ~/.config/mpv/script-opts
   ```

## Configuration

Edit `~/.config/mpv/script-opts/google-translate-subtitles.conf` to customize the behavior:

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

Common language codes supported by Google Translate:
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
4. The script will display an info message in mpv's console when enabling/disabling

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
- Some language pairs work better than others with Google Translate

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
