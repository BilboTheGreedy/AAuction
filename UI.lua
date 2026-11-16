local _, ns = ...
local UI = ns.UI
local C = UI.colors

local QUESTION = "Interface\\Icons\\INV_Misc_QuestionMark"
local GetIcon = (C_Item and C_Item.GetItemIconByID) or GetItemIcon

local frame
local query = ""

local COLUMNS = {
	{ key = "age", text = "Seen", width = 56 },
	{ key = "trend", text = "Trend", width = 62 },
	{ key = "market", text = "Market", width = 118 },
	{ key = "min", text = "Min buyout", width = 118 },
	{ key = "qty", text = "Qty", width = 52 },
}

local function qualityColor(id)
	local q = ns.ItemQuality(id)
	local c = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
	if c then return c.r, c.g, c.b end
	return 1, 1, 1
end

local function insertLink(id)
	local link
	local get = (C_Item and C_Item.GetItemInfo) or GetItemInfo
	if get then
		local ok, _, l = pcall(get, id)
		if ok then link = l end
	end
	if not link then return end
	if ChatFrameUtil and ChatFrameUtil.InsertLink then
		if ChatFrameUtil.InsertLink(link) then return end
	end
	if ChatEdit_InsertLink then ChatEdit_InsertLink(link) end
end

local function createRow(list)
	local row = CreateFrame("Button", nil, list)
	row.hl = UI.Fill(row, C.hover, "HIGHLIGHT")
	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(20, 20)
	row.icon:SetPoint("LEFT", 8, 0)
	row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	row.cells = {}
	local x = -6
	for i, col in ipairs(COLUMNS) do
		local fs = UI.Text(row, "GameFontHighlightSmall", "RIGHT")
		fs:SetPoint("RIGHT", x, 0)
		fs:SetWidth(col.width)
		row.cells[col.key] = fs
		x = x - col.width - 6
	end
	row.name = UI.Text(row, "GameFontHighlight")
	row.name:SetPoint("LEFT", row.icon, "RIGHT", 8, 0)
	row.name:SetPoint("RIGHT", x, 0)
	row:RegisterForClicks("LeftButtonUp")
	row:SetScript("OnClick", function(self)
		local d = self.data
		if d and IsShiftKeyDown and IsShiftKeyDown() then insertLink(d.id) end
	end)
	row:SetScript("OnEnter", function(self)
		list.hovered = self
		local d = self.data
		if not d then return end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		local ok = GameTooltip.SetItemByID and pcall(GameTooltip.SetItemByID, GameTooltip, d.id)
		if not ok then GameTooltip:SetHyperlink("item:" .. d.id) end
		local avg = ns.Average(d.e)
		if avg then
			GameTooltip:AddDoubleLine("Average min buyout", ACore.Money(avg), 0.58, 0.6, 0.65, 1, 1, 1)
			GameTooltip:AddDoubleLine("Scans seen in", tostring(d.e.n or 0), 0.58, 0.6, 0.65, 1, 1, 1)
		end
		GameTooltip:Show()
	end)
	row:SetScript("OnLeave", function(self)
		if list.hovered == self then list.hovered = nil end
		GameTooltip:Hide()
	end)
	return row
end

local function updateRow(row, d)
	local e = d.e
	local icon
	if GetIcon then
		local ok, tex = pcall(GetIcon, d.id)
		if ok then icon = tex end
	end
	row.icon:SetTexture(icon or QUESTION)
	row.name:SetText(d.name)
	row.name:SetTextColor(qualityColor(d.id))
	row.cells.qty:SetText((e.q or 0) > 0 and tostring(e.q) or "-")
	row.cells.min:SetText(e.b and ACore.Money(e.b) or "")
	row.cells.market:SetText(e.m and ACore.Money(e.m) or "")
	row.cells.age:SetText(ns.Age(e.t))
	local trend = d.trend
	local cell = row.cells.trend
	if not trend or math.abs(trend) < 0.005 then
		cell:SetText("-")
		cell:SetTextColor(C.dim[1], C.dim[2], C.dim[3])
	elseif trend < 0 then
		cell:SetText(string.format("%d%%", math.floor(trend * 100 + 0.5)))
		cell:SetTextColor(0.3, 0.9, 0.3)
	else
		cell:SetText(string.format("+%d%%", math.floor(trend * 100 + 0.5)))
		cell:SetTextColor(1, 0.4, 0.3)
	end
