local _, ns = ...

local BATCH = 500
local ROUNDS = 8
local TIMEOUT = 45
local COOLDOWN = 900

local scan = { state = "idle", total = 0, done = 0, missing = 0 }
ns.scan = scan

local AH = C_AuctionHouse

local function modern()
	return AH and AH.ReplicateItems and AH.GetNumReplicateItems and AH.GetReplicateItemInfo
end

local function classic()
	return QueryAuctionItems and GetNumAuctionItems and GetAuctionItemInfo
end

function ns.ScanKind()
	if modern() then return "replicate" end
	if classic() then return "getall" end
	return nil
end

local function count()
	if modern() then
		local ok, n = pcall(AH.GetNumReplicateItems)
		if ok and type(n) == "number" and not ns.IsSecret(n) then return n end
		return 0
	end
	local ok, n, total = pcall(GetNumAuctionItems, "list")
	if ok and type(n) == "number" then return math.max(n, type(total) == "number" and total or 0) end
	return 0
end

local function info(i)
	local r
	if modern() then
		r = { pcall(AH.GetReplicateItemInfo, i - 1) }
	else
		r = { pcall(GetAuctionItemInfo, "list", i) }
	end
	if not r[1] then return nil end
	local name, qty, buyout, id, complete = r[2], r[4], r[11], r[18], r[19]
	if ns.IsSecret(qty) or ns.IsSecret(buyout) or ns.IsSecret(id) or ns.IsSecret(name) then return false end
	if not complete or type(id) ~= "number" or id <= 0 then return nil end
	return id, type(qty) == "number" and qty > 0 and qty or 1, type(buyout) == "number" and buyout or 0, type(name) == "string" and name or nil
end

local function status(text)
	scan.text = text
	ns:Fire("SCAN_PROGRESS")
end

local function finish(state, text)
	scan.state = state
	scan.token = (scan.token or 0) + 1
	scan.found = nil
	scan.pending = nil
	status(text)
end

function ns.CooldownLeft()
	local last = ns.db.lastFull
	if not last then return 0 end
	local left = COOLDOWN - (ns.Now() - last)
	if left < 0 or left > COOLDOWN then return 0 end
	return left
end

function ns.Scanning()
	return scan.state == "waiting" or scan.state == "reading"
end

