-- Чистые ссылки: перед отправкой убирает из ссылок параметры, по которым
-- сайты и соцсети следят, откуда пришёл человек. Остальные параметры
-- (номер страницы, поиск, время в видео) остаются как были. Из меню
-- сообщения можно скопировать его текст с уже чистыми ссылками.

-- Параметры, которые убираются на любом сайте.
local TRACKERS = {
	fbclid = true, gclid = true, dclid = true, gbraid = true, wbraid = true,
	yclid = true, ysclid = true, msclkid = true, twclid = true, ttclid = true,
	igshid = true, igsh = true, mc_cid = true, mc_eid = true,
	_hsenc = true, _hsmi = true, mkt_tok = true, vero_id = true,
	oly_enc_id = true, oly_anon_id = true, rb_clickid = true, s_cid = true,
	ref_src = true, ref_url = true, spm = true, scm = true,
	share_source = true, share_medium = true, share_plat = true,
	share_session_id = true, share_tag = true, share_from = true,
	from_spmid = true, unique_k = true,
}

-- Начала имён: utm_source, utm_medium, pk_campaign...
local PREFIXES = { "utm_", "pk_", "mtm_", "hsa_", "vk_", "_openstat" }

-- Параметры, которые следят только на своём сайте.
local BY_SITE = {
	["youtube.com"] = { si = true, feature = true, pp = true },
	["youtu.be"] = { si = true, feature = true },
	["spotify.com"] = { si = true, context = true },
	["instagram.com"] = { igsh = true },
	["twitter.com"] = { s = true, t = true },
	["x.com"] = { s = true, t = true },
	["tiktok.com"] = { _r = true, _t = true, is_from_webapp = true, sender_device = true },
	["aliexpress.com"] = { spm = true, aff_platform = true, sk = true, aff_trace_key = true },
	["aliexpress.ru"] = { spm = true, aff_platform = true, sk = true, aff_trace_key = true },
}

local function siteRules(host)
	if not plugin.settings.get("site_rules", true) then
		return nil
	end
	for site, rules in pairs(BY_SITE) do
		if host == site or host:sub(-#site - 1) == "." .. site then
			return rules
		end
	end
	return nil
end

-- Свои параметры из настроек: «ref, source» -> { ref = true, source = true }.
local function extraRules()
	local extra = {}
	for name in plugin.settings.get("extra", ""):gmatch("[^,;%s]+") do
		extra[name:lower()] = true
	end
	return extra
end

local function tracked(key, rules, extra)
	if TRACKERS[key] or extra[key] then
		return true
	end
	for _, prefix in ipairs(PREFIXES) do
		if key:sub(1, #prefix) == prefix then
			return true
		end
	end
	return rules ~= nil and rules[key] == true
end

-- Ссылка без меток и сколько их было.
local function clean(url, extra)
	local base, query, fragment = url:match("^([^?#]*)%?([^#]*)(.*)$")
	if not base then
		return url, 0
	end
	local host = (base:match("^%a+://([^/:]+)") or ""):lower()
	local rules = siteRules(host)
	local kept, removed = {}, 0
	for pair in query:gmatch("[^&]+") do
		local key = (pair:match("^([^=]*)") or ""):lower()
		if tracked(key, rules, extra) then
			removed = removed + 1
		else
			kept[#kept + 1] = pair
		end
	end
	if removed == 0 then
		return url, 0
	end
	local result = base
	if #kept > 0 then
		result = result .. "?" .. table.concat(kept, "&")
	end
	return result .. fragment, removed
end

-- Текст с чистыми ссылками, сколько меток убрано и сколько было ссылок.
local function cleanText(text)
	local extra = extraRules()
	local total, links = 0, 0
	local result = text:gsub("https?://[^%s<>\"]+", function(url)
		links = links + 1
		-- Точка или запятая в конце — это конец предложения, не ссылки.
		local body, tail = url:match("^(.-)([%.,;:!%?]*)$")
		local cleaned, removed = clean(body, extra)
		total = total + removed
		return cleaned .. tail
	end)
	return result, total, links
end

local function notify(text)
	tg.toast{ title = plugin.t("title"), text = text }
end

plugin.on("message.send", function(draft)
	local text, total = cleanText(draft.text)
	if total == 0 then
		return nil
	end
	if plugin.settings.get("notify", true) then
		notify(plugin.t("toast.cleaned", total))
	end
	return text
end)

plugin.menu{
	place = "message",
	text = plugin.t("menu.copy"),
	icon = "link",
	on_click = function(ctx)
		local text = ctx.message and ctx.message.text
		if not text or text == "" then
			notify(plugin.t("toast.no_text"))
			return
		end
		local cleaned, total, links = cleanText(text)
		if links == 0 then
			notify(plugin.t("toast.no_links"))
			return
		end
		tg.ui.copy(cleaned)
		notify(total > 0
			and plugin.t("toast.copied", total)
			or plugin.t("toast.copied_clean"))
	end,
}

plugin.settings.page(function()
	return {
		{ type = "header", text = plugin.t("settings.header") },
		{
			type = "switch",
			key = "notify",
			text = plugin.t("settings.notify"),
			subtext = plugin.t("settings.notify.about"),
			icon = "bell",
			default = true,
		},
		{
			type = "switch",
			key = "site_rules",
			text = plugin.t("settings.site_rules"),
			subtext = plugin.t("settings.site_rules.about"),
			icon = "link",
			default = true,
		},
		{
			type = "input",
			key = "extra",
			text = plugin.t("settings.extra"),
			subtext = plugin.t("settings.extra.about"),
			placeholder = plugin.t("settings.extra.placeholder"),
			icon = "edit",
		},
		{ type = "divider", text = plugin.t("settings.kept") },
	}
end)
