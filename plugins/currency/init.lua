-- Курсы валют: «/cur 100 usd rub» не уходит, вместо него плагин спрашивает
-- курс у open.er-api.com (бесплатно, без ключа) и отправляет ответ.
-- Курсы одной валюты держатся час, чтобы не спрашивать на каждое сообщение.
-- Валюта по умолчанию, вид чисел и дата курса — на странице настроек.

local CACHE_SECONDS = 3600

-- Слова и значки в команде: и по-русски, и по-английски, на любом языке
-- интерфейса.
local ALIASES = {
	["$"] = "USD", ["доллар"] = "USD", ["доллара"] = "USD", ["долларов"] = "USD",
	["бакс"] = "USD", ["баксов"] = "USD", ["dollar"] = "USD", ["dollars"] = "USD",
	["€"] = "EUR", ["евро"] = "EUR", ["euro"] = "EUR", ["euros"] = "EUR",
	["₽"] = "RUB", ["руб"] = "RUB", ["рубль"] = "RUB", ["рубля"] = "RUB",
	["рублей"] = "RUB", ["р"] = "RUB", ["ruble"] = "RUB", ["rubles"] = "RUB",
	["rouble"] = "RUB", ["roubles"] = "RUB",
	["¥"] = "CNY", ["юань"] = "CNY", ["юаня"] = "CNY", ["юаней"] = "CNY",
	["yuan"] = "CNY",
	["£"] = "GBP", ["фунт"] = "GBP", ["фунтов"] = "GBP", ["pound"] = "GBP",
	["pounds"] = "GBP",
	["₸"] = "KZT", ["тенге"] = "KZT", ["tenge"] = "KZT",
	["₴"] = "UAH", ["гривна"] = "UAH", ["гривен"] = "UAH", ["hryvnia"] = "UAH",
	["byn"] = "BYN", ["белруб"] = "BYN",
	["лира"] = "TRY", ["лир"] = "TRY", ["lira"] = "TRY",
	["иена"] = "JPY", ["иен"] = "JPY", ["йена"] = "JPY", ["yen"] = "JPY",
	["вон"] = "KRW", ["won"] = "KRW",
}

local cache = {} -- base code -> { rates = {...}, time = os.time(), updated = unixtime }

-- string.lower знает только латиницу: «Доллар» -> «доллар» делаем сами.
local function lower(text)
	if not utf8.len(text) then
		return text:lower()
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

local function code(word)
	if not word then
		return nil
	end
	local alias = ALIASES[word] or ALIASES[lower(word)]
	if alias then
		return alias
	end
	if word:match("^%a%a%a$") then
		return word:upper()
	end
	return nil
end

-- Разделители чисел: из настроек или из языка интерфейса.
local function separators()
	local mode = plugin.settings.get("number_format", 1)
	if mode == 2 then
		return " ", ","
	elseif mode == 3 then
		return ",", "."
	end
	return plugin.t("format.group"), plugin.t("format.decimal")
end

-- 1234567.891 -> «1 234 567,89» или «1,234,567.89»
local function money(value, group, decimal)
	local fixed = string.format("%.2f", value)
	local whole, fraction = fixed:match("^(-?%d+)%.(%d+)$")
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

-- Сумма без «,00» в конце.
local function amount_text(value, group, decimal)
	local text = money(value, group, decimal)
	local zeros = decimal .. "00"
	if text:sub(-#zeros) == zeros then
		text = text:sub(1, -#zeros - 1)
	end
	return text
end

-- Валюта, в которую переводить, если в команде она одна.
local function target(from)
	local wanted = code((plugin.settings.get("target", "")):match("^%s*(.-)%s*$"))
	wanted = wanted or "RUB"
	if from ~= wanted then
		return wanted
	end
	return wanted == "USD" and "EUR" or "USD"
end

-- «/cur 100 usd rub», «/cur usd», «/cur 50 € в ₽», «/cur 100$ to eur»
local function parse(text)
	local rest = text:match("^/cur%s+(.*)$") or ((text == "/cur") and "")
	if not rest then
		return nil
	end
	rest = lower(rest):gsub(",", ".")
		:gsub("%s+в%s+", " "):gsub("%s+to%s+", " "):gsub("%s+in%s+", " ")
	local words = {}
	for word in rest:gmatch("%S+") do
		-- «100$» -> «100», «$»
		local number, sign = word:match("^([%d%.]+)(%D+)$")
		if number then
			words[#words + 1] = number
			words[#words + 1] = sign
		else
			words[#words + 1] = word
		end
	end
	local amount = tonumber(words[1])
	local first = amount and 2 or 1
	local from = code(words[first])
	if not from then
		return false
	end
	local to = code(words[first + 1]) or target(from)
	return { amount = amount or 1, from = from, to = to }
end

local function notify(text)
	tg.toast{ title = plugin.t("title"), text = text }
end

-- Курсы для base: из кэша или от сервиса. Работает внутри tg.async.
local function rates(base)
	local cached = cache[base]
	if cached and os.time() - cached.time < CACHE_SECONDS then
		return cached
	end
	local response = tg.http.request{
		url = "https://open.er-api.com/v6/latest/" .. base,
	}
	if response.status ~= 200 then
		local problem = response.error or tostring(response.status)
		return nil, plugin.t("error.service", problem)
	end
	local data = tg.json.decode(response.body or "")
	if not data or data.result ~= "success" or type(data.rates) ~= "table" then
		if data and data["error-type"] == "unsupported-code" then
			return nil, plugin.t("error.unknown", base)
		end
		return nil, plugin.t("error.answer")
	end
	cached = {
		rates = data.rates,
		time = os.time(),
		updated = tonumber(data.time_last_update_unix),
	}
	cache[base] = cached
	return cached
end

local function convert(peer, request)
	local result, problem = rates(request.from)
	if not result then
		notify(problem)
		return
	end
	local rate = result.rates[request.to]
	if not rate then
		notify(plugin.t("error.unknown", request.to))
		return
	end
	local group, decimal = separators()
	local text = plugin.t("reply", {
		amount = amount_text(request.amount, group, decimal),
		from = request.from,
		result = money(request.amount * rate, group, decimal),
		to = request.to,
	})
	if result.updated and plugin.settings.get("show_date", true) then
		local date = plugin.t("format.date", {
			day = os.date("!%d", result.updated),
			month = os.date("!%m", result.updated),
			year = os.date("!%Y", result.updated),
		})
		text = text .. "\n" .. plugin.t("reply.date", date)
	end
	tg.messages.send(peer, text)
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
	return false -- сама команда не уходит
end)

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
			key = "show_date",
			text = plugin.t("settings.show_date"),
			subtext = plugin.t("settings.show_date.about"),
			icon = "schedule",
			default = true,
		},
		{ type = "divider", text = plugin.t("settings.usage") },
	}
end)
