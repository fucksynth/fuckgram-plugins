-- Link cleaner: before a message is sent, removes the parameters by which
-- sites and social networks follow where a person came from, and unwraps
-- redirect links (google.com/url?q=..., vk.com/away.php?to=...) to the
-- address they lead to. Other parameters (a page number, a search, the
-- time in a video) stay as they were. A message menu copies a text with
-- clean links, the settings page cleans a pasted link.

-- Parameters removed on any site.
local TRACKERS = {
	fbclid = true, gclid = true, dclid = true, gbraid = true, wbraid = true,
	yclid = true, ysclid = true, msclkid = true, twclid = true, ttclid = true,
	igshid = true, igsh = true, mc_cid = true, mc_eid = true,
	_hsenc = true, _hsmi = true, mkt_tok = true, vero_id = true,
	oly_enc_id = true, oly_anon_id = true, rb_clickid = true, s_cid = true,
	ref_src = true, ref_url = true, spm = true, scm = true,
	share_source = true, share_medium = true, share_plat = true,
	share_session_id = true, share_tag = true, share_from = true,
	from_spmid = true, unique_k = true, srsltid = true, _gl = true,
}

-- Name starts: utm_source, utm_medium, pk_campaign...
local PREFIXES = { "utm_", "pk_", "mtm_", "hsa_", "vk_", "_openstat" }

-- Parameters that track only on their own site; "x*" is every name that
-- starts with "x". Names are in lower case.
local BY_SITE = {
	["youtube.com"] = { "si", "feature", "pp" },
	["youtu.be"] = { "si", "feature" },
	["spotify.com"] = { "si", "context" },
	["instagram.com"] = { "igsh" },
	["twitter.com"] = { "s", "t" },
	["x.com"] = { "s", "t" },
	["tiktok.com"] = { "_r", "_t", "is_from_webapp", "sender_device" },
	["aliexpress.com"] = { "spm", "aff_platform", "sk", "aff_trace_key" },
	["aliexpress.ru"] = { "spm", "aff_platform", "sk", "aff_trace_key" },
	["amazon.com"] = { "ref", "ref_", "pd_rd_*", "pf_rd_*", "_encoding", "linkcode", "linkid", "qid", "sr", "sprefix", "crid", "dib", "dib_tag", "content-id" },
	["reddit.com"] = { "share_id", "rdt" },
	["linkedin.com"] = { "trk", "trackingid", "lipi", "refid", "midtoken", "midsig", "trkemail", "eid" },
	["facebook.com"] = { "mibextid", "rdid", "__tn__", "__cft__*", "__xts__*", "fref", "hc_ref" },
	["google"] = { "ved", "ei", "sxsrf", "gs_lcrp", "gs_lp", "sca_esv", "sca_upv", "uact", "iflsig", "aqs", "sourceid", "oq", "rlz", "biw", "bih", "dpr", "sclient" },
}

