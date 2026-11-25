-- MPV Translate Subtitles
-- Copyright (C) 2026 Kristijan Antovski
--
-- This program is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation, either version 3 of the License, or
-- (at your option) any later version.
--
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
-- GNU General Public License for more details.
--
-- You should have received a copy of the GNU General Public License
-- along with this program. If not, see <https://www.gnu.org/licenses/>.

local mp = require 'mp'
local msg = require 'mp.msg'
local options = require 'mp.options'
local utils = require 'mp.utils'

local o = {
    input_lang = 'auto',
    output_lang = 'mk',
    prefetch_seconds = 3,
    toggle_key = 'Ctrl+t',
    font_size = 55,
    font_size_step = 5,
    increase_font_size_key = 'Ctrl+up',
    decrease_font_size_key = 'Ctrl+down',
    curl_command = '/usr/bin/curl',
    translation_backend = 'libretranslate',
    libretranslate_url = 'https://libretranslate.com/translate',
    libretranslate_api_key = '',
}
options.read_options(o, 'translate-subtitles')

local backend = string.lower(o.translation_backend or 'google')
if backend ~= 'google' and backend ~= 'libretranslate' then
    msg.warn('translate-subtitles: unknown translation_backend "' .. tostring(o.translation_backend) .. '"; falling back to "google"')
    backend = 'google'
end

local backend_name = (backend == 'libretranslate' and 'LibreTranslate') or 'Google Translate'

-- A missing or placeholder API key means "anonymous": skip sending api_key
-- rather than fail with an invalid key.
if backend == 'libretranslate' then
    local key = o.libretranslate_api_key
    if key == nil then
        o.libretranslate_api_key = ''
    elseif key == 'replace-with-your-api-key' then
        msg.warn('translate-subtitles: placeholder libretranslate_api_key in config ignored; set a real key or leave it empty for anonymous use')
        o.libretranslate_api_key = ''
    end
end

local overlay = mp.create_osd_overlay('ass-events')
overlay.hidden = true

overlay.data = ''

local status_overlay = mp.create_osd_overlay('ass-events')
status_overlay.hidden = true
status_overlay.data = ''

local state = {
    enabled = false,
    font_size = o.font_size,
    user_delay = 0,
    current_text = nil,
    current_start = nil,
    cache = {},
    pending_lines = {},
    active_line = nil,
    consecutive_failures = 0,
    breaker_cooldown_until = 0,
    update_timer = nil,
    status_timeout = nil,
}

local function normalize_text(text)
    if not text then
        return ''
    end
    return text
        :gsub('\r?\n', ' ')
        :gsub('%s+', ' ')
        :gsub('^%s+', '')
        :gsub('%s+$', '')
end

local function make_cache_key(text)
    return normalize_text(text)
end

local function escape_ass(text)
    if not text or text == '' then
        return ''
    end
    return text
        :gsub('([\\{}])', '\\\\%1')
        :gsub('\r?\n', '\\N')
end

local function update_overlay(text)
    if not text or text == '' then
        overlay.hidden = true
        overlay.data = ''
        overlay:update()
        return
    end

    overlay.data = string.format('{\\an2\\fs%d}%s', state.font_size, escape_ass(text))
    overlay.hidden = false
    overlay:update()
end

local function show_status_notification(text)
    status_overlay.data = string.format('{\\an8\\fs40}%s', escape_ass(text))
    status_overlay.hidden = false
    status_overlay:update()
    if state.status_timeout then
        state.status_timeout:kill()
        state.status_timeout = nil
    end
    state.status_timeout = mp.add_timeout(2.5, function()
        status_overlay.hidden = true
        status_overlay.data = ''
        status_overlay:update()
        state.status_timeout = nil
    end)
end

local function status_message(suffix)
    return string.format('Translation %s > %s %s', o.input_lang, o.output_lang, suffix)
end

local function update_display()
    local now = mp.get_property_number('time-pos', 0)
    local best = nil

    for i = #state.pending_lines, 1, -1 do
        local line = state.pending_lines[i]
        if line.end_time and now >= line.end_time then
            table.remove(state.pending_lines, i)
        elseif line.translation and now >= line.start_time and now < line.end_time then
            if not best or line.start_time > best.start_time then
                best = line
            end
        end
    end

    if best then
        if state.active_line ~= best then
            update_overlay(best.translation)
            state.active_line = best
        end
    else
        if state.active_line then
            update_overlay(nil)
            state.active_line = nil
        end
    end
end



