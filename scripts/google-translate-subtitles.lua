-- MPV Google Translate Subtitles
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

local o = {
    input_lang = 'auto',
    output_lang = 'mk',
    prefetch_seconds = 3,
    toggle_key = 'Ctrl+t',
    curl_command = '/usr/bin/curl',
    translation_backend = 'libretranslate',
    libretranslate_url = 'https://libretranslate.com/translate',
    libretranslate_api_key = 'replace-with-your-api-key',
}
options.read_options(o, 'google-translate-subtitles')

local overlay = mp.create_osd_overlay('ass-events')
overlay.hidden = true

overlay.data = ''

local state = {
    enabled = false,
    user_delay = 0,
    current_text = nil,
    current_start = nil,
    cache = {},
    pending_lines = {},
    active_line = nil,
    update_timer = nil,
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

    overlay.data = string.format('{\\an2}%s', escape_ass(text))
    overlay.hidden = false
    overlay:update()
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


local utils = require 'mp.utils'

local function json_escape(value)
    if not value then
        return ''
    end

    return value
        :gsub('\\', '\\\\')
        :gsub('"', '\\"')
        :gsub('\n', '\\n')
        :gsub('\r', '\\r')
        :gsub('\t', '\\t')
end

local function parse_google_response(body)
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
    if state.cache[line.cache_key] then
        callback(state.cache[line.cache_key].translation)
        return
    end

    local backend = string.lower(o.translation_backend or 'google')
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
            '-X', 'POST',
            '-H', 'Content-Type: application/json',
            '--data', payload,
            o.libretranslate_url,
        }
    else
        args = {
            o.curl_command,
            '-sS',
            '--get',
            '--data-urlencode', 'q=' .. line.text,
            '--data', 'client=gtx',
            '--data', 'sl=' .. o.input_lang,
            '--data', 'tl=' .. o.output_lang,
            '--data', 'dt=t',
            'https://translate.googleapis.com/translate_a/single',
        }
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
            msg.warn('google-translate-subtitles: subprocess init failed:', err or 'unknown error')
            callback(nil)
            return
        end

        if type(result) ~= 'table' or result.status == nil then
            msg.warn('google-translate-subtitles: subprocess returned invalid result:', tostring(result))
            callback(nil)
            return
        end

        if result.status ~= 0 then
            msg.warn('google-translate-subtitles: translate API returned status', result.status,
                'stderr=', result.stderr or 'nil', 'stdout=', result.stdout or 'nil')
            callback(nil)
            return
        end

        local translated = nil
        local parse_err = nil

        if backend == 'libretranslate' then
            translated, parse_err = parse_libretranslate_response(result.stdout or '')
        else
            translated, parse_err = parse_google_response(result.stdout or '')
        end

        if not translated then
            msg.warn('google-translate-subtitles: parse failed:', parse_err,
                'stdout=', result.stdout or 'nil', 'stderr=', result.stderr or 'nil')
            callback(nil)
            return
        end

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
    msg.info('Google subtitle translation enabled')

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
    msg.info('Google subtitle translation disabled')
end

local function toggle_translation()
    if state.enabled then
        disable_translation()
    else
        enable_translation()
    end
end

mp.add_key_binding(o.toggle_key, 'toggle-google-translate-subtitles', toggle_translation)
msg.info('google-translate-subtitles loaded; press ' .. o.toggle_key .. ' to toggle')
