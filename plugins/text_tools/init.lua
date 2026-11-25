-- Text tools: short commands change the text before it is sent,
-- "/up text" -> "TEXT", "/mock text" -> "tExT", "/flip text" -> "ʇxǝʇ" and
-- others. Optional automatic typography turns "quotes" into «quotes»,
-- " - " into " — " and "..." into "…" in every message you send; code and
-- links are left as they are.

-- Lowercase for ASCII only: string.lower depends on the C locale and may
-- break UTF-8 bytes.
local function asciiLower(text)
	return (text:gsub("[A-Z]", function(c)
		return string.char(c:byte() + 32)
	end))
end

-- Letter case for Latin, Latin-1 and Cyrillic (string.upper knows only ASCII).
local function upperCode(c)
	if (c >= 0x61 and c <= 0x7A) or (c >= 0x430 and c <= 0x44F)
		or (c >= 0xE0 and c <= 0xFE and c ~= 0xF7) then
		return c - 32
	elseif c >= 0x450 and c <= 0x45F then
		return c - 80
	end
	return c
end

local function lowerCode(c)
	if (c >= 0x41 and c <= 0x5A) or (c >= 0x410 and c <= 0x42F)
		or (c >= 0xC0 and c <= 0xDE and c ~= 0xD7) then
		return c + 32
	elseif c >= 0x400 and c <= 0x40F then
		return c + 80
	end
	return c
end

local function isLetter(c)
	return upperCode(c) ~= c or lowerCode(c) ~= c
end

