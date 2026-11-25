-- Exchange rates: "/cur 100 usd rub" is not sent; instead the plugin asks
-- open.er-api.com for the rate (free, no key) and sends the answer. One
-- command can name several currencies: "/cur 100 usd rub eur cny".
-- "Convert" in a message menu finds sums like "250 €" in someone else's
-- message and shows them in your currencies.
-- Rates of one currency are kept for an hour, so the service is not asked
-- on every message; when it does not answer, an older rate is used and the
-- answer says of which date it is.

local CACHE_SECONDS = 3600
-- An old rate is better than none, but not a very old one.
local STALE_SECONDS = 7 * 86400
-- A message menu shows at most this many sums: a price list is not a sum.
local MENU_SUMS = 5

-- Symbols and English names, on any interface language.
local ALIASES = {
	["$"] = "USD", ["us$"] = "USD", ["dollar"] = "USD", ["dollars"] = "USD",
	["buck"] = "USD", ["bucks"] = "USD",
	["€"] = "EUR", ["евро"] = "EUR", ["euro"] = "EUR", ["euros"] = "EUR",
	["₽"] = "RUB", ["р"] = "RUB", ["руб"] = "RUB", ["ruble"] = "RUB",
	["rubles"] = "RUB", ["rouble"] = "RUB", ["roubles"] = "RUB",
	["¥"] = "CNY", ["yuan"] = "CNY", ["rmb"] = "CNY",
	["£"] = "GBP", ["pound"] = "GBP", ["pounds"] = "GBP",
	["₸"] = "KZT", ["тенге"] = "KZT", ["tenge"] = "KZT",
	["₴"] = "UAH", ["hryvnia"] = "UAH",
	["белруб"] = "BYN",
	["₺"] = "TRY", ["lira"] = "TRY",
	["yen"] = "JPY",
	["₩"] = "KRW", ["won"] = "KRW",
	["₹"] = "INR", ["rupee"] = "INR", ["rupees"] = "INR",
	["₾"] = "GEL", ["лари"] = "GEL",
	["֏"] = "AMD",
	["zł"] = "PLN",
	["฿"] = "THB", ["бат"] = "THB", ["батов"] = "THB",
	["сум"] = "UZS", ["сумов"] = "UZS",
}

-- Russian words change their endings: "рубль", "рубля", "рублях" all
-- start with "рубл". A stem is checked at the start of the word.
local STEMS = {
	{ "рубл", "RUB" }, { "доллар", "USD" }, { "бакс", "USD" },
	{ "юан", "CNY" }, { "фунт", "GBP" }, { "гривн", "UAH" },
	{ "лир", "TRY" }, { "иен", "JPY" }, { "йен", "JPY" },
	{ "франк", "CHF" }, { "злот", "PLN" }, { "рупи", "INR" },
	{ "дирхам", "AED" }, { "драм", "AMD" }, { "белорусск", "BYN" },
}

-- "100k usd", "1.5 млн руб".
local MULTIPLIERS = {
	k = 1e3, ["к"] = 1e3, ["тыс"] = 1e3, ["тысяч"] = 1e3, ["тысячи"] = 1e3,
	m = 1e6, mln = 1e6, ["млн"] = 1e6,
}

-- Codes a message menu believes in. A command takes any three letters, but
-- in a chat "100 the" or "5 min" are not sums.
local KNOWN = {}
for known in ("USD EUR RUB CNY GBP JPY KZT UAH BYN TRY KRW INR GEL AMD AZN UZS KGS "
	.. "TJS MDL PLN CZK CHF SEK NOK DKK HUF RON BGN RSD CAD AUD NZD HKD SGD THB "
	.. "VND IDR MYR PHP AED SAR ILS EGP BRL MXN ARS ZAR"):gmatch("%u+") do
	KNOWN[known] = true
end

-- Words between the currencies that mean nothing: "100 usd in rub".
local FILLER = { ["в"] = true, ["во"] = true, ["to"] = true, ["in"] = true, ["="] = true, ["->"] = true }

local cache = {} -- base code -> { rates = {...}, time = os.time(), updated = unixtime }

local function setting(key, default)
	return plugin.settings.get(key, default)
end

