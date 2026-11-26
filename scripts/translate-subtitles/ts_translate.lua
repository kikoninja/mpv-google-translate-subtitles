-- MPV Translate Subtitles — translation requests
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
local utils = require 'mp.utils'
local ts_state = require 'ts_state'

local state = ts_state.state

-- Injected by setup() once options are loaded.
local o = nil
local backend = nil
local backend_name = nil

local function setup(options, backend_, backend_name_)
    o = options
    backend = backend_
    backend_name = backend_name_
end

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

return {
    setup = setup,
    make_cache_key = make_cache_key,
    request_translation = request_translation,
}
