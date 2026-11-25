-- Keyboard layout: "ghbdtn" -> "привет", "руддщ" -> "hello". By default the
-- plugin picks the direction itself: the letters the text has more of are
-- the wrong ones. It works on the message field (chat menu, the send
-- button menu, "/fix text") and on messages: your own one is fixed in
-- place, someone else's is shown and copied.

local EN = "`qwertyuiop[]asdfghjkl;'zxcvbnm,./~QWERTYUIOP{}ASDFGHJKL:\"ZXCVBNM<>?@#$^&|"
local RU = "ёйцукенгшщзхъфывапролджэячсмитьбю.ЁЙЦУКЕНГШЩЗХЪФЫВАПРОЛДЖЭЯЧСМИТЬБЮ,\"№;:?/"

local function chars(text)
	local result = {}
	for _, c in utf8.codes(text) do
		result[#result + 1] = utf8.char(c)
	end
	return result
end

local EN_TO_RU, RU_TO_EN = {}, {}
do
	local en, ru = chars(EN), chars(RU)
	for i = 1, #en do
		EN_TO_RU[en[i]] = ru[i]
		-- The point, the comma and the quote are in both layouts: the way
		-- back takes the first match, so "ю." -> "./".
		if RU_TO_EN[ru[i]] == nil then
			RU_TO_EN[ru[i]] = en[i]
		end
	end
end

local function setting(key, default)
	return plugin.settings.get(key, default)
end

local function notify(text)
	tg.toast{ title = plugin.t("title"), text = text }
end

-- Latin and Cyrillic letters in the text.
local function count(text)
	local latin, cyrillic = 0, 0
	for _, c in utf8.codes(text) do
		if (c >= 65 and c <= 90) or (c >= 97 and c <= 122) then
			latin = latin + 1
		elseif (c >= 0x410 and c <= 0x44F) or c == 0x401 or c == 0x451 then
			cyrillic = cyrillic + 1
		end
	end
	return latin, cyrillic
end

-- The map to apply: the direction from the settings, or by the letters.
local function mapFor(text)
	local direction = setting("direction", 1)
	if direction == 2 then
		return EN_TO_RU
	elseif direction == 3 then
		return RU_TO_EN
	end
	local latin, cyrillic = count(text)
	if latin == 0 and cyrillic == 0 then
		return nil
	end
	return (latin >= cyrillic) and EN_TO_RU or RU_TO_EN
end

local function apply(text, map)
	local result = {}
	for _, char in ipairs(chars(text)) do
		result[#result + 1] = map[char] or char
	end
	return table.concat(result)
end

-- Links, addresses and @usernames are pasted rather than typed, so they
-- are in the right layout already.
local function keep(word)
	return word:match("^https?://") or word:match("^www%.") or word:match("^t%.me/")
		or word:match("^@[A-Za-z0-9_]+[%.,!%?:;]*$")
		or word:match("^[A-Za-z0-9._%%+%-]+@[A-Za-z0-9%-]+%.[A-Za-z0-9.%-]+$")
end

-- The text in the other layout, or nil when there is nothing to change.
-- The direction is chosen once for the whole text: "ghbdtn @ann rfr ns"
-- must not flip between the pieces around the name.
local function fix(text)
	if not text or not utf8.len(text) then
		return nil
	end
	local pieces = {} -- { text, keep }
	if setting("keep_links", true) then
		local last = 1
		for start, word, finish in text:gmatch("()([^ \t\r\n]+)()") do
			if keep(word) then
				pieces[#pieces + 1] = { text:sub(last, start - 1), false }
				pieces[#pieces + 1] = { word, true }
				last = finish
			end
		end
		pieces[#pieces + 1] = { text:sub(last), false }
	else
		pieces[1] = { text, false }
	end
	local sample = {}
	for _, piece in ipairs(pieces) do
		if not piece[2] then
			sample[#sample + 1] = piece[1]
		end
	end
	local map = mapFor(table.concat(sample, " "))
	if not map then
		return nil
	end
	local result = {}
	for _, piece in ipairs(pieces) do
		result[#result + 1] = piece[2] and piece[1] or apply(piece[1], map)
	end
	local fixed = table.concat(result)
	return fixed ~= text and fixed or nil
end

-- Shows and copies the fixed text of a message that is not yours.
local function showFixed(fixed)
	tg.ui.copy(fixed)
	if setting("show_result", true) then
		tg.ui.alert(fixed, plugin.t("dialog.copied"))
	else
		notify(plugin.t("toast.copied"))
	end
end

plugin.menu{
	place = "chat",
	text = plugin.t("menu.field"),
	icon = "edit",
	on_click = function()
		local text = tg.compose.get()
		if not text or text == "" then
			notify(plugin.t("toast.empty_field"))
			return
		end
		local fixed = fix(text)
		if not fixed then
			notify(plugin.t("toast.nothing"))
			return
		end
		tg.compose.set(fixed)
	end,
}

-- Right click on the send button: what you typed goes in the other layout
-- at once, without fixing the field first.
plugin.menu{
	place = "send",
	text = plugin.t("menu.send"),
	icon = "send",
	on_click = function(ctx)
		local text = tg.compose.get()
		if not text or text == "" then
			notify(plugin.t("toast.empty_field"))
			return
		end
		local fixed = fix(text)
		if not fixed then
			notify(plugin.t("toast.nothing"))
			return
		end
		if ctx.peer and tg.messages.send(ctx.peer, fixed) then
			tg.compose.set("")
		end
	end,
}

plugin.menu{
	place = "message",
	text = plugin.t("menu.message"),
	icon = "translate",
	on_click = function(ctx)
		local message = ctx.message
		local text = message and message.text
		if not text or text == "" then
			notify(plugin.t("toast.no_text"))
			return
		end
		local fixed = fix(text)
		if not fixed then
			notify(plugin.t("toast.nothing"))
			return
		end
		-- Your own message is fixed where it is; when it can't be edited
		-- any more (too old, say), the text is copied as for others.
		local peer = ctx.peer or message.peer
		if message.out and setting("edit_own", true) and peer
			and tg.messages.edit(peer, message.id, fixed) then
			notify(plugin.t("toast.edited"))
			return
		end
		showFixed(fixed)
	end,
}

-- "/fix ghbdtn" is sent as "привет".
plugin.on("message.send", function(draft)
	if not setting("fix_command", true) then
		return nil
	end
	if draft.text:match("^/fix[ \t\r\n]*$") then
		notify(plugin.t("toast.usage"))
		return false
	end
	local text = draft.text:match("^/fix[ \t\r\n]+(.+)$")
	if not text then
		return nil
	end
	return fix(text) or text
end)

plugin.settings.page(function()
	return {
		{ type = "header", text = plugin.t("settings.header") },
		{
			type = "selector",
			key = "direction",
			text = plugin.t("settings.direction"),
			items = {
				plugin.t("settings.direction.auto"),
				plugin.t("settings.direction.ru"),
				plugin.t("settings.direction.en"),
			},
			default = 1,
			icon = "translate",
		},
		{
			type = "switch",
			key = "keep_links",
			text = plugin.t("settings.keep_links"),
			subtext = plugin.t("settings.keep_links.about"),
			icon = "link",
			default = true,
		},
		{
			type = "text",
			text = plugin.t("settings.try"),
			subtext = plugin.t("settings.try.about"),
			icon = "edit",
			on_click = function()
				tg.async(function()
					local typed = tg.ui.input{
						title = plugin.t("settings.try"),
						placeholder = "ghbdtn",
					}
					if not typed or typed == "" then
						return
					end
					local fixed = fix(typed)
					if fixed then
						showFixed(fixed)
					else
						notify(plugin.t("toast.nothing"))
					end
				end)
			end,
		},
		{ type = "header", text = plugin.t("settings.where") },
		{
			type = "switch",
			key = "edit_own",
			text = plugin.t("settings.edit_own"),
			subtext = plugin.t("settings.edit_own.about"),
			icon = "edit",
			default = true,
		},
		{
			type = "switch",
			key = "show_result",
			text = plugin.t("settings.show_result"),
			subtext = plugin.t("settings.show_result.about"),
			icon = "eye",
			default = true,
		},
		{
			type = "switch",
			key = "fix_command",
			text = plugin.t("settings.fix_command"),
			subtext = plugin.t("settings.fix_command.about"),
			icon = "code",
			default = true,
		},
		{ type = "divider", text = plugin.t("settings.where.about") },
	}
end)
