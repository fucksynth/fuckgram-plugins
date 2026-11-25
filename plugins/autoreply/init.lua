-- Auto-reply: answers private messages while you are away. It is turned on
-- on the settings page (also opened from the main menu) or with commands:
-- "/away text" turns it on (without a text the previous one is used),
-- "/away 2h text" also turns it off by itself in two hours, "/back" turns
-- it off and tells who wrote meanwhile.
-- It answers only people in private chats, each at most once in "repeat"
-- minutes, and keeps quiet in a chat you yourself wrote to in the last
-- "quiet" minutes.

-- Service accounts look like users, but nobody reads an answer there:
-- 777000 sends login codes and notices, 42777 is its old twin.
local SERVICE = { [777000] = true, [42777] = true }

-- "Turn off by itself": hours for each item of the selector, 0 is never.
local OFF_AFTER = { 0, 1, 3, 8, 24 }

-- Units of "/away 2h text". Russian ones too: the command is typed in
-- whatever layout is on.
local UNITS = {
	m = 60, min = 60, h = 3600, d = 86400,
	["м"] = 60, ["мин"] = 60, ["ч"] = 3600, ["д"] = 86400,
}

-- The "who wrote" list keeps this many people: enough for a day off and
-- small enough for a setting.
local LOG_LIMIT = 50

local repliedAt = {} -- chat id -> when it got the answer
local wroteAt = {} -- chat id -> when you wrote there yourself
local offTimer

local function setting(key, default)
	return plugin.settings.get(key, default)
end

local function enabled()
	return setting("enabled", false)
end

-- Plain ASCII spaces: what %s means depends on the C locale, and a byte of
-- a Cyrillic letter must never be cut off as a "space".
local function trim(text)
	return (text:gsub("^[ \t\r\n]+", ""):gsub("[ \t\r\n]+$", ""))
end

-- 14:05 today, 24.11 14:05 on another day.
local function when(time)
	if os.date("%Y%m%d", time) == os.date("%Y%m%d") then
		return os.date("%H:%M", time)
	end
	return os.date("%d.%m %H:%M", time)
end

local function notify(text, duration)
	tg.toast{ title = plugin.t("title"), text = text, duration = duration }
end

-- The answer: your own text from the settings or the default one in the
-- interface language. "{name}" becomes the first name of the person.
local function replyText(peer)
	local text = setting("text", "")
	if text:match("^%s*$") then
		return plugin.t("reply.default")
	end
	if peer then
		local first = (peer.name or ""):match("^(%S+)") or ""
		-- A function, not a string: "%" in a name must stay as it is.
		text = text:gsub("{name}", function()
			return first
		end)
	end
	return text
end

-- Who wrote while you were away: { id, name, count, time }, kept as JSON
-- in a setting, so a restart of the client does not lose it.
local function loadLog()
	local log = tg.json.decode(setting("log", "[]"))
	return type(log) == "table" and log or {}
end

local function saveLog(log)
	plugin.settings.set("log", tg.json.encode(log))
end

