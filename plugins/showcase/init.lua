-- Витрина API: всё, что плагин может добавить в интерфейс клиента.
--
-- • страница настроек (шестерёнка на карточке плагина) со всеми видами
--   строк, вложенной страницей и строкой, нарисованной на холсте;
-- • пункты в главном меню, в меню чата (⋮), у кнопки отправки и в
--   разделах настроек;
-- • плашка поверх окна с названием открытого чата;
-- • окно с кнопками и отправка с разметкой;
-- • тексты на двух языках: locales/en.json и locales/ru.json, plugin.t().

-- Варианты приветствия на языке интерфейса. Страницы строятся при каждом
-- открытии, поэтому список собирается заново, а не один раз при запуске.
local function greetings()
	return {
		plugin.t("greeting.hi"),
		plugin.t("greeting.hello"),
		plugin.t("greeting.yo"),
	}
end

local function greeting()
	local list = greetings()
	return list[plugin.settings.get("greeting", 1)] or list[1]
end

local function escape_html(text)
	return (text:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local overlay

local function current_title()
	local now = tg.ui.current()
	return now.title or plugin.t("overlay.chat_list")
end

local function show_overlay()
	if overlay then
		return
	end
	overlay = tg.ui.overlay{
		corner = "top-right",
		x = 16,
		y = 64,
		width = 230,
		height = 46,
		paint = function(c)
			local w, h = c:size()
			c:rect(0, 0, w, h, "windowBgOver", 12)
			c:stroke(0, 0, w, h, "windowActiveTextFg", 1, 12)
			c:text(12, 6, plugin.t("overlay.label"), {
				size = 11,
				color = "windowSubTextFg",
				width = w - 24,
				height = 14,
			})
			c:text(12, 22, current_title(), {
				size = 13,
				bold = true,
				width = w - 24,
				height = 18,
			})
		end,
		on_click = function()
			tg.toast{ title = plugin.t("title"), text = plugin.t("overlay.toast") }
		end,
	}
end

local function hide_overlay()
	if overlay then
		overlay:close()
		overlay = nil
	end
end

-- Открыли другой чат: плашка перерисовывается.
plugin.on("screen", function()
	if overlay then
		overlay:update()
	end
end)

local function about_page()
	return {
		title = plugin.t("about.title"),
		{ type = "header", text = plugin.t("about.header") },
		{
			type = "text",
			text = plugin.t("about.nested"),
			subtext = plugin.t("about.nested.about"),
			icon = "info",
		},
		{
			type = "text",
			text = plugin.t("about.language"),
			subtext = plugin.t("about.language.about", tg.lang()),
			icon = "translate",
		},
		{
			type = "text",
			text = plugin.t("about.channel"),
			subtext = "@fuckgramplugins",
			icon = "channel",
			accent = true,
			on_click = function()
				tg.ui.open("@fuckgramplugins")
			end,
		},
	}
end

local function settings_page()
	local hello = greeting()
	local signature = plugin.settings.get("signature", "")
	local size = plugin.settings.get("size", 14)
	return {
		{ type = "header", text = plugin.t("settings.display") },
		{
			type = "switch",
			key = "overlay",
			text = plugin.t("settings.overlay"),
			subtext = plugin.t("settings.overlay.about"),
			icon = "eye",
			default = false,
			on_change = function(on)
				if on then
					show_overlay()
				else
					hide_overlay()
				end
			end,
		},
		{
			type = "selector",
			key = "greeting",
			text = plugin.t("settings.greeting"),
			items = greetings(),
			default = 1,
			icon = "chat",
			on_change = function()
				plugin.settings.refresh()
			end,
		},
		{
			type = "input",
			key = "signature",
			text = plugin.t("settings.signature"),
			placeholder = plugin.t("settings.signature.placeholder"),
			icon = "edit",
			on_change = function()
				plugin.settings.refresh()
			end,
		},
		{
			type = "slider",
			key = "size",
			text = plugin.t("settings.size"),
			min = 10,
			max = 24,
			step = 1,
			default = 14,
			on_change = function()
				plugin.settings.refresh()
			end,
		},
		{
			type = "custom",
			height = 72,
			paint = function(c)
				local w, h = c:size()
				c:rect(22, 8, w - 44, h - 16, "windowBgOver", 10)
				c:text(36, 14, plugin.t("preview.greeting", hello), {
					size = size,
					bold = true,
					color = "windowActiveTextFg",
					width = w - 72,
					height = size + 6,
				})
				c:text(36, 18 + size, signature ~= "" and signature or plugin.t("preview.no_signature"), {
					size = 12,
					color = "windowSubTextFg",
					width = w - 72,
					height = 16,
				})
			end,
			on_click = function()
				tg.toast(plugin.t("preview.toast"))
			end,
		},
		{ type = "divider", text = plugin.t("settings.preview.about") },
		{ type = "header", text = plugin.t("settings.about") },
		{
			type = "text",
			text = plugin.t("settings.more"),
			subtext = plugin.t("settings.more.about"),
			icon = "info",
			page = about_page,
		},
		{
			type = "text",
			text = plugin.t("settings.reset"),
			icon = "delete",
			red = true,
			on_click = function()
				tg.async(function()
					local answer = tg.ui.dialog{
						title = plugin.t("reset.title"),
						text = plugin.t("reset.text"),
						buttons = { plugin.t("reset.ok"), plugin.t("cancel") },
						danger = 1,
					}
					if answer == 1 then
						hide_overlay()
						plugin.settings.reset()
					end
				end)
			end,
		},
	}
end

plugin.settings.page(settings_page)

-- Пункты в разных местах клиента. Их текст берётся при запуске плагина.
plugin.menu{
	place = "main",
	text = plugin.t("title"),
	icon = "plugins",
	page = settings_page,
}
plugin.menu{
	place = "settings.fuckgram",
	text = plugin.t("title"),
	icon = "plugins",
	page = settings_page,
}
plugin.menu{
	place = "chat",
	text = plugin.t("menu.greet"),
	icon = "chat",
	on_click = function(ctx)
		tg.async(function()
			local hello = greeting()
			local answer = tg.ui.dialog{
				title = plugin.t("greet.title"),
				text = plugin.t("greet.text", hello),
				buttons = { plugin.t("greet.send"), plugin.t("cancel") },
			}
			if answer == 1 and ctx.peer then
				tg.messages.send(ctx.peer, "**" .. hello .. "**", {
					parse_mode = "markdown",
				})
			end
		end)
	end,
}
plugin.menu{
	place = "send",
	text = plugin.t("menu.signature"),
	icon = "send",
	on_click = function(ctx)
		local signature = plugin.settings.get("signature", "")
		if signature == "" then
			tg.toast(plugin.t("signature.empty"))
		elseif ctx.peer then
			tg.messages.send(ctx.peer, "<i>" .. escape_html(signature) .. "</i>", {
				parse_mode = "html",
			})
		end
	end,
}

-- Окна может ещё не быть при старте: плашка появится, когда оно станет
-- активным.
plugin.on("app.state", function(state)
	if state == "active" and plugin.settings.get("overlay", false) then
		show_overlay()
	end
end)

function on_enable()
	if plugin.settings.get("overlay", false) then
		show_overlay()
	end
end
