local _, ns = ...
local UI = ns.UI
local C = UI.colors
local Sell = ns.Sell

local SellUI = {}
ns.SellUI = SellUI

local QUESTION = "Interface\\Icons\\INV_Misc_QuestionMark"
local GetIcon = (C_Item and C_Item.GetItemIconByID) or GetItemIcon
local BIDS = { 100, 95, 90, 80 }
local RED = { 1, 0.3, 0.3 }

local view
local mode = "bags"
local sel
local opts = {}
local filling = false
local items = {}

local function qualityColor(q)
	local c = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q or 1]
	if c then return c.r, c.g, c.b end
	return 1, 1, 1
end

local function money(v)
	if not v then return "-" end
	return ACore.Money(v)
end

local function current()
	if not sel then return nil end
	for _, e in ipairs(items) do
		if e.id == sel then return e end
	end
end

local function price(e)
	return opts.price or e.price
end

local function split(v)
	v = math.floor(v or 0)
	return math.floor(v / 10000), math.floor(v / 100) % 100, v % 100
end

local function fillBoxes(e)
	filling = true
	local g, s, c = split(price(e))
	view.gold.box:SetText(tostring(g))
	view.silver.box:SetText(tostring(s))
	view.copper.box:SetText(tostring(c))
	view.qty.box:SetText(tostring(Sell.Quantity(e, opts.qty)))
	filling = false
end

local function readPrice()
	if filling then return end
	local g = tonumber(view.gold.box:GetText()) or 0
	local s = tonumber(view.silver.box:GetText()) or 0
	local c = tonumber(view.copper.box:GetText()) or 0
	local v = math.floor(g) * 10000 + math.floor(s) * 100 + math.floor(c)
	opts.price = v > 0 and v or nil
	SellUI.RefreshDetail()
end

local function readQty()
	if filling then return end
	opts.qty = tonumber(view.qty.box:GetText())
	SellUI.RefreshDetail()
end

function SellUI.RefreshDetail()
	if not view then return end
	local e = current()
	local d = view.detail
	if not e then
		d:Hide()
		view.empty:Show()
		return
	end
	view.empty:Hide()
	d:Show()
	local icon = e.icon
	if not icon and GetIcon then
		local ok, tex = pcall(GetIcon, e.id)
		if ok then icon = tex end
	end
	view.icon:SetTexture(icon or QUESTION)
	view.name:SetText(e.name)
	view.name:SetTextColor(qualityColor(e.quality))
	if e.commodity then
		view.have:SetText("You have " .. e.count)
	else
		view.have:SetText("You have " .. e.count .. " in " .. e.stacks .. (e.stacks == 1 and " stack" or " stacks"))
	end
	local p = price(e)
	local qty = Sell.Quantity(e, opts.qty)
	local duration = opts.duration or ns.db.sell.duration or 2
	local bid = opts.bid or ns.db.sell.bid or 100
	view.qty:SetShown(e.commodity and true or false)
	view.qtyText:SetText(e.commodity and "Quantity" or ("Stack of " .. qty))
	view.bid:SetLabel(bid >= 100 and "Bid = buyout" or ("Bid " .. bid .. "% of buyout"))
	view.bid:SetShown(not e.commodity)
	for i, b in ipairs(view.durations) do b:SetActive(i == duration) end
	local deposit = Sell.Deposit(e, duration, qty)
	view.lines.deposit:SetText("Deposit   " .. money(deposit))
	view.lines.total:SetText("Total   " .. (p and money(p * qty) or "-"))
	view.lines.low:SetText("Lowest now   " .. money(e.low))
	view.lines.market:SetText("Market value   " .. money(e.market))
	view.lines.vendor:SetText("Vendor   " .. money(e.vendor))
	local warn = ""
	if not p then
		warn = "No price known. Type one."
	elseif e.vendor and p < e.vendor then
		warn = "Below what a vendor pays"
	elseif e.source == "floor" then
		warn = "Raised to stay above vendor price"
	elseif e.source == "vendor" and not opts.price then
		warn = "Guess from vendor price, no auctions seen"
	elseif e.source == "kept" and not opts.price then
		warn = "Your remembered price"
	elseif e.source == "own" and not opts.price then
		warn = "Same as your own auction"
	end
	view.lines.warn:SetText(warn)
	local c = (p and e.vendor and p < e.vendor) and RED or C.dim
	view.lines.warn:SetTextColor(c[1], c[2], c[3])
	if e.commodity then
		view.post:SetLabel("Post " .. qty)
	elseif e.stacks > 1 then
		view.post:SetLabel("Post 1 of " .. e.stacks .. " stacks")
	else
		view.post:SetLabel("Post")
	end
	view.post:SetWidth(232)
	local kept = ns.db.sell.prices[e.id] ~= nil
	view.keep:SetLabel(kept and "Forget this price" or "Remember this price")
	view.keep:SetActive(kept)
	view.keep:SetWidth(232)
