-- Snowfall: gentle snow over the client window.
-- One overlay the size of the window, without on_click, so every click
-- goes through it to the client. About 22 frames a second while it
-- snows, nothing at all while it does not (the overlay is closed) and no
-- repaints while the window is in the background. By default it snows
-- only from December to February. Texts are in locales/*.json (plugin.t).

local FRAME_MS = 45 -- about 22 frames a second
local IDLE_MS = 1000 -- how often to look again while it does not snow
local MAX_FLAKES = 160 -- at 100 % and a big window
local FULL_AREA = 1280 * 800 -- a window that gets the full amount
-- Smallest and largest flake radius for "small", "medium", "large".
local SIZES = { { 0.8, 1.8 }, { 1.0, 2.8 }, { 1.4, 4.0 } }

local overlay
local ow, oh -- the size the overlay was given
local flakes = {}
local last = tg.now()
local clock = 0 -- seconds of snow, drives the wind and the sway
local window_active = true
local palette -- flake colors, from the theme
local palette_at = -10000

-- Settings.

local function setting(key, default)
	return plugin.settings.get(key, default)
end

local function clamp(x, a, b)
	if x < a then return a elseif x > b then return b end
	return x
end

local function winter()
	local month = os.date("*t").month
	return month == 12 or month <= 2
end

local function snowing()
	if not setting("enabled", true) then
		return false
	end
	return not setting("winter_only", true) or winter()
end

local function radius_range()
	local size = SIZES[tonumber(setting("size", 2)) or 2] or SIZES[2]
	return size[1], size[2]
end

-- Fall speed in px/s for the slider value 1..10.
local function base_speed()
	return 12 + (tonumber(setting("speed", 4)) or 4) * 7
end

local function target_count(w, h)
	local amount = clamp((tonumber(setting("amount", 40)) or 40) / 100, 0.05, 1)
	local area = clamp((w * h) / FULL_AREA, 0.15, 1)
	return math.max(4, math.floor(MAX_FLAKES * amount * area + 0.5))
end

-- Colors: white snow on a dark theme, a soft blue-gray on a light one so
-- the flakes are still seen. Four levels: small far flakes are fainter.
local function dark_theme()
	local color = tg.ui.color("windowBg") or "#ffffffff"
	local r = tonumber(color:sub(4, 5), 16) or 255
	local g = tonumber(color:sub(6, 7), 16) or 255
	local b = tonumber(color:sub(8, 9), 16) or 255
	return (r * 0.299 + g * 0.587 + b * 0.114) < 128
end

local function update_palette(now)
	if palette and now - palette_at < 2000 then
		return
	end
	palette_at = now
	if dark_theme() then
		palette = { "#60ffffff", "#88ffffff", "#b0ffffff", "#d8ffffff" }
	else
		palette = { "#7096b4d2", "#9096b4d2", "#b08fb0cf", "#d08aaccc" }
	end
end

-- Flakes.

local function spawn(f, w, h, anywhere)
	local rmin, rmax = radius_range()
	local k = math.random() ^ 2 -- more small flakes than big ones
	f.r = rmin + (rmax - rmin) * k
	f.depth = k -- 0: far and slow, 1: near and fast
	f.vy = base_speed() * (0.55 + 0.6 * k) * (0.85 + math.random() * 0.3)
	f.x = math.random() * (w + 40) - 20
	f.y = anywhere and math.random() * h or -f.r - math.random() * 40
	f.phase = math.random() * math.pi * 2
	f.sway = 4 + math.random() * 12
	f.freq = 0.4 + math.random() * 0.8
	f.color = clamp(math.floor(k * 4) + 1, 1, 4)
	return f
end

local function fit_count(w, h, anywhere)
	local n = target_count(w, h)
	for i = #flakes + 1, n do
		flakes[i] = spawn({}, w, h, anywhere)
	end
	for i = #flakes, n + 1, -1 do
		flakes[i] = nil
	end
end

-- A slow breeze that changes now and then, mostly to one side.
local function wind_now()
	if not setting("wind", true) then
		return 0
	end
	return 6 + 9 * math.sin(clock / 9) + 4 * math.sin(clock / 3.7)
end

local function step(dt, w, h)
	clock = clock + dt
	local wind = wind_now()
	for i = 1, #flakes do
		local f = flakes[i]
		f.y = f.y + f.vy * dt
		f.x = f.x + wind * (0.4 + 0.6 * f.depth) * dt
		if f.y - f.r > h then
			spawn(f, w, h, false)
		elseif f.x > w + 20 then
			f.x = f.x - (w + 40)
		elseif f.x < -20 then
			f.x = f.x + (w + 40)
		end
	end
end

local function paint(c)
	if not palette then
		return
	end
	for i = 1, #flakes do
		local f = flakes[i]
		local x = f.x + math.sin(clock * f.freq + f.phase) * f.sway
		c:circle(x, f.y, f.r, palette[f.color])
	end
end

-- The overlay.

local function stop()
	if overlay then
		overlay:close()
		overlay = nil
	end
	flakes = {}
	ow, oh = nil, nil
end

local function open(w, h)
	-- No on_click and no draggable: the client lets clicks through.
	overlay = tg.ui.overlay{
		x = 0,
		y = 0,
		width = w,
		height = h,
		paint = paint,
	}
	if overlay then
		ow, oh = w, h
		fit_count(w, h, true)
	end
end

-- One frame: returns the ms to the next one.
local function frame()
	local now = tg.now()
	local dt = clamp((now - last) / 1000, 0, 0.1)
	last = now
	if not snowing() then
		stop()
		return IDLE_MS
	end
	local w, h = tg.ui.window_size()
	if not w or w <= 0 or h <= 0 then
		return IDLE_MS
	end
	if not overlay then
		open(w, h)
		if not overlay then
			return IDLE_MS
		end
	elseif w ~= ow or h ~= oh then
		-- The window was resized: the snow follows.
		overlay:move{ x = 0, y = 0, width = w, height = h }
		ow, oh = w, h
	end
	if not window_active then
		-- The flakes stay where they are until the window is back.
		return IDLE_MS / 2
	end
	update_palette(now)
	fit_count(w, h, false)
	step(dt, w, h)
	overlay:update()
	return FRAME_MS
end

-- Repeating timers are 100 ms at least, so each frame plans the next one;
-- a failed frame still plans one, a second later.
local function loop()
	local ok, delay = pcall(frame)
	tg.timer.after(ok and delay or IDLE_MS, loop)
	if not ok then
		error(delay, 0)
	end
end

plugin.on("app.state", function(state)
	if state == "active" then
		window_active = true
		last = tg.now()
	elseif state == "inactive" then
		window_active = false
	end
end)

loop()

-- Settings page.

-- Rebuild the snow with the new settings.
local function restart()
	stop()
	last = tg.now()
	frame()
end

-- The status line on top of the page follows the switches.
local function changed()
	restart()
	tg.timer.after(0, plugin.settings.refresh)
end

local function status_row()
	local text, subtext, icon
	if snowing() then
		text = plugin.t("status.on")
		subtext = setting("winter_only", true)
			and plugin.t("status.on.winter")
			or plugin.t("status.on.always")
		icon = "star"
	elseif not setting("enabled", true) then
		text = plugin.t("status.off")
		subtext = plugin.t("status.off.about")
		icon = "eye_off"
	else
		text = plugin.t("status.waiting")
		subtext = plugin.t("status.waiting.about")
		icon = "schedule"
	end
	return { type = "text", text = text, subtext = subtext, icon = icon }
end

local function settings_page()
	return {
		status_row(),
		{ type = "header", text = plugin.t("settings.when") },
		{
			type = "switch",
			key = "enabled",
			text = plugin.t("settings.enabled"),
			icon = "power",
			default = true,
			on_change = changed,
		},
		{
			type = "switch",
			key = "winter_only",
			text = plugin.t("settings.winter_only"),
			subtext = plugin.t("settings.winter_only.about"),
			icon = "schedule",
			default = true,
			on_change = changed,
		},
		{ type = "header", text = plugin.t("settings.look") },
		{
			type = "slider",
			key = "amount",
			text = plugin.t("settings.amount"),
			min = 10,
			max = 100,
			step = 5,
			default = 40,
		},
		{
			type = "slider",
			key = "speed",
			text = plugin.t("settings.speed"),
			min = 1,
			max = 10,
			step = 1,
			default = 4,
			on_change = restart,
		},
		{
			type = "selector",
			key = "size",
			text = plugin.t("settings.size"),
			items = {
				plugin.t("size.small"),
				plugin.t("size.medium"),
				plugin.t("size.large"),
			},
			default = 2,
			icon = "customize",
			on_change = restart,
		},
		{
			type = "switch",
			key = "wind",
			text = plugin.t("settings.wind"),
			subtext = plugin.t("settings.wind.about"),
			icon = "refresh",
			default = true,
		},
		{ type = "divider", text = plugin.t("settings.about") },
	}
end

plugin.settings.page(settings_page)

plugin.menu{
	place = "main",
	text = plugin.t("menu"),
	icon = "star",
	page = settings_page,
}
