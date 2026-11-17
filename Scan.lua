local _, ns = ...

local BATCH = 500
local ROUNDS = 8
local TIMEOUT = 30
local STALL = 25
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

local function browsing()
	return AH and AH.SendBrowseQuery and AH.GetBrowseResults and AH.RequestMoreBrowseResults and AH.HasFullBrowseResults
end

local function store()
	return ns.sv or ns.db
end

function ns.ScanKind()
	if modern() and (store().replicateFails or 0) < 2 then return "replicate" end
	if browsing() then return "browse" end
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
	local name, qty, buyout, id = r[2], r[4], r[11], r[18]
	if ns.IsSecret(qty) or ns.IsSecret(buyout) or ns.IsSecret(id) or ns.IsSecret(name) then return false end
	if type(id) ~= "number" or id <= 0 or type(buyout) ~= "number" then return nil end
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
	scan.keys = nil
	scan.more = nil
	status(text)
end

function ns.CooldownLeft()
	local last = store().lastFull
	if not last then return 0 end
	local left = COOLDOWN - (ns.Now() - last)
	if left < 0 or left > COOLDOWN then return 0 end
	return left
end

function ns.Scanning()
	return scan.state == "waiting" or scan.state == "reading" or scan.state == "browsing"
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
	store().lastFull = ns.Now()
	store().replicateFails = nil
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

local function quality()
	local out = {}
	local f = Enum and Enum.AuctionHouseFilter
	if type(f) ~= "table" then return out end
	for _, key in ipairs({ "PoorQuality", "CommonQuality", "UncommonQuality", "RareQuality", "EpicQuality", "LegendaryQuality", "ArtifactQuality" }) do
		if f[key] then out[#out + 1] = f[key] end
	end
	return out
end

local function sorts()
	local out = {}
	local o = Enum and Enum.AuctionHouseSortOrder
	if type(o) ~= "table" then return out end
	if o.Price then out[#out + 1] = { sortOrder = o.Price, reverseSort = false } end
	if o.Name then out[#out + 1] = { sortOrder = o.Name, reverseSort = false } end
	return out
end

local function idle()
	local AHready = AH and AH.IsThrottledMessageSystemReady
	if not AHready then return true end
	local ok, r = pcall(AHready)
	return not ok or r ~= false
end

local function browseDone(full)
	local found = {}
	local n = 0
	for _, k in pairs(scan.keys or {}) do
		n = n + 1
		local f = found[k[1]]
		if not f then
			f = { min = k[2], qty = 0, units = {} }
			found[k[1]] = f
		end
		if k[2] < f.min then f.min = k[2] end
		f.qty = f.qty + k[3]
		f.units[#f.units + 1] = { k[2], k[3] }
	end
	if n == 0 then
		finish("idle", "The auction house sent nothing")
		return
	end
	local priced = ns.Commit(found, full)
	finish("done", priced .. " items priced by browsing")
	ns.Print("scan finished, " .. priced .. " items priced" .. (full and "" or ", the list was cut short"))
	ns:Fire("SCAN_DONE")
end

local function watch(token)
	local mark = scan.done
	ns.After(STALL, function()
		if scan.token ~= token or scan.state ~= "browsing" then return end
		if scan.done == mark then
			browseDone(false)
		else
			watch(token)
		end
	end)
end

local function more()
	if scan.state ~= "browsing" then return end
	local ok, full = pcall(AH.HasFullBrowseResults)
	if ok and full then
		browseDone(true)
		return
	end
	if not idle() then
		scan.more = true
		return
	end
	scan.more = nil
	if not pcall(AH.RequestMoreBrowseResults) then browseDone(false) end
end

local function collect(list)
	if scan.state ~= "browsing" then return end
	if type(list) ~= "table" then
		local ok, all = pcall(AH.GetBrowseResults)
		list = ok and all or nil
	end
	if type(list) ~= "table" then return end
	local keys = scan.keys
	for _, r in ipairs(list) do
		local key = type(r) == "table" and r.itemKey
		local id = type(key) == "table" and key.itemID
		local price, qty = r.minPrice, r.totalQuantity
		if type(id) == "number" and not ns.IsSecret(id) and type(price) == "number" and not ns.IsSecret(price) and price > 0 then
			if type(qty) ~= "number" or ns.IsSecret(qty) or qty < 1 then qty = 1 end
			local name = id .. ":" .. tostring(key.itemLevel or 0) .. ":" .. tostring(key.itemSuffix or 0) .. ":" .. tostring(key.battlePetSpeciesID or 0)
			if not keys[name] then scan.done = scan.done + 1 end
			keys[name] = { id, price, qty }
		end
	end
	scan.total = scan.done
	status("Browsing auctions, " .. scan.done .. " listings")
	more()
end

local function startBrowse()
	scan.token = (scan.token or 0) + 1
	scan.state = "browsing"
	scan.total = 0
	scan.done = 0
	scan.missing = 0
	scan.keys = {}
	scan.more = nil
	local ok = pcall(AH.SendBrowseQuery, { searchString = "", sorts = sorts(), filters = quality(), itemClassFilters = {} })
	if not ok then
		finish("idle", "Scan request failed")
		ns.Print("scan request failed")
		return false
	end
	status("Browsing auctions")
	watch(scan.token)
	return true
end

function ns.StartScan(kind)
	if ns.Scanning() then
		ns.Print("a scan is already running")
		return false
	end
	if not ns.ahOpen then
		ns.Print("open the auction house first")
		return false
	end
	kind = kind or ns.ScanKind()
	if not kind then
		ns.Print("no auction scan API on this client")
		return false
	end
	if kind ~= "browse" then
		local left = ns.CooldownLeft()
		if left > 0 and browsing() then
			kind = "browse"
		elseif left > 0 then
			ns.Print(string.format("full scan available in %d:%02d", math.floor(left / 60), left % 60))
			return false
		end
	end
	if kind == "browse" then
		if not browsing() then
			ns.Print("no auction scan API on this client")
			return false
		end
		return startBrowse()
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
	status("Waiting for the auction house")
	ns.After(TIMEOUT, function()
		if scan.token ~= token or scan.state ~= "waiting" then return end
		if kind == "replicate" then store().replicateFails = (store().replicateFails or 0) + 1 end
		finish("idle", "No answer from the auction house")
		if kind == "replicate" and browsing() and ns.ahOpen then
			ns.Print("no answer to the full scan, browsing the auction house instead")
			startBrowse()
		else
			ns.Print("no answer from the auction house, the server allows one full scan every 15 minutes")
		end
	end)
	return true
end

function ns.RetryFullScan()
	store().replicateFails = nil
	store().lastFull = nil
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

local function browse(added)
	if scan.state == "browsing" then
		collect(added)
		return
	end
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

ns:On("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", function() browse() end)
ns:On("AUCTION_HOUSE_BROWSE_RESULTS_ADDED", browse)
ns:On("AUCTION_HOUSE_BROWSE_FAILURE", function()
	if scan.state == "browsing" then browseDone(false) end
end)
ns:On("AUCTION_HOUSE_THROTTLED_SYSTEM_READY", function()
	if scan.state == "browsing" and scan.more then more() end
end)
