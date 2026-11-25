-- Pomodoro: a round focus timer over the client window.
-- Work, short break and long break follow each other; a click on the card
-- starts or pauses the timer, the small arrow at the bottom resets the
-- period. The card is drawn on a canvas (tg.ui.overlay) and repaints about
-- once a second, faster only while the ring animates. Texts are in
-- locales/*.json (plugin.t).

local CORNERS = { "bottom-right", "bottom-left", "top-right", "top-left" }
local SIZES = { 120, 150 } -- diameter of the card
local MARGIN = 4 -- room for the shadow around the circle
local WORK, SHORT, LONG = 1, 2, 3
local PHASE_COLORS = { "#e5533d", "#2fa866", "#3d8fe5" }

local overlay
local shown_key -- what the card shows, to repaint only on changes
local shown_frac -- the ring as drawn, eases to the real value
local last_frame = tg.now()
local layout = {} -- hit areas of the last paint

-- Settings.

local function setting(key, default)
	return plugin.settings.get(key, default)
end

local function clamp(x, a, b)
	if x < a then return a elseif x > b then return b end
	return x
end

local function card_size()
	return (SIZES[tonumber(setting("size", 1)) or 1] or SIZES[1]) + 2 * MARGIN
end

local function phase_minutes(phase)
	if phase == SHORT then
		return tonumber(setting("short", 5)) or 5
	elseif phase == LONG then
		return tonumber(setting("long", 15)) or 15
	end
	return tonumber(setting("work", 25)) or 25
end

local function phase_ms(phase)
	return math.floor(phase_minutes(phase) * 60000)
end

local function phase_name(phase)
	if phase == SHORT then
		return plugin.t("phase.short")
	elseif phase == LONG then
		return plugin.t("phase.long")
	end
	return plugin.t("phase.work")
end

-- Pomodoros done today.

local function today()
	return os.date("%Y-%m-%d")
end

local function done_today()
	if setting("done_day", "") ~= today() then
		return 0
	end
	return tonumber(setting("done_count", 0)) or 0
end

local function add_done()
	plugin.settings.set("done_count", done_today() + 1)
	plugin.settings.set("done_day", today())
end

-- The timer. While it runs, `ends` is the tg.now() it ends at; while it
-- is paused, `left` is what is left in ms. `fresh` is a period that was
-- not started yet: it follows the length sliders.

local timer = {
	phase = WORK,
	running = false,
	left = 0,
	ends = 0,
	fresh = true,
	cycle = 0, -- work periods since the last long break
}

local function left_ms()
	if timer.running then
		return math.max(0, timer.ends - tg.now())
	end
	return timer.left
end

-- Kept on every change (not every second), so a restart of the client
-- finds the timer where it was. The end of a running period is kept in
-- wall-clock seconds: the steady clock starts again with the client.
local function save()
	local left = left_ms()
	plugin.settings.set("p_phase", timer.phase)
	plugin.settings.set("p_cycle", timer.cycle)
	plugin.settings.set("p_fresh", timer.fresh)
	plugin.settings.set("p_run", timer.running)
	plugin.settings.set("p_left", math.floor(left))
	if timer.running then
		plugin.settings.set("p_end", os.time() + math.ceil(left / 1000))
	end
end

local function start()
	if timer.left <= 0 then
		timer.left = phase_ms(timer.phase)
	end
	timer.running = true
	timer.fresh = false
	timer.ends = tg.now() + timer.left
end

local function pause()
	timer.left = left_ms()
	timer.running = false
end

local function enter(phase)
	timer.phase = phase
	timer.left = phase_ms(phase)
	timer.fresh = true
	timer.running = false
end

local function notify(title, text)
	pcall(tg.toast, { title = title, text = text, duration = 6000 })
end

-- The period is over: count it, go to the next one and say so. `quiet`
-- is for a period that ended while the client was closed.
local function finish(quiet)
	local ended = timer.phase
	local next_phase = WORK
	if ended == WORK then
		add_done()
		timer.cycle = timer.cycle + 1
		local every = tonumber(setting("every", 4)) or 4
		if timer.cycle >= every then
			next_phase = LONG
			timer.cycle = 0
		else
			next_phase = SHORT
		end
	end
	enter(next_phase)
	local auto = setting("auto_next", false) and not quiet
	if auto then
		start()
	end
	save()
	if quiet then
		return
	end
	local minutes = phase_minutes(next_phase)
	local title, text
	if ended == WORK then
		title = plugin.t("toast.work_done")
		if next_phase == LONG then
			text = plugin.t("toast.long_next", minutes)
		else
			text = plugin.t("toast.short_next", minutes)
		end
	else
		title = plugin.t("toast.break_done")
		text = plugin.t("toast.work_next", minutes)
	end
	if not auto then
		text = text .. " " .. plugin.t("toast.click_to_start")
	end
	notify(title, text)
end

local function toggle()
	if timer.running then
		pause()
	else
		start()
	end
	save()
	shown_key = nil
end

local function reset()
	enter(timer.phase)
	save()
	shown_key = nil
end

-- To the next period without counting this one.
local function skip()
	if timer.phase == WORK then
		enter(SHORT)
	else
		enter(WORK)
	end
	save()
	shown_key = nil
end

local function restore()
	local phase = tonumber(setting("p_phase", WORK)) or WORK
	if phase ~= SHORT and phase ~= LONG then
		phase = WORK
	end
	timer.phase = phase
	timer.cycle = tonumber(setting("p_cycle", 0)) or 0
	timer.fresh = setting("p_fresh", true) ~= false
	local full = phase_ms(phase)
	local left = tonumber(setting("p_left", full)) or full
	if timer.fresh then
		left = full
	end
	timer.left = clamp(left, 0, full)
	timer.running = false
	if setting("p_run", false) then
		local rest = (tonumber(setting("p_end", 0)) or 0) - os.time()
		if rest > 0 then
			timer.left = math.min(rest * 1000, full)
			start()
		else
			finish(true)
		end
	end
end

-- Drawing.

local function with_alpha(color, alpha)
	return string.format("#%02x%s", alpha, color:sub(2))
end

local function time_text(ms)
	local seconds = math.ceil(math.max(ms, 0) / 1000)
	return string.format("%d:%02d", seconds // 60, seconds % 60)
end

-- A part of a ring from the top, clockwise: an annulus sector as one
-- polygon, with round ends.
local function draw_arc(c, cx, cy, outer, inner, frac, color)
	if frac <= 0 then
		return
	end
	if frac >= 0.999 then
		c:circle(cx, cy, outer, color)
		c:circle(cx, cy, inner, "windowBg")
		return
	end
	local steps = math.max(2, math.ceil(frac * 96))
	local start = -math.pi / 2
	local sweep = frac * 2 * math.pi
	local points = {}
	for i = 0, steps do
		local a = start + sweep * i / steps
		points[#points + 1] = cx + outer * math.cos(a)
		points[#points + 1] = cy + outer * math.sin(a)
	end
	for i = steps, 0, -1 do
		local a = start + sweep * i / steps
		points[#points + 1] = cx + inner * math.cos(a)
		points[#points + 1] = cy + inner * math.sin(a)
	end
	c:polygon(points, color)
	local mid = (outer + inner) / 2
	local cap = (outer - inner) / 2
	c:circle(cx + mid * math.cos(start), cy + mid * math.sin(start), cap, color)
	c:circle(cx + mid * math.cos(start + sweep), cy + mid * math.sin(start + sweep), cap, color)
end

-- A counterclockwise arrow: "start over".
local function draw_reset(c, x, y, radius, color, width)
	local from, to = math.rad(-60), math.rad(220)
	local steps = 16
	local px, py
	for i = 0, steps do
		local a = to + (from - to) * i / steps
		local nx, ny = x + radius * math.cos(a), y + radius * math.sin(a)
		if px then
			c:line(px, py, nx, ny, color, width)
		end
		px, py = nx, ny
	end
	-- The head at the end of the arc, pointing the way it goes.
	local ex, ey = x + radius * math.cos(from), y + radius * math.sin(from)
	local tx, ty = math.sin(from), -math.cos(from)
	local nx, ny = math.cos(from), math.sin(from)
	local head = radius * 0.55
	c:polygon({
		ex + tx * head, ey + ty * head,
		ex + nx * head * 0.8, ey + ny * head * 0.8,
		ex - nx * head * 0.8, ey - ny * head * 0.8,
	}, color)
end

local function draw_play(c, x, y, size, color)
	c:polygon({
		x - size * 0.4, y - size * 0.5,
		x - size * 0.4, y + size * 0.5,
		x + size * 0.5, y,
	}, color)
end

local function view_now()
	local full = phase_ms(timer.phase)
	local left = left_ms()
	return {
		phase = timer.phase,
		left = left,
		frac = full > 0 and clamp(left / full, 0, 1) or 0,
		running = timer.running,
		fresh = timer.fresh,
		count = done_today(),
	}
end

local function paint_card(c, view, ring)
	local w, h = c:size()
	local d = math.min(w, h) - 2 * MARGIN
	local s = d / 120
	local cx, cy = w / 2, h / 2
	local r = d / 2
	local color = PHASE_COLORS[view.phase] or PHASE_COLORS[WORK]
	c:opacity(clamp((tonumber(setting("opacity", 100)) or 100) / 100, 0.3, 1))

	-- The card with a soft shadow.
	c:circle(cx, cy + 1, r + 3, "#12000000")
	c:circle(cx, cy + 1, r + 1.5, "#1c000000")
	c:circle(cx, cy, r, "windowBg")

	-- The ring: what is left of the period.
	local outer = r - 5 * s
	local inner = outer - 6 * s
	c:circle(cx, cy, outer, with_alpha(color, 0x38))
	c:circle(cx, cy, inner, "windowBg")
	draw_arc(c, cx, cy, outer, inner, ring or view.frac, color)

	c:text(0, cy - 36 * s, phase_name(view.phase), {
		size = 10 * s,
		bold = true,
		color = color,
		width = w,
		height = 16 * s,
		align = "center",
	})
	c:text(0, cy - 21 * s, time_text(view.left), {
		size = 24 * s,
		bold = true,
		color = view.running and "windowBoldFg" or "windowSubTextFg",
		width = w,
		height = 32 * s,
		align = "center",
	})
	c:text(0, cy + 11 * s, plugin.t("card.today", view.count), {
		size = 10 * s,
		color = "windowSubTextFg",
		width = w,
		height = 16 * s,
		align = "center",
	})

	-- At the bottom: "reset" once the period was started, otherwise a
	-- hint that a click starts it.
	local by = cy + 34 * s
	layout.reset = nil
	if not view.fresh then
		draw_reset(c, cx, by, 6 * s, "windowSubTextFg", 1.8 * s)
		layout.reset = { x = cx - 13 * s, y = by - 12 * s, width = 26 * s, height = 24 * s }
	elseif not view.running then
		draw_play(c, cx + 1, by, 10 * s, with_alpha(color, 0xb0))
	end
end

local function paint(c)
	paint_card(c, view_now(), shown_frac)
end

local function inside(box, x, y)
	return box and x >= box.x and x <= box.x + box.width
		and y >= box.y and y <= box.y + box.height
end

local function click(x, y)
	if inside(layout.reset, x, y) then
		reset()
	else
		toggle()
	end
	if overlay then
		overlay:update()
	end
end

-- The card: where it is. A card put by the mouse keeps the corner it was
-- dropped nearest to, so it stays in its place when the window is resized.

local function close_card()
	if overlay then
		overlay:close()
		overlay = nil
	end
	shown_key = nil
end

local function placement()
	local size = card_size()
	local corner = tonumber(setting("pos_corner", 0)) or 0
	local x, y = 16, 16
	if corner >= 1 and corner <= 4 and setting("draggable", true) then
		x = tonumber(setting("pos_x", 16)) or 16
		y = tonumber(setting("pos_y", 16)) or 16
	else
		corner = tonumber(setting("corner", 3)) or 3
	end
	local ww, wh = tg.ui.window_size()
	if ww then
		x = clamp(x, 0, math.max(ww - size, 0))
		y = clamp(y, 0, math.max(wh - size, 0))
	end
	return {
		corner = CORNERS[corner] or CORNERS[3],
		x = x,
		y = y,
		width = size,
		height = size,
	}
end

local function dropped(x, y)
	local size = card_size()
	local ww, wh = tg.ui.window_size()
	if not ww or not overlay then
		return
	end
	local right = x + size / 2 > ww / 2
	local bottom = y + size / 2 > wh / 2
	local corner = (bottom and 0 or 2) + (right and 1 or 2)
	plugin.settings.set("pos_corner", corner)
	plugin.settings.set("pos_x", math.max(0, math.floor(right and (ww - x - size) or x)))
	plugin.settings.set("pos_y", math.max(0, math.floor(bottom and (wh - y - size) or y)))
	overlay:move(placement())
end

local function open_card()
	local spot = placement()
	local draggable = setting("draggable", true) and true or nil
	spot.paint = paint
	spot.on_click = click
	spot.draggable = draggable
	spot.on_drop = draggable and dropped or nil
	overlay = tg.ui.overlay(spot)
end

-- One frame: returns the ms to the next one.
local function frame()
	local now = tg.now()
	local dt = (now - last_frame) / 1000
	last_frame = now
	if timer.running and timer.ends <= now then
		finish(false)
	end
	if not setting("visible", true) then
		close_card()
		return 1000
	end
	if not overlay then
		open_card()
		if not overlay then
			return 1000 -- no window yet
		end
	end
	local view = view_now()
	-- The ring eases to a new value (a reset, a new period) instead of
	-- jumping; the second-by-second run is small enough to just follow.
	local animating = false
	if not shown_frac then
		shown_frac = view.frac
	end
	local diff = view.frac - shown_frac
	if math.abs(diff) > 0.004 then
		shown_frac = shown_frac + diff * math.min(1, dt * 9)
		animating = true
	else
		shown_frac = view.frac
	end
	local key = table.concat({
		view.phase,
		math.ceil(view.left / 1000),
		tostring(view.running),
		tostring(view.fresh),
		view.count,
		string.format("%.3f", shown_frac),
	}, "|")
	if key ~= shown_key then
		shown_key = key
		overlay:update()
	end
	if animating then
		return 33
	elseif timer.running then
		-- Wake up just after the shown second changes.
		return clamp(math.floor(view.left % 1000) + 15, 50, 1000)
	end
	return 1000
end

-- Repeating timers are 100 ms at least, so each frame plans the next one;
-- a failed frame still plans one, a second later.
local function loop()
	local ok, delay = pcall(frame)
	tg.timer.after(ok and delay or 1000, loop)
	if not ok then
		error(delay, 0)
	end
end

restore()
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
	frame()
end

-- A length slider moved: a period that was not started takes the new
-- length at once.
local function length_changed(phase, minutes)
	minutes = tonumber(minutes)
	if minutes and timer.phase == phase and timer.fresh and not timer.running then
		timer.left = math.floor(minutes * 60000)
		save()
	end
	shown_key = nil
end

local function settings_page()
	return {
		{ type = "header", text = plugin.t("settings.card") },
		{
			type = "switch",
			key = "visible",
			text = plugin.t("settings.visible"),
			subtext = plugin.t("settings.visible.about"),
			icon = "timer",
			default = true,
			on_change = rebuild_card,
		},
		{
			type = "switch",
			key = "draggable",
			text = plugin.t("settings.draggable"),
			subtext = plugin.t("settings.draggable.about"),
			icon = "customize",
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
			default = 3,
			icon = "expand",
			on_change = function()
				-- A chosen corner wins over the place the card was put.
				plugin.settings.set("pos_corner", 0)
				rebuild_card()
			end,
		},
		{
			type = "text",
			text = plugin.t("settings.reset_place"),
			icon = "expand",
			accent = true,
			on_click = function()
				plugin.settings.set("pos_corner", 0)
				rebuild_card()
				pcall(tg.toast, plugin.t("toast.reset_place"))
			end,
		},
		{
			type = "selector",
			key = "size",
			text = plugin.t("settings.size"),
			items = { plugin.t("size.normal"), plugin.t("size.large") },
			default = 1,
			icon = "customize",
			on_change = rebuild_card,
		},
		{
			type = "slider",
			key = "opacity",
			text = plugin.t("settings.opacity"),
			min = 30,
			max = 100,
			step = 5,
			default = 100,
			on_change = function()
				shown_key = nil
			end,
		},
		{
			type = "custom",
			height = card_size() + 30,
			paint = function(c)
				local w = c:size()
				local size = card_size()
				c:text(22, 4, plugin.t("preview.caption"), {
					size = 12,
					color = "windowSubTextFg",
					width = w - 44,
					height = 18,
				})
				local saved = layout
				layout = {}
				paint_card(shifted(c, math.max((w - size) / 2, 0), 26, size, size), view_now())
				layout = saved
			end,
		},
		{ type = "header", text = plugin.t("settings.periods") },
		{
			type = "slider",
			key = "work",
			text = plugin.t("settings.work"),
			min = 5,
			max = 90,
			step = 5,
			default = 25,
			on_change = function(v) length_changed(WORK, v) end,
		},
		{
			type = "slider",
			key = "short",
			text = plugin.t("settings.short"),
			min = 1,
			max = 20,
			step = 1,
			default = 5,
			on_change = function(v) length_changed(SHORT, v) end,
		},
		{
			type = "slider",
			key = "long",
			text = plugin.t("settings.long"),
			min = 5,
			max = 45,
			step = 5,
			default = 15,
			on_change = function(v) length_changed(LONG, v) end,
		},
		{
			type = "slider",
			key = "every",
			text = plugin.t("settings.every"),
			min = 2,
			max = 8,
			step = 1,
			default = 4,
		},
		{
			type = "switch",
			key = "auto_next",
			text = plugin.t("settings.auto_next"),
			subtext = plugin.t("settings.auto_next.about"),
			icon = "restore",
			default = false,
		},
		{ type = "header", text = plugin.t("settings.today") },
		{
			type = "text",
			text = plugin.t("settings.done", done_today()),
			subtext = plugin.t("settings.done.about", timer.cycle,
				tonumber(setting("every", 4)) or 4),
			icon = "stats",
		},
		{
			type = "text",
			text = plugin.t("settings.skip"),
			icon = "forward",
			accent = true,
			on_click = function()
				skip()
				plugin.settings.refresh()
				pcall(tg.toast, plugin.t("toast.skipped", phase_name(timer.phase)))
			end,
		},
		{
			type = "text",
			text = plugin.t("settings.reset_today"),
			icon = "delete",
			red = true,
			on_click = function()
				plugin.settings.set("done_count", 0)
				plugin.settings.set("done_day", today())
				timer.cycle = 0
				save()
				shown_key = nil
				plugin.settings.refresh()
				pcall(tg.toast, plugin.t("toast.reset_today"))
			end,
		},
		{ type = "divider", text = plugin.t("settings.clicks") },
	}
end

plugin.settings.page(settings_page)

plugin.menu{
	place = "main",
	text = plugin.t("menu.toggle"),
	icon = "timer",
	on_click = function()
		local visible = not setting("visible", true)
		plugin.settings.set("visible", visible)
		if visible then
			rebuild_card()
		else
			close_card()
		end
		plugin.settings.refresh()
	end,
}
