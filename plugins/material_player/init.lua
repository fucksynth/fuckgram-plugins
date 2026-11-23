-- Плеер Material: карточка в стиле Material 3 поверх окна клиента.
-- Рисуется на холсте (tg.ui.overlay), читает и нажимает плеер клиента
-- (tg.player). Цвета берутся от названия трека или из темы. Тексты — в
-- locales/*.json (plugin.t).

local CORNERS = { "bottom-right", "bottom-left", "top-right", "top-left" }
local SIZES = {
	{ width = 340, height = 136 },
	{ width = 300, height = 76 },
}
local FIXED_HUES = { [3] = 270, [4] = 140, [5] = 28 }

local overlay
local state -- what tg.player.state() said last time
local shown_key -- what the card shows, to repaint only on changes
local morph = 1 -- 0: a square play button (paused), 1: a round one (playing)
local last_tick = tg.now()

-- Settings.

local function setting(key, default)
	return plugin.settings.get(key, default)
end

local function size_option()
	return SIZES[setting("size", 1)] or SIZES[1]
end

-- Colors.

local function clamp(x, a, b)
	if x < a then return a elseif x > b then return b end
	return x
end

local function hsl(h, s, l)
	h = (h % 360) / 360
	local function hue(p, q, t)
		if t < 0 then t = t + 1 end
		if t > 1 then t = t - 1 end
		if t < 1 / 6 then return p + (q - p) * 6 * t end
		if t < 1 / 2 then return q end
		if t < 2 / 3 then return p + (q - p) * (2 / 3 - t) * 6 end
		return p
	end
	local q = l < 0.5 and l * (1 + s) or l + s - l * s
	local p = 2 * l - q
	local r = hue(p, q, h + 1 / 3)
	local g = hue(p, q, h)
	local b = hue(p, q, h - 1 / 3)
	return string.format("#%02x%02x%02x",
		math.floor(r * 255 + 0.5),
		math.floor(g * 255 + 0.5),
		math.floor(b * 255 + 0.5))
end

local function hue_of(text)
	local hash = 0
	for i = 1, #text do
		hash = (hash * 31 + text:byte(i)) % 360
	end
	return hash
end

-- "#aarrggbb" of a theme color -> its hue and whether it is dark.
local function theme_hue()
	local color = tg.ui.color("windowActiveTextFg") or "#ff3390ec"
	local r = tonumber(color:sub(4, 5), 16) / 255
	local g = tonumber(color:sub(6, 7), 16) / 255
	local b = tonumber(color:sub(8, 9), 16) / 255
	local max, min = math.max(r, g, b), math.min(r, g, b)
	if max == min then
		return 210
	end
	local d = max - min
	local h
	if max == r then
		h = (g - b) / d % 6
	elseif max == g then
		h = (b - r) / d + 2
	else
		h = (r - g) / d + 4
	end
	return h * 60
end

local function dark_theme()
	local color = tg.ui.color("windowBg") or "#ffffffff"
	local r = tonumber(color:sub(4, 5), 16)
	local g = tonumber(color:sub(6, 7), 16)
	local b = tonumber(color:sub(8, 9), 16)
	return (r * 0.299 + g * 0.587 + b * 0.114) < 128
end

-- A Material 3 tonal set for a hue.
local function scheme(title)
	local mode = setting("palette", 1)
	local h
	if mode == 1 then
		h = hue_of(title or "")
	elseif mode == 2 then
		h = theme_hue()
	else
		h = FIXED_HUES[mode] or 270
	end
	if dark_theme() then
		return {
			surface = hsl(h, 0.22, 0.14),
			container = hsl(h, 0.30, 0.22),
			primary = hsl(h, 0.75, 0.78),
			on_primary = hsl(h, 0.60, 0.18),
			text = hsl(h, 0.20, 0.92),
			subtext = hsl(h, 0.12, 0.70),
			track = hsl(h, 0.25, 0.32),
		}
	end
	return {
		surface = hsl(h, 0.45, 0.95),
		container = hsl(h, 0.55, 0.88),
		primary = hsl(h, 0.55, 0.42),
		on_primary = "#ffffff",
		text = hsl(h, 0.30, 0.12),
		subtext = hsl(h, 0.15, 0.38),
		track = hsl(h, 0.30, 0.80),
	}
end

-- Drawing.

local function time_text(seconds)
	seconds = math.floor(math.max(seconds or 0, 0))
	return string.format("%d:%02d", seconds // 60, seconds % 60)
end

local layout = {} -- hit areas of the last paint

local function draw_previous(c, x, y, color)
	c:rect(x, y - 7, 3, 14, color, 1)
	c:polygon({ x + 15, y - 8, x + 15, y + 8, x + 4, y }, color)
end

local function draw_next(c, x, y, color)
	c:polygon({ x, y - 8, x, y + 8, x + 11, y }, color)
	c:rect(x + 12, y - 7, 3, 14, color, 1)
end

local function draw_play_pause(c, cx, cy, size, playing, colors)
	-- The button morphs: a rounded square while paused, a circle while
	-- playing, like the Material 3 expressive media controls.
	local radius = 12 + (size / 2 - 12) * morph
	c:rect(cx - size / 2, cy - size / 2, size, size, colors.primary, radius)
	if playing then
		c:rect(cx - 7, cy - 8, 5, 16, colors.on_primary, 2)
		c:rect(cx + 2, cy - 8, 5, 16, colors.on_primary, 2)
	else
		c:polygon({ cx - 5, cy - 9, cx - 5, cy + 9, cx + 9, cy }, colors.on_primary)
	end
end

local function draw_progress(c, x, y, width, fraction, playing, colors)
	local done = width * clamp(fraction, 0, 1)
	if setting("wave", true) and playing then
		-- The squiggly progress of Android 13+: a sine wave up to the
		-- position, moving while the track plays.
		local phase = tg.now() / 1000 * 6
		local step = 3
		local px, py = x, y
		local t = 0
		while t < done do
			t = math.min(t + step, done)
			local nx = x + t
			local ny = y + math.sin(t / 7 + phase) * 3
			c:line(px, py, nx, ny, colors.primary, 3)
			px, py = nx, ny
		end
	else
		c:line(x, y, x + done, y, colors.primary, 3)
	end
	if done < width then
		c:line(x + done + 6, y, x + width, y, colors.track, 3)
	end
	c:rect(x + done - 2, y - 9, 4, 18, colors.primary, 2)
	layout.progress = { x = x, y = y - 12, width = width, height = 24 }
end

local function paint(c)
	if not state then
		return
	end
	local w, h = c:size()
	local colors = scheme(state.title)
	local compact = (setting("size", 1) == 2)
	c:rect(0, 0, w, h, colors.surface, 28)

	-- "Cover": the tonal container with a note.
	local art = compact and 52 or 64
	local ax, ay = 12, compact and 12 or 14
	c:rect(ax, ay, art, art, colors.container, 18)
	c:text(ax, ay + art / 2 - 16, "♪", {
		size = 26,
		bold = true,
		color = colors.primary,
		width = art,
		align = "center",
	})

	local tx = ax + art + 14
	-- The compact card keeps its buttons on the right of the text.
	local tw = compact and (w - tx - 116) or (w - tx - 16)
	local duration = state.duration or 0
	local title = state.title or ""
	if state.voice then
		title = compact and plugin.t("voice.short") or plugin.t("voice")
	end
	local subtitle = state.voice
		and (time_text(state.position) .. " / " .. time_text(duration))
		or (state.performer or "")
	c:text(tx, ay + (compact and 0 or 2), title, {
		size = compact and 14 or 15,
		bold = true,
		color = colors.text,
		width = tw,
		height = 20,
	})
	c:text(tx, ay + (compact and 19 or 22), subtitle, {
		size = compact and 11 or 12,
		color = colors.subtext,
		width = tw,
		height = 16,
	})

	local fraction = duration > 0 and (state.position / duration) or 0
	layout.buttons = {}
	if compact then
		draw_progress(c, tx, ay + 42, tw, fraction, state.playing, colors)
		local cy = h / 2
		local bx = w - 104
		draw_previous(c, bx, cy, colors.text)
		draw_play_pause(c, bx + 46, cy, 38, state.playing, colors)
		draw_next(c, bx + 76, cy, colors.text)
		layout.buttons = {
			{ x = bx - 6, width = 26, action = "previous" },
			{ x = bx + 26, width = 40, action = "toggle" },
			{ x = bx + 70, width = 26, action = "next" },
		}
		layout.buttons_y = { cy - 22, cy + 22 }
		return
	end

	local py = ay + art + 18
	draw_progress(c, 16, py, w - 32, fraction, state.playing, colors)
	c:text(16, py + 10, time_text(state.position), { size = 11, color = colors.subtext })
	c:text(w - 116, py + 10, time_text(duration), {
		size = 11,
		color = colors.subtext,
		width = 100,
		align = "right",
	})
	local cy = ay + art / 2 + 12
	local bx = tx + tw - 112
	draw_previous(c, bx, cy, colors.text)
	draw_play_pause(c, bx + 54, cy, 44, state.playing, colors)
	draw_next(c, bx + 94, cy, colors.text)
	layout.buttons = {
		{ x = bx - 8, width = 30, action = "previous" },
		{ x = bx + 30, width = 48, action = "toggle" },
		{ x = bx + 86, width = 30, action = "next" },
	}
	layout.buttons_y = { cy - 24, cy + 24 }
end

local function click(x, y)
	local bar = layout.progress
	if bar and x >= bar.x and x <= bar.x + bar.width
		and y >= bar.y and y <= bar.y + bar.height then
		tg.player.seek((x - bar.x) / bar.width)
		return
	end
	local top, bottom = layout.buttons_y and layout.buttons_y[1], layout.buttons_y and layout.buttons_y[2]
	if not top or y < top or y > bottom then
		return
	end
	for _, button in ipairs(layout.buttons or {}) do
		if x >= button.x and x <= button.x + button.width then
			if button.action == "previous" then
				tg.player.previous()
			elseif button.action == "next" then
				tg.player.next()
			else
				tg.player.toggle()
			end
			return
		end
	end
end

-- The card follows the player.

local function close_card()
	if overlay then
		overlay:close()
		overlay = nil
	end
	shown_key = nil
end

local function open_card()
	local size = size_option()
	overlay = tg.ui.overlay{
		corner = CORNERS[setting("corner", 1)] or CORNERS[1],
		x = 16,
		y = 16,
		width = size.width,
		height = size.height,
		paint = paint,
		on_click = click,
	}
end

local function tick()
	local now = tg.now()
	local dt = (now - last_tick) / 1000
	last_tick = now
	state = setting("enabled", true) and tg.player.state() or nil
	if state and not state.playing and not setting("paused", true) then
		state = nil
	end
	if not state then
		close_card()
		return
	end
	if not overlay then
		open_card()
		if not overlay then
			return -- no window yet
		end
	end
	local target = state.playing and 1 or 0
	if morph ~= target then
		local delta = dt * 5
		morph = target > morph and math.min(target, morph + delta) or math.max(target, morph - delta)
	end
	local key = table.concat({
		state.title or "",
		tostring(state.playing),
		string.format("%.1f", state.position or 0),
		string.format("%.2f", morph),
	}, "|")
	-- While playing the wave moves: repaint every tick.
	if key ~= shown_key or (state.playing and setting("wave", true)) then
		shown_key = key
		overlay:update()
	end
end

-- 20 frames a second while the wave moves, 4 otherwise. Repeating timers
-- are 100 ms at least, so each frame plans the next one.
local function loop()
	local moving = state and state.playing and setting("wave", true)
	tg.timer.after(moving and 50 or 250, loop)
	tick()
end
loop()

-- Settings page.

-- A canvas that draws into `c` moved by dx, dy and reports `w` x `h`.
local function shifted(c, dx, dy, w, h)
	local p = {}
	function p:size() return w, h end
	function p:fill(color) c:rect(dx, dy, w, h, color) end
	function p:rect(x, y, ...) c:rect(x + dx, y + dy, ...) end
	function p:stroke(x, y, ...) c:stroke(x + dx, y + dy, ...) end
	function p:circle(x, y, ...) c:circle(x + dx, y + dy, ...) end
	function p:line(x1, y1, x2, y2, ...) c:line(x1 + dx, y1 + dy, x2 + dx, y2 + dy, ...) end
	function p:text(x, y, ...) return c:text(x + dx, y + dy, ...) end
	function p:measure(...) return c:measure(...) end
	function p:image(id, x, y, ...) c:image(id, x + dx, y + dy, ...) end
	function p:opacity(value) c:opacity(value) end
	function p:polygon(points, color)
		local moved = {}
		for i = 1, #points, 2 do
			moved[i] = points[i] + dx
			moved[i + 1] = points[i + 1] + dy
		end
		c:polygon(moved, color)
	end
	return p
end

local function rebuild_card()
	close_card()
	tick()
end

local function settings_page()
	return {
		{ type = "header", text = plugin.t("settings.display") },
		{
			type = "switch",
			key = "enabled",
			text = plugin.t("settings.enabled"),
			subtext = plugin.t("settings.enabled.about"),
			icon = "sound",
			default = true,
			on_change = rebuild_card,
		},
		{
			type = "switch",
			key = "paused",
			text = plugin.t("settings.paused"),
			subtext = plugin.t("settings.paused.about"),
			icon = "timer",
			default = true,
			on_change = rebuild_card,
		},
		{
			type = "selector",
			key = "corner",
			text = plugin.t("settings.corner"),
			items = {
				plugin.t("corner.bottom_right"),
				plugin.t("corner.bottom_left"),
				plugin.t("corner.top_right"),
				plugin.t("corner.top_left"),
			},
			default = 1,
			icon = "expand",
			on_change = rebuild_card,
		},
		{
			type = "selector",
			key = "size",
			text = plugin.t("settings.size"),
			items = { plugin.t("size.normal"), plugin.t("size.compact") },
			default = 1,
			icon = "customize",
			on_change = rebuild_card,
		},
		{ type = "header", text = plugin.t("settings.style") },
		{
			type = "selector",
			key = "palette",
			text = plugin.t("settings.palette"),
			items = {
				plugin.t("palette.track"),
				plugin.t("palette.theme"),
				plugin.t("palette.purple"),
				plugin.t("palette.green"),
				plugin.t("palette.orange"),
			},
			default = 1,
			icon = "palette",
			on_change = function()
				shown_key = nil
			end,
		},
		{
			type = "switch",
			key = "wave",
			text = plugin.t("settings.wave"),
			subtext = plugin.t("settings.wave.about"),
			icon = "reactions",
			default = true,
		},
		{
			type = "custom",
			height = 150,
			paint = function(c)
				-- A preview with a made-up track, drawn by the same paint()
				-- through a canvas that moves everything to its place.
				local real = state
				state = state or {
					title = plugin.t("preview.title"),
					performer = plugin.t("preview.performer"),
					playing = true,
					position = 83,
					duration = 225,
				}
				local w = c:size()
				local size = size_option()
				c:text(22, 4, plugin.t("preview.caption"), {
					size = 12,
					color = "windowSubTextFg",
					width = w - 44,
					height = 18,
				})
				local saved = layout
				layout = {}
				paint(shifted(c, math.max((w - size.width) / 2, 0), 26, size.width, size.height))
				layout = saved
				state = real
			end,
		},
		{ type = "divider", text = plugin.t("settings.clicks") },
	}
end

plugin.settings.page(settings_page)

plugin.menu{
	place = "main",
	text = plugin.t("title"),
	icon = "sound",
	page = settings_page,
}
