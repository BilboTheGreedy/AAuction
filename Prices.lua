local _, ns = ...

local HISTORY = 12
local GetInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

function ns.Realm()
	local realms = ns.db.realms
	local r = realms[ns.realmKey]
	if not r then
		r = { items = {}, scans = 0 }
		realms[ns.realmKey] = r
	end
	return r
end

function ns.Entry(id)
	return ns.Realm().items[id]
end

function ns.Market(units)
	if #units == 0 then return nil end
	table.sort(units, function(a, b) return a[1] < b[1] end)
	local total = 0
	for i = 1, #units do total = total + units[i][2] end
	local want = math.max(1, math.ceil(total * 0.3))
	local low = units[1][1]
	local taken, sum = 0, 0
	for i = 1, #units do
		local price, qty = units[i][1], units[i][2]
		if taken > 0 and price > low * 3 then break end
		local n = math.min(qty, want - taken)
		sum = sum + price * n
		taken = taken + n
		if taken >= want then break end
	end
	return math.floor(sum / taken + 0.5)
end

local function entry(items, id)
	local e = items[id]
	if not e then
		e = { n = 0 }
		items[id] = e
	end
	return e
end

function ns.Commit(found, full)
	local realm = ns.Realm()
	local items = realm.items
	local now = ns.Now()
	local count = 0
	for id, f in pairs(found) do
		local value = ns.Market(f.units)
		if value then
			local e = entry(items, id)
			e.b = math.floor(f.min + 0.5)
			e.q = f.qty
			e.t = now
			e.n = e.n + 1
			if f.name then e.s = f.name end
			if e.m then
				e.m = math.floor(e.m * 0.7 + value * 0.3 + 0.5)
			else
				e.m = value
			end
			local h = e.h or {}
			h[#h + 1] = e.b
			while #h > HISTORY do table.remove(h, 1) end
			e.h = h
			count = count + 1
		end
	end
	if full then
		for id, e in pairs(items) do
			if not found[id] then e.q = 0 end
		end
		realm.scans = (realm.scans or 0) + 1
		realm.last = now
	end
	ns:Fire("PRICES_CHANGED")
	return count
end

function ns.Observe(id, minPrice, qty, name)
	if type(id) ~= "number" or type(minPrice) ~= "number" or minPrice <= 0 then return end
	local e = entry(ns.Realm().items, id)
	local now = ns.Now()
	e.b = math.floor(minPrice + 0.5)
	if type(qty) == "number" then e.q = qty end
	if name then e.s = name end
	if not e.m then
		e.m = e.b
		e.n = 1
		e.h = { e.b }
	elseif not e.t or now - e.t > 3600 then
		e.m = math.floor(e.m * 0.9 + e.b * 0.1 + 0.5)
	end
	e.t = now
end

function ns.GetPrice(id)
	if type(id) ~= "number" or not ns.db then return nil end
	local e = ns.Entry(id)
	if not e or not e.m then return nil end
	return e.m, e.b, e.n, e.t, e.q
end

function ns.Trend(e)
	if not e or not e.m or not e.b or e.m <= 0 then return nil end
	return (e.b - e.m) / e.m
end

function ns.Average(e)
	local h = e and e.h
	if not h or #h == 0 then return nil end
	local sum = 0
	for i = 1, #h do sum = sum + h[i] end
	return math.floor(sum / #h + 0.5)
end

function ns.Purge(days)
	local limit = ns.Now() - days * 86400
	local items = ns.Realm().items
	local removed = 0
	for id, e in pairs(items) do
		if not e.t or e.t < limit then
			items[id] = nil
			removed = removed + 1
		end
	end
	ns:Fire("PRICES_CHANGED")
	return removed
end

function ns.Total()
	local n = 0
	for _ in pairs(ns.Realm().items) do n = n + 1 end
	return n
end

function ns.ItemName(id, e)
	if GetInfo then
		local ok, name = pcall(GetInfo, id)
		if ok and type(name) == "string" and name ~= "" then return name end
	end
	return e and e.s or ("Item " .. id)
end

function ns.ItemQuality(id)
	if GetInfo then
		local ok, _, _, quality = pcall(GetInfo, id)
		if ok and type(quality) == "number" then return quality end
	end
	return 1
end

function ns.VendorPrice(id)
	if GetInfo then
		local r = { pcall(GetInfo, id) }
		local price = r[1] and r[12]
		if type(price) == "number" and not ns.IsSecret(price) and price > 0 then return price end
	end
	return nil
end

local SORT = {
	name = function(r) return r.lname end,
	qty = function(r) return r.e.q or 0 end,
	min = function(r) return r.e.b or 0 end,
	market = function(r) return r.e.m or 0 end,
	trend = function(r) return r.trend or 0 end,
	age = function(r) return -(r.e.t or 0) end,
}

function ns.Rows(query, key, desc)
	local words = {}
	for w in (query or ""):lower():gmatch("%S+") do words[#words + 1] = w end
	local rows = {}
	for id, e in pairs(ns.Realm().items) do
		if e.m then
			local name = ns.ItemName(id, e)
			local lname = name:lower()
			local hit = true
			for i = 1, #words do
				if not lname:find(words[i], 1, true) then hit = false break end
			end
			if hit then
				rows[#rows + 1] = { id = id, e = e, name = name, lname = lname, trend = ns.Trend(e) }
			end
		end
	end
	local get = SORT[key] or SORT.name
	table.sort(rows, function(a, b)
		local x, y = get(a), get(b)
		if x ~= y then
			if desc then return x > y end
			return x < y
		end
		return a.id < b.id
	end)
	return rows
end

function AAuction.GetPrice(id)
	return ns.GetPrice(id)
end

function AAuction.GetVendorPrice(id)
	return ns.VendorPrice(id)
end
