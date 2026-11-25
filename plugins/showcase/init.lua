-- API showcase: everything a plugin can add to the client's interface.
--
-- • a settings page (the gear on the plugin card) with every kind of row,
--   nested pages and rows drawn on a canvas;
-- • items in the main menu, in the chat menu (⋮), at the send button and
--   in settings sections;
-- • a widget over the window with the open chat and a ticking clock; the
--   mouse carries it and it stays where it was dropped;
-- • every kind of dialog, sending with formatting;
-- • texts in two languages: locales/en.json and locales/ru.json, plugin.t(),
--   plurals included.

local WIDTH, HEIGHT = 240, 46

-- Theme colors shown on the settings page: a canvas can use them by name.
local SWATCHES = {
	"windowBg", "windowFg", "windowActiveTextFg", "activeButtonBg",
	"attentionButtonFg", "msgInBg", "msgOutBg",
	"historyPeer1UserpicBg", "historyPeer4UserpicBg", "historyPeer7UserpicBg",
}

local function setting(key, default)
	return plugin.settings.get(key, default)
end

-- Greetings in the interface language. Pages are built every time they
-- open, so the list is made anew, not once at start.
local function greetings()
	return {
		plugin.t("greeting.hi"),
		plugin.t("greeting.hello"),
		plugin.t("greeting.yo"),
	}
end

local function greeting()
	local list = greetings()
	return list[setting("greeting", 1)] or list[1]
end