-- string.lower knows only Latin, and in some C locales it spoils bytes of
-- other letters: "Доллар" -> "доллар" is done by hand.
local function lower(text)
	if not utf8.len(text) then
		return (text:gsub("[A-Z]", function(c)
			return string.char(c:byte() + 32)
		end))
	end
	local result = {}
	for _, c in utf8.codes(text) do
		if c >= 0x410 and c <= 0x42F then
			c = c + 0x20
		elseif c == 0x401 then
			c = 0x451
		elseif c >= 65 and c <= 90 then
			c = c + 32
		end
		result[#result + 1] = utf8.char(c)
	end
	return table.concat(result)
end

-- A word (already lower case) -> a currency code or nil.
local function code(word)
	if not word or word == "" then
		return nil
	end
	if ALIASES[word] then
		return ALIASES[word]
	end
	for _, stem in ipairs(STEMS) do
		if word:sub(1, #stem[1]) == stem[1] then
			return stem[2]
		end
	end
	if word:match("^[a-z][a-z][a-z]$") then
		return word:upper()
	end
	return nil
end

-- Number separators: from the settings or from the interface language.
local function separators()
	local mode = setting("number_format", 1)
	if mode == 2 then
		return " ", ","
	elseif mode == 3 then
		return ",", "."
	end
	return plugin.t("format.group"), plugin.t("format.decimal")
end

-- 1234567.891 -> "1 234 567,89" or "1,234,567.89". A sum under one gets
-- more digits: 1 yen is 0.0063 USD, not 0.01.
local function money(value, group, decimal)
	local places = 2
	local size = math.abs(value)
	if size > 0 and size < 1 then
		places = math.min(8, math.max(2, 2 - math.floor(math.log(size, 10))))
	end
	local fixed = string.format("%." .. places .. "f", value)
	local whole, fraction = fixed:match("^(-?%d+)%.(%d+)$")
	if not whole then
		return fixed
	end
	if places > 2 then
		-- Only the digits that say something: 0.006300 -> 0.0063.
		fraction = fraction:gsub("0+$", "")
		if #fraction < 2 then
			fraction = fraction .. string.rep("0", 2 - #fraction)
		end
	end
	local sign = ""
	if whole:sub(1, 1) == "-" then
		sign, whole = "-", whole:sub(2)
	end
	local digits = {}
	for i = #whole, 1, -3 do
		table.insert(digits, 1, whole:sub(math.max(i - 2, 1), i))
	end
	return sign .. table.concat(digits, group) .. decimal .. fraction
end

-- A sum without ",00" at the end.
local function amountText(value, group, decimal)
	local text = money(value, group, decimal)
	local zeros = decimal .. "00"
	if text:sub(-#zeros) == zeros then
		text = text:sub(1, -#zeros - 1)
	end
	return text
end

-- "1,000,000" -> "1000000": commas between groups of three are thousands
-- when there are two of them at least; "1,5" stays a decimal.
local function thousands(number)
	local parts = {}
	for part in number:gmatch("[^,]+") do
		parts[#parts + 1] = part
	end
	if #parts < 3 or #parts[1] > 3 or number:find(",,") then
		return nil
	end
	for i = 2, #parts do
		if #parts[i] ~= 3 then
			return nil
		end
	end
	return table.concat(parts)
end

-- Text -> words where numbers and signs are apart: "100$" -> "100", "$".
local function split(text)
	text = lower(text):gsub("\u{a0}", " "):gsub("\u{202f}", " ")
	text = text:gsub("%d[%d,]*%d", thousands)
	-- "1 000 usd": a space inside a number groups its digits.
	local count
	repeat
		text, count = text:gsub("(%d) (%d%d%d)%f[^%d]", "%1%2")
	until count == 0
	text = text:gsub("(%d),(%d)", "%1.%2")
	local words = {}
	for word in text:gmatch("[^ \t\r\n]+") do
		-- "руб." and "р." are short for the ruble; "100," ends a phrase.
		word = word:gsub("[%.,;:!%?%)]+$", ""):gsub("^[%(]+", "")
		local number, tail = word:match("^(%d+%.?%d*)(.*)$")
		local head, after = word:match("^(%D+)(%d+%.?%d*)$")
		if number then
			words[#words + 1] = number
			if tail ~= "" then
				words[#words + 1] = tail
			end
		elseif head then
			words[#words + 1] = head
			words[#words + 1] = after
		elseif word ~= "" then
			words[#words + 1] = word
		end
	end
	return words
end

-- Default currencies to convert to: "RUB, EUR" from the settings.
local function defaultTargets(from)
	local list, seen = {}, {}
	for word in lower(setting("target", "")):gmatch("[^,; \t]+") do
		local wanted = code(word)
		if wanted and wanted ~= from and not seen[wanted] then
			seen[wanted] = true
			list[#list + 1] = wanted
		end
	end
	if #list == 0 then
		list[1] = (from == "RUB") and "USD" or "RUB"
	end
	return list
end

-- "/cur 100 usd rub", "/cur usd", "/cur 50 € в ₽", "/cur 100$ to eur cny",
-- "/cur 1.5k долларов". nil: not the command; false: could not read it.
local function parse(text)
	local rest = text:match("^/cur[ \t\r\n]+(.*)$") or ((text:match("^/cur[ \t\r\n]*$")) and "")
	if not rest then
		return nil
	end
	local amount, from, targets, seen = nil, nil, {}, {}
	local words = split(rest)
	local i = 1
	while i <= #words do
		local word = words[i]
		local number = tonumber(word)
		if number and not amount then
			amount = number
			local times = MULTIPLIERS[words[i + 1] or ""]
			if times then
				amount = amount * times
				i = i + 1
			end
		elseif not FILLER[word] then
			local found = code(word)
			if found and not from then
				from = found
			elseif found and found ~= from and not seen[found] then
				seen[found] = true
				targets[#targets + 1] = found
			end
		end
		i = i + 1
	end
	if not from then
		return false
	end
	if #targets == 0 then
		targets = defaultTargets(from)
	end
	return { amount = amount or 1, from = from, to = targets }
end

-- Sums in someone else's message: "250 €", "$100", "15 тыс. рублей".
local function findSums(text)
	local words = split(text)
	local sums = {}
	for i, word in ipairs(words) do
		local number = tonumber(word)
		if number and #sums < MENU_SUMS then
			local next = words[i + 1]
			local times = MULTIPLIERS[next or ""]
			if times then
				number = number * times
				next = words[i + 2]
			end
			-- After the number ("250 €") or before it ("$100"). Before
			-- counts only for signs: "в 2025 году" is not a sum in "в".
			local after = next and code(next)
			local before = words[i - 1] and ALIASES[words[i - 1]]
			local found = after or before
			if found and KNOWN[found] then
				sums[#sums + 1] = { amount = number, from = found }
			end
		end
	end
	return sums
end

local function notify(text)
	tg.toast{ title = plugin.t("title"), text = text }
end

local function dateText(unixtime)
	return plugin.t("format.date", {
		day = os.date("!%d", unixtime),
		month = os.date("!%m", unixtime),
		year = os.date("!%Y", unixtime),
	})
end

-- Rates for base: from the cache or from the service. Runs inside tg.async.
local function rates(base)
	local cached = cache[base]
	if cached and os.time() - cached.time < CACHE_SECONDS then
		return cached
	end
	local response = tg.http.request{
		url = "https://open.er-api.com/v6/latest/" .. base,
	}
	local problem
	local data = response.status == 200 and tg.json.decode(response.body or "") or nil
	if response.status ~= 200 then
		problem = plugin.t("error.service", response.error or tostring(response.status))
	elseif type(data) ~= "table" or data.result ~= "success" or type(data.rates) ~= "table" then
		if type(data) == "table" and data["error-type"] == "unsupported-code" then
			return nil, plugin.t("error.unknown", base)
		end
		problem = plugin.t("error.answer")
	end
	if problem then
		-- No network for a minute should not stop the conversion.
		if cached and os.time() - cached.time < STALE_SECONDS then
			cached.stale = true
			return cached
		end
		return nil, problem
	end
	cached = {
		rates = data.rates,
		time = os.time(),
		updated = tonumber(data.time_last_update_unix),
	}
	cache[base] = cached
	return cached
end

-- Lines of the answer for one sum, or nil and the problem.
local function convertLines(request)
	local result, problem = rates(request.from)
	if not result then
		return nil, problem
	end
	local group, decimal = separators()
	local lines = {}
	for _, to in ipairs(request.to) do
		local rate = result.rates[to]
		if not rate then
			return nil, plugin.t("error.unknown", to)
		end
		local line = plugin.t("reply", {
			amount = amountText(request.amount, group, decimal),
			from = request.from,
			result = money(request.amount * rate, group, decimal),
			to = to,
		})
		if setting("show_rate", false) and request.amount ~= 1 then
			line = line .. " " .. plugin.t("reply.rate", {
				from = request.from,
				rate = money(rate, group, decimal),
				to = to,
			})
		end
		lines[#lines + 1] = line
	end
	return lines, nil, result
end

local function dateLine(result)
	if not result.updated or not setting("show_date", true) then
		return nil
	end
	return plugin.t(result.stale and "reply.date_old" or "reply.date", dateText(result.updated))
end

local function convert(peer, request)
	local lines, problem, result = convertLines(request)
	if not lines then
		notify(problem)
		return
	end
	lines[#lines + 1] = dateLine(result)
	tg.messages.send(peer, table.concat(lines, "\n"))
end

-- What "Convert" and the settings row show: all sums into your currencies.
-- A sum that fails is skipped, so one odd word does not hide the others.
local function showSums(sums)
	local lines, last, problem = {}, nil, nil
	for _, sum in ipairs(sums) do
		local converted, failure, result = convertLines({
			amount = sum.amount,
			from = sum.from,
			to = sum.to or defaultTargets(sum.from),
		})
		if converted then
			for _, line in ipairs(converted) do
				lines[#lines + 1] = line
			end
			last = result
		else
			problem = failure
		end
	end
	if #lines == 0 then
		notify(problem or plugin.t("toast.no_sums"))
		return
	end
	local text = table.concat(lines, "\n")
	tg.ui.copy(text)
	local date = last and dateLine(last)
	tg.ui.alert(date and (text .. "\n\n" .. date) or text, plugin.t("dialog.title"))
end

plugin.on("message.send", function(draft)
	local request = parse(draft.text)
	if request == nil then
		return nil
	elseif request == false then
		notify(plugin.t("error.usage"))
		return false
	end
	tg.async(convert, draft.peer, request)
	return false -- the command itself is not sent
end)

plugin.menu{
	place = "message",
	text = plugin.t("menu.convert"),
	icon = "payment",
	on_click = function(ctx)
		local text = ctx.message and ctx.message.text
		local sums = text and findSums(text) or {}
		if #sums == 0 then
			notify(plugin.t("toast.no_sums"))
			return
		end
		tg.async(showSums, sums)
	end,
}

plugin.settings.page(function()
	return {
		{ type = "header", text = plugin.t("settings.conversion") },
		{
			type = "input",
			key = "target",
			text = plugin.t("settings.target"),
			subtext = plugin.t("settings.target.about"),
			placeholder = plugin.t("settings.target.placeholder"),
			icon = "payment",
		},
		{
			type = "text",
			text = plugin.t("settings.try"),
			subtext = plugin.t("settings.try.about"),
			icon = "search",
			on_click = function()
				tg.async(function()
					local typed = tg.ui.input{
						title = plugin.t("settings.try"),
						placeholder = plugin.t("settings.try.placeholder"),
					}
					if not typed or typed:match("^[ \t\r\n]*$") then
						return
					end
					local request = parse("/cur " .. typed)
					if not request then
						notify(plugin.t("error.usage"))
						return
					end
					showSums({ request })
				end)
			end,
		},
		{ type = "header", text = plugin.t("settings.answer") },
		{
			type = "selector",
			key = "number_format",
			text = plugin.t("settings.number_format"),
			items = {
				plugin.t("settings.number_format.auto"),
				money(1234.5, " ", ","),
				money(1234.5, ",", "."),
			},
			default = 1,
			icon = "font",
		},
		{
			type = "switch",
			key = "show_rate",
			text = plugin.t("settings.show_rate"),
			subtext = plugin.t("settings.show_rate.about"),
			icon = "stats",
			default = false,
		},
		{
			type = "switch",
			key = "show_date",
			text = plugin.t("settings.show_date"),
			subtext = plugin.t("settings.show_date.about"),
			icon = "schedule",
			default = true,
		},
		{ type = "divider", text = plugin.t("settings.usage") },
	}
end)
