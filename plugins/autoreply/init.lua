-- Автоответчик: включается на странице настроек (или из главного меню),
-- там же текст и как часто отвечать. Команды тоже работают: «/away текст»
-- включает (без текста — с прежним текстом), «/back» выключает.
-- Отвечает только людям в личных сообщениях, каждому не чаще раза в
-- «repeat» минут, и молчит в чате, куда вы сами писали за последние
-- «quiet» минут.

local repliedAt = {} -- chat id -> когда ответили
local wroteAt = {} -- chat id -> когда вы сами писали

local function enabled()
	return plugin.settings.get("enabled", false)
end

-- Текст ответа: свой из настроек или обычный на языке интерфейса.
local function replyText()
	local text = plugin.settings.get("text", "")
	if text:match("^%s*$") then
		return plugin.t("reply.default")
	end
	return text
end

local function notify(text)
	tg.toast{ title = plugin.t("title"), text = text }
end

-- Отсчёт с этой минуты: старые сообщения не в счёт, все снова получат ответ.
local function start()
	plugin.settings.set("since", os.time())
	repliedAt = {}
end

local function turnOn(text)
	if text and text ~= "" then
		plugin.settings.set("text", text)
	end
	plugin.settings.set("enabled", true)
	start()
	plugin.settings.refresh()
	notify(plugin.t("toast.on", replyText()))
end

local function turnOff()
	plugin.settings.set("enabled", false)
	plugin.settings.refresh()
	notify(plugin.t("toast.off"))
end

plugin.on("message.send", function(draft)
	local text = draft.text
	if plugin.settings.get("commands", true) then
		local away = text:match("^/away%s*(.*)$")
		if away and (away == "" or text:match("^/away%s")) then
			turnOn(away)
			return false
		elseif text == "/back" then
			turnOff()
			return false
		end
	end
	wroteAt[draft.peer] = os.time()
	return nil
end)

plugin.on("message.new", function(msg)
	if not enabled() or msg.out or msg.peer <= 0 or msg.from ~= msg.peer then
		return
	end
	local now = os.time()
	-- Старые сообщения, догруженные после переподключения, не в счёт.
	if msg.date < plugin.settings.get("since", now) or now - msg.date > 300 then
		return
	end
	local repeatSeconds = plugin.settings.get("repeat", 30) * 60
	local quietSeconds = plugin.settings.get("quiet", 10) * 60
	if (repliedAt[msg.peer] or 0) > now - repeatSeconds
		or (wroteAt[msg.peer] or 0) > now - quietSeconds then
		return
	end
	local peer = tg.peers.get(msg.peer)
	if not peer or peer.type ~= "user" or peer.is_self then
		return
	end
	repliedAt[msg.peer] = now
	tg.messages.send(msg.peer, replyText(), {
		reply_to = msg.id,
	})
end)

local function settingsPage()
	return {
		{ type = "header", text = plugin.t("settings.reply") },
		{
			type = "switch",
			key = "enabled",
			text = plugin.t("settings.enabled"),
			subtext = plugin.t("settings.enabled.about"),
			icon = "chat",
			default = false,
			on_change = function(on)
				if on then
					start()
				end
			end,
		},
		{
			type = "input",
			key = "text",
			text = plugin.t("settings.text"),
			placeholder = plugin.t("reply.default"),
			icon = "edit",
		},
		{ type = "header", text = plugin.t("settings.how_often") },
		{
			type = "slider",
			key = "repeat",
			text = plugin.t("settings.repeat"),
			subtext = plugin.t("settings.repeat.about", plugin.settings.get("repeat", 30)),
			icon = "timer",
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
			subtext = plugin.t("settings.quiet.about"),
			icon = "silent",
			min = 0,
			max = 120,
			step = 5,
			default = 10,
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
