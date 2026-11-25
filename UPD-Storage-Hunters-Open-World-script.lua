--[[
	Auto Auction / Auto Sell / Pathfinder - Storage Hunters: Open World
	Uses WindUI for the interface.
	- Auction tab: monitors the bidding minigame and auto-bids when cursor is in the zone.
	- Sell tab: monitors Quick Sell rate + vehicle load weight and auto-sells.
	- Pathfinder tab: state machine automates the full auction loop (walk → trigger → bid → collect).
]]

-- Load WindUI from the dist URL directly
local WindUI = loadstring(game:HttpGet("https://raw.githubusercontent.com/Footagesus/WindUI/main/dist/main.lua"))()

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PathfindingService = game:GetService("PathfindingService")
local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

-- Remote references
local AuctionEvents = ReplicatedStorage:WaitForChild("Events"):WaitForChild("Auction")
local BidRemote = AuctionEvents:WaitForChild("Bid")
local LeaveAuctionRemote = AuctionEvents:WaitForChild("LeaveAuction")

local Pawn = ReplicatedStorage:WaitForChild("Events"):WaitForChild("Pawn")
local GetPawnState = Pawn:WaitForChild("GetPawnState")
local GetSellableItems = Pawn:WaitForChild("GetSellableItems")
local SellItems = Pawn:WaitForChild("SellItems")
local RateChanged = Pawn:WaitForChild("RateChanged")

local UIEvents = ReplicatedStorage:WaitForChild("Events"):WaitForChild("UI")
local VehicleWeightUpdate = UIEvents:WaitForChild("VehicleWeightUpdate")

-- Items module — used to look up category for trophy/accessory filtering
-- Loaded via decompile to avoid "Cannot require a RobloxScript module from a non RobloxScript context" errors
local ItemsModule = (function()
	local ok, result = pcall(function()
		return loadstring(decompile(ReplicatedStorage.Modules.Items))()
	end)
	if ok then return result end
	return {}
end)()

-- ── Area-to-garage mapping for pathfinder toggles ──
local AREA_GARAGES = {
	["Junk Yard"] = { "Scrap Garage" },
	["Back Alley"] = { "Shop Front" },
	["Farmyard"] = { "Stable Garage", "Barn Garage" },
	["Shipyard"] = { "Small Container Garage", "Large Container Garage", "Warehouse Garage" },
}

-- ── State via getgenv() so re-running cleans up old state ──
getgenv().AutoAuction = getgenv().AutoAuction or {}
local State = getgenv().AutoAuction

-- Auction state
State.BidEnabled = false

-- Sell state
State.SellEnabled = false
State.MinSellRate = -15   -- minimum rate percentage (slider: -50..+50)
State.MinWeight = 0        -- minimum weight in kg (slider: 0..100)
State.CurrentWeight = 0    -- current vehicle load weight
State.CurrentRate = 1.0    -- current pawn rate multiplier
State.SellCooldown = 0     -- cooldown timer to avoid spam
State.SellSyncing = false  -- guard against overlapping sell cycles
State.SaveTrophies = true  -- exclude Trophy-category items from auto-sell
State.SaveAccessories = true -- exclude Accessories-category items from auto-sell

-- Pathfinder state
State.PathfinderEnabled = false
State.AreaToggles = State.AreaToggles or {}
for area in pairs(AREA_GARAGES) do
	if State.AreaToggles[area] == nil then
		State.AreaToggles[area] = true
	end
end
State.PathfinderStatus = "Idle"
State.PathfinderPhase = "Idle"
State._pathfinderRunning = false

-- ── Helper: format rate as percentage string ──
local function formatRate(rate)
	local pct = math.floor((rate - 1) * 100 + 0.5)
	if pct >= 0 then
		return "+" .. pct .. "%"
	end
	return pct .. "%"
end

-- ── Helper: get rate as integer percent ──
local function ratePercent(rate)
	return math.floor((rate - 1) * 100 + 0.5)
end

-- ── Helper: get character root position ──
local function getRoot()
	local char = LocalPlayer.Character
	if not char then return nil end
	local root = char:FindFirstChild("HumanoidRootPart")
	if not root then return nil end
	return root
end

