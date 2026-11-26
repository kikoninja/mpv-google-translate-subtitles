-- MPV Translate Subtitles — shared state and font-size persistence
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

-- Persistent state (saved font size) is stored as JSON in the mpv config
-- directory: <config-dir>/script-state/translate-subtitles.json.
-- It overrides the font_size from the config file once the user has
-- adjusted it with the font-size keys. The config file remains the
-- default; the saved value is written on every font size change.

local msg = require 'mp.msg'
local utils = require 'mp.utils'

local MIN_FONT_SIZE = 10
local MAX_FONT_SIZE = 120

local function get_config_dir()
    local xdg = os.getenv('XDG_CONFIG_HOME')
    if xdg and xdg ~= '' then
        return xdg .. '/mpv'
    end
    local home = os.getenv('HOME')
    if home and home ~= '' then
        return home .. '/.config/mpv'
    end
    return nil
end

local function get_state_file()
    local dir = get_config_dir()
    if not dir then
        return nil
    end
    return dir .. '/script-state/translate-subtitles.json'
end

local function shell_quote(path)
    return "'" .. path:gsub("'", "'\"'\"'") .. "'"
end

local function ensure_parent_dir(path)
    local dir = path:match('(.*)/[^/]+$')
    if not dir or dir == '' then
        return
    end
    local ok, p = pcall(io.popen, 'mkdir -p ' .. shell_quote(dir))
    if ok and p then
        p:close()
    end
end

local function load_saved_font_size()
    local path = get_state_file()
    if not path then
        return nil
    end
    local ok_open, f = pcall(io.open, path, 'r')
    if not ok_open or not f then
        return nil
    end
    local ok_read, content = pcall(f.read, f, '*a')
    f:close()
    if not ok_read or not content then
        return nil
    end
    local parsed = nil
    pcall(function()
        parsed = utils.parse_json(content)
    end)
    if type(parsed) ~= 'table' then
        msg.warn('translate-subtitles: state file unreadable; using config font size')
        return nil
    end
    local size = tonumber(parsed.font_size)
    if not size or size ~= size or size <= 0 then
        return nil
    end
    return math.max(MIN_FONT_SIZE, math.min(MAX_FONT_SIZE, size))
end

local function save_font_size(font_size)
    local path = get_state_file()
    if not path then
        msg.warn('translate-subtitles: cannot determine mpv config directory; font size not saved')
        return
    end
    ensure_parent_dir(path)
    local tmp_path = path .. '.tmp'
    local ok, f = pcall(io.open, tmp_path, 'w')
    if not ok or not f then
        msg.warn('translate-subtitles: cannot write state file ' .. tmp_path)
        return
    end
    f:write(string.format('{"font_size": %s}\n', tostring(font_size)))
    f:close()
    if not os.rename(tmp_path, path) then
        pcall(os.remove, tmp_path)
        msg.warn('translate-subtitles: cannot move state file into place')
    end
end

-- Runtime state shared between the modules and main.lua. Created once at load
-- time; main.lua sets font_size once the saved value (or config default) is known.
local state = {
    enabled = false,
    font_size = nil,
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

return {
    state = state,
    MIN_FONT_SIZE = MIN_FONT_SIZE,
    MAX_FONT_SIZE = MAX_FONT_SIZE,
    get_state_file = get_state_file,
    load_saved_font_size = load_saved_font_size,
    save_font_size = save_font_size,
}
