local _, ns = ...

local DIM = { 0.58, 0.6, 0.65 }

local function stackOf(tooltip)
	if not ns.db.stack or not tooltip.GetOwner then return 1 end
	local ok, owner = pcall(tooltip.GetOwner, tooltip)
	if not ok or type(owner) ~= "table" then return 1 end
	local n = owner.count
	if type(n) == "number" and not ns.IsSecret(n) and n > 1 then return n end
	return 1
end

local function line(tooltip, label, each, stack)
	local text = ACore.Money(each)
	if stack > 1 then
		text = text .. "  |cff9499a6x" .. stack .. "|r  " .. ACore.Money(each * stack)
	end
	tooltip:AddDoubleLine(label, text, 0.55, 0.8, 1, 1, 1, 1)
end

local function addLines(tooltip, id)
	if not ns.db or not ns.db.tooltip then return end
	if type(id) ~= "number" or ns.IsSecret(id) then return end
	local market, minBuyout, _, seen = ns.GetPrice(id)
	local vendor = ns.db.vendor and ns.VendorPrice(id)
	if not market and not vendor then return end
	local stack = stackOf(tooltip)
	if market then
		line(tooltip, "Market value", market, stack)
		if minBuyout then
			line(tooltip, "Min buyout (" .. ns.Age(seen) .. ")", minBuyout, stack)
		end
	end
	if vendor then
		line(tooltip, "Vendor", vendor, stack)
	end
	tooltip:Show()
end

ns.TooltipLines = addLines

local function fromData(tooltip, data)
	if tooltip ~= GameTooltip and tooltip ~= ItemRefTooltip then return end
	local id = data and data.id
	if type(id) ~= "number" then return end
	addLines(tooltip, id)
end

local function fromLegacy(tooltip)
	if not tooltip.GetItem then return end
	local _, link = tooltip:GetItem()
	if type(link) ~= "string" then return end
	local id = tonumber(link:match("item:(%d+)"))
	if id then addLines(tooltip, id) end
end

ns:Listen("LOGIN", function()
	local hooked = false
	if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
		hooked = pcall(TooltipDataProcessor.AddTooltipPostCall, Enum.TooltipDataType.Item, function(tooltip, data)
			pcall(fromData, tooltip, data)
		end)
	end
	if not hooked and GameTooltip and GameTooltip.HookScript then
		pcall(GameTooltip.HookScript, GameTooltip, "OnTooltipSetItem", function(tooltip)
			pcall(fromLegacy, tooltip)
		end)
	end
end)
