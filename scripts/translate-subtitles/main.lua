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

-- Entry point. Options and backend live in ts_options.lua, shared state and
-- font-size persistence in ts_state.lua, overlays in ts_display.lua and the
-- translation request logic in ts_translate.lua.

local mp = require 'mp'
local msg = require 'mp.msg'

local ts_options = require 'ts_options'
local ts_state = require 'ts_state'
local ts_display = require 'ts_display'
local ts_translate = require 'ts_translate'

local loaded = ts_options.load_options()
local o = loaded.o
local backend = loaded.backend
local backend_name = loaded.backend_name

local state = ts_state.state

local saved_font_size = ts_state.load_saved_font_size()
if saved_font_size ~= nil and saved_font_size ~= o.font_size then
    msg.info('translate-subtitles: using saved font size ' .. tostring(saved_font_size) .. ' (config default ' .. tostring(o.font_size) .. ')')
end
state.font_size = saved_font_size or o.font_size

ts_display.setup(o)
ts_translate.setup(o, backend, backend_name)

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
        cache_key = ts_translate.make_cache_key(sub_text),
    }

    local cached = state.cache[line.cache_key]
    if cached then
        line.translation = cached.translation
    end

    table.insert(state.pending_lines, line)
    ts_display.update_display()

    if not line.translation then
        ts_translate.request_translation(line, function(translated)
            if not state.enabled then
                return
            end
            line.translation = translated
            ts_display.update_display()
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
    state.update_timer = mp.add_periodic_timer(0.05, ts_display.update_display)
    state.update_timer:resume()
    state.enabled = true
    msg.info(backend_name .. ' subtitle translation enabled')
    ts_display.show_status_notification(ts_display.status_message('ON'))

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
    ts_display.update_overlay(nil)
    state.current_text = nil
    state.current_start = nil
    state.pending_lines = {}
    state.active_line = nil
    state.enabled = false
    -- The translation cache is intentionally kept across disable/enable cycles,
    -- so repeated lines are not re-translated after a toggle.
    msg.info(backend_name .. ' subtitle translation disabled')
    ts_display.show_status_notification(ts_display.status_message('OFF'))
end

local function set_font_size(delta)
    local old = state.font_size
    state.font_size = math.max(ts_state.MIN_FONT_SIZE, math.min(ts_state.MAX_FONT_SIZE, state.font_size + delta))
    if state.font_size ~= old then
        msg.info(string.format('translate-subtitles: font size %s', tostring(state.font_size)))
        if state.active_line then
            ts_display.update_overlay(state.active_line.translation)
        end
        ts_state.save_font_size(state.font_size)
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
