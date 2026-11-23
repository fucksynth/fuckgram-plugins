-- Пиксельный котик: живёт в окне клиента. Рисуется на холсте плашки
-- (tg.ui.overlay), которая ездит по окну; спрайты — строки ниже. Что
-- котик говорит и как называются окрасы — в locales/*.json (plugin.t).

-- "." пусто, "o" контур, "f" шерсть, "d" полоски, "b" животик,
-- "e" глаза, "n" нос. Котик смотрит вправо, влево его отражаем.
local SPRITES = {
	walk1 = {
		"...........o..o.",
		"..........ofoofo",
		"o.........offffo",
		"ofo.......oeffeo",
		".ofo......ofnnfo",
		"..ofoooooooffffo",
		"..offdffdffffffo",
		"..offffffffffffo",
		"...obbbbbbbbbbo.",
		"...ofo.ofo.ofo..",
		"...oo..oo..oo...",
	},
	walk2 = {
		"...........o..o.",
		"..........ofoofo",
		"o.........offffo",
		"ofo.......oeffeo",
		".ofo......ofnnfo",
		"..ofoooooooffffo",
		"..offdffdffffffo",
		"..offffffffffffo",
		"...obbbbbbbbbbo.",
		"....ofo.ofo.ofo.",
		"....oo...oo..oo.",
	},
	sit = {
		"...........o..o.",
		"..........ofoofo",
		"..........offffo",
		"..........oeffeo",
		"..........ofnnfo",
		"....oooooooffffo",
		"...offdffdfffffo",
		"oo.offffffffffo.",
		"ofooobbbbbbbbbo.",
		".offffffoffffo..",
		"..ooooooooooo...",
	},
	sleep = {
		"................",
		"................",
		"...........o..o.",
		"..........ofoofo",
		"..........offffo",
		"..ooooooooofoofo",
		".offdffdffffnnfo",
		"oofffffffffffffo",
		"ofobbbbbbbbbbbo.",
		".oooooooooooooo.",
		"................",
	},
}

local COATS = {
	{ f = "#f4a259", d = "#d9772b", b = "#ffe2bd", o = "#5a2e0e", e = "#2b2b2b", n = "#ff8fab" },
	{ f = "#9aa3ad", d = "#6f7883", b = "#e3e7eb", o = "#2f3a45", e = "#2b2b2b", n = "#ff8fab" },
	{ f = "#2f2f35", d = "#1d1d22", b = "#4a4a52", o = "#0d0d10", e = "#ffd43b", n = "#ff8fab" },
	{ f = "#f4f4f4", d = "#dcdcdc", b = "#ffffff", o = "#7a7a7a", e = "#3b6fd6", n = "#ff8fab" },
	{ f = "#f1e3cf", d = "#6b4a36", b = "#fff6ea", o = "#3d2a1f", e = "#3b8ad6", n = "#ff8fab" },
}

local SPRITE_W, SPRITE_H = 16, 11
local TOP_SPACE = 22 -- above the cat: the bubble and "zzz"

local cat = {
	x = 120,
	y = 160,
	tx = 120,
	ty = 160,
	dir = 1,
	mode = "walk",
	until_ms = 0,
	bubble = nil,
	bubble_until = 0,
	frame_ms = 0,
	frame = 1,
}

local overlay
local overlay_scale

local function setting(key, default)
	return plugin.settings.get(key, default)
end

local function scale()
	return math.floor(setting("size", 3))
end

-- Room around the cat for its speech bubble.
local SIDE_SPACE = 48

local function box_size()
	local s = scale()
	return SPRITE_W * s + SIDE_SPACE * 2, SPRITE_H * s + TOP_SPACE + 4
end

local function say(text, ms)
	cat.bubble = text
	cat.bubble_until = tg.now() + (ms or 1500)
end

-- Somewhere in the window, away from the edges.
local function pick_target()
	local ww, wh = tg.ui.window_size()
	if not ww then
		return
	end
	local bw, bh = box_size()
	cat.tx = math.random(0, math.max(ww - bw, 0))
	cat.ty = math.random(40, math.max(wh - bh, 40))
end

local function sprite()
	if cat.mode == "sit" then
		return SPRITES.sit
	elseif cat.mode == "sleep" then
		return SPRITES.sleep
	end
	return cat.frame == 1 and SPRITES.walk1 or SPRITES.walk2
end

local function paint(c)
	local w, h = c:size()
	local s = scale()
	local coat = COATS[setting("coat", 1)] or COATS[1]
	local rows = sprite()
	local ox = (w - SPRITE_W * s) // 2
	local oy = h - SPRITE_H * s - 2
	-- One rectangle per run of a color in a row: fewer calls.
	for row = 1, SPRITE_H do
		local line = rows[row]
		local col = 1
		while col <= SPRITE_W do
			local ch = line:sub(col, col)
			local run = 1
			while col + run <= SPRITE_W and line:sub(col + run, col + run) == ch do
				run = run + 1
			end
			if ch ~= "." and coat[ch] then
				local x = cat.dir > 0 and (col - 1) or (SPRITE_W - (col - 1) - run)
				c:rect(ox + x * s, oy + (row - 1) * s, run * s, s, coat[ch])
			end
			col = col + run
		end
	end
	if cat.mode == "sleep" then
		local t = (tg.now() // 400) % 3
		local zx = cat.dir > 0 and (ox + 13 * s) or (ox + 1 * s)
		c:text(zx, oy - 8 - t * 4, string.rep("z", t + 1), {
			size = 10 + t * 2,
			bold = true,
			color = "windowSubTextFg",
		})
	end
	if cat.bubble then
		local tw = c:measure(cat.bubble, { size = 11, bold = true })
		local bw = math.min(tw + 12, w)
		local bx = math.max(math.min(w / 2 - bw / 2, w - bw), 0)
		c:rect(bx, 0, bw, 18, "windowBg", 9)
		c:stroke(bx, 0, bw, 18, "windowSubTextFg", 1, 9)
		c:text(bx, 2, cat.bubble, {
			size = 11,
			bold = true,
			color = "windowFg",
			width = bw,
			align = "center",
		})
	end
end

local function pet()
	if cat.mode == "sleep" then
		say(plugin.t("say.sleepy"))
	else
		local name = setting("name", "")
		say(name ~= "" and plugin.t("say.name", name) or plugin.t("say.meow"))
	end
	cat.mode = "run"
	pick_target()
end

local function close_overlay()
	if overlay then
		overlay:close()
		overlay = nil
	end
end

local function open_overlay()
	local bw, bh = box_size()
	overlay = tg.ui.overlay{
		x = math.floor(cat.x),
		y = math.floor(cat.y),
		width = bw,
		height = bh,
		paint = paint,
		on_click = setting("pettable", true) and function() pet() end or nil,
	}
	overlay_scale = scale()
end

local function rest()
	local roll = math.random()
	local hour = tonumber(os.date("%H"))
	local sleepy = setting("night", true) and (hour >= 23 or hour < 7)
	if roll < (sleepy and 0.6 or 0.2) then
		cat.mode = "sleep"
		cat.until_ms = tg.now() + math.random(6000, 15000)
	elseif roll < 0.6 then
		cat.mode = "sit"
		cat.until_ms = tg.now() + math.random(1500, 5000)
	else
		cat.mode = "walk"
		pick_target()
	end
end

local function tick()
	if not setting("enabled", true) then
		close_overlay()
		return
	end
	local ww, wh = tg.ui.window_size()
	if not ww then
		return
	end
	if overlay and overlay_scale ~= scale() then
		close_overlay()
	end
	if not overlay then
		open_overlay()
		if not overlay then
			return
		end
	end
	local now = tg.now()
	if cat.bubble and now > cat.bubble_until then
		cat.bubble = nil
	end
	if cat.mode == "walk" or cat.mode == "run" then
		local speed = (cat.mode == "run" and 4 or 1.4) * setting("speed", 2) / 2
		local dx, dy = cat.tx - cat.x, cat.ty - cat.y
		local distance = math.sqrt(dx * dx + dy * dy)
		if distance <= speed then
			cat.x, cat.y = cat.tx, cat.ty
			rest()
		else
			cat.x = cat.x + dx / distance * speed
			cat.y = cat.y + dy / distance * speed
			if math.abs(dx) > 0.5 then
				cat.dir = dx > 0 and 1 or -1
			end
		end
		local step = cat.mode == "run" and 90 or 160
		if now - cat.frame_ms > step then
			cat.frame_ms = now
			cat.frame = 3 - cat.frame
		end
	elseif now > cat.until_ms then
		cat.mode = "walk"
		pick_target()
	end
	-- The window may have become smaller.
	local bw, bh = box_size()
	cat.x = math.max(0, math.min(cat.x, ww - bw))
	cat.y = math.max(0, math.min(cat.y, wh - bh))
	overlay:move{ x = math.floor(cat.x), y = math.floor(cat.y) }
	overlay:update()
end

-- 25 frames a second. Repeating timers are 100 ms at least, so the next
-- frame is planned by the current one; the next is planned first, so a
-- failed frame does not stop the cat.
local function loop()
	tg.timer.after(40, loop)
	tick()
end
loop()

local function call_cat()
	local ww, wh = tg.ui.window_size()
	if not ww then
		return
	end
	local bw, bh = box_size()
	cat.tx = (ww - bw) // 2
	cat.ty = (wh - bh) // 2
	cat.mode = "run"
	say(plugin.t("say.coming"), 1200)
end

local function settings_page()
	return {
		{ type = "header", text = plugin.t("settings.cat") },
		{
			type = "switch",
			key = "enabled",
			text = plugin.t("settings.enabled"),
			icon = "fave",
			default = true,
		},
		{
			type = "input",
			key = "name",
			text = plugin.t("settings.name"),
			placeholder = plugin.t("settings.name.placeholder"),
			icon = "edit",
		},
		{
			type = "selector",
			key = "coat",
			text = plugin.t("settings.coat"),
			items = {
				plugin.t("coat.ginger"),
				plugin.t("coat.grey"),
				plugin.t("coat.black"),
				plugin.t("coat.white"),
				plugin.t("coat.siamese"),
			},
			default = 1,
			icon = "palette",
		},
		{
			type = "slider",
			key = "size",
			text = plugin.t("settings.size"),
			min = 2,
			max = 5,
			step = 1,
			default = 3,
		},
		{
			type = "slider",
			key = "speed",
			text = plugin.t("settings.speed"),
			min = 1,
			max = 5,
			step = 1,
			default = 2,
		},
		{
			type = "custom",
			height = 70,
			paint = function(c)
				-- The cat of the chosen coat, sitting.
				local coat = COATS[setting("coat", 1)] or COATS[1]
				local s = 4
				local w = c:size()
				local ox = (w - SPRITE_W * s) / 2
				for row = 1, SPRITE_H do
					local line = SPRITES.sit[row]
					for col = 1, SPRITE_W do
						local ch = line:sub(col, col)
						if ch ~= "." and coat[ch] then
							c:rect(ox + (col - 1) * s, 14 + (row - 1) * s, s, s, coat[ch])
						end
					end
				end
			end,
		},
		{ type = "header", text = plugin.t("settings.character") },
		{
			type = "switch",
			key = "pettable",
			text = plugin.t("settings.pettable"),
			subtext = plugin.t("settings.pettable.about"),
			icon = "like",
			default = true,
			on_change = close_overlay,
		},
		{
			type = "switch",
			key = "night",
			text = plugin.t("settings.night"),
			subtext = plugin.t("settings.night.about"),
			icon = "night",
			default = true,
		},
		{
			type = "text",
			text = plugin.t("call"),
			icon = "add_user",
			accent = true,
			on_click = call_cat,
		},
	}
end

plugin.settings.page(settings_page)

plugin.menu{
	place = "main",
	text = plugin.t("call"),
	icon = "fave",
	on_click = call_cat,
}
