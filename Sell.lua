local _, ns = ...

local Sell = { lowest = {}, own = {}, asked = {}, queue = {}, pending = {}, owned = {} }
ns.Sell = Sell

local DURATIONS = { "12h", "24h", "48h" }
Sell.DURATIONS = DURATIONS
local CUT = 0.05

function Sell.Durations()
	local out = {}
	for i, name in ipairs({ "AUCTION_DURATION_ONE", "AUCTION_DURATION_TWO", "AUCTION_DURATION_THREE" }) do
		local text = _G[name]
		out[i] = type(text) == "string" and text ~= "" and text or DURATIONS[i]
	end
	return out
end

local function api()
	return C_AuctionHouse
end

function Sell.Modern()
	local AH = api()
	return AH and AH.PostItem and AH.PostCommodity and ItemLocation and ItemLocation.CreateFromBagAndSlot and true or false
end

function Sell.Classic()
	return (PostAuction or StartAuction) and ClickAuctionSellItemButton and true or false
end

local function location(bag, slot)
	if not ItemLocation or not ItemLocation.CreateFromBagAndSlot then return nil end
	local ok, loc = pcall(ItemLocation.CreateFromBagAndSlot, ItemLocation, bag, slot)
	if ok then return loc end
end

local function numSlots(bag)
	local f = (C_Container and C_Container.GetContainerNumSlots) or GetContainerNumSlots
	if not f then return 0 end
	local ok, n = pcall(f, bag)
	if ok and type(n) == "number" then return n end
	return 0
end

local function slotInfo(bag, slot)
	if C_Container and C_Container.GetContainerItemInfo then
		local ok, t = pcall(C_Container.GetContainerItemInfo, bag, slot)
		if not ok or type(t) ~= "table" then return nil end
		return t.itemID, t.stackCount or 1, t.hyperlink, t.quality, t.isBound, t.isLocked, t.iconFileID
	elseif GetContainerItemInfo then
		local ok, icon, count, locked, quality, _, _, link, _, _, id = pcall(GetContainerItemInfo, bag, slot)
		if not ok or not link then return nil end
		if not id then id = tonumber(link:match("item:(%d+)")) end
		return id, count or 1, link, quality, false, locked, icon
	end
end