-- ── Helper: get humanoid ──
local function getHumanoid()
	local char = LocalPlayer.Character
	if not char then return nil end
	return char:FindFirstChildOfClass("Humanoid")
end

-- ── Helper: find nearest EnterAuction prompt matching enabled areas ──
local function findNearestAuction()
	local root = getRoot()
	if not root then return nil end

	local rootPos = root.Position
	local bestDist = math.huge
	local bestPrompt = nil

	for _, prompt in ipairs(workspace:GetDescendants()) do
		if not (prompt:IsA("ProximityPrompt") and prompt.Name == "EnterAuction") then
			continue
		end

		local garageType = prompt.ObjectText
		-- Check if this garage type belongs to an enabled area
		local areaMatch = false
		local areaName = nil
		for area, garages in pairs(AREA_GARAGES) do
			if State.AreaToggles[area] then
				for _, g in ipairs(garages) do
					if g == garageType then
						areaMatch = true
						areaName = area
						break
					end
				end
			end
			if areaMatch then break end
		end
		if not areaMatch then continue end

		local promptPart = prompt.Parent
		if not promptPart then continue end

		local dist = (promptPart.Position - rootPos).Magnitude
		if dist < bestDist then
			bestDist = dist
			bestPrompt = {
				prompt = prompt,
				promptPart = promptPart,
				position = promptPart.Position,
				garageType = garageType,
				areaName = areaName,
				distance = dist,
			}
		end
	end

	return bestPrompt
end

