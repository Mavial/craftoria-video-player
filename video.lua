local bit32_band, bit32_lshift, bit32_rshift, math_frexp = bit32.band, bit32.lshift, bit32.rshift, math.frexp
local function log2(n) local _, r = math_frexp(n) return r-1 end
local dfpwm = require "cc.audio.dfpwm"
local REPOSITORY = "Mavial/craftoria-video-player"
local DEFAULT_R2_URL = "https://craftoria-video-player.raftoria.workers.dev/videos.json"
local function r2URL()
    return settings.get("video.r2_url") or DEFAULT_R2_URL
end
-- Based on MCJack123/sanjuuni 0.5's 32vid-player-mini.lua.
-- Keep audio decoder state, wait for speaker buffers, and yield between frames.
local file, speaker
local originalTerminal = term.current()
local activeMonitor, ownsMonitor = nil, false
local restoreScreen
local outputs, startupNotice = {}, nil
local configDefaults = {volume = 1, muted = false, speakers = "auto", speaker = "",
    monitor = "", scale = "auto", columns = 0, touchStop = true, startup = "menu", refresh = 0,
    r2_url = DEFAULT_R2_URL}
local configKeys = {volume = "video.volume", muted = "video.muted", speakers = "video.speakers",
    speaker = "video.speaker", monitor = "video.monitor", scale = "video.menu_scale",
    columns = "video.columns", touchStop = "video.touch_stop", startup = "video.startup",
    refresh = "video.refresh_minutes", r2_url = "video.r2_url"}
local function copy(value) local result = {}; for key, item in pairs(value) do result[key] = item end; return result end
local function readConfig()
    local result = copy(configDefaults)
    for key, name in pairs(configKeys) do
        local value = settings.get(name)
        if value ~= nil and type(value) == type(result[key]) then result[key] = value end
    end
    result.volume = result.volume == result.volume and math.max(0, math.min(3, result.volume)) or 1
    if result.speakers ~= "auto" and result.speakers ~= "all" and result.speakers ~= "chosen" then result.speakers = "auto" end
    if result.scale ~= "auto" and result.scale ~= "0.5" and result.scale ~= "1" and result.scale ~= "1.5" then result.scale = "auto" end
    if result.columns ~= 0 and result.columns ~= 2 and result.columns ~= 3 and result.columns ~= 4 then result.columns = 0 end
    if result.startup ~= "loop" then result.startup = "menu" end
    if result.refresh ~= 5 and result.refresh ~= 15 and result.refresh ~= 60 then result.refresh = 0 end
    return result
end
local config = readConfig()
local function saveValues(values)
    local previous = {}
    for name, value in pairs(values) do previous[name] = settings.get(name); settings.set(name, value) end
    local ok, result = pcall(settings.save)
    if ok and result ~= false then return true end
    for name in pairs(values) do
        if previous[name] == nil then settings.unset(name) else settings.set(name, previous[name]) end
    end
    if not ok and tostring(result) == "Terminated" then error(result, 0) end
    return false, ok and "Could not write computer settings." or tostring(result)
