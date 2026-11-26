-- MPV Translate Subtitles — option loading
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

local msg = require 'mp.msg'
local options = require 'mp.options'

local function load_options()
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

    return { o = o, backend = backend, backend_name = backend_name }
end

return { load_options = load_options }
