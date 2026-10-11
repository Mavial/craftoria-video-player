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
    local _, nframes, ctype = ("<IIB"):unpack(file.read(9))
    if ctype ~= 0x0C then closeInput() error("Stream type not supported by this tool") end
    local outputWidth, outputHeight = term.getSize()
    if not bit32.btest(flags, 0x20) and (width > outputWidth or height > outputHeight) then
        error("Video does not fit this screen. Set monitor scale to 0.5 or use a larger wall.", 0)
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
    local start = os.epoch "utc"
    local lastyield = start
    local vframe = 0
    local subs = {}
    term.clear()
    for _ = 1, nframes do
        local size, ftype = ("<IB"):unpack(file.read(5))
        --print(size, ftype, file.seek())
        if ftype == 0 then
            if os.epoch "utc" - lastyield > 3000 then sleep(0) lastyield = os.epoch "utc" end
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
            local audio = file.read(size)
            if speaker then
                if bit32_band(flags, 12) == 0 then
                    local chunk = {audio:byte(1, -1)}
                    for i = 1, #chunk do chunk[i] = chunk[i] - 128 end
                    while not speaker.playAudio(chunk) do os.pullEvent("speaker_audio_empty") end
                else
                    local chunk = decodeAudio(audio)
                    while not speaker.playAudio(chunk) do os.pullEvent("speaker_audio_empty") end
                end
            end
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
            if os.epoch "utc" - lastyield > 3000 then sleep(0) lastyield = os.epoch "utc" end
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

    closeInput()
    if speaker then
        local deadline = os.startTimer(3)
        while true do
            local event, value = os.pullEvent()
            if event == "speaker_audio_empty" or (event == "timer" and value == deadline) then break end
        end
    end
end

local function runPlayback(path, canStop)
    local stopped = false
    local ok, message = pcall(function()
        if canStop then
            parallel.waitForAny(function() play(path) end, function()
                while true do
                    local event, value = os.pullEvent()
                    if file and ((event == "key" and value == keys.backspace) or event == "mouse_click") then
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
    restoreScreen()
    if not ok and tostring(message) == "Terminated" then error(message, 0) end
    return ok, message, stopped
end

local function menu()
    local videos, selected, page, status = {}, 1, 1, ""
    local function refresh()
        restoreScreen()
        term.write("Loading videos from " .. (r2URL() ~= "" and "R2" or "GitHub") .. "...")
        local ok, result = pcall(loadLibrary)
        if ok then
            videos, selected, page = result, 1, 1
            status = #videos == 0 and "No published .32vid videos. Press R to refresh." or "Library updated."
        else
            if tostring(result) == "Terminated" then error(result, 0) end
            status = "Refresh failed: " .. tostring(result)
        end
    end
    refresh()
    while true do
        local width, height = term.getSize()
        if width < 36 or height < 12 then error("Menu needs at least 36 columns and 12 rows. Set monitor scale to 0.5.", 0) end
        local capacity = math.max(1, math.floor((height - 10) / 2))
        local pages = math.max(1, math.ceil(#videos / capacity))
        page = math.min(page, pages)
        restoreScreen()
        local function writeAt(x, y, text, color)
            term.setCursorPos(x, y)
            term.setTextColor(color or colors.white)
            term.write(text:sub(1, width - x + 1))
        end
        writeAt(2, 1, "CRAFTORIA VIDEO LIBRARY", colors.cyan)
        writeAt(2, 2, (r2URL() ~= "" and "Cloudflare R2" or REPOSITORY) .. "  |  " .. #videos .. " videos", colors.lightGray)
        writeAt(2, 3, "Click a video, or use arrows + Enter.")
        writeAt(2, 4, "During playback: click / Backspace to return.", colors.lightGray)
        local first = (page - 1) * capacity + 1
        for index = first, math.min(#videos, first + capacity - 1) do
            local video, y = videos[index], 6 + (index - first) * 2
            writeAt(2, y, (index == selected and "> " or "  ") .. video.title,
                index == selected and colors.yellow or colors.white)
            writeAt(4, y + 1, video.release .. "  |  " .. string.format("%.2f MB", video.size / 1000000), colors.lightGray)
        end
        writeAt(2, height - 4, status:gsub("[%c]", " "), colors.lightGray)
        local buttons = {
            {x = 2, text = "[Prev]", action = "prev"},
            {x = 10, text = "[Next]", action = "next"},
            {x = 18, text = "[Refresh]", action = "refresh"},
            {x = 29, text = "[Quit]", action = "quit"},
        }
        for _, button in ipairs(buttons) do writeAt(button.x, height - 2, button.text, colors.cyan) end
        writeAt(2, height, "Page " .. page .. "/" .. pages .. "  |  R refresh, Q quit", colors.lightGray)

        local event, a, b, c = os.pullEvent()
        local action, chosen
        if event == "key" then
            if a == keys.up then selected = math.max(1, selected - 1)
            elseif a == keys.down then selected = math.min(math.max(1, #videos), selected + 1)
            elseif a == keys.enter or a == keys.numPadEnter then chosen = selected
            elseif a == keys.left or a == keys.pageUp then action = "prev"
            elseif a == keys.right or a == keys.pageDown then action = "next" end
            if a == keys.up or a == keys.down then page = math.floor((selected - 1) / capacity) + 1 end
        elseif event == "char" then
            if a:lower() == "r" then action = "refresh"
            elseif a:lower() == "q" then action = "quit" end
        elseif event == "mouse_scroll" then
            action = a > 0 and "next" or "prev"
        elseif event == "mouse_click" then
            if c == height - 2 then
                for _, button in ipairs(buttons) do
                    if b >= button.x and b < button.x + #button.text then action = button.action end
                end
            elseif c >= 6 and c < 6 + capacity * 2 then
                chosen = first + math.floor((c - 6) / 2)
            end
        end
        if action == "quit" then return
        elseif action == "refresh" then refresh()
        elseif action == "prev" then page = math.max(1, page - 1); selected = (page - 1) * capacity + 1
        elseif action == "next" then page = math.min(pages, page + 1); selected = (page - 1) * capacity + 1 end
        if chosen and videos[chosen] then
            selected = chosen
            restoreScreen()
            term.write("Loading " .. videos[chosen].title .. "...")
            local ok, message, stopped = runPlayback(videos[chosen].url, true)
            status = not ok and ("Playback failed: " .. tostring(message))
                or (stopped and "Stopped." or "Finished.")
        end
    end
end

local path = ...
local ok, message = pcall(function()
    if path then
        local played, failure = runPlayback(path, false)
        if not played then error(failure, 0) end
    else
        menu()
    end
end)
closeInput()
restoreScreen()
if not ok then
    if speaker then pcall(speaker.stop) end
    error(message, 0)
end
