gl.setup(NATIVE_WIDTH, NATIVE_HEIGHT)

node.alias "*" -- catch all communication

util.noglobals()

local json = require "json"
local easing = require "easing"
local loader = require "loader"

local min, max, abs, floor = math.min, math.max, math.abs, math.floor

local IDLE_ASSET = "empty.png"

local node_config = {}

local overlay_debug = false
local font_regl = resource.load_font "default-font.ttf"
local font_bold = resource.load_font "default-font-bold.ttf"

local active_intermission_page_idx

local overlays = {
    resource.create_colored_texture(1,0,0),
    resource.create_colored_texture(0,1,0),
    resource.create_colored_texture(0,0,1),
    resource.create_colored_texture(1,0,1),
    resource.create_colored_texture(1,1,0),
    resource.create_colored_texture(0,1,1),
}

local function in_epsilon(a, b, e)
    return abs(a - b) <= e
end

local function ramp(t_s, t_e, t_c, ramp_time)
    if ramp_time == 0 then return 1 end
    local delta_s = t_c - t_s
    local delta_e = t_e - t_c
    return min(1, delta_s * 1/ramp_time, delta_e * 1/ramp_time)
end

local function wait_frame()
    return coroutine.yield(true)
end

local function wait_t(t)
    while true do
        local now = wait_frame()
        if now >= t then
            return now
        end
    end
end

local function from_to(starts, ends)
    return function()
        local now, x1, y1, x2, y2
        while true do
            now, x1, y1, x2, y2 = wait_frame()
            if now >= starts then
                break
            end
        end
        if now < ends then
            return now, x1, y1, x2, y2
        end
    end
end


local function mktween(fn)
    return function(sx1, sy1, sx2, sy2, ex1, ey1, ex2, ey2, progress)
        return fn(progress, sx1, ex1-sx1, 1),
               fn(progress, sy1, ey1-sy1, 1),
               fn(progress, sx2, ex2-sx2, 1),
               fn(progress, sy2, ey2-sy2, 1)
    end
end

local movements = {
    linear = mktween(easing.linear),
    smooth = mktween(easing.inOutQuint),
}

local function trim(s)
    return s:match "^%s*(.-)%s*$"
end