local function escape_html(text)
	return (text:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local function clamp(x, a, b)
	if x < a then return a elseif x > b then return b end
	return x
end

-- The widget.

local overlay
local clock -- the timer that repaints the clock

local function current_title()
	local now = tg.ui.current()
	if now and now.screen == "chat" and now.title then
		return now.title
	end
	return plugin.t("overlay.chat_list")
end

local function paint_overlay(c)
	local w, h = c:size()
	c:rect(0, 0, w, h, "windowBgOver", 12)
	c:stroke(0, 0, w, h, "windowActiveTextFg", 1, 12)
	c:text(12, 6, plugin.t("overlay.label"), {
		size = 11,
		color = "windowSubTextFg",
		width = w - 96,
		height = 14,
	})
	c:text(w - 72, 6, os.date("%H:%M:%S"), {
		size = 11,
		color = "windowSubTextFg",
		align = "right",
		width = 60,
		height = 14,
	})
	c:text(12, 22, current_title(), {
		size = 13,
		bold = true,
		width = w - 24,
		height = 18,
	})
end

-- Where the widget is: top right by default, or where it was dropped,
-- kept inside a window that may have got smaller since.
local function placement()
	local x, y = setting("pos_x", -1), setting("pos_y", -1)
	if x < 0 or y < 0 then
		return { corner = "top-right", x = 16, y = 64, width = WIDTH, height = HEIGHT }
	end
	local ww, wh = tg.ui.window_size()
	if ww then
		x = clamp(x, 0, math.max(ww - WIDTH, 0))
		y = clamp(y, 0, math.max(wh - HEIGHT, 0))
	end
	return { corner = "top-left", x = x, y = y, width = WIDTH, height = HEIGHT }
end

local function show_overlay()
	if overlay then
		return
	end
	local spot = placement()
	spot.paint = paint_overlay
	spot.on_click = function()
		tg.toast{ title = plugin.t("title"), text = plugin.t("overlay.toast") }
	end
	-- The client carries it after the mouse by itself; we only remember
	-- the place. A dropped overlay counts x, y from the top-left corner.
	spot.draggable = true
	spot.on_drop = function(x, y)
		plugin.settings.set("pos_x", math.floor(x))
		plugin.settings.set("pos_y", math.floor(y))
		plugin.settings.refresh()
	end
	overlay = tg.ui.overlay(spot)
	-- update() repaints only this widget, so a clock costs nearly nothing.
	clock = tg.timer.every(1000, function()
		if overlay then
			overlay:update()
		end
	end)
end

local function hide_overlay()
	if clock then
		tg.timer.cancel(clock)
		clock = nil
	end
	if overlay then
		overlay:close()
		overlay = nil
	end
end

-- Another chat opened: the widget repaints.
plugin.on("screen", function()
	if overlay then
		overlay:update()
	end
end)

-- Pages.

local function dialogs_page()
	return {
		title = plugin.t("dialogs.title"),
		{ type = "header", text = plugin.t("dialogs.header") },
		{
			type = "text",
			text = plugin.t("dialogs.alert"),
			subtext = "tg.ui.alert(text, title)",
			icon = "info",
			on_click = function()
				tg.ui.alert(plugin.t("dialogs.alert.text"), plugin.t("dialogs.alert"))
			end,
		},
		{
			type = "text",
			text = plugin.t("dialogs.confirm"),
			subtext = "tg.ui.confirm{ title, text, ok, cancel }",
			icon = "faq",
			on_click = function()
				tg.async(function()
					local yes = tg.ui.confirm{
						title = plugin.t("dialogs.confirm"),
						text = plugin.t("dialogs.confirm.text"),
						ok = plugin.t("dialogs.confirm.ok"),
						cancel = plugin.t("dialogs.confirm.cancel"),
					}
					tg.toast(plugin.t(yes and "dialogs.confirm.yes" or "dialogs.confirm.no"))
				end)
			end,
		},
		{
			type = "text",
			text = plugin.t("dialogs.input"),
			subtext = "tg.ui.input{ title, text, value, placeholder }",
			icon = "edit",
			on_click = function()
				tg.async(function()
					local name = tg.ui.input{
						title = plugin.t("dialogs.input"),
						text = plugin.t("dialogs.input.text"),
						value = setting("name", ""),
						placeholder = plugin.t("dialogs.input.placeholder"),
					}
					if name then
						plugin.settings.set("name", name)
						plugin.settings.refresh()
						tg.toast(name ~= ""
							and plugin.t("dialogs.input.done", name)
							or plugin.t("dialogs.input.cleared"))
					end
				end)
			end,
		},
		{
			type = "text",
			text = plugin.t("dialogs.choose"),
			subtext = "tg.ui.dialog{ title, items }",
			icon = "select",
			on_click = function()
				tg.async(function()
					local list = greetings()
					local chosen = tg.ui.dialog{
						title = plugin.t("dialogs.choose"),
						text = plugin.t("dialogs.choose.text"),
						items = list,
					}
					-- Without buttons of our own the box has "Cancel": it
					-- gives nil or 0, an item gives its number.
					if chosen and list[chosen] then
						plugin.settings.set("greeting", chosen)
						plugin.settings.refresh()
						tg.toast(plugin.t("dialogs.choose.done", list[chosen]))
					end
				end)
			end,
		},
		{
			type = "text",
			text = plugin.t("dialogs.toast"),
			subtext = "tg.toast{ title, text, duration }",
			icon = "bell",
			on_click = function()
				tg.toast{
					title = plugin.t("title"),
					text = plugin.t("dialogs.toast.text"),
					duration = 5000,
				}
			end,
		},
		{ type = "divider", text = plugin.t("dialogs.about") },
	}
end

local function about_page()
	local plurals = {}
	for _, n in ipairs({ 1, 3, 5, 21 }) do
		plurals[#plurals + 1] = plugin.t("about.plural.n", n)
	end
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
			text = plugin.t("about.plural"),
			subtext = table.concat(plurals, ", "),
			icon = "font",
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

local function preview_title()
	local name = setting("name", "")
	if name ~= "" then
		return plugin.t("preview.greeting_name", greeting(), name)
	end
	return plugin.t("preview.greeting", greeting())
end

local function settings_page()
	local signature = setting("signature", "")
	local size = setting("size", 14)
	local moved = setting("pos_x", -1) >= 0
	local rows = {
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
	}
	if moved then
		rows[#rows + 1] = {
			type = "text",
			text = plugin.t("settings.overlay.back"),
			icon = "restore",
			on_click = function()
				plugin.settings.set("pos_x", nil)
				plugin.settings.set("pos_y", nil)
				if overlay then
					overlay:move(placement())
				end
				plugin.settings.refresh()
			end,
		}
	end
	local more = {
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
			icon = "font",
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
				c:text(36, 14, preview_title(), {
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
		{ type = "header", text = plugin.t("settings.colors") },
		{
			type = "custom",
			height = 64,
			paint = function(c)
				local w = c:size()
				local gap = 8
				local d = math.floor(math.min(32, (w - 44 - gap * (#SWATCHES - 1)) / #SWATCHES))
				for i, name in ipairs(SWATCHES) do
					local x = 22 + (i - 1) * (d + gap)
					-- A thin ring first: windowBg would vanish on the page.
					c:opacity(0.3)
					c:circle(x + d / 2, 8 + d / 2, d / 2, "windowSubTextFg")
					c:opacity(1)
					c:circle(x + d / 2, 8 + d / 2, d / 2 - 1, name)
				end
				c:text(22, 8 + d + 6, plugin.t("colors.hint"), {
					size = 11,
					color = "windowSubTextFg",
					width = w - 44,
					height = 14,
				})
			end,
			on_click = function()
				local lines = {}
				for _, name in ipairs(SWATCHES) do
					lines[#lines + 1] = name .. " " .. tg.ui.color(name)
				end
				tg.ui.copy(table.concat(lines, "\n"))
				tg.toast(plugin.t("colors.copied"))
			end,
		},
		{ type = "header", text = plugin.t("settings.about") },
		{
			type = "text",
			text = plugin.t("settings.dialogs"),
			subtext = plugin.t("settings.dialogs.about"),
			icon = "chat",
			page = dialogs_page,
		},
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
						-- The open page still shows the old values otherwise.
						plugin.settings.refresh()
					end
				end)
			end,
		},
	}
	for _, row in ipairs(more) do
		rows[#rows + 1] = row
	end
	return rows
end

plugin.settings.page(settings_page)

-- Items in different places of the client. Their text is taken when the
-- plugin starts.
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
		local signature = setting("signature", "")
		if signature == "" then
			tg.toast(plugin.t("signature.empty"))
		elseif ctx.peer then
			tg.messages.send(ctx.peer, "<i>" .. escape_html(signature) .. "</i>", {
				parse_mode = "html",
			})
		end
	end,
}

-- There may be no window yet at start: the widget shows up when it
-- becomes active.
plugin.on("app.state", function(state)
	if state == "active" and setting("overlay", false) then
		show_overlay()
	end
end)

function on_enable()
	if setting("overlay", false) then
		show_overlay()
	end
end

function on_disable()
	hide_overlay()
end