local function remember(peer)
	local log = loadLog()
	for _, entry in ipairs(log) do
		if entry.id == peer.id then
			entry.count = (entry.count or 1) + 1
			entry.name = peer.name
			entry.time = os.time()
			saveLog(log)
			return
		end
	end
	if #log < LOG_LIMIT then
		log[#log + 1] = { id = peer.id, name = peer.name, count = 1, time = os.time() }
		saveLog(log)
	end
end

-- "Ann, Bob, Carl and 2 more"
local function names(log)
	local list = {}
	for i = 1, math.min(#log, 3) do
		list[#list + 1] = log[i].name
	end
	local text = table.concat(list, ", ")
	if #log > 3 then
		text = plugin.t("names.more", { text = text, count = #log - 3 })
	end
	return text
end

local turnOff

-- One timer for "turn off by itself". A day at most per wait, so a long
-- absence never asks the timer for a huge delay; it is set again then.
local function armTimer()
	if offTimer then
		tg.timer.cancel(offTimer)
		offTimer = nil
	end
	local untilTime = setting("until", 0)
	if not enabled() or untilTime <= 0 then
		return
	end
	local left = untilTime - os.time()
	if left <= 0 then
		turnOff("timer")
		return
	end
	offTimer = tg.timer.after(math.min(left, 86400) * 1000, function()
		offTimer = nil
		armTimer()
	end)
end

-- When it should turn off: the time of "/away 2h", else the selector.
local function setUntil(seconds)
	if not seconds then
		local hours = OFF_AFTER[setting("off_after", 1)] or 0
		seconds = hours * 3600
	end
	plugin.settings.set("until", seconds > 0 and os.time() + seconds or 0)
	armTimer()
end

-- Counting starts now: older messages do not count, everyone gets the
-- answer again and the "who wrote" list starts empty.
local function start(seconds)
	plugin.settings.set("since", os.time())
	plugin.settings.set("log", "[]")
	repliedAt = {}
	setUntil(seconds)
end

local function turnOn(text, seconds)
	if text and text ~= "" then
		plugin.settings.set("text", text)
	end
	plugin.settings.set("enabled", true)
	start(seconds)
	plugin.settings.refresh()
	local untilTime = setting("until", 0)
	if untilTime > 0 then
		notify(plugin.t("toast.on_until", { text = replyText(), time = when(untilTime) }))
	else
		notify(plugin.t("toast.on", replyText()))
	end
end

-- reason: "timer" when it turned off by itself, nil for the user.
turnOff = function(reason)
	plugin.settings.set("enabled", false)
	plugin.settings.set("until", 0)
	armTimer()
	plugin.settings.refresh()
	local log = loadLog()
	local head = plugin.t(reason == "timer" and "toast.off_timer" or "toast.off")
	if #log == 0 then
		notify(head .. " " .. plugin.t("toast.nobody"))
	else
		notify(head .. " " .. plugin.t("toast.wrote", { count = #log, names = names(log) }), 6000)
	end
end

-- "2h text" -> 7200, "text"; "text" -> nil, "text".
local function duration(rest)
	local number, unit, body = rest:match("^(%d+)(%S+)%s*(.*)$")
	-- string.lower knows only Latin and may spoil other bytes in some
	-- locales: the exact unit is looked up first.
	local seconds = number and (UNITS[unit] or UNITS[unit:lower()])
	if seconds and tonumber(number) > 0 then
		-- A month at most: longer is surely a typo.
		return math.min(tonumber(number) * seconds, 30 * 86400), body
	end
	return nil, rest
end

plugin.on("message.send", function(draft)
	local text = trim(draft.text)
	if setting("commands", true) then
		local rest = (text == "/away") and "" or text:match("^/away%s+(.*)$")
		if rest then
			local seconds, body = duration(rest)
			turnOn(body, seconds)
			return false
		elseif text == "/back" then
			turnOff()
			return false
		end
	end
	wroteAt[draft.peer] = os.time()
	-- Only this client sends through here: a message from the phone does
	-- not mean you are back at the computer.
	if enabled() and setting("off_on_send", false) then
		turnOff()
	end
	return nil
end)

plugin.on("message.new", function(msg)
	if not enabled() or msg.out or msg.peer <= 0 or msg.from ~= msg.peer
		or SERVICE[msg.peer] then
		return
	end
	local now = os.time()
	-- The timer may be late after sleep: the time is what counts.
	local untilTime = setting("until", 0)
	if untilTime > 0 and now >= untilTime then
		turnOff("timer")
		return
	end
	-- Old messages loaded after a reconnection do not count.
	if msg.date < setting("since", now) or now - msg.date > 300 then
		return
	end
	local peer = tg.peers.get(msg.peer)
	if not peer or peer.type ~= "user" or peer.is_self then
		return
	end
	remember(peer)
	local repeatSeconds = setting("repeat", 30) * 60
	local quietSeconds = setting("quiet", 10) * 60
	if (repliedAt[msg.peer] or 0) > now - repeatSeconds
		or (wroteAt[msg.peer] or 0) > now - quietSeconds then
		return
	end
	repliedAt[msg.peer] = now
	tg.messages.send(msg.peer, replyText(peer), {
		reply_to = setting("reply_to", true) and msg.id or nil,
	})
end)

local function logPage()
	local log = loadLog()
	local rows = { title = plugin.t("log.title") }
	if #log == 0 then
		rows[#rows + 1] = { type = "text", text = plugin.t("log.empty"), icon = "info" }
		return rows
	end
	rows[#rows + 1] = { type = "header", text = plugin.t("log.header", #log) }
	-- The latest first: they are the ones waiting for you right now.
	table.sort(log, function(a, b)
		return (a.time or 0) > (b.time or 0)
	end)
	for _, entry in ipairs(log) do
		local id = entry.id
		rows[#rows + 1] = {
			type = "text",
			text = entry.name or tostring(id),
			subtext = plugin.t("log.entry", { count = entry.count or 1, time = when(entry.time or 0) }),
			icon = "user",
			on_click = function()
				tg.ui.open(id)
			end,
		}
	end
	rows[#rows + 1] = { type = "divider", text = plugin.t("log.about") }
	rows[#rows + 1] = {
		type = "text",
		text = plugin.t("log.clear"),
		icon = "delete",
		red = true,
		on_click = function()
			plugin.settings.set("log", "[]")
			plugin.settings.refresh()
		end,
	}
	return rows
end

local function settingsPage()
	local untilTime = setting("until", 0)
	local status = plugin.t("settings.enabled.about")
	if enabled() and untilTime > 0 then
		status = plugin.t("settings.enabled.until", when(untilTime))
	end
	local log = loadLog()
	return {
		{ type = "header", text = plugin.t("settings.reply") },
		{
			type = "switch",
			key = "enabled",
			text = plugin.t("settings.enabled"),
			subtext = status,
			icon = "chat",
			default = false,
			on_change = function(on)
				if on then
					start()
				else
					plugin.settings.set("until", 0)
					armTimer()
				end
				plugin.settings.refresh()
			end,
		},
		{
			type = "input",
			key = "text",
			text = plugin.t("settings.text"),
			subtext = plugin.t("settings.text.about"),
			placeholder = plugin.t("reply.default"),
			icon = "edit",
		},
		{
			type = "switch",
			key = "reply_to",
			text = plugin.t("settings.reply_to"),
			subtext = plugin.t("settings.reply_to.about"),
			icon = "reply",
			default = true,
		},
		{ type = "header", text = plugin.t("settings.turning_off") },
		{
			type = "selector",
			key = "off_after",
			text = plugin.t("settings.off_after"),
			items = {
				plugin.t("settings.off_after.never"),
				plugin.t("hours", 1),
				plugin.t("hours", 3),
				plugin.t("hours", 8),
				plugin.t("hours", 24),
			},
			default = 1,
			icon = "timer",
			on_change = function()
				-- While it is on, the new time counts from now.
				if enabled() then
					setUntil()
				end
				plugin.settings.refresh()
			end,
		},
		{
			type = "switch",
			key = "off_on_send",
			text = plugin.t("settings.off_on_send"),
			subtext = plugin.t("settings.off_on_send.about"),
			icon = "send",
			default = false,
		},
		{ type = "header", text = plugin.t("settings.how_often") },
		{
			type = "slider",
			key = "repeat",
			text = plugin.t("settings.repeat"),
			subtext = plugin.t("settings.repeat.about", setting("repeat", 30)),
			icon = "hourglass",
			min = 5,
			max = 240,
			step = 5,
			default = 30,
			on_change = function()
				plugin.settings.refresh()
			end,
		},
		{
			type = "slider",
			key = "quiet",
			text = plugin.t("settings.quiet"),
			subtext = plugin.t("settings.quiet.about", setting("quiet", 10)),
			icon = "silent",
			min = 0,
			max = 120,
			step = 5,
			default = 10,
			on_change = function()
				plugin.settings.refresh()
			end,
		},
		{ type = "header", text = plugin.t("settings.away") },
		{
			type = "text",
			text = plugin.t("settings.log"),
			subtext = #log > 0
				and plugin.t("toast.wrote", { count = #log, names = names(log) })
				or plugin.t("log.empty"),
			icon = "users",
			page = logPage,
		},
		{ type = "header", text = plugin.t("settings.commands") },
		{
			type = "switch",
			key = "commands",
			text = plugin.t("settings.commands.switch"),
			subtext = plugin.t("settings.commands.about"),
			icon = "code",
			default = true,
		},
		{ type = "divider", text = plugin.t("settings.who") },
	}
end

plugin.settings.page(settingsPage)

plugin.menu{
	place = "main",
	text = plugin.t("title"),
	icon = "chat",
	page = settingsPage,
}

-- The time may have passed while the client was closed.
function on_enable()
	armTimer()
end