-- Rules as sets: { exact = { si = true }, prefixes = { "pd_rd_" } }.
local SITE_RULES = {}
for site, names in pairs(BY_SITE) do
	local rules = { exact = {}, prefixes = {} }
	for _, name in ipairs(names) do
		if name:sub(-1) == "*" then
			rules.prefixes[#rules.prefixes + 1] = name:sub(1, -2)
		else
			rules.exact[name] = true
		end
	end
	SITE_RULES[site] = rules
end

-- Redirect links and the parameter that holds the real address.
local REDIRECTS = {
	{ host = "google", path = "^/url$", params = { "q", "url" } },
	{ host = "vk.com", path = "^/away%.php$", params = { "to" } },
	{ host = "facebook.com", path = "^/l%.php$", params = { "u" } },
	{ host = "l.instagram.com", path = "^/?$", params = { "u" } },
	{ host = "youtube.com", path = "^/redirect$", params = { "q" } },
	{ host = "steamcommunity.com", path = "^/linkfilter/?$", params = { "url", "u" } },
}

local function setting(key, default)
	return plugin.settings.get(key, default)
end

local function notify(text)
	tg.toast{ title = plugin.t("title"), text = text }
end

-- Amazon and Google live on many domains: amazon.de, google.co.uk.
local function siteKey(host)
	if host:match("^google%.") or host:match("%.google%.[a-z.]+$") then
		return "google"
	elseif host:match("^amazon%.") or host:match("%.amazon%.[a-z.]+$") then
		return "amazon.com"
	end
	return nil
end

local function onSite(host, site)
	return host == site or host:sub(-#site - 1) == "." .. site
end

local function siteRules(host)
	if not setting("site_rules", true) then
		return nil
	end
	local key = siteKey(host)
	if key then
		return SITE_RULES[key]
	end
	for site, rules in pairs(SITE_RULES) do
		if onSite(host, site) then
			return rules
		end
	end
	return nil
end

-- Your own parameters from the settings: "ref, source" -> { ref = true, ... }.
local function extraRules()
	local extra = {}
	for name in setting("extra", ""):gmatch("[^,; \t]+") do
		extra[name:lower()] = true
	end
	return extra
end

local function startsWith(text, prefix)
	return text:sub(1, #prefix) == prefix
end

local function tracked(key, rules, extra)
	if TRACKERS[key] or extra[key] then
		return true
	end
	for _, prefix in ipairs(PREFIXES) do
		if startsWith(key, prefix) then
			return true
		end
	end
	if rules then
		if rules.exact[key] then
			return true
		end
		for _, prefix in ipairs(rules.prefixes) do
			if startsWith(key, prefix) then
				return true
			end
		end
	end
	return false
end

local function decode(text)
	return (text:gsub("%%(%x%x)", function(hex)
		return string.char(tonumber(hex, 16))
	end))
end

-- "https://host/path?query#fragment" -> its parts; host in lower case.
local function parts(url)
	local scheme, rest = url:match("^([A-Za-z]+://)(.*)$")
	if not scheme then
		scheme, rest = "", url
	end
	local authority, path = rest:match("^([^/?#]*)(.*)$")
	local host = (authority:match("^([^:]+)") or ""):lower()
	return scheme, authority, host, path
end

-- The address a redirect link leads to, or nil.
local function unwrap(url)
	local _, _, host, path = parts(url)
	local route, query = path:match("^([^?#]*)%?([^#]*)")
	if not route then
		return nil
	end
	for _, redirect in ipairs(REDIRECTS) do
		local hostMatches = redirect.host == "google" and siteKey(host) == "google"
			or onSite(host, redirect.host)
		if hostMatches and route:match(redirect.path) then
			for _, param in ipairs(redirect.params) do
				for pair in query:gmatch("[^&]+") do
					local key, value = pair:match("^([^=]*)=(.*)$")
					if key == param then
						local target = decode(value)
						-- Only a real web address, never "javascript:" and
						-- the like, and nothing with spaces in it.
						if target:match("^https?://[^ \t\r\n]+$") then
							return target
						end
					end
				end
			end
		end
	end
	return nil
end

-- A link without tracking and how many trackers it had.
local function clean(url, extra)
	local removed = 0
	if setting("unwrap", true) then
		local target = unwrap(url)
		if target then
			url, removed = target, 1
		end
	end
	local base, query, fragment = url:match("^([^?#]*)%?([^#]*)(.*)$")
	local _, _, host = parts(url)
	-- Amazon puts its "ref=" into the path as well: /dp/B0123/ref=sr_1_1.
	if siteKey(host) == "amazon.com" and setting("site_rules", true) then
		local path = base or url:match("^([^#]*)")
		local stripped, count = path:gsub("/ref=[^/?#]*", "")
		if count > 0 then
			if base then
				base = stripped
			else
				url = stripped .. url:sub(#path + 1)
			end
			removed = removed + count
		end
	end
	if not base then
		return url, removed
	end
	local rules = siteRules(host)
	local kept, dropped = {}, 0
	for pair in query:gmatch("[^&]+") do
		local key = (pair:match("^([^=]*)") or ""):lower()
		if tracked(key, rules, extra) then
			dropped = dropped + 1
		else
			kept[#kept + 1] = pair
		end
	end
	if dropped == 0 then
		return url, removed
	end
	local result = base
	if #kept > 0 then
		result = result .. "?" .. table.concat(kept, "&")
	end
	return result .. fragment, removed + dropped
end

-- Brackets and quotes around a link belong to the sentence, not to it:
-- "(see https://x.com/a?utm_source=1)" keeps its ")". A ")" that closes a
-- "(" inside the link stays: en.wikipedia.org/wiki/Mercury_(planet).
local OPENERS = { "(", "[", "«", "“", "\"", "'", "<" }
local CLOSERS = { ".", ",", ";", ":", "!", "?", ")", "]", "»", "”", "\"", "'", ">" }

local function balanced(url, open, close)
	local _, opens = url:gsub("%" .. open, "")
	local _, closes = url:gsub("%" .. close, "")
	return opens >= closes
end

local function peel(token)
	local head, tail = "", ""
	local changed = true
	while changed do
		changed = false
		for _, c in ipairs(OPENERS) do
			if #token > #c and startsWith(token, c) then
				head, token, changed = head .. c, token:sub(#c + 1), true
				break
			end
		end
	end
	changed = true
	while changed do
		changed = false
		for _, c in ipairs(CLOSERS) do
			if #token > #c and token:sub(-#c) == c then
				local inside = (c == ")" and balanced(token, "(", ")"))
					or (c == "]" and balanced(token, "[", "]"))
				if not inside then
					token, tail, changed = token:sub(1, -#c - 1), c .. tail, true
					break
				end
			end
		end
	end
	return head, token, tail
end

-- A link without "https://": "www.site.com/..." or "youtu.be/abc?si=x".
local function bareLink(word)
	return word:match("^www%.[A-Za-z0-9]") or word:match("^[A-Za-z0-9%-]+%.[A-Za-z0-9.%-]*[A-Za-z]/")
end

-- Text with clean links, how many trackers were removed and how many links
-- there were.
local function cleanText(text)
	local extra = extraRules()
	local total, links = 0, 0
	local result = text:gsub("[^ \t\r\n]+", function(token)
		-- Only a link with a query can be cleaned; most words leave here.
		if not token:find("?", 1, true) and not token:find("/ref=", 1, true) then
			if token:find("://", 1, true) or bareLink(token) then
				links = links + 1
			end
			return nil
		end
		-- "see:https://..." glued to a word: the link starts at its scheme.
		local glued, rest = token:match("^(.-)(https?://.+)$")
		local head, url, tail
		if rest then
			local inner
			head, inner, tail = peel(rest)
			head, url = glued .. head, inner
		else
			head, url, tail = peel(token)
			if not bareLink(url) then
				return nil
			end
		end
		links = links + 1
		local cleaned, removed = clean(url, extra)
		total = total + removed
		return head .. cleaned .. tail
	end)
	return result, total, links
end

local function addToTotal(count)
	plugin.settings.set("total", setting("total", 0) + count)
end

plugin.on("message.send", function(draft)
	if not setting("auto", true) then
		return nil
	end
	local text, total = cleanText(draft.text)
	if total == 0 then
		return nil
	end
	addToTotal(total)
	if setting("notify", true) then
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
		addToTotal(total)
		notify(total > 0
			and plugin.t("toast.copied", total)
			or plugin.t("toast.copied_clean"))
	end,
}

plugin.settings.page(function()
	local total = setting("total", 0)
	return {
		{ type = "header", text = plugin.t("settings.header") },
		{
			type = "switch",
			key = "auto",
			text = plugin.t("settings.auto"),
			subtext = plugin.t("settings.auto.about"),
			icon = "shield",
			default = true,
		},
		{
			type = "switch",
			key = "notify",
			text = plugin.t("settings.notify"),
			subtext = plugin.t("settings.notify.about"),
			icon = "bell",
			default = true,
		},
		{ type = "header", text = plugin.t("settings.what") },
		{
			type = "switch",
			key = "site_rules",
			text = plugin.t("settings.site_rules"),
			subtext = plugin.t("settings.site_rules.about"),
			icon = "link",
			default = true,
		},
		{
			type = "switch",
			key = "unwrap",
			text = plugin.t("settings.unwrap"),
			subtext = plugin.t("settings.unwrap.about"),
			icon = "forward",
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
		{ type = "header", text = plugin.t("settings.tools") },
		{
			type = "text",
			text = plugin.t("settings.try"),
			subtext = plugin.t("settings.try.about"),
			icon = "copy",
			on_click = function()
				tg.async(function()
					local typed = tg.ui.input{
						title = plugin.t("settings.try"),
						placeholder = "https://youtu.be/…?si=…",
					}
					if not typed or typed:match("^[ \t\r\n]*$") then
						return
					end
					local cleaned, removed, links = cleanText(typed)
					if links == 0 then
						notify(plugin.t("toast.no_links"))
						return
					end
					tg.ui.copy(cleaned)
					addToTotal(removed)
					plugin.settings.refresh()
					tg.ui.alert(cleaned, removed > 0
						and plugin.t("toast.copied", removed)
						or plugin.t("toast.copied_clean"))
				end)
			end,
		},
		{
			type = "text",
			text = plugin.t("settings.total"),
			subtext = total > 0 and plugin.t("settings.total.about", total) or plugin.t("settings.total.none"),
			icon = "stats",
		},
		{ type = "divider", text = plugin.t("settings.kept") },
	}
end)