end
local function speakerDevices()
    local devices = {}
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "speaker" then devices[#devices + 1] = {name = name, device = peripheral.wrap(name)} end
    end
    table.sort(devices, function(a, b) return a.name < b.name end)
    return devices
end
local function selectOutputs()
    local devices = speakerDevices()
    if config.muted or config.volume == 0 then return {} end
    if config.speakers == "all" then return devices end
    if config.speakers == "chosen" then
        for _, output in ipairs(devices) do if output.name == config.speaker then return {output} end end
        -- Recover a disconnected selection without making the settings UI inaccessible.
        startupNotice = "Chosen speaker missing; using automatic output."
    end
    return devices[1] and {devices[1]} or {}
end
local function stopOutputs()
    for _, output in ipairs(outputs) do pcall(output.device.stop) end
end

local function setupMonitor(configured, force)
    -- An explicit ROM "monitor <name> ..." launch keeps its chosen display and
    -- touch conversion. Direct launches select and redirect a display here.
    local wrapped, currentName = pcall(peripheral.getName, originalTerminal)
    if not force and wrapped and peripheral.getType(currentName) == "monitor" then
        if not originalTerminal.isColor() then error("Video playback needs an Advanced Monitor.", 0) end
        originalTerminal.setTextScale(0.5)
        originalTerminal.setCursorBlink(false)
        activeMonitor = currentName
        return
    end

    configured = configured == nil and config.monitor or configured
    local selected
    if configured ~= nil and configured ~= "" then
        if peripheral.getType(configured) == "monitor" and peripheral.wrap(configured).isColor() then
            selected = {name = configured, monitor = peripheral.wrap(configured)}
        else
            startupNotice = "Chosen monitor missing or not advanced; using automatic display."
        end
    end
    if not selected then
        local candidates = {}
        for _, name in ipairs(peripheral.getNames()) do
            if peripheral.getType(name) == "monitor" then
                local ok, candidate = pcall(function()
                    local monitor = peripheral.wrap(name)
                    if not monitor.isColor() then return end
                    local width, height = monitor.getSize()
                    local scale = monitor.getTextScale()
                    return {name = name, monitor = monitor, scale = scale,
                        area = width * height * scale * scale}
                end)
                if ok and candidate then candidates[#candidates + 1] = candidate end
            end
        end
        table.sort(candidates, function(a, b)
            if a.area == b.area then return a.name < b.name end
            return a.area > b.area
        end)
        -- Probe the largest walls first. Restore scales on displays we skip.
        for _, candidate in ipairs(candidates) do
            local ok, fits = pcall(function()
                candidate.monitor.setTextScale(0.5)
                local width, height = candidate.monitor.getSize()
                return width >= 143 and height >= 52
            end)
            if ok and fits then selected = candidate; break end
            pcall(candidate.monitor.setTextScale, candidate.scale)
        end
        -- A smaller Advanced Monitor can still show the menu. Playback reports
        -- the actual required dimensions rather than silently cropping video.
        selected = selected or candidates[1]
    end
    if selected then
        if force then pcall(restoreScreen) end
        selected.monitor.setTextScale(0.5)
        activeMonitor, ownsMonitor = selected.name, true
        term.redirect(selected.monitor)
        term.setCursorBlink(false)
    elseif force then
        activeMonitor, ownsMonitor = nil, false
        term.redirect(originalTerminal)
    end
end

local function inputEvent()
    while true do
        local event = table.pack(os.pullEvent())
        if ownsMonitor and event[1] == "monitor_touch" then
            if event[2] == activeMonitor then return "mouse_click", 1, event[3], event[4] end
        elseif ownsMonitor and event[1]:match("^mouse_") then
            -- Computer-GUI coordinates do not refer to the selected monitor.
        elseif event[1] == "peripheral_detach" and event[2] == activeMonitor then
            error("Video monitor disconnected. Reconnect it and start the player again.", 0)
        else
            return table.unpack(event, 1, event.n)
        end
    end
end

local function setDisplayScale(scale)
    if activeMonitor and term.current().getTextScale() ~= scale then
        term.current().setTextScale(scale)
    end
end

local function closeInput()
    if file then
        pcall(file.close)
        file = nil
    end
end

-- Fetch each page, including asset pages, so the library grows without edits.
local function cataloguePages(url)
    local items = {}
    while url do
        local response, message, failed = http.get(url, {
            ["Accept"] = "application/vnd.github+json",
            ["User-Agent"] = "Craftoria-Video-Player",
        })
        if not response then
            local status = failed and failed.getResponseCode()
            if failed then failed.close() end
            if status == 403 or status == 429 then
                error("Source request limit reached. Wait before refreshing.", 0)
            end
            error(message or "Could not load video catalogue", 0)
        end
        local ok, body, headers = pcall(function()
            return response.readAll(), response.getResponseHeaders()
        end)
        response.close()
        if not ok then error(body, 0) end
        local data = textutils.unserialiseJSON(body)
        if type(data) ~= "table" or (body:match("^%s*(.)") ~= "[") then
            error("Source returned an invalid video list", 0)
        end
        for _, item in ipairs(data) do items[#items + 1] = item end
        local link
        for name, value in pairs(headers) do
            if name:lower() == "link" then link = value end
        end
        url = link and link:match('<([^>]+)>;%s*rel="next"') or nil
    end
    return items
end

local function loadLibrary(source)
    source = source == nil and r2URL() or source
    if source ~= "" then
        if type(source) ~= "string" or not source:match("^https://[^/]+") then
            error("video.r2_url must be an HTTPS catalogue URL", 0)
        end
        local videos, seen = {}, {}
        for _, video in ipairs(cataloguePages(source)) do
            if type(video) ~= "table" or type(video.title) ~= "string" or video.title == ""
                or type(video.url) ~= "string" or not video.url:match("^https://[^/]+")
                or type(video.size) ~= "number" or video.size < 0 then
                error("R2 catalogue contains an invalid video entry", 0)
            end
            if not seen[video.url] then
                seen[video.url] = true
                videos[#videos + 1] = { title = video.title:gsub("[%c]", " "), url = video.url,
                    size = video.size, release = "R2" }
            end
        end
        table.sort(videos, function(a, b) return a.title:lower() < b.title:lower() end)
        return videos
    end
    local releases = cataloguePages("https://api.github.com/repos/" .. REPOSITORY .. "/releases?per_page=100")
    local videos, seen = {}, {}
    for _, release in ipairs(releases) do
        if not release.draft then
            local assets = cataloguePages(release.assets_url .. "?per_page=100")
            for _, asset in ipairs(assets) do
                local name, url = asset.name, asset.browser_download_url
                if type(name) == "string" and name:lower():match("%.32vid$")
                    and asset.state == "uploaded" and type(url) == "string" and not seen[url] then
                    seen[url] = true
                    local title = asset.label
                    if type(title) ~= "string" or title == "" then
                        title = name:sub(1, -7):gsub("[-_]", " "):gsub("(%a)([%w']*)", function(a, b)
                            return a:upper() .. b
                        end)
                    end
                    videos[#videos + 1] = {
                        title = title:gsub("[%c]", " "), url = url,
                        release = tostring(release.tag_name):gsub("[%c]", " "), size = asset.size or 0,
                    }
                end
            end
        end
    end
    table.sort(videos, function(a, b)
        if a.title == b.title then return a.url < b.url end
        return a.title:lower() < b.title:lower()
    end)
    return videos
end

restoreScreen = function()
    for i = 0, 15 do term.setPaletteColor(2^i, term.nativePaletteColor(2^i)) end
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.setCursorPos(1, 1)
    term.clear()
end

local function play(path)
    outputs = selectOutputs()
    speaker = outputs[1] and outputs[1].device
    if path:match "^https?://" then
        local response, message, failed = http.get(path, nil, true)
        if failed then failed.close() end
        file = assert(response, message or "Could not download video")
    else
        file = assert(fs.open(shell.resolve(path), "rb"))
    end

    if file.read(4) ~= "32VD" then closeInput() error("Not a 32Vid file") end
    local width, height, fps, nstreams, flags = ("<HHBBH"):unpack(file.read(8))
    --print(width, height, fps, nstreams, flags)
    if nstreams ~= 1 then closeInput() error("Separate stream files not supported by this tool") end
    if bit32_band(flags, 1) == 0 then closeInput() error("DEFLATE or no compression not supported by this tool") end
    local streamSize, nframes, ctype = ("<IIB"):unpack(file.read(9))
    if ctype ~= 0x0C then closeInput() error("Stream type not supported by this tool") end

    -- Demultiplex compressed audio before starting the playback clock. Keeping
    -- the compressed recording in RAM avoids refills waiting on video decoding.
    local data = file.readAll()
    closeInput()
    if #data ~= streamSize then error("Truncated 32Vid stream", 0) end
    local audioPackets, position = {}, 1
    for _ = 1, nframes do
        if position + 4 > #data then error("Truncated 32Vid packet header", 0) end
        local size, kind = ("<IB"):unpack(data, position)
        local nextPosition = position + 5 + size
        if nextPosition - 1 > #data then error("Truncated 32Vid packet", 0) end
        if kind == 1 then audioPackets[#audioPackets + 1] = data:sub(position + 5, nextPosition - 1) end
        position = nextPosition
    end
    if position ~= #data + 1 then error("Invalid 32Vid stream length", 0) end
    local audioData = table.concat(audioPackets)
    audioPackets, position = nil, 1
    file = {
        read = function(count)
            if not count then local value = data:byte(position); position = position + 1; return value end
            local value = data:sub(position, position + count - 1)
            position = position + count
            return value
        end,
        close = function() data = nil end,
    }
    setDisplayScale(0.5)
    local outputWidth, outputHeight = term.getSize()
    if not bit32.btest(flags, 0x20) and (width > outputWidth or height > outputHeight) then
        error(string.format("Video needs %dx%d characters; this screen is %dx%d. Use a larger Advanced Monitor wall.",
            width, height, outputWidth, outputHeight), 0)
    end

    local monitors, mawidth, maheight
    if bit32.btest(flags, 0x20) then
        mawidth, maheight = bit32_band(bit32_rshift(flags, 6), 7) + 1, bit32_band(bit32_rshift(flags, 9), 7) + 1
        monitors = settings.get('sanjuuni.multimonitor')
        if not monitors or #monitors < maheight or #monitors[1] < mawidth then
            term.clear()
            term.setCursorPos(1, 1)
            print('This video needs monitors to be calibrated before being displayed. Please right-click each monitor in order, from the top left corner to the bottom right corner, going right first, then down.\n')
            monitors = {}
            local a = {}
            for b = 1, maheight do
                monitors[b] = {}
                for c = 1, mawidth do
                    local d, e = term.getCursorPos()
                    for f = 1, maheight do
                        term.setCursorPos(3, e + f - 1)
                        term.clearLine()
                        for g = 1, mawidth do term.blit('\x8F ', g == c and f == b and '00' or '77', 'ff') end
                    end
                    term.setCursorPos(3, e + maheight)
                    term.write('(' .. c .. ', ' .. b .. ')')
                    term.setCursorPos(1, e)
                    repeat
                        local d, h = os.pullEvent('monitor_touch')
                        monitors[b][c] = h
                    until not a[h]
                    a[monitors[b][c]] = true
                    sleep(0.25)
                end
            end
            settings.set('sanjuuni.multimonitor', monitors)
            settings.save()
            print('Calibration complete. Settings have been saved for future use.')
        end
        for _, r in ipairs(monitors) do for i, m in ipairs(r) do r[i] = peripheral.wrap(m) peripheral.call(m, "setTextScale", 0.5) peripheral.call(m, "clear") end end
    end

    local function readDict(size)
        local retval = {}
        for i = 0, size - 1, 2 do
            local b = file.read()
            retval[i] = bit32.rshift(b, 4)
            retval[i+1] = bit32.band(b, 15)
        end
        return retval
    end
    local init, read
    if bit32_band(flags, 3) == 1 then
        local decodingTable, X, readbits, isColor
        function init(c)
            isColor = c
            local R = file.read()
            local L = 2^R
            local Ls = readDict(c and 24 or 32)
            if R == 0 then
                decodingTable = file.read()
                X = nil
                return
            end
            local a = 0
            for i = 0, #Ls do Ls[i] = Ls[i] == 0 and 0 or 2^(Ls[i]-1) a = a + Ls[i] end
            assert(a == L, a)
            decodingTable = {R = R}
            local x, step, next, symbol = 0, 0.625 * L + 3, {}, {}
            for i = 0, #Ls do
                next[i] = Ls[i]
                for _ = 1, Ls[i] do
                    while symbol[x] do x = (x + 1) % L end
                    x, symbol[x] = (x + step) % L, i
                end
            end
            for x = 0, L - 1 do
                local s = symbol[x]
                local t = {s = s, n = R - log2(next[s])}
                t.X, decodingTable[x], next[s] = bit32_lshift(next[s], t.n) - L, t, 1 + next[s]
            end
            local partial, bits, pos = 0, 0, 1
            function readbits(n)
                if not n then n = bits % 8 end
                if n == 0 then return 0 end
                while bits < n do pos, bits, partial = pos + 1, bits + 8, bit32_lshift(partial, 8) + file.read() end
                local retval = bit32_band(bit32_rshift(partial, bits-n), 2^n-1)
                bits = bits - n
                return retval
            end
            X = readbits(R)
        end
        function read(nsym)
            local retval = {}
            if X == nil then
                for i = 1, nsym do retval[i] = decodingTable end
                return retval
            end
            local i = 1
            local last = 0
            while i <= nsym do
                local t = decodingTable[X]
                if isColor and t.s >= 16 then
                    local l = 2^(t.s - 15)
                    for n = 0, l-1 do retval[i+n] = last end
                    i = i + l
                else retval[i], last, i = t.s, t.s, i + 1 end
                X = t.X + readbits(t.n)
            end
            --print(X)
            return retval
        end
    else
        error("Unimplemented!")
    end

    local blitColors = {[0] = "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f"}
    local start, lastyield
    local vframe = 0
    local subs = {}
    term.clear()
    local function renderVideo()
        start = start or os.epoch "utc"
        lastyield = start
        for _ = 1, nframes do
            local size, ftype = ("<IB"):unpack(file.read(5))
            --print(size, ftype, file.seek())
            if ftype == 0 and speaker and #audioData > 0 and os.epoch "utc" > start + (vframe + 3) * 1000 / fps then
                -- Frames are independently compressed. Catch up with audio instead
                -- of spending monitor/decoder time displaying obsolete pictures.
                file.read(size)
                vframe = vframe + 1
            elseif ftype == 0 then
                if os.epoch "utc" - lastyield > 100 then sleep(0) lastyield = os.epoch "utc" end
                local dcstart = os.epoch "utc"
                --print("init screen", vframe, file.seek())
                init(false)
                --print("read screen", vframe, file.seek())
                local screen = read(width * height)
                --print("init colors", vframe, file.seek())
                init(true)
                --print("read bg colors", vframe)
                local bg = read(width * height)
                --print("read fg colors", vframe)
                local fg = read(width * height)
                local dctime = os.epoch "utc" - dcstart
                local wait = start + vframe * 1000 / fps - os.epoch "utc"
                if wait > 0 then sleep(wait / 1000) end
                local texta, fga, bga = {}, {}, {}
                for y = 0, height - 1 do
                    local text, fgs, bgs = "", "", ""
                    for x = 1, width do
                        text = text .. string.char(128 + screen[y*width+x])
                        fgs = fgs .. blitColors[fg[y*width+x]]
                        bgs = bgs .. blitColors[bg[y*width+x]]
                    end
                    texta[y+1], fga[y+1], bga[y+1] = text, fgs, bgs
                end
                for i = 0, 15 do term.setPaletteColor(2^i, file.read() / 255, file.read() / 255, file.read() / 255) end
                for y = 1, height do
                    term.setCursorPos(1, y)
                    term.blit(texta[y], fga[y], bga[y])
                end
                local delete = {}
                for i, v in ipairs(subs) do
                    if vframe <= v.frame + v.length then
                        term.setCursorPos(v.x, v.y)
                        term.setBackgroundColor(v.bgColor)
                        term.setTextColor(v.fgColor)
                        term.write(v.text)
                    else delete[#delete+1] = i end
                end
                for i, v in ipairs(delete) do table.remove(subs, v - i + 1) end
                --term.setCursorPos(1, height + 1)
                --term.clearLine()
                --print("Frame decode time:", dctime, "ms")
                vframe = vframe + 1
            elseif ftype == 1 then
                file.read(size) -- The independent audio worker consumes this track.
            elseif ftype == 8 then
                local data = file.read(size)
                local sub = {}
                sub.frame, sub.length, sub.x, sub.y, sub.color, sub.flags, sub.text = ("<IIHHBBs2"):unpack(data)
                sub.bgColor, sub.fgColor = 2^bit32_rshift(sub.color, 4), 2^bit32_band(sub.color, 15)
                subs[#subs+1] = sub
            elseif ftype >= 0x40 and ftype < 0x80 then
                if ftype == 64 then vframe = vframe + 1 end
                local mx, my = bit32_band(bit32_rshift(ftype, 3), 7) + 1, bit32_band(ftype, 7) + 1
                --print("(" .. mx .. ", " .. my .. ")")
                local term = monitors[my][mx]
                if os.epoch "utc" - lastyield > 100 then sleep(0) lastyield = os.epoch "utc" end
                local width, height = ("<HH"):unpack(file.read(4))
                local dcstart = os.epoch "utc"
                --print("init screen", vframe, file.seek())
                init(false)
                --print("read screen", vframe, file.seek())
                local screen = read(width * height)
                --print("init colors", vframe, file.seek())
                init(true)
                --print("read bg colors", vframe)
                local bg = read(width * height)
                --print("read fg colors", vframe)
                local fg = read(width * height)
                local dctime = os.epoch "utc" - dcstart
                local wait = start + vframe * 1000 / fps - os.epoch "utc"
                if wait > 0 then sleep(wait / 1000) end
                local texta, fga, bga = {}, {}, {}
                for y = 0, height - 1 do
                    local text, fgs, bgs = "", "", ""
                    for x = 1, width do
                        text = text .. string.char(128 + screen[y*width+x])
                        fgs = fgs .. blitColors[fg[y*width+x]]
                        bgs = bgs .. blitColors[bg[y*width+x]]
                    end
                    texta[y+1], fga[y+1], bga[y+1] = text, fgs, bgs
                end
                for i = 0, 15 do term.setPaletteColor(2^i, file.read() / 255, file.read() / 255, file.read() / 255) end
                for y = 1, height do
                    term.setCursorPos(1, y)
                    term.blit(texta[y], fga[y], bga[y])
                end
                --[[local delete = {}
                for i, v in ipairs(subs) do
                    if vframe <= v.frame + v.length then
                        term.setCursorPos(v.x, v.y)
                        term.setBackgroundColor(v.bgColor)
                        term.setTextColor(v.fgColor)
                        term.write(v.text)
                    else delete[#delete+1] = i end
                end
                for i, v in ipairs(delete) do table.remove(subs, v - i + 1) end]]
                --term.setCursorPos(1, height + 1)
                --term.clearLine()
                --print("Frame decode time:", dctime, "ms")
            else closeInput() error("Unknown frame type " .. ftype) end
        end
    end

    local function playAudio(output)
        local decodeAudio = dfpwm.make_decoder()
        local raw = bit32_band(flags, 12) == 0
        local chunkSize = raw and 131072 or 16384
        local function waitForBuffer()
            while true do
                local event, name = os.pullEvent()
                if peripheral.getType(output.name) ~= "speaker" then return false end
                if event == "speaker_audio_empty" and name == output.name then return true end
            end
        end
        for offset = 1, #audioData, chunkSize do
            local encoded = audioData:sub(offset, offset + chunkSize - 1)
            local chunk
            if raw then
                chunk = {}
                for index = 1, #encoded do chunk[index] = encoded:byte(index) - 128 end
            else
                chunk = decodeAudio(encoded)
            end
            while true do
                local ok, accepted = pcall(output.device.playAudio, chunk, config.volume)
                if not ok then
                    if peripheral.getType(output.name) ~= "speaker" then return end
                    error(accepted, 0)
                end
                if accepted then break end
                if not waitForBuffer() then return end
            end
            start = start or os.epoch "utc"
        end
        -- Buffer-empty means "room for another packet", not audible completion.
        -- Wait for the final pending packet to be dispatched, then let it drain.
        if #audioData > 0 then
            if not waitForBuffer() then return end
            local lastSize = (#audioData - 1) % chunkSize + 1
            sleep(lastSize * (raw and 1 or 8) / 48000 + 0.5)
        end
    end
    if speaker and #audioData > 0 then
        local workers = {}
        for _, output in ipairs(outputs) do
            local chosen = output
            workers[#workers + 1] = function() playAudio(chosen) end
        end
        workers[#workers + 1] = renderVideo
        parallel.waitForAll(table.unpack(workers))
    else
        renderVideo()
    end

    closeInput()
end

local function runPlayback(path, canStop, loopVideo)
    local stopped = false
    local ok, message = pcall(function()
        if canStop then
            parallel.waitForAny(function()
                repeat
                    play(path)
                    -- Yield between repeats even for an empty recording, and
                    -- leave the stop listener active while reloading the URL.
                    if loopVideo then sleep(0) end
                until not loopVideo
            end, function()
                while true do
                    local event, value = inputEvent()
                    if (event == "key" and value == keys.backspace) or (event == "mouse_click" and config.touchStop) then
                        stopped = true
                        return
                    end
                end
            end)
        else
            play(path)
        end
    end)
    closeInput()
    if stopped or not ok then stopOutputs() end
    local restored, restoreError = pcall(restoreScreen)
    if not ok and tostring(message) == "Terminated" then error(message, 0) end
    if not restored then error(not ok and message or restoreError, 0) end
    return ok, message, stopped
end

local function menu()
    local videos, selected, page, status = {}, 1, 1, ""
    local statusColor, menuScale = colors.lightGray, 0.5
    local palette = {
        {colors.black, 0x14151D}, {colors.gray, 0x343642}, {colors.blue, 0x29364A},
        {colors.lightGray, 0xABABBB}, {colors.white, 0xEEEEF3}, {colors.cyan, 0x5DD6DF},
        {colors.green, 0x54B89B}, {colors.orange, 0xF1B562}, {colors.red, 0xD26A75},
    }
    local function chooseMenuScale()
        if activeMonitor then
            local requested = tonumber(config.scale) or 1
            setDisplayScale(requested)
            local width, height = term.getSize()
            menuScale = config.scale == "auto" and (width >= 51 and height >= 19 and 1 or 0.5)
                or (width >= 36 and height >= 12 and requested or 0.5)
            setDisplayScale(menuScale)
        end
    end
    local function theme()
        restoreScreen()
        for _, entry in ipairs(palette) do term.setPaletteColor(entry[1], entry[2]) end
    end
    local function bounded(text, width)
        return #text <= width and text or text:sub(1, math.max(0, width - 3)) .. "..."
    end
    local function writeAt(x, y, text, foreground, background)
        local width, height = term.getSize()
        if x > width or y > height then return end
        term.setCursorPos(x, y)
        term.setTextColor(foreground or colors.white)
        term.setBackgroundColor(background or colors.black)
        term.write(text:sub(1, width - x + 1))
    end
    local function fill(x, y, width, height, background)
        for row = y, y + height - 1 do writeAt(x, row, string.rep(" ", width), colors.white, background) end
    end
    local function center(x, y, width, text, foreground, background)
        text = bounded(text, width)
        writeAt(x + math.floor((width - #text) / 2), y, text, foreground, background)
    end
    local function titleLines(text, width, count)
        local lines = {}
        text = text:gsub("%s+", " ")
        for line = 1, count do
            if #text <= width or line == count then lines[line] = bounded(text, width); break end
            local split = text:sub(1, width):match("^.*()%s") or width + 1
            lines[line], text = text:sub(1, split - 1), text:sub(split):gsub("^%s+", "")
        end
        return lines
    end
    local function busy(title, detail)
        setDisplayScale(menuScale)
        theme()
        local width, height = term.getSize()
        fill(1, 1, width, 2, colors.blue)
        center(1, 1, width, "CRAFTORIA VIDEO LIBRARY", colors.white, colors.blue)
        center(2, math.max(3, math.floor(height / 2)), width - 2, title, colors.cyan)
        center(2, math.max(4, math.floor(height / 2) + 2), width - 2, detail, colors.lightGray)
    end
    chooseMenuScale()
    local refreshTimer
    local function scheduleRefresh()
        if refreshTimer then os.cancelTimer(refreshTimer) end
        refreshTimer = config.refresh > 0 and os.startTimer(config.refresh * 60) or nil
    end
    local function refresh()
        busy("SYNCING LIBRARY", "Checking for new recordings...")
        local ok, result = pcall(loadLibrary)
        if ok then
            videos, selected, page = result, 1, 1
            status = #videos == 0 and "No published videos. Tap REFRESH after uploading." or "Library updated."
            statusColor = colors.lightGray
        else
            if tostring(result) == "Terminated" then error(result, 0) end
            status = "Refresh failed: " .. tostring(result)
            statusColor = colors.orange
        end
        scheduleRefresh()
    end
    local function settingsScreen()
        local draft, tab, focused, sectionPage = copy(config), 1, 1, 1
        local tabs = {"AUDIO", "DISPLAY", "PLAYBACK", "LIBRARY"}
        local notice, noticeColor = "Changes apply when you save.", colors.lightGray
        local discoveredSpeakers, discoveredMonitors
        local function rescan()
            discoveredSpeakers, discoveredMonitors = speakerDevices(), {}
            for _, name in ipairs(peripheral.getNames()) do
                if peripheral.getType(name) == "monitor" and peripheral.wrap(name).isColor() then
                    discoveredMonitors[#discoveredMonitors + 1] = name
                end
            end
            table.sort(discoveredMonitors)
        end
        rescan()
        local function changed() notice, noticeColor = "Unsaved changes.", colors.orange end
        local function cycle(options, value, direction)
            local index = 1
            for i, item in ipairs(options) do if item == value then index = i; break end end
            return options[(index - 1 + (direction or 1)) % #options + 1]
        end
        local function selectSpeaker(direction)
            local options = {"auto", "all"}
            for _, output in ipairs(discoveredSpeakers) do options[#options + 1] = output.name end
            local value = cycle(options, draft.speakers == "chosen" and draft.speaker or draft.speakers, direction)
            draft.speakers = (value == "auto" or value == "all") and value or "chosen"
            draft.speaker = draft.speakers == "chosen" and value or ""
            changed()
        end
        local function rescanAction()
            rescan()
            notice, noticeColor = #discoveredSpeakers .. " speakers, " .. #discoveredMonitors .. " advanced monitors.", colors.lightGray
        end
        local function testSpeaker()
            if draft.muted or draft.volume == 0 then notice, noticeColor = "Unmute or increase the volume to test.", colors.orange; return end
            local tested = 0
            for index, output in ipairs(discoveredSpeakers) do
                if draft.speakers == "all" or (draft.speakers == "auto" and index == 1)
                    or (draft.speakers == "chosen" and output.name == draft.speaker) then
                    local ok, accepted = pcall(output.device.playNote, "harp", draft.volume, 12)
                    if ok and accepted then tested = tested + 1 end
                end
            end
            notice, noticeColor = tested > 0 and ("Test tone sent to " .. tested .. " speaker(s).") or "No available speaker accepted the test.",
                tested > 0 and colors.lightGray or colors.orange
        end
        local function editSource()
            notice = "Enter the catalogue URL on the computer."
            local previous = term.current()
            term.redirect(term.native())
            local ok, value = pcall(function()
                term.setBackgroundColor(colors.black); term.setTextColor(colors.white); term.clear(); term.setCursorPos(1, 1)
                print("HTTPS catalogue URL (blank keeps current):")
                return read(nil, nil, nil, draft.r2_url)
            end)
            term.redirect(previous)
            if not ok then error(value, 0) end
            if value ~= "" then draft.r2_url = value; changed() else notice = "Catalogue URL unchanged." end
        end
        local function saveDraft()
            if draft.r2_url ~= "" and not draft.r2_url:match("^https://[^/%s]+[^%s]*$") then
                notice, noticeColor = "Use a valid HTTPS catalogue URL.", colors.orange; return false
            end
            if draft.monitor ~= "" and (peripheral.getType(draft.monitor) ~= "monitor" or not peripheral.wrap(draft.monitor).isColor()) then
                notice, noticeColor = "Chosen advanced monitor is disconnected. Rescan or choose Auto.", colors.orange; return false
            end
            if draft.speakers == "chosen" and peripheral.getType(draft.speaker) ~= "speaker" then
                notice, noticeColor = "Chosen speaker is disconnected. Rescan or choose Auto.", colors.orange; return false
            end
            local newVideos
            if draft.r2_url ~= config.r2_url then
                busy("CHECKING CATALOGUE", "Validating the new video source...")
                local ok, result = pcall(loadLibrary, draft.r2_url)
                if not ok then
                    if tostring(result) == "Terminated" then error(result, 0) end
                    notice, noticeColor = "Source rejected: " .. tostring(result), colors.orange; return false
                end
                newVideos = result
            end
            local values = {}
            for key, name in pairs(configKeys) do values[name] = draft[key] end
            local saved, failure = saveValues(values)
            if not saved then notice, noticeColor = "Save failed: " .. failure, colors.orange; return false end
            local oldMonitor = config.monitor
            config = copy(draft)
            if oldMonitor ~= config.monitor then setupMonitor(config.monitor, true) end
            chooseMenuScale()
            if newVideos then videos, selected, page = newVideos, 1, 1 end
            status, statusColor = "Settings saved.", colors.lightGray
            scheduleRefresh()
            return true
        end
        while true do
            setDisplayScale(menuScale)
            local width, height = term.getSize()
            local stride = height >= 24 and 3 or 2
            local capacity = math.max(1, math.floor((height - 10) / stride))
            local controls = {}
            local function row(label, value, detail, action, special)
                controls[#controls + 1] = {label = label, value = value, detail = detail, action = action, special = special}
            end
            if tab == 1 then
                row("VOLUME", string.format("%.2f", draft.volume), "Normal 1.0 / maximum 3.0", function(direction)
                    draft.volume = math.max(0, math.min(3, draft.volume + 0.25 * (direction or 1))); changed()
                end, "volume")
                row("MUTE", draft.muted and "ON" or "OFF", "Keeps your chosen volume", function() draft.muted = not draft.muted; changed() end)
                row("SPEAKER OUTPUT", draft.speakers == "auto" and "AUTO / FIRST" or draft.speakers == "all" and "ALL CONNECTED" or draft.speaker,
                    #discoveredSpeakers .. " connected; tap to cycle", selectSpeaker)
                row("CHECK SPEAKERS", "RESCAN / TEST", "Test uses unsaved audio choices", rescanAction, "speakers")
            elseif tab == 2 then
                row("MONITOR", draft.monitor == "" and "AUTO / LARGEST" or draft.monitor, "Tap to cycle connected displays", function(direction)
                    local options = {""}; for _, name in ipairs(discoveredMonitors) do options[#options + 1] = name end
                    draft.monitor = cycle(options, draft.monitor, direction); changed()
                end)
                row("MENU TEXT SIZE", draft.scale == "auto" and "AUTO" or draft.scale, "Playback always uses scale 0.5", function(direction)
                    -- Restrict choices to scales that still fit a usable menu.
                    local options = {"auto"}
                    local display = (draft.monitor ~= "" and peripheral.wrap(draft.monitor)) or term.current()
                    if display and display.getTextScale then
                        local scale = display.getTextScale(); local w, h = display.getSize()
                        for _, option in ipairs({"0.5", "1", "1.5"}) do
                            if math.floor(w * scale / tonumber(option)) >= 36 and math.floor(h * scale / tonumber(option)) >= 12 then options[#options + 1] = option end
                        end
                    end
                    draft.scale = cycle(options, draft.scale, direction); changed()
                end)
                row("VIDEO GRID", draft.columns == 0 and "AUTO" or draft.columns .. " COLUMNS", "Layouts adapt to available width", function(direction)
                    local options = {0}
                    local display = (draft.monitor ~= "" and peripheral.wrap(draft.monitor)) or term.current()
                    local w, h = display.getSize()
                    if activeMonitor or draft.monitor ~= "" then
                        local scale = display.getTextScale()
                        local desired = tonumber(draft.scale) or ((w * scale >= 51 and h * scale >= 19) and 1 or 0.5)
                        w = math.floor(w * scale / desired)
                    end
                    for count = 2, 4 do if w - 4 >= 18 * count + 2 * (count - 1) then options[#options + 1] = count end end
                    draft.columns = cycle(options, draft.columns, direction); changed()
                end)
                row("CONNECTED DISPLAYS", "RESCAN", #discoveredMonitors .. " advanced monitors", rescanAction)
            elseif tab == 3 then
                row("TAP VIDEO TO STOP", draft.touchStop and "ON" or "OFF", "Backspace always stops playback", function() draft.touchStop = not draft.touchStop; changed() end)
                row("WHEN PLAYER STARTS", draft.startup == "loop" and "LOOP LAST VIDEO" or "SHOW LIBRARY", "Runs after launch or startup.lua", function()
                    draft.startup = draft.startup == "menu" and "loop" or "menu"; changed()
                end)
                row("CARD ACTIONS", "PLAY / LOOP", "Play once / repeat until stopped")
                row("LAST VIDEO", settings.get("video.last_title") or "NONE YET", "Missing recording returns to library")
            else
                local rates = {[0] = "OFF / MANUAL", [5] = "5 MINUTES", [15] = "15 MINUTES", [60] = "1 HOUR"}
                row("AUTOMATIC REFRESH", rates[draft.refresh], "Checks only while in the library", function(direction)
                    draft.refresh = cycle({0, 5, 15, 60}, draft.refresh, direction); changed()
                end)
                row("CATALOGUE URL", "EDIT ON COMPUTER", draft.r2_url, editSource)
                row("SOURCE", draft.r2_url ~= "" and "R2 CATALOGUE" or "GITHUB", "New URLs are checked before saving")
                row("DOWNLOAD LIMIT", "64 MiB", "Configured on the dedicated server")
            end
            focused = math.max(1, math.min(focused, #controls))
            sectionPage = math.floor((focused - 1) / capacity) + 1
            local pages = math.ceil(#controls / capacity)
            theme()
            fill(1, 1, width, 2, colors.blue)
            center(1, 1, width, "VIDEO LIBRARY / SETTINGS", colors.white, colors.blue)
            writeAt(3, 2, tabs[tab] .. (pages > 1 and (" " .. sectionPage .. "/" .. pages) or ""), colors.cyan, colors.blue)
            local targets = {}
            local function button(x, y, w, text, background, action, h)
                h = h or 2
                fill(x, y, w, h, background)
                center(x, y, w, text, (background == colors.cyan or background == colors.green) and colors.black or colors.white, background)
                targets[#targets + 1] = {x = x, y = y, w = w, h = h, action = action}
            end
            if pages > 1 then
                button(width - 12, 2, 5, "<", colors.blue, function() focused = math.max(1, focused - capacity) end, 1)
                button(width - 6, 2, 5, ">", colors.blue, function() focused = math.min(#controls, focused + capacity) end, 1)
            end
            local tabWidth = math.floor((width - 4 - 3) / 4)
            for index, name in ipairs(tabs) do
                local chosenTab = index
                button(3 + (index - 1) * (tabWidth + 1), 3, tabWidth, name, index == tab and colors.cyan or colors.blue,
                    function() tab, focused = chosenTab, 1 end, 1)
            end
            local controlWidth = math.min(29, math.max(15, math.floor(width * 0.43)))
            local controlX = width - controlWidth - 2
            local first = (sectionPage - 1) * capacity + 1
            for index = first, math.min(#controls, first + capacity - 1) do
                local item = controls[index]
                local y = 5 + (index - first) * stride
                local rowIndex = index
                writeAt(3, y, bounded(item.label, controlX - 4), index == focused and colors.cyan or colors.white)
                if stride == 3 then writeAt(3, y + 1, bounded(tostring(item.detail or ""), controlX - 4), colors.lightGray) end
                local background = item.action and (index == focused and colors.cyan
                    or (stride == 2 and index % 2 == 1 and colors.gray or colors.blue)) or colors.gray
                if item.special == "volume" then
                    button(controlX, y, 4, "-", colors.blue, function() focused = rowIndex; item.action(-1) end)
                    center(controlX + 5, y, controlWidth - 10, item.value, colors.white)
                    button(controlX + controlWidth - 4, y, 4, "+", colors.cyan, function() focused = rowIndex; item.action(1) end)
                elseif item.special == "speakers" then
                    local w = math.floor((controlWidth - 1) / 2)
                    button(controlX, y, w, "RESCAN", colors.blue, rescanAction)
                    button(controlX + w + 1, y, controlWidth - w - 1, "TEST", colors.cyan, testSpeaker)
                else
                    button(controlX, y, controlWidth, tostring(item.value), background, function()
                        focused = rowIndex; if item.action then item.action(1) end
                    end)
                end
            end
            fill(3, height - 4, width - 4, 1, colors.blue)
            writeAt(4, height - 4, bounded(notice:gsub("[%c]", " "), width - 6), noticeColor, colors.blue)
            local exiting, saving = false, false
            local footerWidth = math.min(13, math.floor((width - 6) / 3))
            local footerX = math.floor((width - (footerWidth * 3 + 2)) / 2) + 1
            button(footerX, height - 2, footerWidth, "CANCEL", colors.blue, function() exiting = true end)
            button(footerX + footerWidth + 1, height - 2, footerWidth, "DEFAULTS", colors.blue, function() draft = copy(configDefaults); changed() end)
            button(footerX + (footerWidth + 1) * 2, height - 2, footerWidth, footerWidth >= 11 and "SAVE & BACK" or "SAVE", colors.cyan, function() saving = true end)
            center(1, height, width, "Arrows adjust | Enter | Esc back", colors.lightGray)
            local event, a, b, c = inputEvent()
            if event == "mouse_click" then
                for _, box in ipairs(targets) do
                    if b >= box.x and b < box.x + box.w and c >= box.y and c < box.y + box.h then box.action(); break end
                end
            elseif event == "key" then
                if a == keys.escape or a == keys.backspace then exiting = true
                elseif a == keys.tab then tab, focused = tab % 4 + 1, 1
                elseif a == keys.up then focused = math.max(1, focused - 1)
                elseif a == keys.down then focused = math.min(#controls, focused + 1)
                elseif a == keys.pageUp then focused = math.max(1, focused - capacity)
                elseif a == keys.pageDown then focused = math.min(#controls, focused + capacity)
                elseif a == keys.left or a == keys.right or a == keys.enter then
                    if controls[focused].action then controls[focused].action(a == keys.left and -1 or 1) end
                end
            elseif event == "char" then
                if a:lower() == "s" then saving = true
                elseif a:lower() == "q" then exiting = true end
            elseif (event == "monitor_resize" and a == activeMonitor) or event == "term_resize" then
                chooseMenuScale()
            end
            if saving and saveDraft() then return end
            if exiting then status, statusColor = "Settings cancelled.", colors.lightGray; scheduleRefresh(); return end
        end
    end
    local function playChosen(index, loopVideo)
        selected = index
        local video = videos[index]
        local remembered = saveValues({["video.last_url"] = video.url, ["video.last_title"] = video.title})
        busy(loopVideo and "LOADING LOOP - BACKSPACE TO STOP" or "LOADING VIDEO", video.title)
        local ok, message, stopped = runPlayback(video.url, true, loopVideo)
        status = not ok and ("Playback failed: " .. tostring(message)) or (stopped and "Stopped." or "Finished.")
        if not remembered then status = status .. " Could not remember last video." end
        statusColor = (not ok or not remembered) and colors.orange or colors.lightGray
        if startupNotice then status, statusColor = status .. " " .. startupNotice, colors.orange; startupNotice = nil end
        scheduleRefresh()
    end
    selectOutputs() -- Surface a disconnected saved speaker before starting playback.
    refresh()
    if startupNotice then status, statusColor = startupNotice, colors.orange; startupNotice = nil end
    if config.startup == "loop" then
        local last = settings.get("video.last_url")
        local found
        for index, video in ipairs(videos) do if video.url == last then found = index; break end end
        if found then playChosen(found, true)
        else status, statusColor = "Last video unavailable; showing library.", colors.orange end
    end
    while true do
        setDisplayScale(menuScale)
        local width, height = term.getSize()
        if width < 36 or height < 12 then error("Menu needs at least 36 columns and 12 rows. Use a larger Advanced Monitor.", 0) end
        local roomy = height >= 24
        local contentY, contentEnd = roomy and 5 or 4, height - 6
        local gap, availableWidth = 2, width - 4
        local columns = math.max(1, math.min(4, math.floor((availableWidth + gap) / 20)))
        if config.columns > 0 then columns = math.min(config.columns, columns) end
        local cardWidth = math.floor((availableWidth - gap * (columns - 1)) / columns)
        local availableHeight = contentEnd - contentY + 1
        local rows = math.max(1, math.floor((availableHeight + 1) / (roomy and 7 or 5)))
        local cardHeight = math.min(7, math.floor((availableHeight - rows + 1) / rows))
        local capacity = columns * rows
        local pages = math.max(1, math.ceil(#videos / capacity))
        selected = math.max(1, math.min(selected, #videos))
        page = math.min(pages, math.floor((selected - 1) / capacity) + 1)
        theme()
        fill(1, 1, width, roomy and 3 or 2, colors.blue)
        center(1, 1, width, "CRAFTORIA VIDEO LIBRARY", colors.white, colors.blue)
        local source = r2URL() ~= "" and "Cloudflare R2" or "GitHub"
        local count = #videos .. (#videos == 1 and " video" or " videos")
        writeAt(3, roomy and 3 or 2, source, colors.cyan, colors.blue)
        writeAt(width - #count - 2, roomy and 3 or 2, count, colors.lightGray, colors.blue)
        if roomy then center(1, 2, width, "PLAY ONCE OR LOOP A VIDEO", colors.lightGray, colors.blue) end

        local targets = {}
        local function target(x, y, w, h, action, index)
            targets[#targets + 1] = {x = x, y = y, w = w, h = h, action = action, index = index}
        end
        local first = (page - 1) * capacity + 1
        for index = first, math.min(#videos, first + capacity - 1) do
            local offset = index - first
            local video = videos[index]
            local x = 3 + (offset % columns) * (cardWidth + gap)
            local y = contentY + math.floor(offset / columns) * (cardHeight + 1)
            local accent = index == selected and colors.cyan or colors.blue
            fill(x, y, cardWidth, cardHeight, colors.gray)
            fill(x, y, 1, cardHeight, accent)
            fill(x + 1, y, cardWidth - 1, 1, colors.blue)
            writeAt(x + 2, y, bounded(string.format("%02d  %.1f MB", index, video.size / 1000000), cardWidth - 3),
                index == selected and colors.cyan or colors.lightGray, colors.blue)
            for line, text in ipairs(titleLines(video.title, cardWidth - 4, math.max(1, cardHeight - 2))) do
                writeAt(x + 2, y + line, text, colors.white, colors.gray)
            end
            local footerY = y + cardHeight - 1
            fill(x + 1, footerY, cardWidth - 1, 1, colors.blue)
            fill(x + 1, footerY, 7, 1, colors.green)
            center(x + 1, footerY, 7, "LOOP >", colors.black, colors.green)
            fill(x + cardWidth - 7, footerY, 7, 1, accent)
            center(x + cardWidth - 7, footerY, 7, "PLAY >",
                index == selected and colors.black or colors.white, accent)
            -- Register the more specific loop button before the whole card.
            target(x + 1, footerY, 7, 1, "loop", index)
            target(x, y, cardWidth, cardHeight, "play", index)
        end
        if #videos == 0 then
            center(3, contentY, width - 4, statusColor == colors.orange and "LIBRARY UNAVAILABLE" or "YOUR LIBRARY IS EMPTY", colors.lightGray)
        end

        local statusY, buttonY, buttonHeight = height - 4, height - 2, 2
        fill(3, statusY, width - 4, 1, colors.blue)
        writeAt(4, statusY, bounded(status:gsub("[%c]", " "), width - 6), statusColor, colors.blue)
        local buttons = {
            {text = "PREV", action = "prev", enabled = page > 1},
            {text = "NEXT", action = "next", enabled = page < pages},
            {text = "REFRESH", action = "refresh", enabled = true, color = colors.cyan},
            {text = "SETTINGS", action = "settings", enabled = true, color = colors.green},
            {text = "QUIT", action = "quit", enabled = true, color = colors.red},
        }
        local buttonGap = width >= 60 and 2 or 1
        local buttonWidth = math.min(11, math.floor((width - 4 - buttonGap * 4) / 5))
        local x = math.floor((width - (buttonWidth * 5 + buttonGap * 4)) / 2) + 1
        for _, button in ipairs(buttons) do
            local w = buttonWidth
            local background = button.enabled and (button.color or colors.blue) or colors.gray
            fill(x, buttonY, w, buttonHeight, background)
            local label = w < 8 and button.action == "settings" and "SET" or w < 7 and button.action == "refresh" and "SYNC" or button.text
            center(x, buttonY + math.floor((buttonHeight - 1) / 2), w, label,
                button.color and colors.black or (button.enabled and colors.white or colors.lightGray), background)
            if button.enabled then target(x, buttonY, w, buttonHeight, button.action) end
            x = x + w + buttonGap
        end
        local shortcuts = width >= 60 and " | Enter play, L loop | S settings | R/Q" or " | Enter/L | S settings | R/Q"
        center(1, height, width, "Page " .. page .. "/" .. pages .. shortcuts, colors.lightGray)

        local event, a, b, c = inputEvent()
        local action, chosen
        if event == "key" then
            if a == keys.up then selected = math.max(1, selected - columns)
            elseif a == keys.down then selected = math.min(math.max(1, #videos), selected + columns)
            elseif a == keys.left then selected = math.max(1, selected - 1)
            elseif a == keys.right then selected = math.min(math.max(1, #videos), selected + 1)
            elseif a == keys.enter or a == keys.numPadEnter then chosen = selected
            elseif a == keys.pageUp then action = "prev"
            elseif a == keys.pageDown then action = "next" end
        elseif event == "char" then
            if a:lower() == "l" then action, chosen = "loop", selected
            elseif a:lower() == "r" then action = "refresh"
            elseif a:lower() == "s" then action = "settings"
            elseif a:lower() == "q" then action = "quit" end
        elseif event == "mouse_scroll" then
            action = a > 0 and "next" or "prev"
        elseif event == "mouse_click" then
            for _, box in ipairs(targets) do
                if b >= box.x and b < box.x + box.w and c >= box.y and c < box.y + box.h then
                    action, chosen = box.action, box.index
                    break
                end
            end
        elseif (event == "monitor_resize" and a == activeMonitor) or event == "term_resize" then
            local newWidth, newHeight = term.getSize()
            if newWidth ~= width or newHeight ~= height then chooseMenuScale() end
        elseif event == "timer" and a == refreshTimer then
            action = "refresh"
        end
        if action == "quit" then return
        elseif action == "refresh" then refresh()
        elseif action == "settings" then settingsScreen()
        elseif action == "prev" then page = math.max(1, page - 1); selected = (page - 1) * capacity + 1
        elseif action == "next" then page = math.min(pages, page + 1); selected = (page - 1) * capacity + 1 end
        if chosen and videos[chosen] then
            playChosen(chosen, action == "loop")
        end
    end
end

local path = ...
local ok, message = pcall(function()
    setupMonitor()
    if path then
        local played, failure = runPlayback(path, false)
        if not played then error(failure, 0) end
    else
        menu()
    end
end)
closeInput()
pcall(restoreScreen)
term.redirect(originalTerminal)
if not ok then
    stopOutputs()
    error(message, 0)
end