end

function SellUI.Refresh(keep)
	if not view or not view:IsShown() then return end
	items = Sell.Items()
	local under = Sell.Undercut()
	view.bagsTab:SetActive(mode == "bags")
	view.underTab:SetLabel("Undercut (" .. #under .. ")")
	view.underTab:SetActive(mode == "under")
	if mode == "under" then
		view.list:SetData(under, keep)
		view.status:SetText(#under == 0 and "None of your auctions is undercut" or "Click an auction to cancel it")
	else
		view.list:SetData(items, keep)
		if not ns.ahOpen then
			view.status:SetText("Open the auction house to post")
		else
			view.status:SetText("Click posts at the suggested price.  Right-click to set details.")
		end
	end
	if sel and not current() then
		sel = nil
		opts = {}
	end
	local e = current()
	if e then fillBoxes(e) end
	SellUI.RefreshDetail()
end

function SellUI.Select(id)
	if not view then return end
	if ns.UI.SetView then ns.UI.SetView("sell") end
	mode = "bags"
	if sel ~= id then opts = {} end
	sel = id
	SellUI.Refresh(true)
	for i, e in ipairs(items) do
		if e.id == id then
			local list = view.list
			if i <= list.offset or i > list.offset + list:Visible() then list:ScrollTo(math.max(1, i - 2)) end
			break
		end
	end
	Sell.Query(id)
end

function SellUI.Shown()
	return view ~= nil and view:IsShown()
end

function SellUI.State()
	return sel, opts, mode
end

local COLS = { { "price", "Post at", 96 }, { "low", "Lowest", 90 }, { "market", "Market", 90 } }

local function createRow(list)
	local row = CreateFrame("Button", nil, list)
	row.sel = UI.Fill(row, C.select)
	row.hl = UI.Fill(row, C.hover, "HIGHLIGHT")
	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(22, 22)
	row.icon:SetPoint("LEFT", 8, 0)
	row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	row.cells = {}
	local x = -6
	for i = #COLS, 1, -1 do
		local col = COLS[i]
		local fs = UI.Text(row, "GameFontHighlightSmall", "RIGHT")
		fs:SetPoint("RIGHT", x, 0)
		fs:SetWidth(col[3])
		row.cells[col[1]] = fs
		x = x - col[3] - 4
	end
	row.count = UI.Text(row, "GameFontDisableSmall", "RIGHT", C.dim)
	row.count:SetPoint("RIGHT", x, 0)
	row.count:SetWidth(54)
	row.name = UI.Text(row, "GameFontHighlight")
	row.name:SetPoint("LEFT", row.icon, "RIGHT", 8, 0)
	row.name:SetPoint("RIGHT", row.count, "LEFT", -4, 0)
	row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	row:SetScript("OnClick", function(self, button)
		local d = self.data
		if not d then return end
		if mode == "under" then
			local ok, err = Sell.Cancel(d)
			if not ok then ns.Print(err) end
			return
		end
		if button == "RightButton" then
			SellUI.Select(d.id)
			return
		end
		local result, why = Sell.Click(d)
		if result == "select" or result == "confirm" then
			SellUI.Select(d.id)
			view.status:SetText(d.name .. ": " .. why .. ". Check the price and press Post.")
		end
	end)
	row:SetScript("OnEnter", function(self)
		list.hovered = self
		local d = self.data
		if not d then return end
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		local shown = false
		if d.slots and GameTooltip.SetBagItem then
			shown = pcall(GameTooltip.SetBagItem, GameTooltip, d.slots[1][1], d.slots[1][2])
		end
		if not shown then GameTooltip:SetHyperlink(d.link or ("item:" .. d.id)) end
		GameTooltip:Show()
		if mode == "bags" then Sell.Query(d.id) end
	end)
	row:SetScript("OnLeave", function(self)
		if list.hovered == self then list.hovered = nil end
		GameTooltip:Hide()
	end)
	return row
end

local function updateRow(row, d)
	local icon = d.icon
	if not icon and GetIcon then
		local ok, tex = pcall(GetIcon, d.id)
		if ok then icon = tex end
	end
	row.icon:SetTexture(icon or QUESTION)
	row.name:SetText(d.name or "")
	if mode == "under" then
		row.sel:Hide()
		row.name:SetTextColor(qualityColor(ns.ItemQuality(d.id)))
		row.count:SetText("x" .. d.qty)
		row.cells.price:SetText(money(d.unit))
		row.cells.price:SetTextColor(RED[1], RED[2], RED[3])
		row.cells.low:SetText(money(d.low))
		row.cells.market:SetText("cancel")
		return
	end
	row.sel:SetShown(d.id == sel)
	row.name:SetTextColor(qualityColor(d.quality))
	row.count:SetText("x" .. d.count .. (d.stacks > 1 and not d.commodity and (" (" .. d.stacks .. ")") or ""))
	row.cells.price:SetText(money(d.price))
	if d.price and d.vendor and d.price < d.vendor then
		row.cells.price:SetTextColor(RED[1], RED[2], RED[3])
	elseif d.source == "vendor" or not d.price then
		row.cells.price:SetTextColor(C.dim[1], C.dim[2], C.dim[3])
	else
		row.cells.price:SetTextColor(C.text[1], C.text[2], C.text[3])
	end
	row.cells.low:SetText(money(d.low))
	row.cells.market:SetText(money(d.market))
end

function SellUI.Build(frame)
	local body = frame.body
	view = CreateFrame("Frame", nil, body)
	view:SetAllPoints(body)
	view:Hide()

	local strip = CreateFrame("Frame", nil, view)
	strip:SetPoint("TOPLEFT")
	strip:SetPoint("TOPRIGHT")
	strip:SetHeight(28)
	UI.Fill(strip, { 0.075, 0.08, 0.1, 1 })
	view.bagsTab = UI.Button(strip, "Bags", function()
		mode = "bags"
		SellUI.Refresh()
	end)
	view.bagsTab:SetPoint("LEFT", 8, 0)
	view.underTab = UI.Button(strip, "Undercut (0)", function()
		mode = "under"
		Sell.RefreshOwned()
		SellUI.Refresh()
	end)
	view.underTab:SetPoint("LEFT", view.bagsTab, "RIGHT", 6, 0)
	local x = -254 - 14
	for i = #COLS, 1, -1 do
		local col = COLS[i]
		local fs = UI.Text(strip, "GameFontDisableSmall", "RIGHT", C.dim)
		fs:SetPoint("RIGHT", x, 0)
		fs:SetWidth(col[3])
		fs:SetText(col[2])
		x = x - col[3] - 4
	end

	local panel = CreateFrame("Frame", nil, view)
	panel:SetPoint("TOPRIGHT", 0, -28)
	panel:SetPoint("BOTTOMRIGHT", 0, 22)
	panel:SetWidth(254)
	UI.Fill(panel, C.panel)
	view.empty = UI.Text(panel, "GameFontDisableSmall", "CENTER", C.dim)
	view.empty:SetPoint("TOP", 0, -40)
	view.empty:SetWidth(230)
	view.empty:SetWordWrap(true)
	view.empty:SetText("Click an item to post it. Right-click to change price, amount or duration first.")

	local d = CreateFrame("Frame", nil, panel)
	d:SetAllPoints(panel)
	view.detail = d
	view.icon = d:CreateTexture(nil, "ARTWORK")
	view.icon:SetSize(32, 32)
	view.icon:SetPoint("TOPLEFT", 10, -10)
	view.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	view.name = UI.Text(d, "GameFontNormal")
	view.name:SetPoint("TOPLEFT", view.icon, "TOPRIGHT", 8, -1)
	view.name:SetPoint("RIGHT", -8, 0)
	view.have = UI.Text(d, "GameFontDisableSmall", "LEFT", C.dim)
	view.have:SetPoint("TOPLEFT", view.name, "BOTTOMLEFT", 0, -4)

	local label = UI.Text(d, "GameFontHighlightSmall")
	label:SetPoint("TOPLEFT", 10, -56)
	label:SetText("Price each (gold, silver, copper)")
	view.gold = UI.EditBox(d, "g", readPrice)
	view.gold:SetPoint("TOPLEFT", 10, -72)
	view.gold:SetWidth(84)
	view.silver = UI.EditBox(d, "s", readPrice)
	view.silver:SetPoint("LEFT", view.gold, "RIGHT", 6, 0)
	view.silver:SetWidth(68)
	view.copper = UI.EditBox(d, "c", readPrice)
	view.copper:SetPoint("LEFT", view.silver, "RIGHT", 6, 0)
	view.copper:SetWidth(68)

	view.qtyText = UI.Text(d, "GameFontHighlightSmall")
	view.qtyText:SetPoint("TOPLEFT", 10, -108)
	view.qty = UI.EditBox(d, "amount", readQty)
	view.qty:SetPoint("TOPLEFT", 90, -103)
	view.qty:SetWidth(84)

	view.bid = UI.Button(d, "Bid = buyout", function()
		local cur = opts.bid or ns.db.sell.bid or 100
		local nextIndex = 1
		for i, v in ipairs(BIDS) do
			if v == cur then nextIndex = i % #BIDS + 1 end
		end
		opts.bid = BIDS[nextIndex]
		ns.db.sell.bid = opts.bid
		SellUI.RefreshDetail()
	end)
	view.bid:SetPoint("TOPLEFT", 10, -134)

	view.durations = {}
	for i, text in ipairs(Sell.Durations()) do
		local b = UI.Button(d, text, function()
			opts.duration = i
			ns.db.sell.duration = i
			SellUI.RefreshDetail()
		end)
		if i == 1 then
			b:SetPoint("TOPLEFT", 10, -162)
		else
			b:SetPoint("LEFT", view.durations[i - 1], "RIGHT", 6, 0)
		end
		view.durations[i] = b
	end

	view.lines = {}
	local y = -194
	for _, key in ipairs({ "deposit", "total", "low", "market", "vendor", "warn" }) do
		local fs = UI.Text(d, "GameFontHighlightSmall")
		fs:SetPoint("TOPLEFT", 10, y)
		fs:SetPoint("RIGHT", -8, 0)
		view.lines[key] = fs
		y = y - 17
	end

	view.post = UI.Button(d, "Post", function()
		local e = current()
		if not e then return end
		local result = Sell.Click(e, { price = price(e), qty = opts.qty, duration = opts.duration, bid = opts.bid, force = true })
		if result == "posted" and ns.db.sell.prices[e.id] then ns.db.sell.prices[e.id] = price(e) end
		if result == "confirm" then view.status:SetText("The auction house warns about this price. Press Post again to confirm.") end
	end)
	view.post:SetHeight(28)
	view.post:SetPoint("BOTTOMLEFT", 10, 44)
	view.keep = UI.Button(d, "Remember this price", function()
		local e = current()
		if not e then return end
		local prices = ns.db.sell.prices
		if prices[e.id] then
			prices[e.id] = nil
			opts.price = nil
		else
			prices[e.id] = price(e)
		end
		SellUI.Refresh(true)
	end)
	view.keep:SetPoint("BOTTOMLEFT", 10, 12)

	local list = UI.List(view, 30, createRow, updateRow)
	list:SetPoint("TOPLEFT", 0, -30)
	list:SetPoint("BOTTOMRIGHT", panel, "BOTTOMLEFT", -2, 0)
	view.list = list

	local foot = CreateFrame("Frame", nil, view)
	foot:SetPoint("BOTTOMLEFT")
	foot:SetPoint("BOTTOMRIGHT")
	foot:SetHeight(22)
	UI.Fill(foot, C.bar)
	view.status = UI.Text(foot, "GameFontDisableSmall", "LEFT", C.dim)
	view.status:SetPoint("LEFT", 10, 0)
	view.status:SetPoint("RIGHT", -10, 0)

	view:SetScript("OnShow", function() SellUI.Refresh() end)
	return view
end

ns:Listen("SELL_CHANGED", function()
	ns.Debounce("sellview", 0.1, function() SellUI.Refresh(true) end)
end)
ns:Listen("PRICES_CHANGED", function()
	ns.Debounce("sellview", 0.1, function() SellUI.Refresh(true) end)
end)
