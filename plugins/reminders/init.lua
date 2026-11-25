-- Reminders: "/remind 10m buy milk", "/remind 18:30 call mom",
-- "/remind tomorrow 9:00 dentist". The command never reaches the chat.
-- At the time a window (or a toast) shows the reminder and, if chosen in
-- the settings, a message goes to Saved Messages. Reminders are kept in
-- a file, so they survive a restart; the ones missed while the client was
-- closed are shown at the next start.

local FILE = "reminders.json"
local MAX_DELAY = 30000 -- ms: the next check is never further than this
local SCHEDULE_MIN = 30 -- s: closer reminders are not scheduled in Telegram

local state = { next = 1, items = {} }
local timer = nil

-- Lowercase for ASCII and Cyrillic (string.lower knows only ASCII).
local function lower(text)
	local ok, result = pcall(function()
		local out = {}
		for _, c in utf8.codes(text) do
			if c >= 0x41 and c <= 0x5A then
				c = c + 32
			elseif c >= 0x410 and c <= 0x42F then
				c = c + 32
			elseif c >= 0x400 and c <= 0x40F then
				c = c + 80
			end
			out[#out + 1] = utf8.char(c)
		end
		return table.concat(out)
	end)
	if ok then
		return result
	end
	return (text:gsub("[A-Z]", function(c)
		return string.char(c:byte() + 32)
	end))
end

-- First `limit` characters of a one-line text.
local function short(text, limit)
	text = text:gsub("%s+", " ")
	local length = utf8.len(text)
	if length and length > limit then
		return text:sub(1, utf8.offset(text, limit + 1) - 1) .. "…"
	end
	return text
end

-- Storage ------------------------------------------------------------------

local function loadState()
	local raw = plugin.files.read(FILE)
	if not raw then
		return
	end
	local data = tg.json.decode(raw)
	if type(data) ~= "table" then
		return
	end
	local items = {}
	local maxId = 0
	if type(data.items) == "table" then
		for _, item in ipairs(data.items) do
			if type(item) == "table" and type(item.at) == "number"
				and type(item.text) == "string" and type(item.id) == "number" then
				local id = math.floor(item.id)
				items[#items + 1] = {
					id = id,
					at = math.floor(item.at),
					text = item.text,
					peer = type(item.peer) == "number" and math.floor(item.peer) or nil,
					scheduled = item.scheduled == true,
				}
				maxId = math.max(maxId, id)
			end
		end
	end
	state.items = items
	state.next = math.max(type(data.next) == "number" and math.floor(data.next) or 1, maxId + 1)
end

local function saveState()
	plugin.files.write(FILE, tg.json.encode({ next = state.next, items = state.items }))
end

local function sorted()
	local list = {}
	for _, item in ipairs(state.items) do
		list[#list + 1] = item
	end
	table.sort(list, function(a, b)
		if a.at == b.at then
			return a.id < b.id
		end
		return a.at < b.at
	end)
	return list
end

local function removeById(id)
	for index, item in ipairs(state.items) do
		if item.id == id then
			table.remove(state.items, index)
			return item
		end
	end
	return nil
end

-- Formatting ---------------------------------------------------------------

local function dayNumber(time)
	local d = os.date("*t", time)
	return os.time({ year = d.year, month = d.month, day = d.day, hour = 12 })
end

-- "today 18:30", "tomorrow 09:00", "25.12 10:00", "25.12.2027 10:00".
local function formatWhen(at)
	local now = os.time()
	local clock = os.date("%H:%M", at)
	local days = math.floor((dayNumber(at) - dayNumber(now)) / 86400 + 0.5)
	if days == 0 then
		return plugin.t("when.today", clock)
	elseif days == 1 then
		return plugin.t("when.tomorrow", clock)
	elseif days == -1 then
		return plugin.t("when.yesterday", clock)
	elseif os.date("%Y", at) == os.date("%Y", now) then
		return plugin.t("when.date", os.date("%d.%m", at), clock)
	end
	return plugin.t("when.date", os.date("%d.%m.%Y", at), clock)
end

-- "in 2 h 5 min".
local function formatIn(seconds)
	if seconds < 60 then
		return plugin.t("in.soon")
	end
	local minutes = math.floor(seconds / 60 + 0.5)
	local days = minutes // 1440
	local hours = (minutes % 1440) // 60
	local rest = minutes % 60
	local parts = {}
	if days > 0 then
		parts[#parts + 1] = plugin.t("unit.d", days)
	end
	if hours > 0 then
		parts[#parts + 1] = plugin.t("unit.h", hours)
	end
	if rest > 0 and days == 0 then
		parts[#parts + 1] = plugin.t("unit.m", rest)
	end
	return plugin.t("in", table.concat(parts, " "))
end

-- Parsing "when" -------------------------------------------------------------

local UNITS = {
	s = 1, sec = 1, secs = 1, second = 1, seconds = 1,
	["с"] = 1, ["сек"] = 1, ["секунда"] = 1, ["секунду"] = 1, ["секунды"] = 1, ["секунд"] = 1,
	m = 60, min = 60, mins = 60, minute = 60, minutes = 60,
	["м"] = 60, ["мин"] = 60, ["минута"] = 60, ["минуту"] = 60, ["минуты"] = 60, ["минут"] = 60,
	h = 3600, hr = 3600, hrs = 3600, hour = 3600, hours = 3600,
	["ч"] = 3600, ["час"] = 3600, ["часа"] = 3600, ["часов"] = 3600,
	d = 86400, day = 86400, days = 86400,
	["д"] = 86400, ["дн"] = 86400, ["день"] = 86400, ["дня"] = 86400, ["дней"] = 86400,
	w = 604800, week = 604800, weeks = 604800,
	["нед"] = 604800, ["неделя"] = 604800, ["неделю"] = 604800, ["недели"] = 604800, ["недель"] = 604800,
}

local function unitOf(word)
	if not word then
		return nil
	end
	return UNITS[(word:gsub("[%.,]$", ""))]
end

-- "10m", "1h30m", "10мин" -> seconds.
local function durationToken(word)
	local total, rebuilt = 0, ""
	for number, unit in word:gmatch("(%d+)(%D+)") do
		local seconds = unitOf(unit)
		if not seconds then
			return nil
		end
		total = total + tonumber(number) * seconds
		rebuilt = rebuilt .. number .. unit
	end
	if rebuilt ~= word or total == 0 then
		return nil
	end
	return total
end

-- "18:30", "9am", "6:15pm", and a bare "9" when allowed -> hour, minute.
local function parseClock(word, allowBare)
	if not word then
		return nil
	end
	word = word:gsub("[%.,]$", "")
	local hour, minute, suffix = word:match("^(%d%d?):(%d%d)([a-z]*)$")
	if not hour then
		hour, suffix = word:match("^(%d%d?)([ap]m)$")
		minute = "0"
	end
	if not hour and allowBare then
		hour = word:match("^(%d%d?)$")
		minute, suffix = "0", ""
	end
	if not hour then
		return nil
	end
	hour, minute = tonumber(hour), tonumber(minute)
	if suffix == "pm" then
		if hour > 12 then return nil end
		if hour < 12 then hour = hour + 12 end
	elseif suffix == "am" then
		if hour > 12 then return nil end
		if hour == 12 then hour = 0 end
	elseif suffix ~= "" then
		return nil
	end
	if hour > 23 or minute > 59 then
		return nil
	end
	return hour, minute
end

local function tokenize(text)
	local list = {}
	local position = 1
	while true do
		local from, word, to = text:match("^%s*()(%S+)()", position)
		if not from then
			break
		end
		list[#list + 1] = { low = lower(word), from = from }
		position = to
	end
	return list
end

-- Returns the unixtime and the rest of the text, or nil and an error key.
local function parseWhen(text)
	local now = os.time()
	local list = tokenize(text)
	local i = 1
	local function word(shift)
		local token = list[i + (shift or 0)]
		return token and token.low
	end
	local function rest()
		local token = list[i]
		if not token then
			return ""
		end
		return (text:sub(token.from):gsub("%s+$", ""))
	end

	-- In 10 minutes, через 2 часа, 1h30m, 2 days.
	local relative = false
	if word() == "in" or word() == "через" then
		relative = true
		i = i + 1
	end
	local total = 0
	while list[i] do
		local w = word()
		local seconds = durationToken(w)
		if seconds then
			total = total + seconds
			i = i + 1
		elseif w:match("^%d+$") and unitOf(word(1)) then
			total = total + tonumber(w) * unitOf(word(1))
			i = i + 2
		elseif relative and total == 0 and (w == "a" or w == "an") and unitOf(word(1)) then
			total = unitOf(word(1))
			i = i + 2
		elseif relative and total == 0 and w == "полчаса" then
			total = 1800
			i = i + 1
		elseif relative and total == 0 and #w > 1 and unitOf(w) then
			total = unitOf(w)
			i = i + 1
		elseif total > 0 and (w == "and" or w == "и")
			and (durationToken(word(1) or "") or (word(1) or ""):match("^%d+$")) then
			i = i + 1
		else
			break
		end
	end
	if total > 0 then
		return now + total, rest()
	elseif relative then
		return nil, "error.when"
	end

	-- Today / tomorrow / 25.12[.2026], then [at] 18:30.
	local today = os.date("*t", now)
	local date = { year = today.year, month = today.month, day = today.day }
	local dayGiven, dateGiven, yearGiven = false, false, false
	local w = word()
	if w == "today" or w == "сегодня" then
		dayGiven = true
		i = i + 1
	elseif w == "tomorrow" or w == "завтра" then
		date.day = date.day + 1
		dayGiven = true
		i = i + 1
	elseif w == "послезавтра" then
		date.day = date.day + 2
		dayGiven = true
		i = i + 1
	elseif w then
		local day, month, year = w:match("^(%d%d?)%.(%d%d?)%.?(%d*)$")
		day, month = tonumber(day), tonumber(month)
		if day and month and month >= 1 and month <= 12 and day >= 1 and day <= 31
			and (year == "" or #year == 2 or #year == 4) then
			date.day, date.month = day, month
			if year ~= "" then
				date.year = (#year == 2) and (2000 + tonumber(year)) or tonumber(year)
				yearGiven = true
			end
			dayGiven, dateGiven = true, true
			i = i + 1
		end
	end

	local hour, minute
	w = word()
	if (w == "at" or w == "в" or w == "во" or w == "@") and parseClock(word(1), true) then
		hour, minute = parseClock(word(1), true)
		i = i + 2
	else
		hour, minute = parseClock(w, dayGiven)
		if hour then
			i = i + 1
		end
	end
	if not hour then
		if not dayGiven then
			return nil, "error.when"
		end
		hour, minute = math.floor(plugin.settings.get("morning", 9)), 0
	end

	local function make()
		return os.time({
			year = date.year, month = date.month, day = date.day,
			hour = hour, min = minute, sec = 0,
		})
	end
	local at = make()
	if at <= now then
		if not dayGiven then
			date.day = date.day + 1
			at = make()
		elseif dateGiven and not yearGiven then
			date.year = date.year + 1
			at = make()
		end
	end
	if at <= now then
		return nil, "error.past"
	end
	return at, rest()
end

-- Saved Messages -------------------------------------------------------------

local function savedMode()
	return plugin.settings.get("saved", 1)
end

local function sendToSaved(text, schedule)
	local me = tg.me()
	if not me then
		tg.log("reminders: no account to send to Saved Messages")
		return false
	end
	local options = nil
	if schedule then
		options = { schedule = schedule }
	end
	return tg.messages.send(me.id, "⏰ " .. text, options)
end

-- Timer ------------------------------------------------------------------------

local tick

local function plan()
	if timer then
		tg.timer.cancel(timer)
		timer = nil
	end
	local nextAt = nil
	for _, item in ipairs(state.items) do
		if not nextAt or item.at < nextAt then
			nextAt = item.at
		end
	end
	if not nextAt then
		return
	end
	local delay = (nextAt - os.time()) * 1000
	delay = math.max(250, math.min(delay, MAX_DELAY))
	timer = tg.timer.after(math.floor(delay), tick)
end

local function changed()
	saveState()
	plan()
	plugin.settings.refresh()
end

-- Adds a reminder; with "schedule in Telegram" also schedules the message.
local function add(at, text, peer)
	if text == nil or text:match("^%s*$") then
		text = plugin.t("default_text")
	end
	local item = { id = state.next, at = at, text = text, peer = peer, scheduled = false }
	state.next = state.next + 1
	state.items[#state.items + 1] = item
	if savedMode() == 3 and at - os.time() >= SCHEDULE_MIN then
		item.scheduled = true
		-- Not from inside the send filter: on the next turn of the loop.
		tg.timer.after(0, function()
			if not sendToSaved(text, at) then
				item.scheduled = false
				saveState()
			end
		end)
	end
	changed()
	return item
end

local function confirmAdded(item)
	tg.toast({
		title = plugin.t("toast.added"),
		text = formatWhen(item.at) .. " (" .. formatIn(item.at - os.time()) .. ")\n"
			.. short(item.text, 120),
	})
end

-- Showing ------------------------------------------------------------------------

local function describe(item, now, many)
	local line = many and ("• " .. short(item.text, 200)) or item.text
	if now - item.at > 120 then
		line = line .. "\n" .. plugin.t("late", formatWhen(item.at))
	elseif many then
		line = line .. " (" .. os.date("%H:%M", item.at) .. ")"
	end
	return line
end

local function show(due)
	local now = os.time()
	local lines = {}
	for _, item in ipairs(due) do
		lines[#lines + 1] = describe(item, now, #due > 1)
	end
	local text = table.concat(lines, "\n")
	local title = "⏰ " .. plugin.t("title")
	if plugin.settings.get("show", 1) == 2 then
		tg.toast({ title = title, text = text, duration = 30000 })
		return
	end
	local peer = (#due == 1) and due[1].peer or nil
	local buttons = {
		plugin.t("button.ok"),
		plugin.t("button.snooze10"),
		peer and plugin.t("button.open") or plugin.t("button.snooze60"),
	}
	tg.async(function()
		local chosen = tg.ui.dialog({ title = title, text = text, buttons = buttons })
		if chosen == 2 or (chosen == 3 and not peer) then
			local delay = (chosen == 2) and 600 or 3600
			for _, item in ipairs(due) do
				add(os.time() + delay, item.text, item.peer)
			end
			tg.toast({ title = plugin.t("title"), text = plugin.t("toast.snoozed", formatIn(delay)) })
		elseif chosen == 3 and peer then
			tg.ui.open(peer)
		end
	end)
end

tick = function()
	timer = nil
	local now = os.time()
	local due = {}
	local index = 1
	while index <= #state.items do
		local item = state.items[index]
		if item.at <= now then
			due[#due + 1] = item
			table.remove(state.items, index)
		else
			index = index + 1
		end
	end
	if #due > 0 then
		table.sort(due, function(a, b) return a.at < b.at end)
		changed()
		if savedMode() ~= 1 then
			for _, item in ipairs(due) do
				if not item.scheduled then
					sendToSaved(item.text, nil)
				end
			end
		end
		show(due)
	else
		plan()
	end
end

-- Deleting and listing --------------------------------------------------------------

local function askDelete(item)
	tg.async(function()
		local text = formatWhen(item.at) .. "\n" .. item.text
		if item.scheduled then
			text = text .. "\n\n" .. plugin.t("delete.scheduled")
		end
		local yes = tg.ui.confirm({
			title = plugin.t("delete.title"),
			text = text,
			ok = plugin.t("delete.ok"),
			cancel = plugin.t("button.cancel"),
		})
		if yes and removeById(item.id) then
			changed()
		end
	end)
end

local function showList()
	local list = sorted()
	if #list == 0 then
		tg.toast({ title = plugin.t("title"), text = plugin.t("list.empty") })
		return
	end
	local items = {}
	for index, item in ipairs(list) do
		items[index] = formatWhen(item.at) .. " — " .. short(item.text, 60)
	end
	tg.async(function()
		local chosen = tg.ui.dialog({
			title = plugin.t("list.title", #list),
			text = plugin.t("list.about"),
			items = items,
		})
		if chosen and list[chosen] then
			askDelete(list[chosen])
		end
	end)
end

local function usage()
	tg.toast({ title = plugin.t("title"), text = plugin.t("usage"), duration = 8000 })
end

local function failed(error)
	tg.toast({
		title = plugin.t("title"),
		text = plugin.t(error) .. "\n" .. plugin.t("usage"),
		duration = 8000,
	})
end

-- Asks "when" (and the text) in a box; `text` is used when nothing else is typed.
local function addWithInput(peer, text)
	tg.async(function()
		local value = tg.ui.input({
			title = plugin.t("input.title"),
			text = text and plugin.t("input.about_message") or plugin.t("input.about"),
			placeholder = plugin.t("input.placeholder"),
			ok = plugin.t("input.ok"),
			cancel = plugin.t("button.cancel"),
		})
		if not value or value:match("^%s*$") then
			return
		end
		local at, rest = parseWhen(value)
		if not at then
			failed(rest)
			return
		end
		if rest == "" and text then
			rest = text
		end
		confirmAdded(add(at, rest, peer))
	end)
end

-- Commands ------------------------------------------------------------------------

local REMIND = { ["/remind"] = true, ["/напомни"] = true }
local LIST = { ["/reminders"] = true, ["/напоминания"] = true }

plugin.on("message.send", function(draft)
	local command, args = draft.text:match("^(/%S+)%s*(.*)$")
	if not command then
		return nil
	end
	command = lower(command)
	if LIST[command] and args == "" then
		showList()
		return false
	elseif not REMIND[command] then
		return nil
	end
	if args:match("^%s*$") then
		usage()
		return false
	end
	local at, rest = parseWhen(args)
	if not at then
		failed(rest)
		return false
	end
	confirmAdded(add(at, rest, draft.peer))
	return false
end)

plugin.menu({
	place = "message",
	text = plugin.t("menu.message"),
	icon = "timer",
	on_click = function(ctx)
		local text = ctx.message and ctx.message.text or ""
		if text:match("^%s*$") then
			text = nil
		else
			text = short(text, 300)
		end
		addWithInput(ctx.peer, text)
	end,
})

-- Settings page -----------------------------------------------------------------------

local function settingsPage()
	local rows = {
		title = plugin.t("title"),
		{ type = "header", text = plugin.t("settings.upcoming") },
	}
	local list = sorted()
	if #list == 0 then
		rows[#rows + 1] = {
			type = "text",
			text = plugin.t("list.empty"),
			subtext = plugin.t("settings.empty.about"),
			icon = "info",
		}
	end
	for _, item in ipairs(list) do
		rows[#rows + 1] = {
			type = "text",
			text = short(item.text, 80),
			subtext = formatWhen(item.at) .. " · " .. formatIn(item.at - os.time()),
			icon = "timer",
			on_click = function()
				askDelete(item)
			end,
		}
	end
	rows[#rows + 1] = {
		type = "text",
		text = plugin.t("settings.add"),
		icon = "add",
		accent = true,
		on_click = function()
			addWithInput(nil, nil)
		end,
	}
	if #list > 1 then
		rows[#rows + 1] = {
			type = "text",
			text = plugin.t("settings.clear"),
			icon = "delete",
			red = true,
			on_click = function()
				tg.async(function()
					local yes = tg.ui.confirm({
						title = plugin.t("settings.clear"),
						text = plugin.t("settings.clear.about", #state.items),
						ok = plugin.t("delete.ok"),
						cancel = plugin.t("button.cancel"),
					})
					if yes then
						state.items = {}
						changed()
					end
				end)
			end,
		}
	end
	rows[#rows + 1] = { type = "divider", text = plugin.t("settings.tap") }

	rows[#rows + 1] = { type = "header", text = plugin.t("settings.how") }
	rows[#rows + 1] = {
		type = "selector",
		key = "show",
		text = plugin.t("settings.show"),
		items = { plugin.t("settings.show.window"), plugin.t("settings.show.toast") },
		default = 1,
		icon = "bell",
	}
	rows[#rows + 1] = {
		type = "selector",
		key = "saved",
		text = plugin.t("settings.saved"),
		items = {
			plugin.t("settings.saved.off"),
			plugin.t("settings.saved.time"),
			plugin.t("settings.saved.schedule"),
		},
		default = 1,
		icon = "saved",
	}
	rows[#rows + 1] = { type = "divider", text = plugin.t("settings.saved.about") }
	rows[#rows + 1] = {
		type = "slider",
		key = "morning",
		text = plugin.t("settings.morning"),
		subtext = plugin.t("settings.morning.about", math.floor(plugin.settings.get("morning", 9))),
		icon = "night",
		min = 5,
		max = 12,
		step = 1,
		default = 9,
		on_change = function()
			plugin.settings.refresh()
		end,
	}
	rows[#rows + 1] = { type = "divider", text = plugin.t("settings.commands") }
	return rows
end

plugin.settings.page(settingsPage)

plugin.menu({
	place = "main",
	text = plugin.t("title"),
	icon = "timer",
	page = settingsPage,
})

function on_disable()
	if timer then
		tg.timer.cancel(timer)
		timer = nil
	end
end

loadState()
-- The first check a bit after the start: missed reminders are shown then.
timer = tg.timer.after(3000, tick)