local function split(str, delim)
    local result, pat, last = {}, "(.-)" .. delim .. "()", 1
    for part, pos in string.gmatch(str, pat) do
        result[#result+1] = part
        last = pos
    end
    result[#result+1] = string.sub(str, last)
    return result
end

local function wrap(str, limit, indent, indent1)
    limit = limit or 72
    local here = 1
    local wrapped = str:gsub("(%s+)()(%S+)()", function(sp, st, word, fi)
        if fi-here > limit then
            here = st
            return "\n"..word
        end
    end)
    local splitted = {}
    for token in string.gmatch(wrapped, "[^\n]+") do
        splitted[#splitted + 1] = token
    end
    return splitted
end

local function Pinner()
    local pinned = {}

    local function update(asset_name, file)
        if pinned[asset_name] then
            pinned[asset_name]:dispose()
        end
        pinned[asset_name] = file
    end

    local function pin(asset_name)
        local ok, file = pcall(resource.open_file, asset_name)
        if ok then
            update(asset_name, file)
        end
    end

    local function flush()
        for asset_name, _ in pairs(pinned) do
            update(asset_name, nil)
        end
    end

    local function get(asset_name)
        if pinned[asset_name] then
            print('using pinned asset', asset_name)
            return pinned[asset_name]:copy()
        else
            print('using direct asset', asset_name)
            return asset_name
        end
    end

    return {
        pin = pin;
        flush = flush;
        get = get;
    }
end

local pinner = Pinner()

local function Clock()
    local base_day = 0
    local base_week = 0
    local human_time = ""
    local unix_diff = 0

    util.data_mapper{
        ["clock/since_midnight"] = function(since_midnight)
            base_day = tonumber(since_midnight) - sys.now()
        end;
        ["clock/since_monday"] = function(since_monday)
            base_week = tonumber(since_monday) - sys.now()
        end;
        ["clock/human"] = function(time)
            human_time = time
        end;
    }

    local function day_of_week()
        return math.floor((base_week + sys.now()) / 86400)
    end

    local function hour_of_week()
        return math.floor((base_week + sys.now()) / 3600)
    end

    local function human()
        return human_time
    end

    local function unix()
        local now = sys.now()
        if now == 0 then
            return os.time()
        end
        if unix_diff == 0 then
            local ts = os.time()
            if ts > 1000000 then
                unix_diff = ts - sys.now()
            end
        end
        return now + unix_diff
    end

    return {
        day_of_week = day_of_week;
        hour_of_week = hour_of_week;
        human = human;
        unix = unix;
    }
end

local clock = Clock()

local SharedData = function()
    -- {
    --    scope: { key: data }
    -- }
    local data = {}

    -- {
    --    key: { scope: listener }
    -- }
    local listeners = {}

    local function call_listener(scope, listener, key, value)
        local ok, err = xpcall(listener, debug.traceback, scope, value)
        if not ok then
            print("while calling listener for key " .. key .. ":" .. err)
        end
    end

    local function call_listeners(scope, key, value)
        local key_listeners = listeners[key]
        if not key_listeners then
            return
        end

        for _, listener in pairs(key_listeners) do
            call_listener(scope, listener, key, value)
        end
    end

    local function update(scope, key, value)
        if not data[scope] then
            data[scope] = {}
        end
        data[scope][key] = value
        if value == nil and not next(data[scope]) then
            data[scope] = nil
        end
        return call_listeners(scope, key, value)
    end

    local function delete(scope, key)
        return update(scope, key, nil)
    end

    local function add_listener(scope, key, listener)
        local key_listeners = listeners[key]
        if not key_listeners then
            listeners[key] = {}
            key_listeners = listeners[key]
        end
        if key_listeners[scope] then
            error "right now only a single listener is supported per scope"
        end
        key_listeners[scope] = listener
        for scope, scoped_data in pairs(data) do
            for key, value in pairs(scoped_data) do
                call_listener(scope, listener, key, value)
            end
        end
    end

    local function del_scope(scope)
        for key, key_listeners in pairs(listeners) do
            key_listeners[scope] = nil
            if not next(key_listeners) then
                listeners[key] = nil
            end
        end

        local scoped_data = data[scope]
        if scoped_data then
            for key, value in pairs(scoped_data) do
                delete(scope, key)
            end
        end
        data[scope] = nil
    end

    return {
        update = update;
        delete = delete;
        add_listener = add_listener;
        del_scope = del_scope;
    }
end

local data = SharedData()

local tiles = loader.setup "tile.lua"
tiles.make_api = function(tile)
    return {
        wait_frame = wait_frame,
        wait_t = wait_t,
        from_to = from_to,

        clock = clock,

        update_data = function(key, value)
            data.update(tile, key, value)
            data.delete(tile, key)
        end,
        add_listener = function(key, listener)
            data.add_listener(tile, key, listener)
        end,
    }
end

node.event("module_unload", function(tile)
    data.del_scope(tile)
end)

local function TileChild(config)
    return function(starts, ends)
        local tile = tiles.modules[config.asset_name]
        return tile.task(starts, ends, config)
    end
end

local kenburns_shader = resource.create_shader[[
    uniform sampler2D Texture;
    varying vec2 TexCoord;
    uniform vec4 Color;
    uniform float x, y, s;
    void main() {
        gl_FragColor = texture2D(Texture, TexCoord * vec2(s, s) + vec2(x, y)) * Color;
    }
]]

local function remote_or_local_asset(asset_name)
    local ok, file
    if node_config.poll_url ~= "" then
        ok, file = pcall(resource.open_file, "remote-" .. asset_name)
        if ok then
            print("using remotely fetched file for", asset_name)
            return file
        end
    end
    return pinner.get(asset_name)
end

local function Image(config)
    -- config:
    --   asset_name: 'foo.jpg'
    --   kenburns: true/false
    --   fade_time: 0-1
    --   fit: true/false

    local file = remote_or_local_asset(config.asset_name)

    return function(starts, ends)
        wait_t(starts - 2)

        local img = resource.load_image(file)

        local fade_time = config.fade_time or 0.5

        if config.kenburns then
            local function lerp(s, e, t)
                return s + t * (e-s)
            end

            local paths = {
                {from = {x=0.0,  y=0.0,  s=1.0 }, to = {x=0.08, y=0.08, s=0.9 }},
                {from = {x=0.05, y=0.0,  s=0.93}, to = {x=0.03, y=0.03, s=0.97}},
                {from = {x=0.02, y=0.05, s=0.91}, to = {x=0.01, y=0.05, s=0.95}},
                {from = {x=0.07, y=0.05, s=0.91}, to = {x=0.04, y=0.03, s=0.95}},
            }

            local path = paths[math.random(1, #paths)]

            local to, from = path.to, path.from
            if math.random() >= 0.5 then
                to, from = from, to
            end

            local w, h = img:size()
            local duration = ends - starts
            local linear = easing.linear

            local function lerp(s, e, t)
                return s + t * (e-s)
            end

            for now, x1, y1, x2, y2 in from_to(starts, ends) do
                local t = (now - starts) / duration
                kenburns_shader:use{
                    x = lerp(from.x, to.x, t);
                    y = lerp(from.y, to.y, t);
                    s = lerp(from.s, to.s, t);
                }
                if config.fit then
                    util.draw_correct(img, x1, y1, x2, y2, ramp(
                        starts, ends, now, fade_time
                    ))
                else
                    img:draw(x1, y1, x2, y2, ramp(
                        starts, ends, now, fade_time
                    ))
                end
                kenburns_shader:deactivate()
            end
        else
            for now, x1, y1, x2, y2 in from_to(starts, ends) do
                if config.fit then
                    util.draw_correct(img, x1, y1, x2, y2, ramp(
                        starts, ends, now, fade_time
                    ))
                else
                    img:draw(x1, y1, x2, y2, ramp(
                        starts, ends, now, fade_time
                    ))
                end
            end
        end
        img:dispose()
    end
end

local function Idle(config)
    return function() end;
end

local function Video(config)
    -- config:
    --   asset_name: 'foo.mp4'
    --   fit: aspect fit or scale?
    --   fade_time: 0-1
    --   raw: use raw video?
    --   layer: video layer for raw videos

    local file = remote_or_local_asset(config.asset_name)

    return function(starts, ends)
        wait_t(starts - 1)

        local fade_time = config.fade_time or 0.5

        local vid
        if config.raw then
            local raw = sys.get_ext "raw_video"
            vid = raw.load_video{
                file = file,
                paused = true,
                audio = node_config.audio,
            }
            vid:layer(-10)

            for now, x1, y1, x2, y2 in from_to(starts, ends) do
                vid:layer(config.layer or 5):start()
                vid:target(x1, y1, x2, y2):alpha(ramp(
                    starts, ends, now, fade_time
                ))
            end
        else
            vid = resource.load_video{
                file = file,
                paused = true,
                audio = node_config.audio,
            }

            for now, x1, y1, x2, y2 in from_to(starts, ends) do
                vid:start()
                if config.fit then
                    util.draw_correct(vid, x1, y1, x2, y2, ramp(
                        starts, ends, now, fade_time
                    ))
                else
                    vid:draw(x1, y1, x2, y2, ramp(
                        starts, ends, now, fade_time
                    ))
                end
            end
        end

        vid:dispose()
    end
end

local function Flat(config)
    -- config:
    --   color: "#rrggbb"
    --   fade_time: 0-1
    --   opacity: 0-1

    local color = config.color:gsub("#","")
    local r, g, b = tonumber("0x"..color:sub(1,2))/255, tonumber("0x"..color:sub(3,4))/255, tonumber("0x"..color:sub(5,6))/255

    local opacity = config.opacity or 1
    local flat = resource.create_colored_texture(r, g, b, opacity)
    local fade_time = config.fade_time or 0.5

    return function(starts, ends)
        for now, x1, y1, x2, y2 in from_to(starts, ends) do
            flat:draw(x1, y1, x2, y2, ramp(
                starts, ends, now, fade_time
            ))
        end
        flat:dispose()
    end
end

local function TimeTile(config)
    return function(starts, ends)
        local font = config.font
        local r, g, b = config.r, config.g, config.b
        for now, x1, y1, x2, y2 in from_to(starts, ends) do
            local size = y2 - y1 - 8
            local time = clock.human()
            local w = font:width(time, size)
            local offset = ((x2 - x1) - w) / 2
            config.font:write(x1+offset,  y1+4, time, size, r,g,b,1)
        end
    end
end

local white = resource.create_colored_texture(1,1,1,1)
local function InteractionTitle(config)
    return function(starts, ends)
        local font = config.font
        local flat = resource.create_colored_texture(config.bg.r, config.bg.g, config.bg.b, 1)
        for now, x1, y1, x2, y2 in from_to(starts, ends) do
            local size = y2 - y1 - 8
            local w = font:width(config.text, size)
            x1 = x2 - w - 40
            flat:draw(x1, y1+2, x2, y2)
            white:draw(x1, y1, x1+2, y2)
            config.font:write(x1+20, y1+4, config.text, size, config.fg.r, config.fg.g, config.fg.b,1)
        end
        flat:dispose()
    end
end

local function ResetIntermission(config)
    return function(starts, ends)
        print "intermission ended"
        wait_t(ends)
        active_intermission_page_idx = nil
    end
end

local function Markup(config)
    local text = config.text
    local width = config.width
    local height = config.height
    local color = config.color:gsub("#","")
    local r, g, b = tonumber("0x"..color:sub(1,2))/255, tonumber("0x"..color:sub(3,4))/255, tonumber("0x"..color:sub(5,6))/255

    local y = 0
    local max_x = 0
    local writes = {}

    local CELL_PADDING = 40
    local PARAGRAPH_SPLIT = 40
    local LINE_HEIGHT = 1.05

    local DEFAULT_FONT_SIZE = 35
    local H1_FONT_SIZE = 70
    local H2_FONT_SIZE = 50

    local function max_per_line(font, size, width)
        -- try to calculate the max characters/line
        -- number based on the average character width
        -- of the specified font.
        local test_width = font:width("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz", size)
        local avg_width = test_width / 52
        local chars_per_line = width / avg_width
        return math.floor(chars_per_line)
    end

    local rows = {}
    local function flush_table()
        local max_w = {}
        for ri = 1, #rows do
            local row = rows[ri]
            for ci = 1, #row do
                local col = row[ci]
                max_w[ci] = max(max_w[ci] or 0, col.width)
            end
        end

        local TABLE_SEPARATE = 40

        for ri = 1, #rows do
            local row = rows[ri]
            local x = 0
            for ci = 1, #row do
                local col = row[ci]
                if col.text ~= "" then
                    col.x = x
                    col.y = y
                    writes[#writes+1] = col
                end
                x = x + max_w[ci]+CELL_PADDING
            end
            y = y + DEFAULT_FONT_SIZE * LINE_HEIGHT
            max_x = max(max_x, x-CELL_PADDING)
        end
        rows = {}
    end

    local function add_row()
        local cols = {}
        rows[#rows+1] = cols
        return cols
    end

    local function layout_paragraph(paragraph)
        for line in string.gmatch(paragraph, "[^\n]+") do
            local font = font_regl
            local size = DEFAULT_FONT_SIZE -- font size for line
            local maxl = max_per_line(font, size, width)

            if line:find "|" then
                -- table row
                local cols = add_row()
                for field in line:gmatch("[^|]+") do
                    field = trim(field)
                    local width = font:width(field, size)
                    cols[#cols+1] = {
                        font = font,
                        text = field,
                        size = size,
                        width = width,
                    }
                end
            else
                -- plain text, wrapped
                flush_table()

                -- markdown header # and ##
                if line:sub(1,2) == "##" then
                    line = line:sub(3)
                    font = font_bold
                    size = H2_FONT_SIZE
                    maxl = max_per_line(font, size, width)
                elseif line:sub(1,1) == "#" then
                    line = line:sub(2)
                    font = font_bold
                    size = H1_FONT_SIZE
                    maxl = max_per_line(font, size, width)
                end

                local chunks = wrap(line, maxl)
                for idx = 1, #chunks do
                    local chunk = chunks[idx]
                    chunk = trim(chunk)
                    writes[#writes+1] = {
                        font = font,
                        x = 0,
                        y = y,
                        text = chunk,
                        size = size,
                    }
                    local width = font:width(chunk, size)
                    y = y + size * LINE_HEIGHT
                    max_x = max(max_x, width)
                end
            end
        end

        flush_table()
    end

    local paragraphs = split(text, "\n\n")
    for idx = 1, #paragraphs do
        local paragraph = paragraphs[idx]
        paragraph = paragraph:gsub("\t", " ")
        layout_paragraph(paragraph)
        y = y + PARAGRAPH_SPLIT
    end

    -- remove one split
    local max_y = y - PARAGRAPH_SPLIT

    local base_x = (width-max_x) / 2
    local base_y = (height-max_y) / 2

    return function(starts, ends)
        for now, x1, y1, x2, y2 in from_to(starts, ends) do
            local x = x1 + base_x
            local y = y1 + base_y
            -- overlays[1]:draw(x, y, x+max_x, y+max_y, 0.1)
            for idx = 1, #writes do
                local w = writes[idx]
                w.font:write(x+w.x, y+w.y, w.text, w.size, r,g,b,1)
            end
        end
    end
end

local function JobQueue()
    local jobs = {}

    local function add(fn, starts, ends, coord)
        local co = coroutine.create(fn)
        local ok, again = coroutine.resume(co, starts, ends)
        if not ok then
            return error(("%s\n%s\ninside coroutine started by"):format(
                again, debug.traceback(co)
            ))
        elseif not again then
            return
        end

        local job = {
            starts = starts,
            ends = ends,
            coord = coord,
            co = co,
        }

        jobs[#jobs+1] = job
    end

    local function tick(now)
        for idx = 1, #jobs do
            local job = jobs[idx]
            local x1, y1, x2, y2 = job.coord(job.starts, job.ends, now)

            if overlay_debug then
                overlays[(idx-1)%#overlays+1]:draw(x1, y1, x2, y2, 0.1)
            end

            local ok, again = coroutine.resume(job.co, now, x1, y1, x2, y2)
            if not ok then
                print(("%s\n%s\ninside coroutine %s resumed by"):format(
                    again, debug.traceback(job.co), job)
                )
                job.done = true
            elseif not again then
                job.done = true
            end
        end

        -- iterate backwards so we can remove finished jobs
        for idx = #jobs,1,-1 do
            local job = jobs[idx]
            if job.done then
                table.remove(jobs, idx)
            end
        end

        if #jobs == 0 then
            print "empty"
        end
    end

    local function flush()
        for idx = #jobs,1,-1 do
            table.remove(jobs, idx)
        end
        node.gc()
    end

    return {
        tick = tick;
        add = add;
        flush = flush;
    }
end


local function Scheduler(playlist_source, job_queue)
    local scheduled_until = clock.unix()
    local next_schedule = 0

    local SCHEDULE_LOOKAHEAD = 2

    local function enqueue_playlist(playlist)
        -- get total playlist duration
        local total_duration = 0
        for idx = 1, #playlist do
            local item = playlist[idx]
            total_duration = max(total_duration, item.offset + item.duration)
        end

        print("playlist duration is", total_duration)

        local function enqueue(starts, item)
            local ends = starts + item.duration
            job_queue.add(item.fn, starts, ends, item.coord)
        end

        local base = scheduled_until

        print("base unix time is", base)

        for idx = 1, #playlist do
            local item = playlist[idx]
            local starts = base + item.offset
            enqueue(starts, item)
        end

        scheduled_until = base + total_duration
        next_schedule = scheduled_until - SCHEDULE_LOOKAHEAD
    end

    local function tick(now)
        if now < next_schedule then
            return
        end

        local playlist = playlist_source.create_next()
        enqueue_playlist(playlist)
    end

    local function intermission(idx)
        local playlist = playlist_source.create_intermission(idx)
        if not playlist then
            print "requested intermission does not exist"
            return
        end
        job_queue.flush()
        scheduled_until = clock.unix()
        enqueue_playlist(playlist)
        active_intermission_page_idx = idx
    end

    return {
        tick = tick;
        intermission = intermission;
    }
end

local function Playlist()
    local playlist, offset

    local function reset()
        playlist = {}
        offset = 0
    end

    local function add(item)
        playlist[#playlist+1] = item
    end

    local function static(x1, y1, x2, y2)
        return function(s, e, now)
            return x1, y1, x2, y2
        end
    end

    local function tile_fullbleed(s, e, now)
        return 0, 0, WIDTH, HEIGHT
    end

    local function tile_fullscreen(s, e, now)
        return 0, 0, WIDTH, HEIGHT-50
    end

    local function tile_logo(s, e, now)
        return WIDTH-350, 75, WIDTH-100, 203
    end

    local function tile_center_overlay(s, e, now)
        return WIDTH/8, HEIGHT/4, (WIDTH/8)*7, (HEIGHT/6)*5
    end

    local function tile_center_inner(s, e, now)
        return (WIDTH/8)+10, (HEIGHT/4)+10, ((WIDTH/8)*7)+10, ((HEIGHT/6)*5)+10
    end

    local function tile_top(s, e, now)
        return 0, 0, WIDTH/2, 100
    end

    local function tile_bottom(s, e, now)
        return 0, HEIGHT-50, WIDTH, HEIGHT
    end

    local function tile_bottom_scroller(s, e, now)
        return 300, HEIGHT-50, WIDTH, HEIGHT
    end

    local function tile_bottom_clock(s, e, now)
        return 0, HEIGHT-50, 300, HEIGHT
    end

    local function tile_bottom_right(s, e, now)
        return 0, HEIGHT-50, WIDTH, HEIGHT
    end

    local function tile_right(s, e, now)
        return WIDTH/2, 100, WIDTH, HEIGHT-50
    end

    local function tile_left(s, e, now)
        return 0, 100, WIDTH/2, HEIGHT-50
    end

    local function add_info_bar(page, duration)
        add{
            offset = offset,
            duration = duration,
            fn = Image{
                fade_time = 0,
                asset_name = node_config.footer.asset_name,
            },
            coord = tile_bottom,
        }
        add{
            offset = offset,
            duration = duration,
            fn = TimeTile{
                font = font_regl,
                r = 1, g = 1, b = 1,
            },
            coord = tile_bottom_clock,
        }
    end

    local function image_or_video_player(media, kenburns)
        if media.type == "image" then
            return Image{
                fade_time = 0,
                asset_name = media.asset_name,
                kenburns = kenburns,
            }
        else
            return Video{
                fade_time = 0,
                asset_name = media.asset_name,
                raw = true,
            }
        end
    end

    local function get_duration(page)
        local duration = 10
        if page.duration == "auto" then
            if page.media.metadata.duration then
                duration = tonumber(page.media.metadata.duration)
            end
        else
            duration = tonumber(page.duration)
        end
        return duration
    end

    local function page_fullscreen(page, duration)
        duration = duration or get_duration(page)
        add{
            offset = offset,
            duration = duration,
            fn = image_or_video_player(page.media),
            coord = tile_fullscreen,
        }
        add_info_bar(page, duration)
        offset = offset + duration
    end

    local function page_overlay(page, duration)
        duration = duration or get_duration(page)
        add{
            offset = offset,
            duration = duration,
            fn = image_or_video_player(page.media),
            coord = tile_fullbleed,
        }
        add{
            offset = offset,
            duration = duration,
            fn = Flat{
                fade_time = 0,
                color = '#000000',
                opacity = 0.4,
            },
            coord = tile_center_overlay,
        }
        add{
            offset = offset,
            duration = duration,
            fn = Image{
                fade_time = 0,
                asset_name = 'WMS-logo1.png',
                kenburns = false,
            },
            coord = tile_logo,
        }
        add{
            offset = offset,
            duration = duration,
            fn = Markup{
                text = page.config.text or "",
                width = ((WIDTH/8)*6)-20,
                height = ((HEIGHT/6)*4)-20,
                color = page.config.foreground or "#ffffff",
            },
            coord = tile_center_inner,
        }
        -- add_info_bar(page, duration)
        offset = offset + duration
    end

    local function page_text_left(page, duration)
        duration = duration or get_duration(page)
        add{
            offset = offset,
            duration = duration,
            fn = Flat{
                fade_time = 0,
                color = '#FF0000',
                opacity = 0.2,
            },
            coord = tile_top,
        }
        add{
            offset = offset,
            duration = duration,
            fn = image_or_video_player(page.media, page.config.kenburns),
            coord = tile_right,
        }
        add{
            offset = offset,
            duration = duration,
            fn = Flat{
                fade_time = 0,
                color = page.config.background or "#000000",
            },
            coord = tile_left,
        }
        add{
            offset = offset,
            duration = duration,
            fn = Markup{
                text = page.config.text or "",
                width = WIDTH/2,
                height = HEIGHT-200,
                color = page.config.foreground or "#ffffff",
            },
            coord = tile_left,
        }
        add_info_bar(page, duration)
        offset = offset + duration
    end

    local function page_text_right(page, duration)
        duration = duration or get_duration(page)
        add{
            offset = offset,
            duration = duration,
            fn = Image{
                fade_time = 0,
                asset_name = node_config.header.asset_name,
            },
            coord = tile_top,
        }
        add{
            offset = offset,
            duration = duration,
            fn = image_or_video_player(page.media, page.config.kenburns),
            coord = tile_left,
        }
        add{
            offset = offset,
            duration = duration,
            fn = Flat{
                fade_time = 0,
                color = page.config.background or "#000000",
            },
            coord = tile_right,
        }
        add{
            offset = offset,
            duration = duration,
            fn = Markup{
                text = page.config.text or "",
                width = WIDTH/2,
                height = HEIGHT-200,
                color = page.config.foreground or "#ffffff",
            },
            coord = tile_right,
        }
        add_info_bar(page, duration)
        offset = offset + duration
    end

    local layouts = {
        ["fullscreen"] = page_fullscreen;
        ["text-left"] = page_text_left;
        ["text-right"] = page_text_right;
        ["center-overlay"] = page_overlay;
    }

    local function create_intermission(idx)
        local page = node_config.pages[idx]
        if not page then
            return
        end

        reset()
        local duration = page.interaction.duration
        if duration == "auto" then
            duration = get_duration(page)
        else
            duration = 99999999999
        end
        layouts[page.layout](page, duration)
        local title = page.interaction.title
        if title ~= "" then
            add{
                offset = 0,
                duration = duration,
                fn = InteractionTitle{
                    text = title,
                    font = font_regl,
                    bg = {r=0, g=0, b=0},
                    fg = {r=1, g=1, b=1},
                },
                coord = tile_bottom_right,
            }
        end

        add{
            offset = 0,
            duration = duration,
            fn = ResetIntermission{},
            coord = static(0, 0, 0, 0),
        }

        return playlist
    end

    local cycle_idx = 0
    local function create_next()
        reset()
        local how = clock.hour_of_week()
        for retry = 1, #node_config.pages do
            cycle_idx = cycle_idx % #node_config.pages + 1
            local page = node_config.pages[cycle_idx]
            -- hours might be empty, in which case the hour
            -- should default to true. So explicitly test
            -- for unscheduled hours.
            if page.schedule.hours[how+1] == false then
                print("page ", idx, "not scheduled")
            else
                layouts[page.layout](page)
                break -- found a working page
            end
        end
        return playlist
    end

    local function create_all()
        reset()
        local how = clock.hour_of_week()
        for idx = 1, #node_config.pages do
            local page = node_config.pages[idx]
            -- hours might be empty, in which case the hour
            -- should default to true. So explicitly test
            -- for unscheduled hours.
            if page.schedule.hours[how+1] == false then
                print("page ", idx, "not scheduled")
            else
                layouts[page.layout](page)
            end
        end
        return playlist
    end

    return {
        create_all = create_all;
        create_next = create_next;
        create_intermission = create_intermission;
    }
end

local job_queue = JobQueue()
local playlist = Playlist()
local scheduler = Scheduler(playlist, job_queue)

local function handle_event(event)
    if event.action == "down" then
        for idx = 1, #node_config.pages do
            local page = node_config.pages[idx]
            if page.interaction.key == event.key then
                scheduler.intermission(idx)
            end
        end
    end
end

util.data_mapper{
    ["input/event"] = function(raw_event)
        return handle_event(json.decode(raw_event))
    end
}

util.json_watch("config.json", function(new_config)
    node_config = new_config

    -- pin asset files if possible
    pinner.flush()
    for idx = 1, #node_config.pages do
        local page = node_config.pages[idx]
        pinner.pin(page.media.asset_name)
    end

    -- TODO: Be smarter about restarting the intermission.
    -- Maybe detect if page itself has change compared to the
    -- currently active version?
    if active_intermission_page_idx then
        scheduler.intermission(active_intermission_page_idx)
    end
end)

function node.render()
    gl.clear(0, 0, 0, 1)
    local now = clock.unix()
    scheduler.tick(now)

    local fov = math.atan2(HEIGHT, WIDTH*2) * 360 / math.pi
    gl.perspective(fov, WIDTH/2, HEIGHT/2, -WIDTH,
                        WIDTH/2, HEIGHT/2, 0)
    job_queue.tick(now)
    -- print("active intermission", active_intermission_page_idx)
end
