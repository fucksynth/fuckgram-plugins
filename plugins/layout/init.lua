-- Раскладка: «ghbdtn» -> «привет», «руддщ» -> «hello». Направление плагин
-- выбирает сам: каких букв в тексте больше, те и неправильные. Команду
-- /fix, ссылки и окно с результатом можно настроить на странице настроек.

local EN = "`qwertyuiop[]asdfghjkl;'zxcvbnm,./~QWERTYUIOP{}ASDFGHJKL:\"ZXCVBNM<>?@#$^&"
local RU = "ёйцукенгшщзхъфывапролджэячсмитьбю.ЁЙЦУКЕНГШЩЗХЪФЫВАПРОЛДЖЭЯЧСМИТЬБЮ,\"№;:?"

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
		-- Точка, запятая и кавычки есть в обеих раскладках: для обратного
		-- пути берём первое соответствие, так «ю.» -> «./».
		if RU_TO_EN[ru[i]] == nil then
			RU_TO_EN[ru[i]] = en[i]
		end
	end
end

local function convert(text)
	if not utf8.len(text) then
		return nil
	end
	local latin, cyrillic = 0, 0
	for _, c in utf8.codes(text) do
		if (c >= 65 and c <= 90) or (c >= 97 and c <= 122) then
			latin = latin + 1
		elseif (c >= 0x410 and c <= 0x44F) or c == 0x401 or c == 0x451 then
			cyrillic = cyrillic + 1
		end
	end
	if latin == 0 and cyrillic == 0 then
		return nil
	end
	local map = (latin >= cyrillic) and EN_TO_RU or RU_TO_EN
	local result = {}
	for _, char in ipairs(chars(text)) do
		result[#result + 1] = map[char] or char
	end
	return table.concat(result)
end

-- Ссылки и @имена не трогаем: их обычно вставляют, а не набирают.
-- Без этой настройки переводится весь текст.
local function convertKeepingLinks(text)
	if not plugin.settings.get("keep_links", true) then
		return convert(text) or text
	end
	local pieces, last = {}, 1
	for start, word, finish in text:gmatch("()(%S+)()") do
		if word:match("^https?://") or word:match("^@[%w_]+$") then
			pieces[#pieces + 1] = convert(text:sub(last, start - 1)) or text:sub(last, start - 1)
			pieces[#pieces + 1] = word
			last = finish
		end
	end
	pieces[#pieces + 1] = convert(text:sub(last)) or text:sub(last)
	return table.concat(pieces)
end

local function notify(text)
	tg.toast{ title = plugin.t("title"), text = text }
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
		tg.compose.set(convertKeepingLinks(text))
	end,
}

plugin.menu{
	place = "message",
	text = plugin.t("menu.message"),
	icon = "translate",
	on_click = function(ctx)
		local text = ctx.message and ctx.message.text
		if not text or text == "" then
			notify(plugin.t("toast.no_text"))
			return
		end
		local fixed = convertKeepingLinks(text)
		tg.ui.copy(fixed)
		if plugin.settings.get("show_result", true) then
			tg.ui.alert(fixed, plugin.t("dialog.copied"))
		else
			notify(plugin.t("toast.copied"))
		end
	end,
}

-- «/fix ghbdtn» уходит как «привет».
plugin.on("message.send", function(draft)
	if not plugin.settings.get("fix_command", true) then
		return nil
	end
	local text = draft.text:match("^/fix%s+(.+)$")
	if not text then
		return nil
	end
	return convertKeepingLinks(text)
end)

plugin.settings.page(function()
	return {
		{ type = "header", text = plugin.t("settings.header") },
		{
			type = "switch",
			key = "keep_links",
			text = plugin.t("settings.keep_links"),
			subtext = plugin.t("settings.keep_links.about"),
			icon = "link",
			default = true,
		},
		{
			type = "switch",
			key = "fix_command",
			text = plugin.t("settings.fix_command"),
			subtext = plugin.t("settings.fix_command.about"),
			icon = "send",
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
		{ type = "divider", text = plugin.t("settings.where") },
	}
end)