local scanner
local function tipLines(bag, slot)
	local out = {}
	if C_TooltipInfo and C_TooltipInfo.GetBagItem then
		local ok, data = pcall(C_TooltipInfo.GetBagItem, bag, slot)
		if ok and type(data) == "table" and type(data.lines) == "table" then
			for _, l in ipairs(data.lines) do
				if type(l) == "table" and type(l.leftText) == "string" and not ns.IsSecret(l.leftText) then out[#out + 1] = l.leftText end
			end
			return out
		end
	end
	if scanner == nil then
		local ok, tip = pcall(CreateFrame, "GameTooltip", "AAuctionScanTip", nil, "GameTooltipTemplate")
		scanner = ok and tip or false
	end
	if not scanner or not scanner.SetOwner or not scanner.SetBagItem then return out end
	scanner:SetOwner(UIParent, "ANCHOR_NONE")
	if not pcall(scanner.SetBagItem, scanner, bag, slot) then return out end
	for i = 1, (scanner.NumLines and scanner:NumLines()) or 0 do
		local fs = _G["AAuctionScanTipTextLeft" .. i]
		local text = fs and fs.GetText and fs:GetText()
		if type(text) == "string" and text ~= "" then out[#out + 1] = text end
	end
	return out
end

local conjured = {}
local function blocked(bag, slot, id, checkBound)
	if conjured[id] ~= nil and not checkBound then return conjured[id] end
	local lines = tipLines(bag, slot)
	local made, bound = false, false
	for _, text in ipairs(lines) do
		if text == ITEM_CONJURED then made = true end
		if text == ITEM_SOULBOUND or text == ITEM_BIND_QUEST or text == ITEM_ACCOUNTBOUND or text == ITEM_BNETACCOUNTBOUND then bound = true end
	end
	if #lines > 0 then conjured[id] = made end
	return made or (checkBound and bound) or false
end

local function sellable(bag, slot)
	local AH = api()
	if AH and AH.IsSellItemValid then
		local loc = location(bag, slot)
		if loc then
			local ok, valid = pcall(AH.IsSellItemValid, loc, false)
			if ok and valid == false then return false end
		end
	end
	return true
end

local function commodity(bag, slot)
	local AH = api()
	if not AH or not AH.GetItemCommodityStatus then return false end
	local loc = location(bag, slot)
	if not loc then return false end
	local ok, status = pcall(AH.GetItemCommodityStatus, loc)
	return ok and status == 2
end

local function fresh(e)
	return e and e.b and (e.q or 0) > 0 and e.t and ns.Now() - e.t < 2 * 86400
end

function Sell.Step()
	local AH = api()
	if AH and AH.SupportsCopperValues then
		local ok, copper = pcall(AH.SupportsCopperValues)
		if ok and copper == false then return 100 end
	end
	return 1
end

local function mine(id)
	local best
	for _, a in ipairs(Sell.owned) do
		if a.id == id and (not best or a.unit < best) then best = a.unit end
	end
	return best
end

function Sell.Price(id)
	local cfg = ns.db.sell
	local entry = ns.Entry(id)
	local market = entry and entry.m
	local vendor = ns.VendorPrice(id)
	local low = Sell.lowest[id]
	local stale = false
	if not low and fresh(entry) then low, stale = entry.b, true end
	local price, source
	local kept = cfg.prices[id]
	local own = stale and mine(id)
	if kept then
		price, source = kept, "kept"
	elseif own and own <= low then
		price, source = own, "own"
	elseif low then
		if cfg.rule == "percent" then
			price = math.floor(low * (1 - (cfg.percent or 1) / 100))
		elseif cfg.rule == "match" then
			price = low
		else
			price = low - Sell.Step()
		end
		source = "undercut"
	elseif market then
		price, source = math.floor(market * (cfg.marketMult or 1) + 0.5), "market"
	elseif vendor then
		price, source = math.floor(vendor * (cfg.vendorMult or 3) + 0.5), "vendor"
	end
	local step = Sell.Step()
	if price and step > 1 and not kept then
		if source == "undercut" or source == "own" then
			price = math.floor(price / step) * step
		else
			price = math.ceil(price / step) * step
		end
	end
	if price and not kept and vendor then
		local floor = math.ceil(vendor * (1 + (cfg.margin or 5) / 100) / (1 - CUT))
		floor = math.ceil(floor / step) * step
		if price < floor then
			price = floor
			if source == "undercut" or source == "own" then source = "floor" end
		end
	end
	if price and price < step then price = step end
	return price, source, low, market, vendor
end

function Sell.Items()
	local byId, list = {}, {}
	local legacy = not (C_Container and C_Container.GetContainerItemInfo)
	for bag = 0, 4 do
		for slot = 1, numSlots(bag) do
			local id, count, link, quality, bound, locked, icon = slotInfo(bag, slot)
			if type(id) == "number" and link and not bound and not locked then
				local e = byId[id]
				if e == nil then
					local classID
					local instant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
					if instant then
						local ok, _, _, _, _, _, c = pcall(instant, id)
						if ok then classID = c end
					end
					if classID == 12 or not sellable(bag, slot) or blocked(bag, slot, id, legacy) then
						byId[id] = false
					else
						e = {
							id = id, link = link, quality = quality or ns.ItemQuality(id), icon = icon,
							name = link:match("%[(.-)%]") or ns.ItemName(id), count = 0, slots = {},
							commodity = commodity(bag, slot),
						}
						byId[id] = e
						list[#list + 1] = e
					end
				end
				if e then
					e.count = e.count + count
					e.slots[#e.slots + 1] = { bag, slot, count }
				end
			end
		end
	end
	for _, e in ipairs(list) do
		e.stacks = #e.slots
		e.price, e.source, e.low, e.market, e.vendor = Sell.Price(e.id)
	end
	table.sort(list, function(a, b)
		if a.name ~= b.name then return a.name < b.name end
		return a.id < b.id
	end)
	return list
end

function Sell.Find(id)
	for _, e in ipairs(Sell.Items()) do
		if e.id == id then return e end
	end
end

function Sell.Quantity(e, qty)
	if e.commodity then
		qty = tonumber(qty) or e.count
		return math.max(1, math.min(e.count, math.floor(qty)))
	end
	return e.slots[1][3]
end

function Sell.NeedsConfirm(e, price, qty)
	price = price or e.price
	if not price then return true, "no price data" end
	if e.source == nil or e.source == "vendor" then return true, "no auction price known" end
	if (e.quality or 1) >= 3 then return true, "rare or better" end
	if e.vendor and price < e.vendor then return true, "below the vendor price" end
	if e.market and e.source ~= "kept" and price < e.market * 0.5 then return true, "less than half the market value" end
	local limit = ns.db.sell.threshold or 0
	if limit > 0 and price * Sell.Quantity(e, qty) > limit then return true, "above the safety limit" end
	return false
end

function Sell.Deposit(e, duration, qty)
	local AH = api()
	if not AH then return nil end
	qty = Sell.Quantity(e, qty)
	if e.commodity and AH.CalculateCommodityDeposit then
		local ok, d = pcall(AH.CalculateCommodityDeposit, e.id, duration, qty)
		if ok and type(d) == "number" then return d end
	elseif AH.CalculateItemDeposit then
		local loc = location(e.slots[1][1], e.slots[1][2])
		if loc then
			local ok, d = pcall(AH.CalculateItemDeposit, loc, duration, qty)
			if ok and type(d) == "number" then return d end
		end
	end
	return nil
end

local function ready()
	local AH = api()
	if AH and AH.IsThrottledMessageSystemReady then
		local ok, r = pcall(AH.IsThrottledMessageSystemReady)
		if ok and r == false then return false end
	end
	return true
end

local function logPost(p)
	if ns.db.sell.log == false then return end
	ns.Print("posted " .. p.qty .. "x " .. p.name .. " at " .. ACore.Money(p.price) .. " each")
end

function Sell.Post(e, opts)
	opts = opts or {}
	if not ns.ahOpen then return false, "open the auction house first" end
	local price = opts.price or e.price
	if not price or price < 1 then return false, "no price set" end
	local duration = opts.duration or ns.db.sell.duration or 2
	local qty = Sell.Quantity(e, opts.qty)
	local bidPct = opts.bid or ns.db.sell.bid or 100
	local step = Sell.Step()
	if price % step ~= 0 then return false, "prices must be in whole silver here" end
	local bid = bidPct < 100 and math.max(step, math.floor(price * bidPct / 100 / step) * step) or nil
	local bag, slot = e.slots[1][1], e.slots[1][2]
	local AH = api()
	if Sell.Modern() then
		if not ready() then return false, "the auction house is busy, click again" end
		local loc = location(bag, slot)
		if not loc then return false, "item not found" end
		local ok, needs
		local a = Sell.awaiting
		local confirm = e.commodity and AH.ConfirmPostCommodity or (not e.commodity and AH.ConfirmPostItem) or nil
		Sell.awaiting = nil
		if a and confirm and opts.force and a.id == e.id and a.price == price and a.qty == qty and a.duration == duration and a.bid == bid then
			if e.commodity then
				ok = pcall(confirm, loc, duration, qty, price)
			else
				ok = pcall(confirm, loc, duration, qty, bid, price)
			end
		elseif e.commodity then
			ok, needs = pcall(AH.PostCommodity, loc, duration, qty, price)
		else
			ok, needs = pcall(AH.PostItem, loc, duration, qty, bid, price)
		end
		if not ok then return false, "the auction house refused the post" end
		if needs and confirm then
			Sell.awaiting = { id = e.id, price = price, qty = qty, duration = duration, bid = bid }
			return false, "confirm"
		end
		Sell.pending[#Sell.pending + 1] = { name = e.name, qty = qty, price = price, id = e.id }
	elseif Sell.Classic() then
		local pick = (C_Container and C_Container.PickupContainerItem) or PickupContainerItem
		if not pick then return false, "cannot pick the item up" end
		if ClearCursor then ClearCursor() end
		pick(bag, slot)
		ClickAuctionSellItemButton()
		if ClearCursor then ClearCursor() end
		if GetAuctionSellItemInfo then
			local okInfo, placed = pcall(GetAuctionSellItemInfo)
			if okInfo and not placed then return false, "that item cannot be auctioned" end
		end
		local post = PostAuction or StartAuction
		local ok = pcall(post, (bid or price) * qty, price * qty, duration, qty, 1)
		if not ok then return false, "the auction house refused the post" end
		logPost({ name = e.name, qty = qty, price = price })
	else
		return false, "no posting API on this client"
	end
	Sell.own[e.id] = math.min(Sell.own[e.id] or price, price)
	ns:Fire("SELL_CHANGED")
	return true
end

function Sell.Click(e, opts)
	local confirm, why = Sell.NeedsConfirm(e, opts and opts.price, opts and opts.qty)
	if confirm and not (opts and opts.force) then return "select", why end
	local ok, err = Sell.Post(e, opts)
	if not ok then
		if err == "confirm" then return "confirm", "the auction house asks you to confirm this price" end
		ns.Print(err)
		return "error", err
	end
	return "posted"
end

local function send(id)
	local AH = api()
	if not AH or not AH.MakeItemKey then return end
	local e = Sell.Find(id)
	local okKey, key = pcall(AH.MakeItemKey, id)
	if not okKey or not key then return end
	Sell.asked[id] = ns.Now()
	if e and not e.commodity and AH.SendSellSearchQuery then
		pcall(AH.SendSellSearchQuery, key, {}, false)
	elseif AH.SendSearchQuery then
		pcall(AH.SendSearchQuery, key, {}, false)
	end
end

function Sell.Query(id)
	if not ns.ahOpen or type(id) ~= "number" then return false end
	local AH = api()
	if not AH or not AH.SendSearchQuery then return false end
	local last = Sell.asked[id]
	if last and ns.Now() - last < 30 then return false end
	if not ready() then
		Sell.queue[1] = id
		return false
	end
	send(id)
	return true
end

local function setLowest(id, low, mine, qty)
	Sell.lowest[id] = low
	if mine then Sell.own[id] = mine end
	if low then ns.Observe(id, low, qty) end
	ns:Fire("SELL_CHANGED")
end

ns:On("COMMODITY_SEARCH_RESULTS_UPDATED", function(id)
	local AH = api()
	if type(id) ~= "number" or not AH or not AH.GetNumCommoditySearchResults then return end
	local ok, n = pcall(AH.GetNumCommoditySearchResults, id)
	if not ok or type(n) ~= "number" then return end
	local low, mine, total = nil, nil, 0
	for i = 1, n do
		local okInfo, r = pcall(AH.GetCommoditySearchResultInfo, id, i)
		if okInfo and type(r) == "table" and type(r.unitPrice) == "number" then
			total = total + (r.quantity or 0)
			local allMine = r.containsOwnerItem and (r.numOwnerItems or 0) >= (r.quantity or 0)
			if allMine then
				if not mine or r.unitPrice < mine then mine = r.unitPrice end
			elseif not low or r.unitPrice < low then
				low = r.unitPrice
			end
		end
	end
	setLowest(id, low, mine, total)
end)

ns:On("ITEM_SEARCH_RESULTS_UPDATED", function(key)
	local AH = api()
	if type(key) ~= "table" or type(key.itemID) ~= "number" or not AH or not AH.GetNumItemSearchResults then return end
	local ok, n = pcall(AH.GetNumItemSearchResults, key)
	if not ok or type(n) ~= "number" then return end
	local low, mine, total = nil, nil, 0
	for i = 1, n do
		local okInfo, r = pcall(AH.GetItemSearchResultInfo, key, i)
		if okInfo and type(r) == "table" and type(r.buyoutAmount) == "number" and r.buyoutAmount > 0 then
			total = total + math.max(1, type(r.quantity) == "number" and r.quantity or 1)
			local unit = r.buyoutAmount
			if r.containsOwnerItem then
				if not mine or unit < mine then mine = unit end
			elseif not low or unit < low then
				low = unit
			end
		end
	end
	setLowest(key.itemID, low and math.floor(low + 0.5), mine and math.floor(mine + 0.5), total)
end)

ns:On("AUCTION_HOUSE_THROTTLED_SYSTEM_READY", function()
	local id = table.remove(Sell.queue, 1)
	if id then send(id) end
end)

ns:On("AUCTION_HOUSE_AUCTION_CREATED", function()
	local p = table.remove(Sell.pending, 1)
	if p then logPost(p) end
	Sell.RefreshOwned()
end)

ns:On("AUCTION_HOUSE_SHOW_ERROR", function()
	local p = table.remove(Sell.pending, 1)
	if p then ns.Print("could not post " .. p.name) end
	ns:Fire("SELL_CHANGED")
end)

function Sell.RefreshOwned()
	local AH = api()
	if AH and AH.QueryOwnedAuctions then
		pcall(AH.QueryOwnedAuctions, {})
	elseif GetOwnerAuctionItems then
		pcall(GetOwnerAuctionItems)
	end
end

local function readOwned()
	local AH = api()
	local out = {}
	if AH and AH.GetNumOwnedAuctions and AH.GetOwnedAuctionInfo then
		local ok, n = pcall(AH.GetNumOwnedAuctions)
		if not ok or type(n) ~= "number" then return out end
		for i = 1, n do
			local okInfo, r = pcall(AH.GetOwnedAuctionInfo, i)
			if okInfo and type(r) == "table" and (r.status == nil or r.status == 0) and type(r.itemKey) == "table" then
				local id = r.itemKey.itemID
				if type(id) == "number" and type(r.buyoutAmount) == "number" and r.buyoutAmount > 0 then
					out[#out + 1] = { auction = r.auctionID, id = id, unit = r.buyoutAmount, qty = r.quantity or 1, link = r.itemLink }
				end
			end
		end
	elseif GetNumAuctionItems and GetAuctionItemInfo then
		local ok, n = pcall(GetNumAuctionItems, "owner")
		if not ok or type(n) ~= "number" then return out end
		for i = 1, n do
			local r = { pcall(GetAuctionItemInfo, "owner", i) }
			local qty, buyout, id, sold = r[4], r[11], r[18], r[17]
			if r[1] and type(id) == "number" and type(buyout) == "number" and buyout > 0 and sold ~= 1 then
				qty = type(qty) == "number" and qty > 0 and qty or 1
				out[#out + 1] = { index = i, id = id, unit = math.floor(buyout / qty + 0.5), qty = qty }
			end
		end
	end
	return out
end

function Sell.Undercut()
	local rows = {}
	for _, a in ipairs(Sell.owned) do
		local low = Sell.lowest[a.id]
		if not low then
			local entry = ns.Entry(a.id)
			if fresh(entry) then low = entry.b end
		end
		if low and low < a.unit then
			a.low = low
			a.name = a.link and a.link:match("%[(.-)%]") or ns.ItemName(a.id, ns.Entry(a.id))
			rows[#rows + 1] = a
		end
	end
	table.sort(rows, function(a, b)
		if a.name ~= b.name then return a.name < b.name end
		return a.unit < b.unit
	end)
	return rows
end

function Sell.Cancel(a)
	local AH = api()
	if a.auction and AH and AH.CancelAuction then
		if AH.CanCancelAuction then
			local ok, can = pcall(AH.CanCancelAuction, a.auction)
			if ok and can == false then return false, "that auction cannot be cancelled" end
		end
		if not ready() then return false, "the auction house is busy, click again" end
		local ok = pcall(AH.CancelAuction, a.auction)
		if not ok then return false, "cancel refused" end
	elseif a.index and CancelAuction then
		local ok = pcall(CancelAuction, a.index)
		if not ok then return false, "cancel refused" end
	else
		return false, "no cancel API on this client"
	end
	for i, o in ipairs(Sell.owned) do
		if o == a then table.remove(Sell.owned, i) break end
	end
	if ns.db.sell.log ~= false then ns.Print("cancelled " .. (a.name or ns.ItemName(a.id))) end
	ns:Fire("SELL_CHANGED")
	return true
end

local function owned()
	Sell.owned = readOwned()
	ns:Fire("SELL_CHANGED")
end

ns:On("OWNED_AUCTIONS_UPDATED", owned)
ns:On("AUCTION_OWNED_LIST_UPDATE", owned)
ns:On("AUCTION_CANCELED", function() Sell.RefreshOwned() end)
ns:On("BAG_UPDATE_DELAYED", function()
	if ns.ahOpen then ns.Debounce("sellbags", 0.2, function() ns:Fire("SELL_CHANGED") end) end
end)

ns:Listen("AH_CHANGED", function()
	if ns.ahOpen then
		Sell.RefreshOwned()
	else
		Sell.lowest, Sell.asked, Sell.queue, Sell.pending, Sell.owned = {}, {}, {}, {}, {}
		Sell.awaiting = nil
	end
end)

local function focusSlot()
	local f
	if GetMouseFoci then
		local ok, list = pcall(GetMouseFoci)
		f = ok and type(list) == "table" and list[1] or nil
	elseif GetMouseFocus then
		local ok, v = pcall(GetMouseFocus)
		f = ok and v or nil
	end
	if type(f) ~= "table" or not f.GetID or not f.GetParent then return nil end
	local ok, slot = pcall(f.GetID, f)
	local bag
	if f.GetBagID then
		local okBag, b = pcall(f.GetBagID, f)
		if okBag then bag = b end
	end
	if type(bag) ~= "number" then
		local okParent, parent = pcall(f.GetParent, f)
		if okParent and type(parent) == "table" and parent.GetID then
			local okID, b = pcall(parent.GetID, parent)
			if okID then bag = b end
		end
	end
	if ok and type(slot) == "number" and type(bag) == "number" then return bag, slot end
	return nil
end

local function modified(link, loc)
	if not ns.ahOpen or not ns.db or type(link) ~= "string" then return end
	local id = tonumber(link:match("item:(%d+)"))
	if not id then return end
	local alt = IsAltKeyDown and IsAltKeyDown()
	local shift = IsShiftKeyDown and IsShiftKeyDown()
	if not alt and not shift then return end
	local e = Sell.Find(id)
	if not e then return end
	local bag, slot
	if type(loc) == "table" and loc.GetBagAndSlot then
		local ok, b, s = pcall(loc.GetBagAndSlot, loc)
		if ok then bag, slot = b, s end
	end
	if not bag or not slot then bag, slot = focusSlot() end
	local inBags = false
	if bag and slot then
		for i, s in ipairs(e.slots) do
			if s[1] == bag and s[2] == slot then
				table.remove(e.slots, i)
				table.insert(e.slots, 1, s)
				inBags = true
				break
			end
		end
	end
	if alt and ns.db.sell.alt ~= false then
		if not inBags then return end
		local result, why = Sell.Click(e)
		if result == "select" or result == "confirm" then
			ns.Print(e.name .. " not posted: " .. why .. ". Use the Post button.")
			if ns.SellUI then ns.SellUI.Select(id) end
		end
	elseif shift and ns.SellUI and ns.SellUI.Shown() then
		ns.SellUI.Select(id)
	end
end
Sell.Modified = modified

ns:Listen("LOGIN", function()
	if hooksecurefunc and HandleModifiedItemClick then
		pcall(hooksecurefunc, "HandleModifiedItemClick", modified)
	end
end)

local function radio(tbl, key, value, text)
	return {
		text = text, checked = tbl[key] == value,
		func = function()
			tbl[key] = value
			ns:Fire("SELL_CHANGED")
			ns:Fire("PRICES_CHANGED")
		end,
	}
end

function ns.Options()
	local UI = ns.UI
	local db = ns.db
	local s = db.sell
	local function changed() ns:Fire("SELL_CHANGED") end
	local entries = {
		{ text = "Prices", title = true },
		UI.Check(db, "tooltip", "Show prices in item tooltips"),
		UI.Check(db, "stack", "Show the stack total too"),
		UI.Check(db, "vendor", "Show the vendor price"),
		UI.Check(db, "passive", "Learn prices while I browse the auction house"),
		{ text = "Deals are this far below market value", title = true },
		radio(db, "deal", 20, "20%"),
		radio(db, "deal", 30, "30%"),
		radio(db, "deal", 50, "50%"),
		{ text = "Selling", title = true },
		UI.Check(s, "open", "Open the Sell view with the auction house"),
		UI.Check(s, "alt", "Alt-click a bag item to post it"),
		UI.Check(s, "log", "Say what was posted in chat"),
		{ text = "Suggested price", title = true },
		radio(s, "rule", "copper", "Undercut the lowest by the smallest step"),
		radio(s, "rule", "percent", "Undercut the lowest by " .. (s.percent or 1) .. "%"),
		radio(s, "rule", "match", "Match the lowest"),
		{ text = "Undercut percent", title = true },
	}
	for _, p in ipairs({ 1, 2, 5, 10 }) do
		entries[#entries + 1] = radio(s, "percent", p, p .. "%")
	end
	entries[#entries + 1] = { text = "With no auctions to compare", title = true }
	for _, m in ipairs({ 0.9, 1, 1.1, 1.25 }) do
		entries[#entries + 1] = radio(s, "marketMult", m, "Market value x " .. m)
	end
	for _, m in ipairs({ 2, 3, 5 }) do
		entries[#entries + 1] = radio(s, "vendorMult", m, "Vendor price x " .. m .. " when nothing is known")
	end
	entries[#entries + 1] = { text = "One-click safety limit", title = true }
	for _, g in ipairs({ 0, 10, 50, 200, 1000 }) do
		entries[#entries + 1] = radio(s, "threshold", g * 10000, g == 0 and "No limit" or (g .. " gold per post"))
	end
	entries[#entries + 1] = { text = "Default duration", title = true }
	for i, d in ipairs(Sell.Durations()) do
		entries[#entries + 1] = radio(s, "duration", i, d)
	end
	entries[#entries + 1] = { text = "Data", title = true }
	entries[#entries + 1] = {
		text = "Forget my remembered prices",
		func = function()
			s.prices = {}
			changed()
		end,
	}
	entries[#entries + 1] = {
		text = "Try the fast full scan again",
		func = function()
			ns.RetryFullScan()
			ns.Print("the next scan asks for the whole auction house at once")
		end,
	}
	entries[#entries + 1] = {
		text = "Remove items not seen for 30 days",
		func = function() ns.Print("removed " .. ns.Purge(30) .. " items") end,
	}
	entries[#entries + 1] = {
		text = "Forget all prices on this realm",
		func = function()
			UI.Confirm("Forget every price stored for " .. ns.realmKey .. "?", function()
				ns.db.realms[ns.realmKey] = nil
				ns:Fire("PRICES_CHANGED")
			end)
		end,
	}
	return entries
end