local function add(id, qty, buyout, name)
	if buyout <= 0 then return end
	local unit = buyout / qty
	local f = scan.found[id]
	if not f then
		f = { min = unit, qty = 0, units = {}, name = name }
		scan.found[id] = f
	end
	if unit < f.min then f.min = unit end
	f.qty = f.qty + qty
	f.units[#f.units + 1] = { unit, qty }
end

local function complete()
	local n = ns.Commit(scan.found, true)
	local total, missing = scan.total, scan.missing
	finish("done", n .. " items priced from " .. total .. " auctions")
	ns.Print("scan finished, " .. n .. " items priced from " .. total .. " auctions" .. (missing > 0 and (", " .. missing .. " unreadable") or ""))
	ns:Fire("SCAN_DONE")
end

local function step(token)
	if scan.token ~= token or scan.state ~= "reading" then return end
	local pending = scan.pending
	local handled = 0
	while handled < BATCH do
		local i
		if scan.cursor <= scan.total then
			i = scan.cursor
			scan.cursor = scan.cursor + 1
		elseif scan.retry and scan.retryAt <= #scan.retry then
			i = scan.retry[scan.retryAt]
			scan.retryAt = scan.retryAt + 1
		else
			break
		end
		handled = handled + 1
		local id, qty, buyout, name = info(i)
		if id then
			add(id, qty, buyout, name)
			scan.done = scan.done + 1
		elseif id == false then
			scan.done = scan.done + 1
			scan.missing = scan.missing + 1
		else
			pending[#pending + 1] = i
		end
	end
	status("Reading auctions " .. scan.done .. " / " .. scan.total)
	local more = scan.cursor <= scan.total or (scan.retry and scan.retryAt <= #scan.retry)
	if more then
		ns.After(0.02, function() step(token) end)
		return
	end
	if #pending > 0 and scan.round < ROUNDS then
		scan.round = scan.round + 1
		scan.retry = pending
		scan.retryAt = 1
		scan.pending = {}
		ns.After(0.6, function() step(token) end)
		return
	end
	scan.missing = scan.missing + #pending
	complete()
end

local function begin()
	if scan.state ~= "waiting" then return end
	local total = count()
	if total == 0 then return end
	scan.state = "reading"
	scan.total = total
	scan.done = 0
	scan.missing = 0
	scan.cursor = 1
	scan.round = 0
	scan.retry = nil
	scan.pending = {}
	scan.found = {}
	local token = scan.token
	status("Reading auctions 0 / " .. total)
	ns.After(0.02, function() step(token) end)
end

function ns.StopScan(reason)
	if not ns.Scanning() then return end
	finish("idle", reason and ("Scan " .. reason) or "")
end

function ns.StartScan()
	if ns.Scanning() then
		ns.Print("a scan is already running")
		return false
	end
	if not ns.ahOpen then
		ns.Print("open the auction house first")
		return false
	end
	local kind = ns.ScanKind()
	if not kind then
		ns.Print("no auction scan API on this client")
		return false
	end
	local left = ns.CooldownLeft()
	if left > 0 then
		ns.Print(string.format("full scan available in %d:%02d", math.floor(left / 60), left % 60))
		return false
	end
	if kind == "getall" and CanSendAuctionQuery then
		local ok, _, all = pcall(CanSendAuctionQuery, "list")
		if ok and all == false then
			ns.Print("the server is not accepting a full scan yet")
			return false
		end
	end
	scan.token = (scan.token or 0) + 1
	scan.state = "waiting"
	scan.total = 0
	scan.done = 0
	scan.missing = 0
	local token = scan.token
	local ok
	if kind == "replicate" then
		ok = pcall(AH.ReplicateItems)
	else
		ok = pcall(QueryAuctionItems, "", nil, nil, 0, nil, nil, true, false, nil)
	end
	if not ok then
		finish("idle", "Scan request failed")
		ns.Print("scan request failed")
		return false
	end
	ns.db.lastFull = ns.Now()
	status("Waiting for the auction house")
	ns.After(TIMEOUT, function()
		if scan.token == token and scan.state == "waiting" then
			finish("idle", "No answer from the auction house")
			ns.Print("no answer from the auction house, the server allows one full scan every 15 minutes")
		end
	end)
	return true
end

ns:On("REPLICATE_ITEM_LIST_UPDATE", function()
	if modern() then begin() end
end)

ns:On("AUCTION_ITEM_LIST_UPDATE", function()
	if not modern() then begin() end
end)

ns:Listen("AH_CHANGED", function()
	if not ns.ahOpen and ns.Scanning() then
		ns.StopScan("stopped, the auction house was closed")
		ns.Print("scan stopped, the auction house was closed")
	end
end)

local function browse()
	if not ns.db or not ns.db.passive or ns.Scanning() then return end
	if not AH or not AH.GetBrowseResults then return end
	local ok, results = pcall(AH.GetBrowseResults)
	if not ok or type(results) ~= "table" then return end
	local seen = 0
	for _, r in ipairs(results) do
		local key = type(r) == "table" and r.itemKey
		local id = type(key) == "table" and key.itemID
		local price, qty = r.minPrice, r.totalQuantity
		if type(id) == "number" and not ns.IsSecret(id) and not ns.IsSecret(price) and not ns.IsSecret(qty) then
			ns.Observe(id, price, qty)
			seen = seen + 1
		end
	end
	if seen > 0 then
		ns.Debounce("browse", 0.5, function() ns:Fire("PRICES_CHANGED") end)
	end
end

ns:On("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", browse)
ns:On("AUCTION_HOUSE_BROWSE_RESULTS_ADDED", browse)
