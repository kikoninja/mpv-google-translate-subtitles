-- MPV Translate Subtitles — overlays and status notification
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
local ts_state = require 'ts_state'

local state = ts_state.state

local languages = nil
local overlay = nil
local status_overlay = nil

local function escape_ass(text)
    if not text or text == '' then
        return ''
    end
    return text
        :gsub('([\\{}])', '\\\\%1')
        :gsub('\r?\n', '\\N')
end

local function setup(opts)
    languages = { input_lang = opts.input_lang, output_lang = opts.output_lang }

    overlay = mp.create_osd_overlay('ass-events')
    overlay.hidden = true
    overlay.data = ''

    status_overlay = mp.create_osd_overlay('ass-events')
    status_overlay.hidden = true
    status_overlay.data = ''
end

local function update_overlay(text)
    if not text or text == '' then
        overlay.hidden = true
        overlay.data = ''
        overlay:update()
        return
    end

    overlay.data = string.format('{\\an2\\fs%s}%s', tostring(state.font_size), escape_ass(text))
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
    return string.format('Translation %s > %s %s', languages.input_lang, languages.output_lang, suffix)
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

return {
    setup = setup,
    update_overlay = update_overlay,
    show_status_notification = show_status_notification,
    status_message = status_message,
    update_display = update_display,
}