local function codes(text)
	local list = {}
	for _, c in utf8.codes(text) do
		list[#list + 1] = c
	end
	return list
end

local function join(list)
	local out = {}
	for index, c in ipairs(list) do
		out[index] = utf8.char(c)
	end
	return table.concat(out)
end

local function mapCodes(text, fn)
	local list = codes(text)
	for index, c in ipairs(list) do
		list[index] = fn(c)
	end
	return join(list)
end

local function upper(text)
	return mapCodes(text, upperCode)
end

local function lower(text)
	return mapCodes(text, lowerCode)
end

-- "hello world" -> "Hello World".
local function title(text)
	local list = codes(text)
	local wordStart = true
	for index, c in ipairs(list) do
		if isLetter(c) then
			list[index] = wordStart and upperCode(c) or lowerCode(c)
			wordStart = false
		elseif c ~= 0x27 and c ~= 0x2019 then -- apostrophes stay inside words
			wordStart = true
		end
	end
	return join(list)
end

-- "hello world" -> "hElLo WoRlD".
local function mock(text)
	local list = codes(text)
	local up = false
	for index, c in ipairs(list) do
		if isLetter(c) then
			list[index] = up and upperCode(c) or lowerCode(c)
			up = not up
		end
	end
	return join(list)
end

local function reverse(text)
	local list = codes(text)
	local out = {}
	for index = #list, 1, -1 do
		out[#out + 1] = utf8.char(list[index])
	end
	return table.concat(out)
end

-- Upside-down letters. Cyrillic is turned to lower case first.
local FLIP = {
	a = "ɐ", b = "q", c = "ɔ", d = "p", e = "ǝ", f = "ɟ", g = "ƃ", h = "ɥ",
	i = "ᴉ", j = "ɾ", k = "ʞ", l = "l", m = "ɯ", n = "u", o = "o", p = "d",
	q = "b", r = "ɹ", s = "s", t = "ʇ", u = "n", v = "ʌ", w = "ʍ", x = "x",
	y = "ʎ", z = "z",
	A = "∀", B = "ꓭ", C = "Ɔ", D = "ꓷ", E = "Ǝ", F = "Ⅎ", G = "⅁", H = "H",
	I = "I", J = "ſ", K = "ꓘ", L = "˥", M = "W", N = "N", O = "O", P = "Ԁ",
	Q = "Ό", R = "ꓤ", S = "S", T = "⊥", U = "∩", V = "Λ", W = "M", X = "X",
	Y = "⅄", Z = "Z",
	["0"] = "0", ["1"] = "Ɩ", ["2"] = "ᄅ", ["3"] = "Ɛ", ["4"] = "ㄣ",
	["5"] = "ϛ", ["6"] = "9", ["7"] = "ㄥ", ["8"] = "8", ["9"] = "6",
	["."] = "˙", [","] = "'", ["'"] = ",", ["\""] = "„", ["!"] = "¡",
	["?"] = "¿", ["("] = ")", [")"] = "(", ["["] = "]", ["]"] = "[",
	["{"] = "}", ["}"] = "{", ["<"] = ">", [">"] = "<", ["_"] = "‾",
	["&"] = "⅋", [";"] = "؛", ["«"] = "»", ["»"] = "«",
	["а"] = "ɐ", ["б"] = "ƍ", ["в"] = "ʚ", ["г"] = "ɹ", ["д"] = "ɓ",
	["е"] = "ǝ", ["ё"] = "ǝ", ["ж"] = "ж", ["з"] = "ε", ["и"] = "и",
	["й"] = "ņ", ["к"] = "ʞ", ["л"] = "v", ["м"] = "w", ["н"] = "н",
	["о"] = "о", ["п"] = "u", ["р"] = "d", ["с"] = "ɔ", ["т"] = "ɯ",
	["у"] = "ʎ", ["ф"] = "ф", ["х"] = "х", ["ц"] = "ǹ", ["ч"] = "Һ",
	["ш"] = "m", ["щ"] = "m", ["ъ"] = "q", ["ы"] = "ıq", ["ь"] = "q",
	["э"] = "є", ["ю"] = "oı", ["я"] = "ʁ",
}

local function flip(text)
	local list = codes(text)
	local out = {}
	for index = #list, 1, -1 do
		local c = list[index]
		if c >= 0x400 and c <= 0x42F then
			c = lowerCode(c)
		end
		local char = utf8.char(c)
		out[#out + 1] = FLIP[char] or char
	end
	return table.concat(out)
end

-- Typography -------------------------------------------------------------------

local QUOTES = {
	{ "«", "»", "„", "“" },
	{ "“", "”", "‘", "’" },
}

-- Straight double quotes to typographic ones, nested quotes get the inner
-- pair. Text with unbalanced quotes is left alone.
local function quotes(text, style)
	local marks = QUOTES[style] or QUOTES[1]
	local out = {}
	local depth = 0
	local lastOpen = false
	local previous = ""
	for index = 1, #text do
		local char = text:sub(index, index)
		if char == "\"" then
			local opening = index == 1 or lastOpen
				or previous:match("[%s%(%[{]") ~= nil
			if opening then
				depth = depth + 1
				out[#out + 1] = (depth % 2 == 1) and marks[1] or marks[3]
				lastOpen = true
			else
				if depth == 0 then
					return text
				end
				out[#out + 1] = (depth % 2 == 1) and marks[2] or marks[4]
				depth = depth - 1
				lastOpen = false
			end
		else
			out[#out + 1] = char
			lastOpen = false
		end
		previous = char
	end
	if depth ~= 0 then
		return text
	end
	return table.concat(out)
end

local function settingOn(key)
	return plugin.settings.get(key, true) == true
end

local function typography(text)
	-- Code and links are kept as they are: they are swapped for \1N\2 marks
	-- and put back at the end.
	local kept = {}
	local function keep(piece)
		kept[#kept + 1] = piece
		return "\1" .. #kept .. "\2"
	end
	local result = text:gsub("```.-```", keep)
	result = result:gsub("`[^`\n]+`", keep)
	result = result:gsub("[A-Za-z][A-Za-z0-9%+%.%-]*://[^%s]+", keep)
	result = result:gsub("www%.[^%s]+", keep)

	if settingOn("ellipsis") then
		result = result:gsub("%.%.%.", "…")
	end
	if settingOn("dashes") then
		-- Only between words: "- item" at the start of a line stays.
		result = result:gsub("([^%s]) +%-%-? +", "%1 — ")
		result = result:gsub("([^%s%-])%-%-([^%s%-])", "%1—%2")
	end
	if settingOn("quotes") then
		result = quotes(result, plugin.settings.get("quote_style", 1))
	end

	result = result:gsub("\1(%d+)\2", function(index)
		return kept[tonumber(index)]
	end)
	return result
end

-- Commands -----------------------------------------------------------------------

local COMMANDS = {
	up = upper,
	low = lower,
	title = title,
	mock = mock,
	rev = reverse,
	flip = flip,
	fix = typography,
}

local function escapeHtml(text)
	return (text:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

-- In a chat with a bot "/up" may be the bot's command.
local function botChat(peer)
	if not plugin.settings.get("skip_bots", true) then
		return false
	end
	local info = tg.peers.get(peer)
	return info ~= nil and info.type == "bot"
end

plugin.on("message.send", function(draft)
	local text = draft.text
	local name, argument = text:match("^/([A-Za-z]+)%s+(.+)$")
	if name and plugin.settings.get("commands", true) then
		name = asciiLower(name)
		local isCommand = COMMANDS[name] ~= nil or name == "spoiler"
		if isCommand and not botChat(draft.peer) then
			if name == "spoiler" then
				local peer = draft.peer
				local html = "<tg-spoiler>" .. escapeHtml(argument) .. "</tg-spoiler>"
				-- Sent on the next turn of the loop, not from inside the filter.
				tg.timer.after(0, function()
					tg.messages.send(peer, html, { parse_mode = "html" })
				end)
				return false
			end
			local ok, result = pcall(COMMANDS[name], argument)
			if not ok or result == "" then
				tg.toast({ title = plugin.t("title"), text = plugin.t("error") })
				return false
			end
			return result
		end
	end
	if text:sub(1, 1) == "/" or not plugin.settings.get("auto", false) then
		return nil
	end
	local ok, result = pcall(typography, text)
	if ok and result ~= text then
		return result
	end
	return nil
end)

-- Settings page -----------------------------------------------------------------

local function refresh()
	plugin.settings.refresh()
end

plugin.settings.page(function()
	local example = plugin.t("settings.example.text")
	local ok, fixed = pcall(typography, example)
	return {
		{ type = "header", text = plugin.t("settings.typography") },
		{
			type = "switch",
			key = "auto",
			text = plugin.t("settings.auto"),
			subtext = plugin.t("settings.auto.about"),
			icon = "font",
			default = false,
		},
		{
			type = "switch",
			key = "quotes",
			text = plugin.t("settings.quotes"),
			icon = "edit",
			default = true,
			on_change = refresh,
		},
		{
			type = "selector",
			key = "quote_style",
			text = plugin.t("settings.quote_style"),
			items = { "«…» „…“", "“…” ‘…’" },
			default = 1,
			icon = "customize",
			on_change = refresh,
		},
		{
			type = "switch",
			key = "dashes",
			text = plugin.t("settings.dashes"),
			icon = "edit",
			default = true,
			on_change = refresh,
		},
		{
			type = "switch",
			key = "ellipsis",
			text = plugin.t("settings.ellipsis"),
			icon = "edit",
			default = true,
			on_change = refresh,
		},
		{
			type = "text",
			text = plugin.t("settings.example"),
			subtext = ok and fixed or example,
			icon = "info",
		},
		{ type = "divider", text = plugin.t("settings.kept") },
		{ type = "header", text = plugin.t("settings.commands") },
		{
			type = "switch",
			key = "commands",
			text = plugin.t("settings.commands.switch"),
			icon = "code",
			default = true,
		},
		{
			type = "switch",
			key = "skip_bots",
			text = plugin.t("settings.skip_bots"),
			subtext = plugin.t("settings.skip_bots.about"),
			icon = "bot",
			default = true,
		},
		{ type = "divider", text = plugin.t("settings.list") },
	}
end)