end

local function optionsMenu(anchor)
	local db = ns.db
	local entries = {
		{ text = "Options", title = true },
		UI.Toggle(db, "tooltip", "Show prices in item tooltips"),
		UI.Toggle(db, "stack", "Show the stack total too"),
		UI.Toggle(db, "vendor", "Show the vendor price"),
		UI.Toggle(db, "passive", "Learn prices while I browse the auction house"),
		{ text = "Data", title = true },
		{
			text = "Remove items not seen for 30 days",
			func = function()
				ns.Print("removed " .. ns.Purge(30) .. " items")
			end,
		},
		{
			text = "Forget all prices on this realm",
			func = function()
				UI.Confirm("Forget every price stored for " .. ns.realmKey .. "?", function()
					ns.db.realms[ns.realmKey] = nil
					ns:Fire("PRICES_CHANGED")
				end)
			end,
		},
	}
	for _, e in ipairs(UI.ScaleEntries(db, function(s) frame:SetScale(s) end)) do
		entries[#entries + 1] = e
	end
	UI.Menu(anchor, entries)
end

local function build()
	frame = UI.Window("AAuctionFrame", "AAuction", 760, 540, ns.db)
	local body = frame.body

	local search = UI.EditBox(frame.bar, "Search scanned items", function(text)
		ns.Debounce("search", 0.2, function()
			local q = text:gsub("^%s+", ""):gsub("%s+$", "")
			if q == query then return end
			query = q
			UI.Refresh()
		end)
	end)
	search:SetPoint("LEFT", 150, 0)
	search:SetWidth(280)
	frame.search = search

	local options = UI.Button(frame.bar, "Options", function(self) optionsMenu(self) end)
	options:SetPoint("RIGHT", frame.close, "LEFT", -6, 0)
	frame.options = options

	local scanButton = UI.Button(frame.bar, "Scan", function()
		if ns.Scanning() then
			ns.StopScan("stopped")
		else
			ns.StartScan()
		end
		UI.RefreshStatus()
	end)
	scanButton:SetPoint("RIGHT", options, "LEFT", -6, 0)
	frame.scanButton = scanButton

	local head = CreateFrame("Frame", nil, body)
	head:SetPoint("TOPLEFT")
	head:SetPoint("TOPRIGHT")
	head:SetHeight(26)
	UI.Fill(head, { 0.075, 0.08, 0.1, 1 })
	frame.heads = {}
	local function header(key, text)
		local b = UI.Button(head, text, function()
			if ns.db.sort == key then
				ns.db.desc = not ns.db.desc
			else
				ns.db.sort = key
				ns.db.desc = key ~= "name"
			end
			UI.Refresh()
		end)
		b.key = key
		b.text = text
		b.edges[1]:Hide() b.edges[2]:Hide() b.edges[3]:Hide() b.edges[4]:Hide()
		b.bg:Hide()
		frame.heads[#frame.heads + 1] = b
		return b
	end
	local x = -14
	for _, col in ipairs(COLUMNS) do
		local b = header(col.key, col.text)
		b.label:ClearAllPoints()
		b.label:SetPoint("RIGHT", 0, 0)
		b:SetWidth(col.width)
		b:SetPoint("RIGHT", x, 0)
		b.fixed = col.width
		x = x - col.width - 6
	end
	local nameHead = header("name", "Item")
	nameHead.label:ClearAllPoints()
	nameHead.label:SetPoint("LEFT", 0, 0)
	nameHead:SetPoint("LEFT", 36, 0)
	nameHead:SetWidth(120)
	nameHead.fixed = 120

	local bar = UI.Bar(body, 16)
	bar:SetPoint("BOTTOMLEFT", 0, 22)
	bar:SetPoint("BOTTOMRIGHT", 0, 22)
	bar:Hide()
	frame.progress = bar

	local list = UI.List(body, 26, createRow, updateRow)
	list:SetPoint("TOPLEFT", 0, -28)
	list:SetPoint("BOTTOMRIGHT", 0, 40)
	frame.list = list

	local foot = CreateFrame("Frame", nil, body)
	foot:SetPoint("BOTTOMLEFT")
	foot:SetPoint("BOTTOMRIGHT")
	foot:SetHeight(22)
	UI.Fill(foot, C.bar)
	local hint = UI.Text(foot, "GameFontDisableSmall", "LEFT", C.dim)
	hint:SetPoint("LEFT", 10, 0)
	frame.hint = hint
	local count = UI.Text(foot, "GameFontDisableSmall", "RIGHT", C.dim)
	count:SetPoint("RIGHT", -10, 0)
	frame.count = count
	hint:SetPoint("RIGHT", count, "LEFT", -10, 0)

	frame:SetScript("OnShow", function() UI.Refresh() end)
end

function UI.RefreshStatus()
	if not frame or not frame:IsShown() then return end
	local scan = ns.scan
	local running = ns.Scanning()
	frame.scanButton:SetLabel(running and "Stop" or "Scan")
	frame.scanButton:SetActive(running)
	frame.scanButton:SetShown(ns.ahOpen or running)
	if running then
		frame.progress:Show()
		frame.progress:SetMinMaxValues(0, math.max(1, scan.total))
		frame.progress:SetValue(scan.done)
		frame.progress.left:SetText(scan.text or "")
		frame.progress.right:SetText(scan.total > 0 and (math.floor(scan.done / scan.total * 100) .. "%") or "")
	else
		frame.progress:Hide()
	end
	local realm = ns.Realm()
	local text
	if running then
		text = scan.text or ""
	elseif not ns.ahOpen then
		text = "Open the auction house to scan.  Shift-click an item to link it."
	else
		local left = ns.CooldownLeft()
		if left > 0 then
			text = string.format("Next full scan in %d:%02d", math.floor(left / 60), left % 60)
		else
			text = scan.text and scan.text ~= "" and scan.text or "Ready to scan"
		end
	end
	frame.hint:SetText(text)
	local last = realm.last and ("last scan " .. ns.Age(realm.last) .. " ago") or "never scanned"
	frame.count:SetText(#frame.list.data .. " items  ·  " .. ns.realmKey .. "  ·  " .. last)
end

function UI.Refresh(keep)
	if not frame or not frame:IsShown() then return end
	for _, b in ipairs(frame.heads) do
		local on = ns.db.sort == b.key
		b.label:SetText(b.text .. (on and (ns.db.desc and " v" or " ^") or ""))
		local c = on and C.accent or C.dim
		b.label:SetTextColor(c[1], c[2], c[3])
		b:SetWidth(b.fixed)
	end
	frame.list:SetData(ns.Rows(query, ns.db.sort, ns.db.desc), keep)
	UI.RefreshStatus()
end

function UI.Show()
	if not frame then build() end
	frame:Show()
	UI.Refresh()
end

function UI.Hide()
	if frame then frame:Hide() end
end

function UI.Toggle()
	if frame and frame:IsShown() then
		UI.Hide()
	else
		UI.Show()
	end
end

function UI.SetSearch(text)
	if not frame then return end
	frame.search.box:SetText(text or "")
end

local ahButton
local function attach()
	local parent = AuctionHouseFrame or AuctionFrame
	if ahButton or type(parent) ~= "table" then return end
	local ok, b = pcall(UI.Button, parent, "AAuction", function() UI.Toggle() end)
	if not ok then return end
	b:SetPoint("BOTTOMRIGHT", parent, "TOPRIGHT", 0, 2)
	ahButton = b
end

ns:Listen("AH_CHANGED", function()
	if ns.ahOpen then attach() end
	UI.RefreshStatus()
end)

ns:Listen("SCAN_PROGRESS", function() UI.RefreshStatus() end)
ns:Listen("SCAN_DONE", function() UI.Refresh(true) end)
ns:Listen("PRICES_CHANGED", function()
	ns.Debounce("rows", 0.3, function() UI.Refresh(true) end)
end)
ns:Listen("LAYOUT_RESET", function()
	if frame then frame:Restore() end
end)