-- ── Helper: pathfind and walk to a target position ──
local function walkTo(targetPos, timeoutSeconds)
	local hum = getHumanoid()
	local root = getRoot()
	if not hum or not root then
		task.wait(1)
		return false
	end

	local startTime = tick()

	while tick() - startTime < (timeoutSeconds or 30) do
		root = getRoot()
		hum = getHumanoid()
		if not root or not hum then
			return false
		end

		local dist = (root.Position - targetPos).Magnitude
		if dist < 5 then
			hum:MoveTo(targetPos)
			return true
		end

		-- Compute a path
		local pathParams = {
			AgentRadius = 2,
			AgentHeight = 5,
			AgentCanJump = true,
			AgentMaxSlope = 45,
			WaypointSpacing = 4,
		}
		local ok, path = pcall(function()
			return PathfindingService:CreatePath(pathParams):ComputeAsync(root.Position, targetPos)
		end)

		if ok and path and path.Status == Enum.PathStatus.Success then
			local waypoints = path:GetWaypoints()
			hum:MoveTo(waypoints[#waypoints].Position)

			-- Walk along the path
			for i, wp in ipairs(waypoints) do
				if tick() - startTime >= (timeoutSeconds or 30) then
					hum:MoveTo(root.Position)
					return false
				end

				if wp.Action == Enum.PathWaypointAction.Jump then
					hum.Jump = true
				end

				-- Move to next waypoint
				hum:MoveTo(wp.Position)
				repeat
					task.wait(0.1)
					root = getRoot()
					if not root then
						hum:MoveTo(root and root.Position or Vector3.new())
						return false
					end
				until (root.Position - wp.Position).Magnitude < 5 or not hum
			end
		else
			-- Direct approach as fallback
			hum:MoveTo(targetPos)
			task.wait(1)
		end

		-- Re-check distance
		root = getRoot()
		if root and (root.Position - targetPos).Magnitude < 5 then
			hum:MoveTo(targetPos)
			return true
		end
	end

	return false
end

-- ── Helper: find prompts by name near a position (e.g. PickupPrompt or OpenBoxPrompt) ──
local function findPromptsNear(centerPos, radius, promptName)
	local results = {}
	for _, desc in ipairs(workspace:GetDescendants()) do
		if desc:IsA("ProximityPrompt") and desc.Name == promptName then
			local parentPart = desc.Parent
			if parentPart and parentPart:IsA("BasePart") then
				local dist = (parentPart.Position - centerPos).Magnitude
				if dist <= radius then
					table.insert(results, {
						prompt = desc,
						part = parentPart,
						position = parentPart.Position,
						distance = dist,
					})
				end
			end
		end
	end
	table.sort(results, function(a, b) return a.distance < b.distance end)
	return results
end

-- ── Helper: trigger a ProximityPrompt instantly using the executor-native function ──
local function triggerPrompt(prompt)
	local ok = pcall(function()
		fireproximityprompt(prompt)
	end)
	task.wait(0.1)
	return ok
end

-- ── Disconnect old connections if re-running ──
local function disconnectAll()
	if State.BidHeartbeat then
		State.BidHeartbeat:Disconnect()
		State.BidHeartbeat = nil
	end
	if State.SellHeartbeat then
		State.SellHeartbeat:Disconnect()
		State.SellHeartbeat = nil
	end
	if State.WeightConnection then
		State.WeightConnection:Disconnect()
		State.WeightConnection = nil
	end
	if State.RateConnection then
		State.RateConnection:Disconnect()
		State.RateConnection = nil
	end
	if State.PickupConnection then
		State.PickupConnection:Disconnect()
		State.PickupConnection = nil
	end
end
disconnectAll()

-- ── Vehicle weight tracking ──
State.CurrentWeight = 0
State.WeightConnection = VehicleWeightUpdate.OnClientEvent:Connect(function(currentKg, maxKg)
	State.CurrentWeight = tonumber(currentKg) or 0
end)

-- ── Pawn rate tracking ──
State.RateConnection = RateChanged.OnClientEvent:Connect(function(data)
	if type(data) == "table" and data.rate then
		State.CurrentRate = data.rate
	end
end)

-- ── Auction Bid Heartbeat ──
State.BidHeartbeat = RunService.Heartbeat:Connect(function()
	if not State.BidEnabled then
		return
	end

	local gui = PlayerGui:FindFirstChild("UIControllerGui")
	if not gui then
		return
	end

	local container = gui:FindFirstChild("AuctionBiddingContainer")
	if not container or not container.Visible then
		return
	end

	local now = tick()
	if State.LastBidTime and now - State.LastBidTime < 0.35 then
		return
	end

	local barRow = container:FindFirstChild("BidBarRow")
	if not barRow or not barRow.Visible then
		return
	end

	local track = barRow:FindFirstChild("Track")
	if not track then
		return
	end

	local cursor = track:FindFirstChild("Cursor")
	local bidZone = track:FindFirstChild("BidZone")
	if not cursor or not bidZone then
		return
	end

	local cPos = cursor.Position.X.Scale
	local zPos = bidZone.Position.X.Scale
	local zWidth = bidZone.Size.X.Scale
	local tolerance = 0.0075

	if zPos <= cPos + tolerance and cPos - tolerance <= zPos + zWidth then
		local ok = pcall(function()
			BidRemote:FireServer()
		end)
		if not ok then
			warn("[AutoAuction] Bid failed")
		end
		State.LastBidTime = tick()
	end
end)

-- ── Sell Heartbeat ──
State.SellHeartbeat = RunService.Heartbeat:Connect(function()
	if not State.SellEnabled then
		return
	end
	if State.SellSyncing then
		return
	end
	if tick() < State.SellCooldown then
		return
	end

	local pct = ratePercent(State.CurrentRate)
	if pct < State.MinSellRate then
		return
	end

	local weight = State.CurrentWeight
	if weight < State.MinWeight then
		return
	end

	-- All conditions met — attempt to sell
	State.SellSyncing = true

	task.spawn(function()
		local ok, items = pcall(function()
			return GetSellableItems:InvokeServer()
		end)

		if not ok or type(items) ~= "table" then
			State.SellSyncing = false
			return
		end

		-- Collect GUIDs of non-favorited items, respecting filters
		local toSell = {}
		for guid, info in pairs(items) do
			if not info.Favorited then
				local itemDef = ItemsModule[info.ItemId]
				local skip = false
				if itemDef then
					if State.SaveTrophies and itemDef.Category == "Trophy" then
						skip = true
					end
					if State.SaveAccessories and itemDef.Category == "Accessories" then
						skip = true
					end
				end
				if not skip then
					table.insert(toSell, guid)
				end
			end
		end

		if #toSell == 0 then
			State.SellSyncing = false
			return
		end

		local ok2, result = pcall(function()
			return SellItems:InvokeServer(toSell)
		end)

		if ok2 then
			-- Reset cooldown: 15 seconds before checking again
			State.SellCooldown = tick() + 15
		end

		State.SellSyncing = false
	end)
end)

-- ── Auction pickup event (fires when items spawn after winning) ──
State._itemsAvailable = false
State.PickupConnection = AuctionEvents:WaitForChild("AuctionPickupStart").OnClientEvent:Connect(function(bidAmount, totalValue)
	State._itemsAvailable = true
end)
AuctionEvents:WaitForChild("AuctionPickupEnd").OnClientEvent:Connect(function()
	State._itemsAvailable = false
end)

-- ── Pathfinder state machine runner ──
local function pathfinderLoop()
	while State.PathfinderEnabled and State._pathfinderRunning do
		-- STATE 1: FIND AUCTION
		State.PathfinderPhase = "Finding Auction"
		local target = findNearestAuction()
		if not target then
			State.PathfinderStatus = "No eligible auctions found, waiting..."
			task.wait(5)
			continue
		end

		State.PathfinderStatus = "Walking to " .. target.garageType .. " (" .. target.areaName .. ")"

		-- STATE 2: WALK TO AUCTION
		State.PathfinderPhase = "Walking to Auction"
		local walked = walkTo(target.position, 45)
		if not walked then
			State.PathfinderStatus = "Failed to reach auction, retrying..."
			task.wait(3)
			continue
		end

		-- STATE 3: TRIGGER AUCTION
		State.PathfinderPhase = "Triggering Auction"
		State.PathfinderStatus = "Starting auction..."
		-- Walk closer (within 6 studs for the 7-stud prompt range)
		walkTo(target.position, 5)

		-- Trigger the EnterAuction prompt instantly via the native executor function
		triggerPrompt(target.prompt)
		task.wait(1)

		-- Check if bidding window opened
		local gui = PlayerGui:FindFirstChild("UIControllerGui")
		local container = gui and gui:FindFirstChild("AuctionBiddingContainer")
		if not (container and container.Visible) then
			-- Try once more
			triggerPrompt(target.prompt)
			task.wait(1)
		end

		-- STATE 4: WAIT FOR BIDDING TO FINISH
		State.PathfinderPhase = "Waiting for Bidding"
		State.PathfinderStatus = "Auction in progress, waiting for result..."

		-- Wait for the auction to resolve (bidding UI closes AND we either win or lose)
		State._itemsAvailable = false
		local biddingEndTime = tick()
		local inAuction = true

		while inAuction and State.PathfinderEnabled do
			task.wait(0.5)

			gui = PlayerGui:FindFirstChild("UIControllerGui")
			container = gui and gui:FindFirstChild("AuctionBiddingContainer")

			-- If the bidding UI is gone, the auction resolved
			if not (container and container.Visible) then
				-- Double-check: if we won, items should be spawning
				if State._itemsAvailable then
					inAuction = false
				else
					-- Wait a bit more to see if items appear (winning) or it was just a loss
					if tick() - biddingEndTime > 8 then
						inAuction = false
					end
				end
			else
				biddingEndTime = tick()
			end

			-- Safety: max wait of 3 minutes for an auction
			if tick() - biddingEndTime > 180 then
				inAuction = false
			end
		end

		-- STATE 5: COLLECT ITEMS (if we won) — with verification loop
		if State._itemsAvailable then
			State.PathfinderPhase = "Collecting Items"
			State.PathfinderStatus = "Auction won! Collecting items..."
			task.wait(1)

			-- Helper: find the garage model in workspace matching the won auction
			local function findGarageModel()
				for _, model in ipairs(workspace:GetChildren()) do
					local name = model.Name
					if name == target.garageType or name:find(target.garageType) then
						return model
					end
				end
				return nil
			end

			local garageModel = findGarageModel()
			local garagePos = garageModel and garageModel:GetPivot().Position or target.position

			-- Blacklist for glitched/unreachable objects
			local blacklist = {}
			local function isBlacklisted(key)
				return blacklist[key] and blacklist[key].attempts >= 3
			end
			local function recordAttempt(key)
				blacklist[key] = blacklist[key] or { attempts = 0 }
				blacklist[key].attempts = blacklist[key].attempts + 1
			end

			-- Verification loop: repeat until garage is fully cleared or timeout
			local garageLoopStart = tick()
			local garageCleared = false

			while not garageCleared and State.PathfinderEnabled do
				-- Safety: if we've been in this garage > 20 seconds, bail out
				if tick() - garageLoopStart > 20 then
					State.PathfinderStatus = "Garage timeout (20s), moving on"
					task.wait(0.5)
					break
				end

				-- PHASE A: OPEN BOXES/CRATES
				State.PathfinderStatus = "Opening boxes in garage..."
				local boxes = findPromptsNear(garagePos, 80, "OpenBoxPrompt")
				for i, box in ipairs(boxes) do
					if not State.PathfinderEnabled then break end

					local key = tostring(box.prompt)
					if isBlacklisted(key) then continue end

					State.PathfinderStatus = "Opening box " .. i .. "/" .. #boxes
					local arrived = walkTo(box.position, 15)
					if arrived then
						triggerPrompt(box.prompt)
						task.wait(0.3)
					else
						recordAttempt(key)
					end
				end

				-- PHASE B: COLLECT ALL ITEMS
				State.PathfinderStatus = "Collecting items..."

				-- Find all PickupPrompt instances near the garage area
				local pickups = findPromptsNear(target.position, 60, "PickupPrompt")

				if #pickups == 0 then
					-- Try at the garage model position
					if garageModel then
						pickups = findPromptsNear(garagePos, 80, "PickupPrompt")
					end
				end

				if #pickups == 0 then
					-- Last resort: search the entire workspace for pickup prompts
					for _, desc in ipairs(workspace:GetDescendants()) do
						if desc:IsA("ProximityPrompt") and desc.Name == "PickupPrompt" then
							local parent = desc.Parent
							if parent and parent:IsA("BasePart") then
								table.insert(pickups, {
									prompt = desc,
									part = parent,
									position = parent.Position,
									distance = 0,
								})
							end
						end
					end
					table.sort(pickups, function(a, b) return a.distance < b.distance end)
				end

				-- Walk to each pickup and collect using fireproximityprompt
				for i, pickup in ipairs(pickups) do
					if not State.PathfinderEnabled then break end

					local key = tostring(pickup.prompt)
					if isBlacklisted(key) then continue end

					State.PathfinderStatus = "Collecting item " .. i .. "/" .. #pickups
					local arrived = walkTo(pickup.position, 15)
					if arrived then
						triggerPrompt(pickup.prompt)
						task.wait(0.3)
					else
						recordAttempt(key)
					end
				end

				-- VERIFICATION: check if anything remains
				task.wait(0.3)

				local remainingBoxes = findPromptsNear(garagePos, 80, "OpenBoxPrompt")
				local remainingItems = findPromptsNear(garagePos, 80, "PickupPrompt")

				if #remainingBoxes == 0 and #remainingItems == 0 then
					garageCleared = true
					State.PathfinderStatus = "Garage cleared!"
				else
					State.PathfinderStatus = "Verification: " .. #remainingBoxes .. " boxes, " .. #remainingItems .. " items remain"
				end

				task.wait(0.3)
			end

			-- ── EXIT GARAGE: walk back to the auction board ──
			State.PathfinderPhase = "Exiting Garage"
			State.PathfinderStatus = "Exiting garage, returning to auction board..."
			walkTo(target.position, 20)

			-- Ensure we're safely outside before transitioning back to State 1
			local exitStart = tick()
			local root = getRoot()
			while root and (root.Position - target.position).Magnitude >= 6 and State.PathfinderEnabled do
				if tick() - exitStart > 15 then
					break
				end
				root = getRoot()
				if root then
					local hum = getHumanoid()
					if hum then
						hum:MoveTo(target.position)
					end
				end
				task.wait(0.5)
			end
		else
			State.PathfinderStatus = "Auction lost or no items to collect"
			task.wait(2)
		end

		State.PathfinderStatus = "Cycle complete, searching for next auction..."
		task.wait(1)
	end

	State.PathfinderPhase = "Idle"
	if not State.PathfinderEnabled then
		State.PathfinderStatus = "Disabled"
	else
		State.PathfinderStatus = "Stopped"
	end
	State._pathfinderRunning = false
end

-- ── Start/stop pathfinder ──
local function setPathfinderEnabled(value)
	State.PathfinderEnabled = value

	if value and not State._pathfinderRunning then
		State._pathfinderRunning = true
		State.PathfinderStatus = "Starting..."
		task.spawn(pathfinderLoop)
	elseif not value then
		State.PathfinderStatus = "Disabled"
	end
end

-- ═══════════════════════════════════════════════════════════════
-- WindUI
-- ═══════════════════════════════════════════════════════════════
local Window = WindUI:CreateWindow({
	Title = "Auto Auction",
	Folder = "AutoAuction",
	Icon = "solar:cursor-square-bold-duotone",
	NewElements = true,
	HideSearchBar = true,
	Topbar = {
		Height = 38,
		ButtonsType = "Mac",
	},
})

-- ═══════════════════════════════════════════════════════════════
-- Auction Tab
-- ═══════════════════════════════════════════════════════════════
local AuctionTab = Window:Tab({
	Title = "Auction",
	Desc = "Auto bidding controls",
	Icon = "solar:cursor-square-bold-duotone",
})

AuctionTab:Toggle({
	Title = "Auto Bid",
	Desc = "Automatically bid when the cursor is in the green zone",
	Value = State.BidEnabled,
	Callback = function(value)
		State.BidEnabled = value
	end,
})

AuctionTab:Space()

AuctionTab:Paragraph({
	Title = "How it works",
	Desc = "Monitors the bidding bar during garage auctions and automatically fires a bid when the moving cursor overlaps the green target zone.",
})

AuctionTab:Space()

AuctionTab:Button({
	Title = "Leave Auction",
	Icon = "solar:logout-2-bold",
	Callback = function()
		local ok, result = pcall(function()
			return LeaveAuctionRemote:InvokeServer()
		end)
		if ok and result then
			local UIController = require(ReplicatedStorage.Modules.UIController)
			UIController:Close("AuctionBidding")
			UIController:Close("AuctionPowers")
			UIController:Close("AuctionWinningBid")
		end
	end,
})

-- ═══════════════════════════════════════════════════════════════
-- Auto Sell Tab
-- ═══════════════════════════════════════════════════════════════
local SellTab = Window:Tab({
	Title = "Auto Sell",
	Desc = "Auto quick-sell controls",
	Icon = "solar:wallet-bold-duotone",
})

-- Master Toggle
SellTab:Toggle({
	Title = "Master Toggle",
	Desc = "Enable auto-selling when conditions are met",
	Value = State.SellEnabled,
	Callback = function(value)
		State.SellEnabled = value
	end,
})

SellTab:Space()

-- Min Sell Rate slider (range -50% to +50%)
local RateSlider
RateSlider = SellTab:Slider({
	Title = "Sell Rate",
	Desc = "Minimum quick-sell rate (%) to trigger a sale",
	IsTooltip = true,
	IsTextbox = true,
	Width = 200,
	Step = 1,
	Value = {
		Min = -50,
		Max = 50,
		Default = -15,
	},
	Callback = function(value)
		State.MinSellRate = value
	end,
})
State.MinSellRate = -15

SellTab:Space()

-- Min Load Weight slider
local WeightSlider
WeightSlider = SellTab:Slider({
	Title = "Load Weight",
	Desc = "Minimum vehicle load weight (kg) to trigger a sale",
	IsTooltip = true,
	IsTextbox = true,
	Width = 200,
	Step = 1,
	Value = {
		Min = 0,
		Max = 100,
		Default = 20,
	},
	Callback = function(value)
		State.MinWeight = value
	end,
})
State.MinWeight = 20

SellTab:Space()

-- Save Trophies toggle
SellTab:Toggle({
	Title = "Save Trophies",
	Desc = "Don't auto-sell items with the Trophy category (e.g. Gavel Trophy)",
	Value = State.SaveTrophies,
	Callback = function(value)
		State.SaveTrophies = value
	end,
})

SellTab:Space()

-- Save Accessories toggle
SellTab:Toggle({
	Title = "Save Accessories",
	Desc = "Don't auto-sell items with the Accessories category",
	Value = State.SaveAccessories,
	Callback = function(value)
		State.SaveAccessories = value
	end,
})

SellTab:Space()

-- Live status readout
local StatusSection = SellTab:Section({
	Title = "Status",
})

local RateLabel
local WeightLabel
local StatusLabel

-- Build a small live-status group
local StatusGroup = SellTab:Group({})

RateLabel = StatusGroup:Paragraph({
	Title = "Current Rate",
	Desc = "Waiting for data...",
})

WeightLabel = StatusGroup:Paragraph({
	Title = "Vehicle Load",
	Desc = "Waiting for data...",
})

StatusLabel = StatusGroup:Paragraph({
	Title = "Auto Sell Status",
	Desc = "Inactive",
})

-- ── Live status updater ──
if State.StatusUpdater then
	State.StatusUpdater:Disconnect()
end
State.StatusUpdater = RunService.Heartbeat:Connect(function()
	if not RateLabel or not WeightLabel or not StatusLabel then
		return
	end

	local pct = ratePercent(State.CurrentRate)
	RateLabel:SetDesc("Rate: " .. formatRate(State.CurrentRate))

	WeightLabel:SetDesc("Weight: " .. math.floor(State.CurrentWeight) .. " kg")

	if not State.SellEnabled then
		StatusLabel:SetDesc("Disabled — toggle Master Toggle on")
		return
	end

	if pct < State.MinSellRate then
		StatusLabel:SetDesc("Waiting for rate (" .. pct .. "% < " .. State.MinSellRate .. "%)")
		return
	end

	if State.CurrentWeight < State.MinWeight then
		StatusLabel:SetDesc("Waiting for weight (" .. math.floor(State.CurrentWeight) .. "kg < " .. State.MinWeight .. "kg)")
		return
	end

	if State.SellSyncing then
		StatusLabel:SetDesc("Selling in progress...")
		return
	end

	if tick() < State.SellCooldown then
		local remaining = math.floor(State.SellCooldown - tick())
		StatusLabel:SetDesc("Cooldown (" .. remaining .. "s)")
		return
	end

	StatusLabel:SetDesc("Conditions met — ready to sell")
end)

-- Manual refresh button
SellTab:Space()
SellTab:Button({
	Title = "Refresh Now",
	Icon = "solar:refresh-bold",
	Callback = function()
		task.spawn(function()
			local ok, state = pcall(function()
				return GetPawnState:InvokeServer()
			end)
			if ok and type(state) == "table" and state.rate then
				State.CurrentRate = state.rate
			end
		end)
	end,
})

-- ═══════════════════════════════════════════════════════════════
-- Pathfinder Tab
-- ═══════════════════════════════════════════════════════════════
local PathfinderTab = Window:Tab({
	Title = "Pathfinder",
	Desc = "Auto auction loop",
	Icon = "solar:map-arrow-right-bold-duotone",
})

-- Master Pathfinder Toggle
PathfinderTab:Toggle({
	Title = "Master Pathfinder",
	Desc = "Enable the full auto-auction loop (walk → trigger → bid → collect)",
	Value = State.PathfinderEnabled,
	Callback = function(value)
		setPathfinderEnabled(value)
	end,
})

PathfinderTab:Space()

-- Section label for area toggles
PathfinderTab:Section({
	Title = "Target Areas",
	TextSize = 16,
})

-- Area toggle for each garage tier
for _, area in ipairs({ "Junk Yard", "Back Alley", "Farmyard", "Shipyard" }) do
	PathfinderTab:Toggle({
		Title = area,
		Desc = "Target " .. area .. " auctions",
		Value = State.AreaToggles[area],
		Callback = function(value)
			State.AreaToggles[area] = value
		end,
	})
	PathfinderTab:Space()
end

-- Status readout
PathfinderTab:Section({
	Title = "Status",
})

local PFGroup = PathfinderTab:Group({})

local PhaseLabel = PFGroup:Paragraph({
	Title = "Current Phase",
	Desc = "Idle",
})

local StateLabel = PFGroup:Paragraph({
	Title = "State",
	Desc = "Waiting for activation",
})

-- ── Pathfinder status updater ──
if State.PFStatusUpdater then
	State.PFStatusUpdater:Disconnect()
end
State.PFStatusUpdater = RunService.Heartbeat:Connect(function()
	if PhaseLabel then
		PhaseLabel:SetDesc(State.PathfinderPhase or "Idle")
	end
	if StateLabel then
		StateLabel:SetDesc(State.PathfinderStatus or "Waiting for activation")
	end
end)

print("[AutoAuction] Loaded successfully")
