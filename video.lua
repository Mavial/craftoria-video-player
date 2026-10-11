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

local function setupMonitor()
    -- An explicit ROM "monitor <name> ..." launch keeps its chosen display and
    -- touch conversion. Direct launches select and redirect a display here.
    local wrapped, currentName = pcall(peripheral.getName, originalTerminal)
    if wrapped and peripheral.getType(currentName) == "monitor" then
        if not originalTerminal.isColor() then error("Video playback needs an Advanced Monitor.", 0) end
        originalTerminal.setTextScale(0.5)
        originalTerminal.setCursorBlink(false)
        activeMonitor = currentName
        return
    end

    local selected, configured = nil, settings.get("video.monitor")
    if configured ~= nil and configured ~= "" then
        if type(configured) ~= "string" or peripheral.getType(configured) ~= "monitor" then
            error("video.monitor is not connected. Use 'set video.monitor nil' to enable automatic selection.", 0)
        end
        selected = {name = configured, monitor = peripheral.wrap(configured)}
        if not selected.monitor.isColor() then error("video.monitor must name an Advanced Monitor.", 0) end
    else
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
        selected.monitor.setTextScale(0.5)
        activeMonitor, ownsMonitor = selected.name, true
        term.redirect(selected.monitor)
        term.setCursorBlink(false)
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

local function loadLibrary()
    local source = r2URL()
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

local function restoreScreen()
    for i = 0, 15 do term.setPaletteColor(2^i, term.nativePaletteColor(2^i)) end
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.setCursorPos(1, 1)
    term.clear()
end

local function play(path)
    local decodeAudio = dfpwm.make_decoder()
    speaker = peripheral.find "speaker"
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

    local function playAudio()
        local raw = bit32_band(flags, 12) == 0
        local chunkSize = raw and 131072 or 16384
        local speakerName = peripheral.getName(speaker)
        for offset = 1, #audioData, chunkSize do
            local encoded = audioData:sub(offset, offset + chunkSize - 1)
            local chunk
            if raw then
                chunk = {}
                for index = 1, #encoded do chunk[index] = encoded:byte(index) - 128 end
            else
                chunk = decodeAudio(encoded)
            end
            while not speaker.playAudio(chunk) do
                repeat local _, name = os.pullEvent("speaker_audio_empty") until name == speakerName
            end
            start = start or os.epoch "utc"
        end
        -- Buffer-empty means "room for another packet", not audible completion.
        -- Wait for the final pending packet to be dispatched, then let it drain.
        if #audioData > 0 then
            repeat local _, name = os.pullEvent("speaker_audio_empty") until name == speakerName
            local lastSize = (#audioData - 1) % chunkSize + 1
            sleep(lastSize * (raw and 1 or 8) / 48000 + 0.5)
        end
    end
    if speaker and #audioData > 0 then
        parallel.waitForAll(playAudio, renderVideo)
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
                    if (event == "key" and value == keys.backspace) or event == "mouse_click" then
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
    if speaker and (stopped or not ok) then pcall(speaker.stop) end
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
            setDisplayScale(1)
            local width, height = term.getSize()
            menuScale = width >= 51 and height >= 19 and 1 or 0.5
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
    end
    refresh()
    while true do
        setDisplayScale(menuScale)
        local width, height = term.getSize()
        if width < 36 or height < 12 then error("Menu needs at least 36 columns and 12 rows. Use a larger Advanced Monitor.", 0) end
        local roomy = height >= 24
        local contentY, contentEnd = roomy and 5 or 4, height - 6
        local gap, availableWidth = 2, width - 4
        local columns = math.max(1, math.min(4, math.floor((availableWidth + gap) / 20)))
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
            {text = "QUIT", action = "quit", enabled = true, color = colors.red},
        }
        local buttonGap = width >= 60 and 2 or 1
        local buttonWidth = math.min(11, math.floor((width - 4 - buttonGap * 3) / 4))
        local x = math.floor((width - (buttonWidth * 4 + buttonGap * 3)) / 2) + 1
        for _, button in ipairs(buttons) do
            local w = buttonWidth
            local background = button.enabled and (button.color or colors.blue) or colors.gray
            fill(x, buttonY, w, buttonHeight, background)
            center(x, buttonY + math.floor((buttonHeight - 1) / 2), w, button.text,
                button.color and colors.black or (button.enabled and colors.white or colors.lightGray), background)
            if button.enabled then target(x, buttonY, w, buttonHeight, button.action) end
            x = x + w + buttonGap
        end
        local shortcuts = width >= 60 and " | Enter play, L loop | R refresh, Q quit" or " | Enter/L play/loop | R/Q"
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
        end
        if action == "quit" then return
        elseif action == "refresh" then refresh()
        elseif action == "prev" then page = math.max(1, page - 1); selected = (page - 1) * capacity + 1
        elseif action == "next" then page = math.min(pages, page + 1); selected = (page - 1) * capacity + 1 end
        if chosen and videos[chosen] then
            selected = chosen
            local loopVideo = action == "loop"
            busy(loopVideo and "LOADING LOOP - TOUCH / BACKSPACE TO STOP" or "LOADING VIDEO", videos[chosen].title)
            local ok, message, stopped = runPlayback(videos[chosen].url, true, loopVideo)
            status = not ok and ("Playback failed: " .. tostring(message))
                or (stopped and "Stopped." or "Finished.")
            statusColor = not ok and colors.orange or colors.lightGray
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
    if speaker then pcall(speaker.stop) end
    error(message, 0)
end