local function json_escape(value)
    if not value then
        return ''
    end

    -- Byte-by-byte escaping: the character-class shortcut [\0-\31] is a
    -- malformed pattern in the LuaJIT that mpv embeds (plain Lua accepts it,
    -- so luac alone wouldn't catch this).
    local out = {}
    for i = 1, #value do
        local b = string.byte(value, i)
        local c = string.char(b)
        if c == '\\' then
            out[#out + 1] = '\\\\'
        elseif c == '"' then
            out[#out + 1] = '\\"'
        elseif b == 8 then
            out[#out + 1] = '\\b'
        elseif b == 12 then
            out[#out + 1] = '\\f'
        elseif b == 10 then
            out[#out + 1] = '\\n'
        elseif b == 13 then
            out[#out + 1] = '\\r'
        elseif b == 9 then
            out[#out + 1] = '\\t'
        elseif b < 32 then
            out[#out + 1] = string.format('\\u%04x', b)
        else
            out[#out + 1] = c
        end
    end
    return table.concat(out)
end

local function parse_translation_response(body) -- parses the Google Translate API response format
    local parsed = utils.parse_json(body)
    if type(parsed) ~= 'table' or type(parsed[1]) ~= 'table' then
        return nil, 'unexpected response format'
    end

    local parts = {}
    for _, item in ipairs(parsed[1]) do
        if type(item) == 'table' and type(item[1]) == 'string' then
            parts[#parts + 1] = item[1]
        end
    end

    return table.concat(parts, '')
end

local function parse_libretranslate_response(body)
    local parsed = utils.parse_json(body)
    if type(parsed) ~= 'table' then
        return nil, 'unexpected response format'
    end

    if type(parsed.translatedText) == 'string' then
        return parsed.translatedText
    end

    if type(parsed.translations) == 'table' and type(parsed.translations[1]) == 'table' and type(parsed.translations[1].translatedText) == 'string' then
        return parsed.translations[1].translatedText
    end

    return nil, 'missing translatedText in response'
end

local function request_translation(line, callback)
    local cached = state.cache[line.cache_key]
    if cached then
        callback(cached.translation)
        return
    end

    -- Circuit breaker: after repeated failures, skip requests for a cooldown
    -- period. This is wall-clock based (independent of subtitle timing) and
    -- only gates the network request, not the display.
    if os.time() < state.breaker_cooldown_until then
        msg.warn('translate-subtitles: circuit breaker open for ' .. backend_name .. '; skipping translation request')
        callback(nil)
        return
    end

    local args = {}

    if backend == 'libretranslate' then
        local payload = '{"q":"' .. json_escape(line.text) .. '","source":"' .. json_escape(o.input_lang) .. '","target":"' .. json_escape(o.output_lang) .. '","format":"text"'
        if o.libretranslate_api_key and o.libretranslate_api_key ~= '' then
            payload = payload .. ',"api_key":"' .. json_escape(o.libretranslate_api_key) .. '"'
        end
        payload = payload .. '}'

        args = {
            o.curl_command,
            '-sS',
            '--connect-timeout', '5',
            '--max-time', '20',
            '-X', 'POST',
            '-H', 'Content-Type: application/json',
            '--data', payload,
            o.libretranslate_url,
        }
    else
        args = {
            o.curl_command,
            '-sS',
            '--connect-timeout', '5',
            '--max-time', '20',
            '--get',
            '--data-urlencode', 'q=' .. line.text,
            '--data', 'client=gtx',
            '--data', 'sl=' .. o.input_lang,
            '--data', 'tl=' .. o.output_lang,
            '--data', 'dt=t',
            'https://translate.googleapis.com/translate_a/single',
        }
    end

    -- Records a failed attempt, aborts with callback(nil), and opens the
    -- circuit breaker after 5 consecutive failures.
    local function fail(reason)
        state.consecutive_failures = state.consecutive_failures + 1
        msg.warn('translate-subtitles: ' .. backend_name .. ' request failed: ' .. reason)
        if state.consecutive_failures >= 5 then
            state.consecutive_failures = 0
            state.breaker_cooldown_until = os.time() + 60
            msg.warn('translate-subtitles: circuit breaker open for 60s after 5 consecutive failures')
        end
        callback(nil)
    end

    mp.command_native_async({
        name = 'subprocess',
        capture_stdout = true,
        capture_stderr = true,
        args = args,
    }, function(success, result, err)
        if not state.enabled then
            return
        end

        if not success then
            fail('subprocess init failed: ' .. tostring(err or 'unknown error'))
            return
        end

        if type(result) ~= 'table' or result.status == nil then
            fail('subprocess returned invalid result: ' .. tostring(result))
            return
        end

        if result.status ~= 0 then
            fail('translate API returned status ' .. tostring(result.status)
                .. ' stderr=' .. tostring(result.stderr or 'nil')
                .. ' stdout=' .. tostring(result.stdout or 'nil'))
            return
        end

        local translated = nil
        local parse_err = nil

        if backend == 'libretranslate' then
            translated, parse_err = parse_libretranslate_response(result.stdout or '')
        else
            translated, parse_err = parse_translation_response(result.stdout or '')
        end

        if not translated then
            fail('parse failed: ' .. tostring(parse_err)
                .. ' stdout=' .. tostring(result.stdout or 'nil')
                .. ' stderr=' .. tostring(result.stderr or 'nil'))
            return
        end

        state.consecutive_failures = 0

        if not state.cache[line.cache_key] then
            state.cache[line.cache_key] = {
                text = line.text,
                start_time = line.start_time,
                end_time = line.end_time,
                translation = translated,
            }
        end

        callback(translated)
    end)
end

local function on_subtitle_change(_, sub_text)
    if not state.enabled then
        return
    end

    if not sub_text or sub_text == '' then
        state.current_text = nil
        state.current_start = nil
        -- Keep the last overlay visible until the updater confirms the line is finished.
        return
    end

    local start_time = mp.get_property_number('sub-start', nil)
    if not start_time then
        start_time = mp.get_property_number('time-pos', 0)
    end

    if sub_text == state.current_text and start_time == state.current_start then
        return
    end

    state.current_text = sub_text
    state.current_start = start_time

    local end_time = mp.get_property_number('sub-end', nil)
    if not end_time or end_time <= start_time then
        local duration = mp.get_property_number('sub-duration', nil)
        if not duration or duration <= 0 then
            duration = 4.0
        end
        end_time = start_time + duration
    end

    local line = {
        text = sub_text,
        start_time = start_time,
        end_time = end_time,
        translation = nil,
        cache_key = make_cache_key(sub_text),
    }

    local cached = state.cache[line.cache_key]
    if cached then
        line.translation = cached.translation
    end

    table.insert(state.pending_lines, line)
    update_display()

    if not line.translation then
        request_translation(line, function(translated)
            if not state.enabled then
                return
            end
            line.translation = translated
            update_display()
        end)
    end
end

local function enable_translation()
    if state.enabled then
        return
    end

    state.user_delay = mp.get_property_number('sub-delay', 0)
    mp.set_property_number('sub-delay', state.user_delay - o.prefetch_seconds)
    mp.set_property('sub-visibility', 'no')
    mp.observe_property('sub-text', 'string', on_subtitle_change)
    state.update_timer = mp.add_periodic_timer(0.05, update_display)
    state.update_timer:resume()
    state.enabled = true
    msg.info(backend_name .. ' subtitle translation enabled')
    show_status_notification(status_message('ON'))

    mp.add_timeout(0.2, function()
        local current = mp.get_property('sub-text')
        if current and current ~= '' then
            on_subtitle_change(nil, current)
        end
    end)
end

local function disable_translation()
    if not state.enabled then
        return
    end

    mp.unobserve_property(on_subtitle_change)
    if state.update_timer then
        state.update_timer:kill()
        state.update_timer = nil
    end
    mp.set_property('sub-visibility', 'yes')
    mp.set_property_number('sub-delay', state.user_delay)
    update_overlay(nil)
    state.current_text = nil
    state.current_start = nil
    state.pending_lines = {}
    state.active_line = nil
    state.enabled = false
    -- The translation cache is intentionally kept across disable/enable cycles,
    -- so repeated lines are not re-translated after a toggle.
    msg.info(backend_name .. ' subtitle translation disabled')
    show_status_notification(status_message('OFF'))
end

local function set_font_size(delta)
    local min_size = 10
    local max_size = 400
    local old = state.font_size
    state.font_size = math.max(min_size, math.min(max_size, state.font_size + delta))
    if state.font_size ~= old then
        msg.info(string.format('translate-subtitles: font size %d', state.font_size))
        if state.active_line then
            update_overlay(state.active_line.translation)
        end
    end
end

local function increase_font_size()
    set_font_size(o.font_size_step)
end

local function decrease_font_size()
    set_font_size(-o.font_size_step)
end

local function toggle_translation()
    if state.enabled then
        disable_translation()
    else
        enable_translation()
    end
end

mp.add_key_binding(o.toggle_key, 'toggle-translate-subtitles', toggle_translation)
if o.increase_font_size_key and o.increase_font_size_key ~= '' then
    mp.add_key_binding(o.increase_font_size_key, 'increase-translate-subtitles-font-size', increase_font_size)
end
if o.decrease_font_size_key and o.decrease_font_size_key ~= '' then
    mp.add_key_binding(o.decrease_font_size_key, 'decrease-translate-subtitles-font-size', decrease_font_size)
end
msg.info('translate-subtitles loaded (' .. backend_name .. '); press ' .. o.toggle_key .. ' to toggle')
