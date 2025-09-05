-- Manastorm Manager - Automatically opens Manastorm Caches
-- Compatible with WoW 3.3.5a and Lua 5.1

local addonName = "ManastormManager"
local version = "1.0"

-- Addon variables
local isOpening = false
local isProcessingQueue = false  -- Prevent multiple ProcessQueue calls
local openQueue = {}
local currentlyOpening = 0
local totalCaches = 0
local initialCacheCount = 0  -- Track how many we started with
local bonusMessageShown = false
local lastScanResults = {}  -- Track what we found in last scan for comparison
local noItemsFoundCount = 0  -- Track how many times in a row we found no items

-- UI references for status updates
local dockOpenButton = nil
local mainOpenButton = nil

-- Vendor variables
local isVendoring = false
local vendorQueue = {}
local currentlyVendoring = 0
local totalVendorItems = 0
local totalGoldEarned = 0
local sessionGoldEarned = 0  -- Track total gold across all vendor sessions

-- Auto-open timer variables
local autoOpenTimer = nil
local lastCacheCount = 0
local bagCheckTimer = nil

-- NPC Detection variables
local npcScanTimer = nil
local lastNPCAlert = 0  -- Timestamp of last alert to prevent spam
local alertCooldown = 30  -- Cooldown in seconds between alerts for same NPC
local detectedNPCs = {}  -- Track detected NPCs with timestamps
local detectedGUIDs = {}  -- Track specific NPC instances by GUID
local flashFrame = nil  -- Frame for screen flash effect
local toastFrame = nil  -- Frame for NPC toast notification
local currentToastUnit = nil  -- Currently displayed NPC unit ID

-- GUI variables
local optionsFrame = nil
local mainFrame = nil
local dockFrame = nil

-- Forward declarations for GUI functions
local ShowOptionsGUI
local ShowMainUI
local ShowProtectedItemsGUI
local ShowAutoVendingGUI

-- Default settings
local defaultSettings = {
    delay = 0.7,  -- Delay between opening caches (seconds) - enough time for loot window
    verbose = false,  -- Show detailed messages
    vendorDelay = 0.2,  -- Delay between vendoring items (seconds)
    -- Sell gear by rarity (true = sell, false = keep)
    sellTrash = true,     -- Gray items (quality 0)
    sellCommon = true,    -- White items (quality 1)
    sellUncommon = true,  -- Green items (quality 2)
    sellRare = true,      -- Blue items (quality 3) - changed to true
    sellEpic = false,     -- Purple items (quality 4)
    protectedItems = {},  -- List of item names to never sell
    autoSellItems = {},  -- List of item names to always sell
    autoOpen = false,  -- Automatically open caches when found
    adventureMode = false,  -- Adventure Mode: open Adventurer's Caches and manage Hearthstones
    showDock = true,  -- Show the main UI dock
    dockTheme = "blizzard",  -- Dock theme: "blizzard" or "elvui"
    dockLocked = false,  -- Whether the dock is locked from moving
    dockPoint = "CENTER",  -- Dock anchor point
    dockRelativePoint = "CENTER",  -- Dock relative anchor point
    dockX = 200,  -- Dock X offset
    dockY = 200,  -- Dock Y offset
    -- NPC Detection settings
    npcDetection = true,  -- Enable NPC detection for rare spawns
    npcScanInterval = 2.0,  -- Scan interval in seconds
    npcAlertSound = true,  -- Play alert sound when NPC found
    npcFlashScreen = true,  -- Flash screen edges when NPC found
    npcMarkTarget = true,  -- Place raid target marker on detected NPC
    npcLightMode = true  -- Use light scanning mode for better performance
}

-- Initialize settings with defaults
local function InitializeSettings()
    ManastormManagerDB = ManastormManagerDB or {}
    
    -- Add any missing settings from defaults
    for key, value in pairs(defaultSettings) do
        if ManastormManagerDB[key] == nil then
            ManastormManagerDB[key] = value
        end
    end
    
    -- Special handling for tables to preserve existing data
    ManastormManagerDB.protectedItems = ManastormManagerDB.protectedItems or {}
    ManastormManagerDB.autoSellItems = ManastormManagerDB.autoSellItems or {}
end

-- Print function with addon prefix
local function Print(msg)
    print("|cff00ff00[Millhouse Manastorm]|r " .. msg)
end

-- Debug print function (only for verbose mode)
local function DebugPrint(msg)
    if ManastormManagerDB.verbose then
        Print("|cffcccccc" .. msg .. "|r")
    end
end

-- Wildcard matching function (supports * wildcards)
local function MatchesPattern(itemName, pattern)
    if not itemName or not pattern then
        if ManastormManagerDB and ManastormManagerDB.verbose then
            DebugPrint("MatchesPattern: itemName='" .. (itemName or "nil") .. "', pattern='" .. (pattern or "nil") .. "' - returning false")
        end
        return false
    end
    
    -- Convert to lowercase for case-insensitive matching
    local lowerItem = string.lower(itemName)
    local lowerPattern = string.lower(pattern)
    
    if ManastormManagerDB and ManastormManagerDB.verbose then
        DebugPrint("MatchesPattern: Testing '" .. lowerItem .. "' against pattern '" .. lowerPattern .. "'")
    end
    
    -- If no wildcards, do exact match
    if not string.find(lowerPattern, "*", 1, true) then
        local result = lowerItem == lowerPattern
        if ManastormManagerDB and ManastormManagerDB.verbose then
            DebugPrint("MatchesPattern: Exact match = " .. tostring(result))
        end
        return result
    end
    
    -- Convert wildcard pattern to Lua pattern
    -- Escape special Lua pattern characters except *
    local luaPattern = string.gsub(lowerPattern, "([%^%$%(%)%%%.%[%]%+%-%?])", "%%%1")
    -- Replace * with .*
    luaPattern = string.gsub(luaPattern, "%*", ".*")
    -- Anchor the pattern to match the entire string
    luaPattern = "^" .. luaPattern .. "$"
    
    local result = string.find(lowerItem, luaPattern) ~= nil
    
    if ManastormManagerDB and ManastormManagerDB.verbose then
        DebugPrint("MatchesPattern: Lua pattern = '" .. luaPattern .. "', result = " .. tostring(result))
    end
    
    return result
end


-- Update button texts to show opening status
local function UpdateButtonStatus()
    local buttonText = "Open Caches"
    
    if isOpening then
        local remaining = totalCaches - currentlyOpening
        if remaining > 0 then
            buttonText = "Opening... (" .. remaining .. " left)"
        elseif table.getn(openQueue) > 0 then
            buttonText = "Processing..."
        else
            buttonText = "Finishing..."
        end
    end
    
    -- Update dock button if it exists
    if dockOpenButton then
        dockOpenButton:SetText(buttonText)
    end
    
    -- Update main UI button if it exists
    if mainOpenButton then
        mainOpenButton:SetText(buttonText)
    end
end

-- Find all Manastorm Caches (and Adventurer's Caches in Adventure Mode) in bags
-- More reliable cache finding with detailed counting
local function FindManastormCaches(forceRescan, includeLocked)
    local caches = {}
    local bonusCaches = 0
    local totalCount = 0
    
    -- If we're not forcing a rescan and isOpening is true, be more thorough
    local thoroughScan = forceRescan or isOpening
    
    -- Scan all bags (0-4: backpack + 4 bags)
    for bag = 0, 4 do
        local numSlots = GetContainerNumSlots(bag)
        if numSlots then
            for slot = 1, numSlots do
                local itemLink = GetContainerItemLink(bag, slot)
                if itemLink then
                    local itemName = GetItemInfo(itemLink)
                    local isManastormCache = itemName and string.find(itemName, "Manastorm") and string.find(itemName, "Cache")
                    local isAdventurerCache = ManastormManagerDB.adventureMode and itemName and string.find(itemName, "Adventurer") and string.find(itemName, "Cache")
                    
                    if isManastormCache or isAdventurerCache then
                        local texture, itemCount, locked, quality, readable = GetContainerItemInfo(bag, slot)
                        
                        -- More thorough validation during opening process
                        if thoroughScan then
                            DebugPrint("Found cache: " .. itemName .. " at bag " .. bag .. " slot " .. slot .. 
                                     " count=" .. (itemCount or 0) .. " locked=" .. tostring(locked))
                        end
                        
                        -- Include locked items if requested (for re-scanning during processing)
                        if (not locked or includeLocked) and itemCount and itemCount > 0 then
                            -- Check if this is a Bonus Manastorm Cache (only applies to Manastorm caches)
                            if isManastormCache and string.find(itemName, "Bonus") then
                                bonusCaches = bonusCaches + itemCount
                            else
                                -- Regular cache that can be opened
                                table.insert(caches, {
                                    bag = bag, 
                                    slot = slot, 
                                    count = itemCount, 
                                    name = itemName,
                                    id = bag .. ":" .. slot,  -- Unique identifier
                                    locked = locked,  -- Track lock status
                                    type = isManastormCache and "manastorm" or "adventurer"
                                })
                                totalCount = totalCount + itemCount
                            end
                        end
                    end
                end
            end
        end
    end
    
    -- If we found bonus caches, inform the player (but only once per session)
    if bonusCaches > 0 and not bonusMessageShown then
        Print("I detect " .. bonusCaches .. " Bonus Manastorm Cache" .. (bonusCaches > 1 and "s" or "") .. " in your possession!")
        print("|cffff8800Even my incredible magical abilities have limits - these special caches resist my power! You must open them yourself, mortal.|r")
        bonusMessageShown = true
    end
    
    if thoroughScan then
        DebugPrint("Cache scan complete: " .. table.getn(caches) .. " slots with " .. totalCount .. " total caches")
    end
    
    return caches, totalCount
end

-- Adventure Mode: Find and clean up multiple Hearthstones
local function CleanupExtraHearthstones()
    if not ManastormManagerDB.adventureMode then
        return
    end
    
    local hearthstones = {}
    
    -- Scan all bags for Hearthstone items
    for bag = 0, 4 do
        local numSlots = GetContainerNumSlots(bag)
        if numSlots then
            for slot = 1, numSlots do
                local itemLink = GetContainerItemLink(bag, slot)
                if itemLink then
                    local itemName = GetItemInfo(itemLink)
                    if itemName and string.find(itemName, "Hearthstone") then
                        local texture, itemCount, locked = GetContainerItemInfo(bag, slot)
                        if not locked and itemCount and itemCount > 0 then
                            table.insert(hearthstones, {
                                bag = bag,
                                slot = slot,
                                count = itemCount,
                                name = itemName
                            })
                        end
                    end
                end
            end
        end
    end
    
    -- If we have multiple hearthstones, destroy the extras
    if table.getn(hearthstones) > 1 then
        print(" ")  -- Blank line before
        print("|cffff8800I'm detecting an anomaly in time! You have multiple hearthstones and some seem to be from alternate timelines!|r")
        print("|cffff8800Stand back, I, Millhouse the Magnificent will untangle these threads of fate and restore order!|r")
        print("|cffff8800...Tell Chromie I said to stop meddling in Magic so obviously beyond them. Leave it to a professional!|r")
        print(" ")  -- Blank line after
        
        -- Keep the first one, destroy the rest
        for i = 2, table.getn(hearthstones) do
            local hs = hearthstones[i]
            DebugPrint("Destroying extra " .. hs.name .. " at bag " .. hs.bag .. " slot " .. hs.slot)
            PickupContainerItem(hs.bag, hs.slot)
            DeleteCursorItem()
        end
    end
end

-- NPC Detection Functions

-- Create screen flash effect
local function CreateFlashEffect()
    if flashFrame then
        return flashFrame
    end
    
    flashFrame = CreateFrame("Frame", "ManastormFlashFrame", UIParent)
    flashFrame:SetAllPoints()
    flashFrame:SetFrameStrata("FULLSCREEN_DIALOG")
    flashFrame:Hide()
    
    -- Create border textures for flashing effect
    local borders = {}
    local borderSize = 8
    
    -- Top border
    borders.top = flashFrame:CreateTexture(nil, "OVERLAY")
    borders.top:SetTexture(1, 1, 0, 0.7)  -- Yellow with transparency
    borders.top:SetPoint("TOPLEFT", flashFrame, "TOPLEFT")
    borders.top:SetPoint("TOPRIGHT", flashFrame, "TOPRIGHT")
    borders.top:SetHeight(borderSize)
    
    -- Bottom border  
    borders.bottom = flashFrame:CreateTexture(nil, "OVERLAY")
    borders.bottom:SetTexture(1, 1, 0, 0.7)
    borders.bottom:SetPoint("BOTTOMLEFT", flashFrame, "BOTTOMLEFT")
    borders.bottom:SetPoint("BOTTOMRIGHT", flashFrame, "BOTTOMRIGHT")
    borders.bottom:SetHeight(borderSize)
    
    -- Left border
    borders.left = flashFrame:CreateTexture(nil, "OVERLAY")
    borders.left:SetTexture(1, 1, 0, 0.7)
    borders.left:SetPoint("TOPLEFT", flashFrame, "TOPLEFT")
    borders.left:SetPoint("BOTTOMLEFT", flashFrame, "BOTTOMLEFT")
    borders.left:SetWidth(borderSize)
    
    -- Right border
    borders.right = flashFrame:CreateTexture(nil, "OVERLAY")
    borders.right:SetTexture(1, 1, 0, 0.7)
    borders.right:SetPoint("TOPRIGHT", flashFrame, "TOPRIGHT")
    borders.right:SetPoint("BOTTOMRIGHT", flashFrame, "BOTTOMRIGHT")
    borders.right:SetWidth(borderSize)
    
    flashFrame.borders = borders
    return flashFrame
end

-- Flash the screen edges
local function FlashScreen()
    if not ManastormManagerDB or not ManastormManagerDB.npcFlashScreen then
        return
    end
    
    local frame = CreateFlashEffect()
    frame:Show()
    
    -- Animate the flash
    local elapsed = 0
    local duration = 0.8
    local pulses = 3
    
    frame:SetScript("OnUpdate", function(self, dt)
        elapsed = elapsed + dt
        local progress = elapsed / duration
        
        if progress >= 1 then
            self:Hide()
            self:SetScript("OnUpdate", nil)
            return
        end
        
        -- Calculate alpha for pulsing effect
        local pulseProgress = (progress * pulses) % 1
        local alpha = 0.7 * (1 - pulseProgress)
        
        -- Update all border alphas
        for _, border in pairs(self.borders) do
            border:SetTexture(1, 1, 0, alpha)
        end
    end)
end

-- Play alert sound
local function PlayAlertSound()
    if not ManastormManagerDB or not ManastormManagerDB.npcAlertSound then
        return
    end
    
    -- Play a notification sound - using RaidWarning sound
    PlaySound("RaidWarning")
end

-- Create NPC toast notification
local function CreateToastNotification()
    if toastFrame then
        return toastFrame
    end
    
    toastFrame = CreateFrame("Frame", "ManastormNPCToast", UIParent)
    toastFrame:SetSize(220, 140)
    
    -- Load saved position or use default
    if ManastormManagerDB.toastPoint then
        toastFrame:SetPoint(
            ManastormManagerDB.toastPoint,
            UIParent,
            ManastormManagerDB.toastRelativePoint or "CENTER",
            ManastormManagerDB.toastX or 0,
            ManastormManagerDB.toastY or 0
        )
    else
        -- Default position above dock
        toastFrame:SetPoint("BOTTOM", dockFrame, "TOP", 0, 10)
    end
    
    toastFrame:SetFrameStrata("HIGH")
    toastFrame:EnableMouse(true)
    toastFrame:SetMovable(true)
    toastFrame:RegisterForDrag("LeftButton")
    toastFrame:Hide()
    
    -- Drag functionality
    toastFrame:SetScript("OnDragStart", function(self)
        if not IsShiftKeyDown() then
            return  -- Only allow dragging with Shift held
        end
        self:StartMoving()
    end)
    
    toastFrame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        -- Save the position
        local point, _, relativePoint, x, y = self:GetPoint()
        ManastormManagerDB.toastPoint = point
        ManastormManagerDB.toastRelativePoint = relativePoint
        ManastormManagerDB.toastX = x
        ManastormManagerDB.toastY = y
        Print("Toast position saved! Future notifications will appear here.")
    end)
    
    -- Background
    local bg = toastFrame:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetTexture(0, 0, 0, 0.8)
    
    -- Border
    local border = CreateFrame("Frame", nil, toastFrame)
    border:SetAllPoints()
    border:SetBackdrop({
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12,
        insets = {left = 2, right = 2, top = 2, bottom = 2}
    })
    border:SetBackdropBorderColor(1, 0.8, 0, 1) -- Gold border
    
    -- Title
    local title = toastFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -8)
    title:SetTextColor(1, 0, 0, 1) -- Red
    title:SetText("RARE SPAWN!")
    toastFrame.title = title
    
    -- NPC Name
    local npcName = toastFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    npcName:SetPoint("TOP", title, "BOTTOM", 0, -4)
    npcName:SetTextColor(1, 1, 0, 1) -- Yellow
    npcName:SetText("")
    toastFrame.npcName = npcName
    
    -- 3D Model Frame
    local modelFrame = CreateFrame("PlayerModel", nil, toastFrame)
    modelFrame:SetSize(80, 80)
    modelFrame:SetPoint("LEFT", 10, -10)
    modelFrame:SetCamera(0)
    toastFrame.modelFrame = modelFrame
    
    -- Click to target button using SecureActionButton to avoid taint
    local targetButton = CreateFrame("Button", nil, toastFrame, "SecureActionButtonTemplate")
    targetButton:SetAllPoints(modelFrame)
    targetButton:SetAttribute("type", "macro")
    -- We'll set the macro text when we show the toast
    toastFrame.targetButton = targetButton
    
    -- Close button
    local closeButton = CreateFrame("Button", nil, toastFrame)
    closeButton:SetSize(16, 16)
    closeButton:SetPoint("TOPRIGHT", -4, -4)
    closeButton:SetNormalTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Up")
    closeButton:SetPushedTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Down")
    closeButton:SetHighlightTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Highlight")
    closeButton:SetScript("OnClick", function()
        toastFrame:Hide()
        currentToastUnit = nil
    end)
    toastFrame.closeButton = closeButton
    
    -- Instructions text
    local instructions = toastFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    instructions:SetPoint("BOTTOMLEFT", 10, 8)
    instructions:SetPoint("BOTTOMRIGHT", -30, 8)
    instructions:SetHeight(30)
    instructions:SetJustifyH("LEFT")
    instructions:SetTextColor(0.8, 0.8, 0.8, 1)
    instructions:SetText("Click model to target\nShift+Drag to move • X to close")
    toastFrame.instructions = instructions
    
    -- Auto-hide timer
    local autoHideTimer = nil
    toastFrame.StartAutoHide = function(self, duration)
        if autoHideTimer then
            autoHideTimer:SetScript("OnUpdate", nil)
        end
        
        autoHideTimer = CreateFrame("Frame")
        local elapsed = 0
        autoHideTimer:SetScript("OnUpdate", function(timer, dt)
            elapsed = elapsed + dt
            if elapsed >= (duration or 10) then
                timer:SetScript("OnUpdate", nil)
                self:Hide()
                currentToastUnit = nil
            end
        end)
    end
    
    return toastFrame
end

-- Show toast notification for detected NPC
local function ShowNPCToast(unitId, npcName)
    if not ManastormManagerDB or not ManastormManagerDB.npcDetection then
        return
    end
    
    local toast = CreateToastNotification()
    currentToastUnit = unitId
    
    -- Set NPC name
    toast.npcName:SetText(npcName)
    
    -- Try to set the model - this might not work perfectly in 3.3.5a
    if toast.modelFrame and UnitExists(unitId) then
        -- Method 1: Try to set model from unit
        toast.modelFrame:SetUnit(unitId)
        
        -- Method 2: Fallback - try to set by creature display ID (if available)
        -- This would need specific display IDs for each NPC, which we don't have
        -- So we'll rely on SetUnit working
        
        -- Set camera position
        toast.modelFrame:SetCamera(0)
        toast.modelFrame:SetPosition(0, 0, 0)
        toast.modelFrame:SetFacing(0)
    end
    
    -- Set up the secure targeting macro for the button
    if toast.targetButton then
        -- Use /targetexact to avoid partial name matches
        local macroText = "/targetexact " .. npcName
        toast.targetButton:SetAttribute("macrotext", macroText)
    end
    
    -- Show the toast
    toast:Show()
    
    -- Auto-hide after 15 seconds
    toast:StartAutoHide(15)
    
    DebugPrint("Showing toast notification for: " .. npcName)
end

-- Mark target with raid icon
local function MarkNPCTarget(unitId)
    if not ManastormManagerDB or not ManastormManagerDB.npcMarkTarget or not unitId then
        return
    end
    
    -- Check if target already has a raid icon
    local existingMark = GetRaidTargetIndex(unitId)
    if existingMark and existingMark > 0 then
        DebugPrint("Target already has raid mark " .. existingMark .. ", not overriding")
        return
    end
    
    -- Set raid target icon 7 (cross/X) on the NPC
    -- Only works if player has raid/party lead or assist
    SetRaidTarget(unitId, 7)
    DebugPrint("Marked target with cross (7) raid icon")
end

-- Scan for target NPCs
local function ScanForTargetNPCs()
    if not ManastormManagerDB or not ManastormManagerDB.npcDetection then
        return
    end
    
    local currentTime = GetTime()
    local targetNPCs = {
        "Clepto the Cardnapper",
        "Greedy Demon"
    }
    
    -- Helper function to check and alert for target NPC
    local function CheckUnit(unitId, unitName)
        if not unitName then return end
        
        -- Get unit GUID for tracking specific instances
        local unitGUID = UnitGUID(unitId)
        
        -- Check if unit is dead
        if UnitIsDead(unitId) then
            -- If this specific NPC instance was tracked, remove it
            if unitGUID and detectedGUIDs[unitGUID] then
                DebugPrint("Detected NPC with GUID " .. unitGUID .. " is dead, removing from tracking")
                detectedGUIDs[unitGUID] = nil
            end
            -- Also clear the name-based cooldown for this NPC type
            for _, targetName in ipairs(targetNPCs) do
                if unitName == targetName and detectedNPCs[targetName] then
                    DebugPrint("Detected NPC " .. targetName .. " is dead, clearing cooldown")
                    detectedNPCs[targetName] = nil  -- Clear cooldown so new spawns are detected immediately
                end
            end
            return false
        end
        
        -- Check if unit is attackable (not already tapped by another player)
        if not UnitCanAttack("player", unitId) then
            DebugPrint("Unit " .. unitName .. " cannot be attacked, skipping")
            return false
        end
        
        for _, targetName in ipairs(targetNPCs) do
            if unitName == targetName then
                -- Check if we've already alerted for this specific NPC instance
                if unitGUID and detectedGUIDs[unitGUID] then
                    -- We've already alerted for this specific NPC
                    return false
                end
                
                -- This is a new instance of the NPC (different GUID or no GUID available)
                -- Mark this specific instance as detected
                if unitGUID then
                    detectedGUIDs[unitGUID] = currentTime
                end
                
                -- Also track by name for fallback (in case GUID isn't available)
                detectedNPCs[targetName] = currentTime
                
                -- Alert the player
                Print("|cffff0000RARE SPAWN DETECTED:|r |cffffee00" .. targetName .. "|r has been found!")
                Print("The magnificent Millhouse has marked this creature for your convenience!")
                
                -- Flash screen
                FlashScreen()
                
                -- Play sound
                PlayAlertSound()
                
                -- Show toast notification with NPC model
                ShowNPCToast(unitId, targetName)
                
                -- Mark with raid target (only if not already marked)
                MarkNPCTarget(unitId)
                
                DebugPrint("Detected and marked: " .. targetName .. " (unit: " .. unitId .. ", GUID: " .. (unitGUID or "unknown") .. ")")
                return true
            end
        end
        return false
    end
    
    -- Check target
    if UnitExists("target") then
        local targetName = UnitName("target")
        CheckUnit("target", targetName)
    end
    
    -- Check mouseover
    if UnitExists("mouseover") then
        local mouseoverName = UnitName("mouseover")
        CheckUnit("mouseover", mouseoverName)
    end
    
    -- Check party/raid targets
    if GetNumPartyMembers() > 0 then
        for i = 1, GetNumPartyMembers() do
            local unitId = "party" .. i .. "target"
            if UnitExists(unitId) then
                local unitName = UnitName(unitId)
                CheckUnit(unitId, unitName)
            end
        end
    end
    
    -- Check raid targets if in raid
    if GetNumRaidMembers() > 0 then
        for i = 1, GetNumRaidMembers() do
            local unitId = "raid" .. i .. "target"
            if UnitExists(unitId) then
                local unitName = UnitName(unitId)
                CheckUnit(unitId, unitName)
            end
        end
    end
    
    -- Try to scan nameplates
    for i = 1, 40 do
        local unitId = "nameplate" .. i
        if UnitExists(unitId) then
            local unitName = UnitName(unitId)
            CheckUnit(unitId, unitName)
        end
    end
end

-- Start NPC detection timer
local function StartNPCDetection()
    -- Ensure settings are initialized
    if not ManastormManagerDB then
        InitializeSettings()
    end
    
    if not ManastormManagerDB.npcDetection then
        StopNPCDetection()
        return
    end
    
    if npcScanTimer then
        return  -- Already running
    end
    
    -- Default scan interval if not set
    local scanInterval = ManastormManagerDB.npcScanInterval or 2.0
    
    npcScanTimer = CreateFrame("Frame")
    local elapsed = 0
    
    npcScanTimer:SetScript("OnUpdate", function(self, dt)
        elapsed = elapsed + dt
        if elapsed >= scanInterval then
            elapsed = 0
            ScanForTargetNPCs()
        end
    end)
    
    DebugPrint("NPC Detection started (scan interval: " .. scanInterval .. "s)")
end

-- Stop NPC detection timer
local function StopNPCDetection()
    if npcScanTimer then
        npcScanTimer:SetScript("OnUpdate", nil)
        npcScanTimer = nil
        DebugPrint("NPC Detection stopped")
    end
end

-- Open a single cache
local function OpenCache(bag, slot, isAutoOpen)
    -- Get item info before opening
    local itemLink = GetContainerItemLink(bag, slot)
    local itemName = itemLink and GetItemInfo(itemLink) or "Unknown Cache"
    
    -- Safety check: Verify this is actually a cache before using it
    if itemLink and itemName then
        local isManastormCache = string.find(itemName, "Manastorm") and string.find(itemName, "Cache")
        local isAdventurerCache = ManastormManagerDB.adventureMode and string.find(itemName, "Adventurer") and string.find(itemName, "Cache")
        
        if not (isManastormCache or isAdventurerCache) then
            DebugPrint("WARNING: Attempted to open non-cache item: " .. itemName .. " at bag " .. bag .. " slot " .. slot)
            return  -- Don't open non-cache items
        end
    end
    
    DebugPrint("Opening " .. itemName .. " at bag " .. bag .. " slot " .. slot)
    UseContainerItem(bag, slot)
    currentlyOpening = currentlyOpening + 1
    
    -- Update button status to show progress
    UpdateButtonStatus()
    
    -- No more chat spam - completion message is handled in ProcessQueue
end

-- Count empty bag slots
local function GetEmptyBagSlots()
    local emptySlots = 0
    for bag = 0, 4 do
        local numSlots = GetContainerNumSlots(bag)
        if numSlots and numSlots > 0 then
            for slot = 1, numSlots do
                local texture = GetContainerItemInfo(bag, slot)
                if not texture then
                    emptySlots = emptySlots + 1
                end
            end
        end
    end
    return emptySlots
end

-- Process the opening queue
local function ProcessQueue(isAutoOpen)
    if not isOpening then
        DebugPrint("ProcessQueue: Stopping because isOpening is false")
        return
    end
    
    if isProcessingQueue then
        DebugPrint("ProcessQueue: Already processing, skipping")
        return
    end
    
    isProcessingQueue = true
    local queueSize = table.getn(openQueue)
    DebugPrint("ProcessQueue: Queue has " .. queueSize .. " items")
    
    -- Check bag space before continuing
    local emptySlots = GetEmptyBagSlots()
    if emptySlots <= 1 then
        Print("|cffff0000Stopping cache opening - bags are full! (" .. emptySlots .. " slots remaining)|r")
        Print("|cffffee00Clear some bag space and use /ms open to continue.|r")
        isProcessingQueue = false  -- Clear this before StopOpening
        StopOpening()
        return
    end
    
    -- Get next cache from queue
    if queueSize > 0 then
        local cache = table.remove(openQueue, 1)
        DebugPrint("Processing cache at bag " .. cache.bag .. " slot " .. cache.slot)
        
        -- Verify the cache is still there and is actually a cache
        local texture, itemCount, locked = GetContainerItemInfo(cache.bag, cache.slot)
        if texture then
            -- Double-check that this is still a cache item
            local itemLink = GetContainerItemLink(cache.bag, cache.slot)
            local isStillCache = false
            if itemLink then
                local itemName = GetItemInfo(itemLink)
                if itemName then
                    local isManastormCache = string.find(itemName, "Manastorm") and string.find(itemName, "Cache")
                    local isAdventurerCache = ManastormManagerDB.adventureMode and string.find(itemName, "Adventurer") and string.find(itemName, "Cache")
                    isStillCache = isManastormCache or isAdventurerCache
                end
            end
            
            if not isStillCache then
                -- Item in this slot is no longer a cache (probably got replaced by loot)
                DebugPrint("Item at bag " .. cache.bag .. " slot " .. cache.slot .. " is no longer a cache, skipping")
                -- Continue immediately
                local timer = CreateFrame("Frame")
                local elapsed = 0
                timer:SetScript("OnUpdate", function(self, elapsedTime)
                    elapsed = elapsed + elapsedTime
                    if elapsed >= 0.1 then
                        timer:SetScript("OnUpdate", nil)
                        isProcessingQueue = false
                        ProcessQueue(isAutoOpen)
                    end
                end)
            elseif locked then
                -- Check if we've tried too many times (level-restricted caches)
                cache.retries = (cache.retries or 0) + 1
                
                if cache.retries >= 3 then
                    -- Skip this cache after 3 failed attempts
                    local itemLink = GetContainerItemLink(cache.bag, cache.slot)
                    local itemName = itemLink and GetItemInfo(itemLink) or "Unknown Cache"
                    Print("|cffff0000Cannot open " .. itemName .. " - may require level 70. Skipping after 3 attempts.|r")
                    DebugPrint("Cache at bag " .. cache.bag .. " slot " .. cache.slot .. " failed 3 times, skipping")
                else
                    -- If locked, put it back at the end of the queue and continue with next
                    DebugPrint("Cache is locked (attempt " .. cache.retries .. "), requeueing and continuing")
                    table.insert(openQueue, cache)
                end
                
                -- Process next with a small delay to avoid freezing
                local timer = CreateFrame("Frame")
                local elapsed = 0
                timer:SetScript("OnUpdate", function(self, elapsedTime)
                    elapsed = elapsed + elapsedTime
                    if elapsed >= 0.1 then  -- Small delay to prevent freezing
                        timer:SetScript("OnUpdate", nil)
                        isProcessingQueue = false
                        ProcessQueue(isAutoOpen)
                    end
                end)
            else
                -- Open the cache
                OpenCache(cache.bag, cache.slot, isAutoOpen)
                noItemsFoundCount = 0  -- Reset counter since we opened something
                
                -- Wait before processing the next one to ensure loot window has time
                local timer = CreateFrame("Frame")
                local elapsed = 0
                timer:SetScript("OnUpdate", function(self, elapsedTime)
                    elapsed = elapsed + elapsedTime
                    if elapsed >= ManastormManagerDB.delay then
                        timer:SetScript("OnUpdate", nil)
                        -- Continue processing next cache
                        isProcessingQueue = false
                        ProcessQueue(isAutoOpen)
                    end
                end)
            end
        else
            -- Cache no longer exists, continue with small delay
            DebugPrint("Cache no longer exists at bag " .. cache.bag .. " slot " .. cache.slot)
            local timer = CreateFrame("Frame")
            local elapsed = 0
            timer:SetScript("OnUpdate", function(self, elapsedTime)
                elapsed = elapsed + elapsedTime
                if elapsed >= 0.1 then  -- Small delay to prevent freezing
                    timer:SetScript("OnUpdate", nil)
                    isProcessingQueue = false
                    ProcessQueue(isAutoOpen)
                end
            end)
        end
    else
        -- Queue is empty, rescan for more caches (include locked ones since they might be mid-loot)
        local caches, totalCount = FindManastormCaches(true, true)
        
        if table.getn(caches) > 0 then
            -- Found caches, reset counter and rebuild queue
            noItemsFoundCount = 0
            DebugPrint("Found " .. table.getn(caches) .. " caches (including locked), adding to queue")
            
            for i, cache in ipairs(caches) do
                table.insert(openQueue, {bag = cache.bag, slot = cache.slot, retries = 0})
            end
            
            -- Continue processing with small delay to avoid freezing
            local timer = CreateFrame("Frame")
            local elapsed = 0
            timer:SetScript("OnUpdate", function(self, elapsedTime)
                elapsed = elapsed + elapsedTime
                if elapsed >= 0.1 then
                    timer:SetScript("OnUpdate", nil)
                    isProcessingQueue = false
                    ProcessQueue(isAutoOpen)
                end
            end)
        else
            -- No caches found
            noItemsFoundCount = noItemsFoundCount + 1
            DebugPrint("No caches found (attempt " .. noItemsFoundCount .. ")")
            
            -- Only give up after 3 consecutive attempts with no caches found
            if noItemsFoundCount < 3 then
                -- Wait and try again with shorter delay
                local timer = CreateFrame("Frame")
                local elapsed = 0
                timer:SetScript("OnUpdate", function(self, elapsedTime)
                    elapsed = elapsed + elapsedTime
                    if elapsed >= 0.5 then  -- Wait 0.5 seconds between retries
                        timer:SetScript("OnUpdate", nil)
                        isProcessingQueue = false
                        ProcessQueue(isAutoOpen)
                    end
                end)
            else
                -- We've tried 3 times with no caches, we're really done
                isOpening = false
                isProcessingQueue = false
                
                -- Update UI immediately after setting isOpening to false
                UpdateButtonStatus()
                if mainFrame then
                    mainFrame.UpdateStatus()
                end
                
                print(" ")  -- Blank line before
                if currentlyOpening > 0 then
                    print("|cffff8800Successfully opened " .. currentlyOpening .. " Manastorm Cache" .. (currentlyOpening > 1 and "s" or "") .. "!|r")
                end
                print("|cffff8800If you have any excess priceless artifacts that were lost in time, I'm making a collection.|r")
                print(" ")  -- Blank line after
                
                -- Reset all counters
                currentlyOpening = 0
                totalCaches = 0
                initialCacheCount = 0
                noItemsFoundCount = 0
                
            end
        end
    end
end

-- Main function to start opening caches
local function OpenManastormCaches(isAutoOpen, isRestart)
    if isOpening then
        if not isAutoOpen and not isRestart then
            Print("Restarting cache opening process...")
            -- Stop the current process
            isOpening = false
            isProcessingQueue = false  -- Clear this flag too
            openQueue = {}
            currentlyOpening = 0
            totalCaches = 0
            
            -- Update main UI if it exists
            if mainFrame then
                mainFrame.UpdateStatus()
            end
            
            -- Small delay before restarting
            local timer = CreateFrame("Frame")
            local elapsed = 0
            timer:SetScript("OnUpdate", function(self, elapsedTime)
                elapsed = elapsed + elapsedTime
                if elapsed >= 0.2 then
                    timer:SetScript("OnUpdate", nil)
                    OpenManastormCaches(false, true)  -- Restart with flags
                end
            end)
            return
        elseif not isAutoOpen and not isRestart then
            return
        end
    end
    
    if InCombatLockdown() then
        if not isAutoOpen then
            Print("I cannot focus my magical energies while in combat! Wait until the fighting is over!")
        end
        return
    end
    
    local caches, totalCount = FindManastormCaches(true, false)
    
    if table.getn(caches) == 0 then
        if not isAutoOpen then
            Print("I sense no Manastorm Caches in your pitiful bags, mortal.")
        end
        return
    end
    
    -- Build the opening queue
    openQueue = {}
    totalCaches = 0
    
    for i, cache in ipairs(caches) do
        -- Add one entry per cache (caches don't stack) with retry counter
        table.insert(openQueue, {bag = cache.bag, slot = cache.slot, retries = 0})
        totalCaches = totalCaches + cache.count
    end
    
    -- Track how many we're starting with
    initialCacheCount = totalCaches
    
    -- Adventure Mode: Clean up extra hearthstones before opening caches
    CleanupExtraHearthstones()
    
    -- Determine message based on what types of caches we're opening
    local cacheTypes = {}
    local manastormCount = 0
    local adventurerCount = 0
    
    for _, cache in ipairs(caches) do
        if cache.type == "manastorm" then
            manastormCount = manastormCount + cache.count
        elseif cache.type == "adventurer" then
            adventurerCount = adventurerCount + cache.count
        end
    end
    
    -- Only show verbose messages if not auto-opening or if verbose logging is enabled
    if not isAutoOpen or ManastormManagerDB.verbose then
        print(" ")  -- Blank line before
        if ManastormManagerDB.adventureMode and adventurerCount > 0 then
            if manastormCount > 0 then
                Print("Adventure Mode engaged! Stand back in awe as Millhouse Manastorm opens " .. 
                      manastormCount .. " Manastorm Cache" .. (manastormCount > 1 and "s" or "") .. 
                      " and " .. adventurerCount .. " Adventurer's Cache" .. (adventurerCount > 1 and "s" or "") .. "!")
            else
                Print("Adventure Mode engaged! Stand back in awe as Millhouse Manastorm opens " .. 
                      adventurerCount .. " Adventurer's Cache" .. (adventurerCount > 1 and "s" or "") .. "!")
            end
        else
            Print("Stand back in awe as Millhouse Manastorm opens " .. totalCaches .. " Manastorm Cache" .. (totalCaches > 1 and "s" or "") .. " that are being magically unsealed!")
        end
        print(" ")  -- Blank line after
    end
    
    isOpening = true
    currentlyOpening = 0
    
    -- Update button status to show we're starting
    UpdateButtonStatus()
    
    ProcessQueue(isAutoOpen)
    
    -- Update main UI if it exists
    if mainFrame then
        mainFrame.UpdateStatus()
    end
end

-- Stop opening caches
local function StopOpening()
    if isOpening then
        Print("Fine! I shall cease my magnificent work. I opened " .. currentlyOpening .. " out of " .. totalCaches .. " caches before you interrupted my genius!")
        isOpening = false
        isProcessingQueue = false
        openQueue = {}
        currentlyOpening = 0
        totalCaches = 0
        initialCacheCount = 0
        noItemsFoundCount = 0
        
        -- Update button status back to normal
        UpdateButtonStatus()
        
        -- Update main UI if it exists
        if mainFrame then
            mainFrame.UpdateStatus()
        end
    else
        Print("I am not currently demonstrating my cache-opening prowess, mortal.")
    end
end

-- Millhouse quotes for auto-opening (orange text)
local millhouseQuotes = {
    "What's in the Box?",
    "This place is crazy! I could spend years here investigating all this technology!",
    "You know, I found my Staff of Dominance in one of these bad mamma-jammas!",
    "You know... I'm currently looking for a benevolent benefactor to fund my research. Are you interested?",
    "BREAKTHROUGH! I've discovered the ultimate weapon of mass destruction: an organic, bipedal, and extremely adorable killing machine: duck!... Oh, and these worthless trinkets.",
    "Hey! Prison taught me one very important lesson, well, two if you count how to hold your soap, but yes! SURVIVAL! We can't scour for Legendary Artifacts of Power like these if you don't take this seriously.",
    "Now that is a fancy weapon? You should let me borrow it sometime!",
    "...Of course, if I had a fancy weapon like yours I'd be running this place! And much more competently, I might add.",
    "Heh, Spoils of war? I've killed cockroaches bigger than that!",
    "Dibbs on any artifacts that can help me in my research! Wait... Do you not know what a duck is?",
    "Let me open this right here... And of course I'll need some mana... Actually, do you think you can take this one without me? I need to conjure some water.",
    "These aritfacts are much too lowly for Millhouse the Magnificent! ...You take them."
}

-- Get random Millhouse quote
local function GetRandomMillhouseQuote()
    local randomIndex = math.random(1, table.getn(millhouseQuotes))
    return millhouseQuotes[randomIndex]
end

-- Count caches in bags
local function CountCaches()
    local caches, totalCount = FindManastormCaches()
    local count = totalCount or 0
    
    if count > 0 then
        Print("My keen magical senses detect " .. count .. " Manastorm Cache" .. (count > 1 and "s" or "") .. " awaiting my attention!")
    else
        Print("Your bags contain no Manastorm Caches worthy of my incredible power.")
    end
end

-- Find all equipment items under epic rarity in bags
local function FindVendorItems()
    local items = {}
    
    -- Function to determine if we should sell this quality
    local function ShouldSellQuality(quality)
        if quality == 0 then return ManastormManagerDB.sellTrash ~= false end     -- Gray (default true)
        if quality == 1 then return ManastormManagerDB.sellCommon ~= false end   -- White (default true)
        if quality == 2 then return ManastormManagerDB.sellUncommon ~= false end -- Green (default true)
        if quality == 3 then return ManastormManagerDB.sellRare ~= false end     -- Blue (default true)
        if quality == 4 then return ManastormManagerDB.sellEpic == true end      -- Purple (default false)
        return false  -- Don't sell legendary or higher
    end
    
    -- Scan all bags (0-4: backpack + 4 bags)
    for bag = 0, 4 do
        local numSlots = GetContainerNumSlots(bag)
        if numSlots then
            for slot = 1, numSlots do
                local texture, itemCount, locked, quality, readable = GetContainerItemInfo(bag, slot)
                if texture and not locked then
                    local itemLink = GetContainerItemLink(bag, slot)
                    if itemLink then
                        local itemName, _, itemQuality, itemLevel, itemMinLevel, itemType, itemSubType, itemStackCount, itemEquipLoc, _, vendorPrice = GetItemInfo(itemLink)
                        
                        -- Use itemQuality from GetItemInfo, not quality from GetContainerItemInfo
                        quality = itemQuality
                        
                        -- Debug: Show ALL items that contain "pattern" in the name, regardless of quality
                        if ManastormManagerDB.verbose and itemName and string.find(string.lower(itemName), "pattern") then
                            DebugPrint("FOUND PATTERN ITEM: '" .. itemName .. "' (type: " .. (itemType or "nil") .. ", subType: " .. (itemSubType or "nil") .. ", equipLoc: '" .. (itemEquipLoc or "") .. "', quality: " .. (quality or "nil") .. ", vendorPrice: " .. (vendorPrice or "nil") .. ", shouldSellQuality: " .. tostring(ShouldSellQuality(quality)) .. ")")
                        end
                        
                        -- Check if item is protected (don't sell)
                        local isProtected = false
                        if ManastormManagerDB.protectedItems then
                            for _, protectedName in ipairs(ManastormManagerDB.protectedItems) do
                                if itemName and MatchesPattern(itemName, protectedName) then
                                    isProtected = true
                                    break
                                end
                            end
                        end
                        
                        -- Check if item is in auto-sell list
                        local isAutoSell = false
                        if ManastormManagerDB.autoSellItems then
                            for _, autoSellName in ipairs(ManastormManagerDB.autoSellItems) do
                                if itemName and MatchesPattern(itemName, autoSellName) then
                                    isAutoSell = true
                                    DebugPrint("Item '" .. itemName .. "' matched auto-sell pattern '" .. autoSellName .. "'")
                                    break
                                end
                            end
                            -- Debug: if item didn't match and it contains "pattern", show what patterns were checked
                            if not isAutoSell and ManastormManagerDB.verbose and itemName and string.find(string.lower(itemName), "pattern") then
                                DebugPrint("Pattern item '" .. itemName .. "' checking against auto-sell patterns:")
                                for _, autoSellName in ipairs(ManastormManagerDB.autoSellItems) do
                                    DebugPrint("  Testing pattern '" .. autoSellName .. "'...")
                                end
                            end
                        end
                        
                        -- Determine if this item should be sold
                        local shouldSell = false
                        local reason = ""
                        
                        -- Debug logging for gray items
                        if quality == 0 and ManastormManagerDB.verbose then
                            DebugPrint("Gray item found: " .. (itemName or "Unknown") .. 
                                      " | vendorPrice=" .. tostring(vendorPrice) .. 
                                      " | isProtected=" .. tostring(isProtected) .. 
                                      " | sellTrash=" .. tostring(ManastormManagerDB.sellTrash) ..
                                      " | itemType=" .. tostring(itemType) ..
                                      " | itemEquipLoc=" .. tostring(itemEquipLoc))
                        end
                        
                        if isAutoSell and vendorPrice and vendorPrice > 0 and not isProtected then
                            shouldSell = true
                            reason = "auto-sell item"
                        elseif quality and ShouldSellQuality(quality) and vendorPrice and vendorPrice > 0 and not isProtected then
                            -- For gray items (quality 0), sell ALL items, not just equipment
                            if quality == 0 then
                                shouldSell = true
                                reason = "gray (trash) item"
                            -- For other qualities, only sell equipment
                            elseif itemEquipLoc and itemEquipLoc ~= "" then
                                shouldSell = true
                                reason = "equipment item of sellable quality"
                            end
                        end
                        
                        if shouldSell then
                            table.insert(items, {
                                bag = bag, 
                                slot = slot, 
                                count = itemCount or 1, 
                                name = itemName or "Unknown Item",
                                quality = quality,
                                itemType = itemType or "Unknown",
                                vendorPrice = vendorPrice
                            })
                            DebugPrint("ADDING TO SELL LIST: " .. (itemName or "Unknown") .. " (quality " .. (quality or "nil") .. ", sells for " .. (vendorPrice or "0") .. ") - reason: " .. reason)
                        else
                            -- Debug why pattern items aren't being sold
                            if ManastormManagerDB.verbose and itemName and string.find(string.lower(itemName), "pattern") then
                                local reasons = {}
                                if not vendorPrice or vendorPrice == 0 then
                                    table.insert(reasons, "no vendor price")
                                end
                                if isProtected then
                                    table.insert(reasons, "protected")
                                end
                                if not isAutoSell and not (quality and ShouldSellQuality(quality) and itemEquipLoc and itemEquipLoc ~= "") then
                                    table.insert(reasons, "not auto-sell and not sellable equipment")
                                end
                                DebugPrint("NOT SELLING pattern item '" .. itemName .. "' - reasons: " .. table.concat(reasons, ", "))
                            end
                        end
                    end
                end
            end
        end
    end
    
    return items
end

-- Base64 encoding table for string compression
local base64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

-- Simple string encoding for import/export
local function EncodeItemList(itemList, listType)
    if not itemList or table.getn(itemList) == 0 then
        return ""
    end
    
    -- Create data string: type|item1;item2;item3
    local dataStr = listType .. "|"
    for i, item in ipairs(itemList) do
        if i > 1 then
            dataStr = dataStr .. ";"
        end
        dataStr = dataStr .. item
    end
    
    -- Simple base64-like encoding
    local result = ""
    for i = 1, string.len(dataStr) do
        local byte = string.byte(dataStr, i)
        result = result .. string.format("%02x", byte)
    end
    
    return "MS:" .. result
end

-- Decode import string
local function DecodeItemList(importStr)
    if not importStr or importStr == "" then
        return nil, nil, "Empty import string"
    end
    
    -- Check for MS prefix
    if not string.find(importStr, "^MS:") then
        return nil, nil, "Invalid import string format. Must start with 'MS:'"
    end
    
    -- Remove prefix
    local hexStr = string.sub(importStr, 4)
    
    -- Decode hex back to string
    local dataStr = ""
    for i = 1, string.len(hexStr), 2 do
        local hexByte = string.sub(hexStr, i, i + 1)
        local byte = tonumber(hexByte, 16)
        if byte then
            dataStr = dataStr .. string.char(byte)
        else
            return nil, nil, "Invalid hex encoding in import string"
        end
    end
    
    -- Parse data string: type|item1;item2;item3
    local pipePos = string.find(dataStr, "|")
    if not pipePos then
        return nil, nil, "Invalid data format - missing type separator"
    end
    
    local listType = string.sub(dataStr, 1, pipePos - 1)
    local itemsStr = string.sub(dataStr, pipePos + 1)
    
    -- Split items by semicolon
    local items = {}
    if itemsStr and itemsStr ~= "" then
        for item in string.gmatch(itemsStr, "[^;]+") do
            table.insert(items, item)
        end
    end
    
    return items, listType, nil
end

-- Forward declaration for ImportItemList
local ImportItemList

-- Import items from string
ImportItemList = function(importStr)
    Print("DEBUG: ImportItemList called with string of length: " .. string.len(importStr or ""))
    local items, listType, error = DecodeItemList(importStr)
    
    if error then
        Print("DEBUG: DecodeItemList returned error: " .. error)
        return false, "Import failed: " .. error
    end
    Print("DEBUG: DecodeItemList successful, listType: " .. (listType or "nil"))
    
    -- Ensure database tables are initialized
    if not ManastormManagerDB.protectedItems then
        ManastormManagerDB.protectedItems = {}
    end
    if not ManastormManagerDB.autoSellItems then
        ManastormManagerDB.autoSellItems = {}
    end
    
    if listType == "PROTECTED" then
        -- Import protected items
        local newItems = 0
        for i, item in ipairs(items) do
            -- Check if already exists
            local exists = false
            for j, existingItem in ipairs(ManastormManagerDB.protectedItems) do
                if string.lower(existingItem) == string.lower(item) then
                    exists = true
                    break
                end
            end
            
            if not exists then
                table.insert(ManastormManagerDB.protectedItems, item)
                newItems = newItems + 1
            end
        end
        
        local message = "Imported " .. newItems .. " new protected items (" .. table.getn(items) .. " total in import string)."
        if newItems > 0 then
            message = message .. " Use /ms listprotected to see all protected items."
        end
        return true, message
        
    elseif listType == "AUTOSELL" then
        -- Import auto-sell items
        local newItems = 0
        for i, item in ipairs(items) do
            -- Check if already exists
            local exists = false
            for j, existingItem in ipairs(ManastormManagerDB.autoSellItems) do
                if string.lower(existingItem) == string.lower(item) then
                    exists = true
                    break
                end
            end
            
            if not exists then
                table.insert(ManastormManagerDB.autoSellItems, item)
                newItems = newItems + 1
            end
        end
        
        local message = "Imported " .. newItems .. " new auto-sell items (" .. table.getn(items) .. " total in import string)."
        if newItems > 0 then
            message = message .. " Use /ms listautosell to see all auto-sell items."
        end
        return true, message
        
    else
        return false, "Unknown import type: " .. (listType or "nil")
    end
end

-- Global reference to prevent multiple windows
local importExportFrame = nil

-- Create ElvUI-style button
local function CreateElvUIButton(parent, text, hasLightBorder)
    local button = CreateFrame("Button", nil, parent)
    button:SetNormalFontObject("GameFontNormal")
    button:SetHighlightFontObject("GameFontHighlight")
    
    -- Create backdrop
    if hasLightBorder then
        -- Light gray border for Options button
        button:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Buttons\\WHITE8X8",
            tile = false, tileSize = 0, edgeSize = 1,
            insets = { left = 0, right = 0, top = 0, bottom = 0 }
        })
        button:SetBackdropColor(0.1, 0.1, 0.1, 0.8)
        button:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)  -- Light gray border
    else
        -- No border for main buttons
        button:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8X8",
            tile = false, tileSize = 0,
            insets = { left = 0, right = 0, top = 0, bottom = 0 }
        })
        button:SetBackdropColor(0.1, 0.1, 0.1, 0.8)
    end
    
    -- Set text
    button:SetText(text)
    local fontString = button:GetFontString()
    fontString:SetTextColor(1, 1, 1, 1)
    fontString:SetPoint("CENTER", 0, 0)
    
    -- Hover effect
    button:SetScript("OnEnter", function(self)
        self:SetBackdropColor(0, 0.7, 0.9, 0.3)  -- Cyan glow
        if hasLightBorder then
            self:SetBackdropBorderColor(0, 0.7, 0.9, 1)  -- Cyan border on hover
        end
        fontString:SetTextColor(0, 0.9, 1, 1)  -- Cyan text
    end)
    
    button:SetScript("OnLeave", function(self)
        self:SetBackdropColor(0.1, 0.1, 0.1, 0.8)
        if hasLightBorder then
            self:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)  -- Back to light gray border
        end
        fontString:SetTextColor(1, 1, 1, 1)
    end)
    
    -- Click effect
    button:SetScript("OnMouseDown", function(self)
        fontString:SetPoint("CENTER", 1, -1)
    end)
    
    button:SetScript("OnMouseUp", function(self)
        fontString:SetPoint("CENTER", 0, 0)
    end)
    
    return button
end

-- Create Import/Export popup window
local function ShowImportExportWindow(title, text, isImport, listType)
    -- Close existing window if open
    if importExportFrame then
        importExportFrame:Hide()
        importExportFrame = nil
    end
    
    local currentTheme = ManastormManagerDB.dockTheme or "blizzard"
    
    -- Create frame
    local frame = CreateFrame("Frame", "ManastormImportExportFrame", UIParent)
    importExportFrame = frame  -- Store global reference
    frame:SetSize(400, 400)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("DIALOG")
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    
    -- Apply theme
    if currentTheme == "elvui" then
        frame:SetBackdrop({
            bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
            edgeFile = "Interface\\Buttons\\WHITE8X8",
            tile = true, tileSize = 16, edgeSize = 2,
            insets = {left = 2, right = 2, top = 2, bottom = 2}
        })
        frame:SetBackdropColor(0.05, 0.05, 0.05, 0.9)
        frame:SetBackdropBorderColor(0, 0, 0, 1)
    else
        frame:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 32,
            insets = {left = 11, right = 12, top = 12, bottom = 11}
        })
    end
    
    -- Title
    local titleText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    titleText:SetPoint("TOP", 0, -15)
    titleText:SetText(title)
    if currentTheme == "elvui" then
        titleText:SetTextColor(1, 1, 1, 1)
    end
    
    -- Close X button in corner
    local closeXButton = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    closeXButton:SetPoint("TOPRIGHT", -5, -5)
    closeXButton:SetScript("OnClick", function()
        frame:Hide()
    end)
    
    -- Text input area (fixed size, not scrollable for import)
    local editBox
    if isImport then
        -- For import: create a scrollable text input area
        local scrollFrame = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
        scrollFrame:SetSize(360, 250)
        scrollFrame:SetPoint("TOP", 0, -50)
        
        editBox = CreateFrame("EditBox", nil, scrollFrame)
        editBox:SetMultiLine(true)
        editBox:SetAutoFocus(false)  -- Don't auto-focus to avoid issues
        editBox:SetFontObject(ChatFontNormal)
        editBox:SetWidth(340)
        editBox:SetText(text or "")
        editBox:EnableMouse(true)
        editBox:SetMaxLetters(0)  -- No character limit
        scrollFrame:SetScrollChild(editBox)
        
        -- Set minimum height for the editBox
        editBox:SetHeight(250)
        
        -- Enable paste functionality
        editBox:SetScript("OnEscapePressed", function(self)
            self:ClearFocus()
        end)
        
        -- Click to focus
        editBox:SetScript("OnMouseDown", function(self)
            self:SetFocus()
        end)
        
        -- Apply theme-appropriate backdrop to the scroll frame
        if currentTheme == "elvui" then
            scrollFrame:SetBackdrop({
                bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
                edgeFile = "Interface\\Buttons\\WHITE8X8",
                tile = true, tileSize = 16, edgeSize = 1,
                insets = {left = 3, right = 3, top = 3, bottom = 3}
            })
            scrollFrame:SetBackdropColor(0.1, 0.1, 0.1, 0.9)
            scrollFrame:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
        else
            scrollFrame:SetBackdrop({
                bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
                edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                tile = true, tileSize = 16, edgeSize = 12,
                insets = {left = 3, right = 3, top = 3, bottom = 3}
            })
        end
    else
        -- For export: scrollable text area
        local scrollFrame = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
        scrollFrame:SetPoint("TOPLEFT", 20, -45)
        scrollFrame:SetPoint("BOTTOMRIGHT", -40, 80)
        
        editBox = CreateFrame("EditBox", nil, scrollFrame)
        editBox:SetMultiLine(true)
        editBox:SetAutoFocus(true)
        editBox:SetFontObject(ChatFontNormal)
        editBox:SetWidth(scrollFrame:GetWidth())
        editBox:SetText(text or "")
        scrollFrame:SetScrollChild(editBox)
        
        -- Auto-size the editBox height (only for export mode)
        editBox:SetScript("OnTextChanged", function(self)
            local text = self:GetText()
            local lines = 1
            for i = 1, string.len(text) do
                if string.sub(text, i, i) == "\n" then
                    lines = lines + 1
                end
            end
            self:SetHeight(math.max(lines * 14, scrollFrame:GetHeight()))
        end)
    end
    
    if isImport then
        editBox:SetText("Paste your import string here...")
        editBox:SetScript("OnEditFocusGained", function(self)
            if self:GetText() == "Paste your import string here..." then
                self:SetText("")
            end
        end)
        editBox:SetScript("OnEditFocusLost", function(self)
            if self:GetText() == "" then
                self:SetText("Paste your import string here...")
            end
        end)
    else
        -- For export, select all text
        editBox:SetScript("OnShow", function(self)
            self:HighlightText()
        end)
    end
    
    -- Buttons
    if isImport then
        -- Paste helper text
        local pasteHelp = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        pasteHelp:SetPoint("TOP", scrollFrame, "BOTTOM", 0, -5)
        pasteHelp:SetText("Click in the text box above, then press Ctrl+V to paste")
        if currentTheme == "elvui" then
            pasteHelp:SetTextColor(0.7, 0.7, 0.7, 1)
        else
            pasteHelp:SetTextColor(0.6, 0.6, 0.6, 1)
        end
        
        -- Import button
        local importButton
        if currentTheme == "elvui" then
            importButton = CreateElvUIButton(frame, "Import", false)
            importButton:SetFrameLevel(frame:GetFrameLevel() + 2)
            Print("DEBUG: Created ElvUI Import button at frame level " .. importButton:GetFrameLevel())
        else
            importButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
            importButton:SetText("Import")
            importButton:SetFrameLevel(frame:GetFrameLevel() + 2)
        end
        importButton:SetSize(100, 25)
        importButton:SetPoint("BOTTOM", -55, 30)
        importButton:Show()
        importButton:SetScript("OnClick", function()
            local importString = editBox:GetText()
            Print("DEBUG: Import button clicked. String length: " .. string.len(importString or ""))
            if importString and importString ~= "Paste your import string here..." and importString ~= "" then
                Print("DEBUG: Calling ImportItemList with string starting with: " .. string.sub(importString, 1, 20))
                local success, message = ImportItemList(importString)
                Print(message or "No message returned from ImportItemList")
                if success then
                    frame:Hide()
                    -- Refresh the appropriate list if it's open
                    if listType == "PROTECTED" and protectedItemsFrame and protectedItemsFrame:IsVisible() and protectedItemsFrame.RefreshList then
                        protectedItemsFrame.RefreshList()
                    elseif listType == "AUTOSELL" and autoVendingFrame and autoVendingFrame:IsVisible() and autoVendingFrame.RefreshList then
                        autoVendingFrame.RefreshList()
                    end
                end
            else
                Print("Please paste an import string first!")
            end
        end)
        
        -- Close button for import
        local closeButton
        if currentTheme == "elvui" then
            closeButton = CreateElvUIButton(frame, "Close", false)
            closeButton:SetFrameLevel(frame:GetFrameLevel() + 2)
            Print("DEBUG: Created ElvUI Close button at frame level " .. closeButton:GetFrameLevel())
        else
            closeButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
            closeButton:SetText("Close")
            closeButton:SetFrameLevel(frame:GetFrameLevel() + 2)
        end
        closeButton:SetSize(100, 25)
        closeButton:SetPoint("BOTTOM", 55, 30)
        closeButton:Show()
        closeButton:SetScript("OnClick", function()
            frame:Hide()
        end)
    else
        -- Copy to Clipboard button for export
        local copyButton
        if currentTheme == "elvui" then
            copyButton = CreateElvUIButton(frame, "Copy All", false)
        else
            copyButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
            copyButton:SetText("Copy All")
        end
        copyButton:SetSize(100, 25)
        copyButton:SetPoint("BOTTOM", -55, 15)
        copyButton:SetScript("OnClick", function()
            editBox:SetFocus()
            editBox:HighlightText()
            Print("Export string selected. Press Ctrl+C to copy to clipboard.")
        end)
        
        -- Close button for export
        local closeButton
        if currentTheme == "elvui" then
            closeButton = CreateElvUIButton(frame, "Close", false)
        else
            closeButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
            closeButton:SetText("Close")
        end
        closeButton:SetSize(100, 25)
        closeButton:SetPoint("BOTTOM", 55, 15)
        closeButton:SetScript("OnClick", function()
            frame:Hide()
        end)
    end
    
    frame:Show()
    return frame
end

-- Export protected items
local function ExportProtectedItems()
    local exportStr = EncodeItemList(ManastormManagerDB.protectedItems, "PROTECTED")
    if exportStr == "" then
        Print("No protected items to export.")
        return
    end
    
    ShowImportExportWindow("Export Protected Items", exportStr, false, "PROTECTED")
end

-- Export auto-sell items  
local function ExportAutoSellItems()
    local exportStr = EncodeItemList(ManastormManagerDB.autoSellItems, "AUTOSELL")
    if exportStr == "" then
        Print("No auto-sell items to export.")
        return
    end
    
    ShowImportExportWindow("Export Auto-Sell Items", exportStr, false, "AUTOSELL")
end

-- Format copper into gold, silver, copper display
local function FormatMoney(copper)
    local gold = math.floor(copper / 10000)
    local silver = math.floor((copper - gold * 10000) / 100)
    local copperLeft = copper - gold * 10000 - silver * 100
    
    local str = ""
    if gold > 0 then
        str = str .. "|cffffff00" .. gold .. "g|r "
    end
    if silver > 0 or gold > 0 then
        str = str .. "|cffcccccc" .. silver .. "s|r "
    end
    if copperLeft > 0 or (gold == 0 and silver == 0) then
        str = str .. "|cffcc8866" .. copperLeft .. "c|r"
    end
    
    return str
end

-- Vendor a single item
local function VendorItem(bag, slot, item)
    -- Double-check the item can be sold before attempting
    local itemLink = GetContainerItemLink(bag, slot)
    if itemLink then
        local _, _, _, _, _, _, _, _, _, _, vendorPrice = GetItemInfo(itemLink)
        if not vendorPrice or vendorPrice == 0 then
            DebugPrint("Cannot sell " .. item.name .. " - skipping")
            currentlyVendoring = currentlyVendoring + 1
            totalVendorItems = totalVendorItems - 1
            return
        end
        
        UseContainerItem(bag, slot)
        
        currentlyVendoring = currentlyVendoring + 1
        local remaining = totalVendorItems - currentlyVendoring
        
        totalGoldEarned = totalGoldEarned + vendorPrice
        
        Print("Behold! I have transmuted |cffcccccc" .. item.name .. "|r into " .. FormatMoney(vendorPrice) .. "! (" .. remaining .. " remaining)")
    else
        DebugPrint("Cannot get item info for " .. item.name .. " - skipping")
        currentlyVendoring = currentlyVendoring + 1
        totalVendorItems = totalVendorItems - 1
    end
end

-- Process the vendor queue
local function ProcessVendorQueue()
    if not isVendoring then
        return
    end
    
    if table.getn(vendorQueue) == 0 then
        -- We're done with this batch - just finish quietly
        isVendoring = false
        Print("My magnificent transmutation spree is complete! I have transformed " .. currentlyVendoring .. " worthless items into gold!")
        currentlyVendoring = 0
        totalVendorItems = 0
        -- Don't reset totalGoldEarned here - let MERCHANT_CLOSED handle it
        
        -- Update main UI if it exists
        if mainFrame then
            mainFrame.UpdateStatus()
        end
        return
    end
    
    -- Get next item from queue
    local item = table.remove(vendorQueue, 1)
    if item then
        -- Verify the item is still there and not locked
        local texture, itemCount, locked = GetContainerItemInfo(item.bag, item.slot)
        if texture and not locked and itemCount and itemCount > 0 then
            VendorItem(item.bag, item.slot, item)
        else
            -- Item no longer available, adjust remaining count
            totalVendorItems = totalVendorItems - 1
            DebugPrint("Item at bag " .. item.bag .. " slot " .. item.slot .. " is no longer available")
        end
    end
    
    -- Schedule next vendor action
    if table.getn(vendorQueue) > 0 then
        local timer = CreateFrame("Frame")
        timer:RegisterEvent("ADDON_LOADED")
        local elapsed = 0
        timer:SetScript("OnUpdate", function(self, elapsedTime)
            elapsed = elapsed + elapsedTime
            if elapsed >= ManastormManagerDB.vendorDelay then
                timer:SetScript("OnUpdate", nil)
                ProcessVendorQueue()
            end
        end)
    end
end

-- Main function to vendor equipment
local function VendorEquipment()
    if isVendoring then
        Print("I am already transmuting your pathetic gear into gold! Even my incredible powers need time!")
        return
    end
    
    if InCombatLockdown() then
        Print("I cannot perform delicate transmutation magic while in combat! Wait until the battle ends!")
        return
    end
    
    -- Check if merchant window is open
    if not MerchantFrame or not MerchantFrame:IsVisible() then
        Print("I require a merchant to witness my incredible transmutation abilities! Find one first, mortal!")
        return
    end
    
    -- Initialize session gold if this is the first vendor session
    sessionGoldEarned = sessionGoldEarned or 0
    
    local items = FindVendorItems()
    
    if table.getn(items) == 0 then
        Print("Your bags contain no items worthy of my transmutation magic!")
        return
    end
    
    -- Build the vendor queue and count by type
    vendorQueue = {}
    totalVendorItems = 0
    local grayCount = 0
    local equipCount = 0
    
    for i, item in ipairs(items) do
        table.insert(vendorQueue, item)
        totalVendorItems = totalVendorItems + 1
        if item.quality == 0 then
            grayCount = grayCount + 1
        end
        if item.itemType == "Armor" or item.itemType == "Weapon" then
            equipCount = equipCount + 1
        end
    end
    
    -- Provide more detailed information about what we're selling
    local itemTypeText = ""
    if grayCount > 0 then
        itemTypeText = grayCount .. " gray item" .. (grayCount > 1 and "s" or "")
        if equipCount > grayCount then
            itemTypeText = itemTypeText .. " and " .. (equipCount - grayCount) .. " piece" .. ((equipCount - grayCount) > 1 and "s" or "") .. " of equipment"
        end
    else
        itemTypeText = equipCount .. " piece" .. (equipCount > 1 and "s" or "") .. " of equipment"
    end
    
    Print("Excellent! I have found " .. itemTypeText .. " to transmute into gold through my superior magic!")
    
    isVendoring = true
    currentlyVendoring = 0
    totalGoldEarned = 0
    ProcessVendorQueue()
    
    -- Update main UI if it exists
    if mainFrame then
        mainFrame.UpdateStatus()
    end
end

-- Function to show session total when merchant closes
local function ShowVendorSessionTotal()
    DebugPrint("ShowVendorSessionTotal called, sessionGoldEarned = " .. (sessionGoldEarned or 0))
    if sessionGoldEarned and sessionGoldEarned > 0 then
        Print("Behold my magnificent work! Total transmutation earnings: " .. FormatMoney(sessionGoldEarned))
        print("|cffff8800What use would Millhouse the Magnificent have with gold? ...Now TREASURE on the other hand...|r")
        sessionGoldEarned = 0  -- Reset for next session
    end
end

-- Stop vendoring items
local function StopVendoring()
    if isVendoring then
        Print("Fine! I shall halt my incredible transmutation work! I had already transformed " .. currentlyVendoring .. " out of " .. totalVendorItems .. " items into gold!")
        if totalGoldEarned > 0 then
            Print("My magical prowess had already earned: " .. FormatMoney(totalGoldEarned))
        end
        isVendoring = false
        vendorQueue = {}
        currentlyVendoring = 0
        totalVendorItems = 0
        totalGoldEarned = 0
        
        -- Update main UI if it exists
        if mainFrame then
            mainFrame.UpdateStatus()
        end
    else
        Print("I am not currently demonstrating my superior transmutation abilities, mortal.")
    end
end

-- Count vendorable items
local function CountVendorItems()
    local items = FindVendorItems()
    local count = table.getn(items)
    
    if count > 0 then
        -- Count different types for better feedback
        local grayCount = 0
        local equipCount = 0
        for i, item in ipairs(items) do
            if item.quality == 0 then
                grayCount = grayCount + 1
            end
            if item.itemType == "Armor" or item.itemType == "Weapon" then
                equipCount = equipCount + 1
            end
        end
        
        local itemTypeText = ""
        if grayCount > 0 then
            itemTypeText = grayCount .. " gray item" .. (grayCount > 1 and "s" or "")
            if equipCount > grayCount then
                itemTypeText = itemTypeText .. " and " .. (equipCount - grayCount) .. " piece" .. ((equipCount - grayCount) > 1 and "s" or "") .. " of equipment"
            end
        else
            itemTypeText = equipCount .. " piece" .. (equipCount > 1 and "s" or "") .. " of equipment"
        end
        
        Print("My superior senses detect " .. itemTypeText .. " ready for my transmutation magic!")
    else
        Print("Your bags contain no items worthy of my incredible powers.")
    end
end

-- Create ElvUI-style button

-- Create ElvUI-style lock button with special locked state styling
local function CreateElvUILockButton(parent, text, isLocked)
    local button = CreateFrame("Button", nil, parent)
    button:SetNormalFontObject("GameFontNormal")
    button:SetHighlightFontObject("GameFontHighlight")
    
    -- Create backdrop
    button:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        tile = false, tileSize = 0, edgeSize = 1,
        insets = { left = 0, right = 0, top = 0, bottom = 0 }
    })
    
    -- Set text
    button:SetText(text)
    local fontString = button:GetFontString()
    fontString:SetPoint("CENTER", 0, 0)
    
    -- Function to update button appearance based on lock state
    local function UpdateLockState()
        local locked = ManastormManagerDB.dockLocked
        if locked then
            -- Locked state: white background, black text, light gray border
            button:SetBackdropColor(1, 1, 1, 0.9)  -- White background
            button:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)  -- Light gray border
            fontString:SetTextColor(0, 0, 0, 1)  -- Black text
        else
            -- Unlocked state: dark background, white text, light gray border (same as Options)
            button:SetBackdropColor(0.1, 0.1, 0.1, 0.8)  -- Dark background
            button:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)  -- Light gray border
            fontString:SetTextColor(1, 1, 1, 1)  -- White text
        end
    end
    
    -- Initial state
    UpdateLockState()
    
    -- Hover effect
    button:SetScript("OnEnter", function(self)
        local locked = ManastormManagerDB.dockLocked
        if locked then
            -- When locked, hover gives a subtle cyan tint to white background
            self:SetBackdropColor(0.9, 0.95, 1, 0.9)
            self:SetBackdropBorderColor(0, 0.7, 0.9, 1)
        else
            -- When unlocked, normal cyan hover
            self:SetBackdropColor(0, 0.7, 0.9, 0.3)
            self:SetBackdropBorderColor(0, 0.7, 0.9, 1)
            fontString:SetTextColor(0, 0.9, 1, 1)
        end
    end)
    
    button:SetScript("OnLeave", function(self)
        UpdateLockState()  -- Return to proper state
    end)
    
    -- Click effect
    button:SetScript("OnMouseDown", function(self)
        fontString:SetPoint("CENTER", 1, -1)
    end)
    
    button:SetScript("OnMouseUp", function(self)
        fontString:SetPoint("CENTER", 0, 0)
    end)
    
    -- Store the update function so we can call it externally
    button.UpdateLockState = UpdateLockState
    
    return button
end

-- Function to apply theme to dock
local function ApplyDockTheme(frame)
    local theme = ManastormManagerDB.dockTheme or "blizzard"
    
    if theme == "elvui" then
        -- ElvUI style - Modern, clean, dark, no border
        frame:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8X8",
            tile = false, tileSize = 0,
            insets = { left = 0, right = 0, top = 0, bottom = 0 }
        })
        frame:SetBackdropColor(0.1, 0.1, 0.1, 0.9)
    else
        -- Blizzard default style
        frame:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 32,
            insets = { left = 11, right = 12, top = 12, bottom = 11 }
        })
        frame:SetBackdropColor(1, 1, 1, 1)
        frame:SetBackdropBorderColor(1, 1, 1, 1)
    end
end

-- Function to close both management windows
local function CloseBothManagementWindows()
    if ManastormManagerDB.verbose then
        Print("CloseBothManagementWindows called")
    end
    
    -- Try to get frames by global names if our references are nil
    if not protectedItemsFrame then
        protectedItemsFrame = _G["ManastormManagerProtectedItemsFrame"]
    end
    if not autoVendingFrame then
        autoVendingFrame = _G["ManastormManagerAutoVendingFrame"]
    end
    
    if protectedItemsFrame and protectedItemsFrame:IsVisible() then
        protectedItemsFrame:Hide()
        if ManastormManagerDB.verbose then
            Print("Protected Items window closed")
        end
    end
    if autoVendingFrame and autoVendingFrame:IsVisible() then
        autoVendingFrame:Hide()
        if ManastormManagerDB.verbose then
            Print("Auto-Vending window closed")
        end
    end
end

-- Create options GUI
local function CreateOptionsGUI()
    if optionsFrame then
        return optionsFrame
    end
    
    -- Main frame
    optionsFrame = CreateFrame("Frame", "ManastormManagerOptionsFrame", UIParent)
    optionsFrame:SetSize(400, 480)
    optionsFrame:SetPoint("CENTER")
    
    -- Apply ElvUI-style theming
    local currentTheme = ManastormManagerDB.dockTheme or "blizzard"
    if currentTheme == "elvui" then
        -- ElvUI style - dark background with black border
        optionsFrame:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Buttons\\WHITE8X8",
            tile = false, tileSize = 0, edgeSize = 2,
            insets = { left = 2, right = 2, top = 2, bottom = 2 }
        })
        optionsFrame:SetBackdropColor(0.1, 0.1, 0.1, 0.95)
        optionsFrame:SetBackdropBorderColor(0, 0, 0, 1)
    else
        -- Blizzard default style
        optionsFrame:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 32,
            insets = { left = 11, right = 12, top = 12, bottom = 11 }
        })
    end
    
    optionsFrame:SetMovable(true)
    optionsFrame:EnableMouse(true)
    optionsFrame:RegisterForDrag("LeftButton")
    optionsFrame:SetScript("OnDragStart", optionsFrame.StartMoving)
    optionsFrame:SetScript("OnDragStop", optionsFrame.StopMovingOrSizing)
    -- Close management windows when options frame is hidden
    optionsFrame:SetScript("OnHide", function()
        CloseBothManagementWindows()
    end)
    optionsFrame:Hide()
    
    -- Title
    local title = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -20)
    title:SetText("Manastorm Manager Options")
    if currentTheme == "elvui" then
        title:SetTextColor(0, 0.9, 1, 1)  -- Cyan for ElvUI
    else
        title:SetTextColor(1, 0.82, 0, 1)  -- Gold for Blizzard
    end
    
    -- Close button
    local closeButton = CreateFrame("Button", nil, optionsFrame, "UIPanelCloseButton")
    closeButton:SetPoint("TOPRIGHT", -5, -5)
    
    -- Verbose checkbox
    local verboseCheck = CreateFrame("CheckButton", nil, optionsFrame, "UICheckButtonTemplate")
    verboseCheck:SetPoint("TOPLEFT", 30, -60)
    verboseCheck:SetScript("OnClick", function()
        ManastormManagerDB.verbose = verboseCheck:GetChecked() and true or false
        Print("Verbose mode " .. (ManastormManagerDB.verbose and "enabled" or "disabled") .. ".")
    end)
    local verboseLabel = verboseCheck:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    verboseLabel:SetPoint("LEFT", verboseCheck, "RIGHT", 5, 0)
    verboseLabel:SetText("Verbose logging")
    if currentTheme == "elvui" then
        verboseLabel:SetTextColor(1, 1, 1, 1)  -- White for ElvUI
    end
    
    -- Auto-open checkbox
    local autoOpenCheck = CreateFrame("CheckButton", nil, optionsFrame, "UICheckButtonTemplate")
    autoOpenCheck:SetPoint("TOPLEFT", 30, -90)
    autoOpenCheck:SetScript("OnClick", function()
        ManastormManagerDB.autoOpen = autoOpenCheck:GetChecked() and true or false
        Print("Auto-open " .. (ManastormManagerDB.autoOpen and "enabled" or "disabled") .. ".")
        if ManastormManagerDB.autoOpen then
            -- Reset cache count when enabling auto-open
            local caches, totalCount = FindManastormCaches()
            lastCacheCount = totalCount or 0
        end
    end)
    local autoOpenLabel = autoOpenCheck:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    autoOpenLabel:SetPoint("LEFT", autoOpenCheck, "RIGHT", 5, 0)
    autoOpenLabel:SetText("Auto-open new caches")
    if currentTheme == "elvui" then
        autoOpenLabel:SetTextColor(1, 1, 1, 1)  -- White for ElvUI
    end
    
    -- Adventure Mode checkbox
    local adventureModeCheck = CreateFrame("CheckButton", nil, optionsFrame, "UICheckButtonTemplate")
    adventureModeCheck:SetPoint("TOPLEFT", 30, -120)
    adventureModeCheck:SetScript("OnClick", function()
        ManastormManagerDB.adventureMode = adventureModeCheck:GetChecked() and true or false
        Print("Adventure Mode " .. (ManastormManagerDB.adventureMode and "enabled" or "disabled") .. ".")
        if ManastormManagerDB.adventureMode then
            print("|cffff8800Adventure Mode engaged! Now opening Adventurer's Caches and managing Hearthstones too!|r")
        end
    end)
    local adventureModeLabel = adventureModeCheck:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    adventureModeLabel:SetPoint("LEFT", adventureModeCheck, "RIGHT", 5, 0)
    adventureModeLabel:SetText("Adventure Mode (Adventurer's Caches + Hearthstone cleanup)")
    if currentTheme == "elvui" then
        adventureModeLabel:SetTextColor(1, 1, 1, 1)  -- White for ElvUI
    end
    
    -- Show dock checkbox (moved down)
    local showDockCheck = CreateFrame("CheckButton", nil, optionsFrame, "UICheckButtonTemplate")
    showDockCheck:SetPoint("TOPLEFT", 30, -150)
    showDockCheck:SetScript("OnClick", function()
        ManastormManagerDB.showDock = showDockCheck:GetChecked() and true or false
        Print("Manastorm Dock " .. (ManastormManagerDB.showDock and "enabled" or "disabled") .. ".")
        if ManastormManagerDB.showDock then
            ShowDock()
        else
            HideDock()
        end
    end)
    local showDockLabel = showDockCheck:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    showDockLabel:SetPoint("LEFT", showDockCheck, "RIGHT", 5, 0)
    showDockLabel:SetText("Show Manastorm Dock")
    if currentTheme == "elvui" then
        showDockLabel:SetTextColor(1, 1, 1, 1)  -- White for ElvUI
    end
    
    -- Theme dropdown
    local themeDropdown = CreateFrame("Frame", "ManastormManagerThemeDropdown", optionsFrame, "UIDropDownMenuTemplate")
    themeDropdown:SetPoint("TOPLEFT", 10, -220)
    
    local function InitializeThemeDropdown(self, level)
        local info = UIDropDownMenu_CreateInfo()
        
        info.text = "Blizzard Classic"
        info.value = "blizzard"
        info.func = function()
            ManastormManagerDB.dockTheme = "blizzard"
            UIDropDownMenu_SetText(themeDropdown, "Blizzard Classic")
            if dockFrame then
                ApplyDockTheme(dockFrame)
                -- Recreate dock to apply new positioning
                dockFrame:Hide()
                dockFrame = nil
                ShowDock()
            end
        end
        info.checked = (ManastormManagerDB.dockTheme == "blizzard")
        UIDropDownMenu_AddButton(info, level)
        
        info.text = "ElvUI Style"
        info.value = "elvui"
        info.func = function()
            ManastormManagerDB.dockTheme = "elvui"
            UIDropDownMenu_SetText(themeDropdown, "ElvUI Style")
            if dockFrame then
                ApplyDockTheme(dockFrame)
                -- Recreate dock to apply new positioning
                dockFrame:Hide()
                dockFrame = nil
                ShowDock()
            end
        end
        info.checked = (ManastormManagerDB.dockTheme == "elvui")
        UIDropDownMenu_AddButton(info, level)
    end
    
    UIDropDownMenu_Initialize(themeDropdown, InitializeThemeDropdown)
    UIDropDownMenu_SetWidth(themeDropdown, 150)
    UIDropDownMenu_SetText(themeDropdown, ManastormManagerDB.dockTheme == "elvui" and "ElvUI Style" or "Blizzard Classic")
    
    local themeLabel = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    themeLabel:SetPoint("BOTTOM", themeDropdown, "TOP", 0, 5)
    themeLabel:SetText("Dock Theme")
    if currentTheme == "elvui" then
        themeLabel:SetTextColor(1, 1, 1, 1)  -- White for ElvUI
    end
    
    -- Delay slider
    local delaySlider = CreateFrame("Slider", "ManastormManagerDelaySlider", optionsFrame, "OptionsSliderTemplate")
    delaySlider:SetPoint("TOPLEFT", 30, -280)
    delaySlider:SetSize(200, 20)
    delaySlider:SetMinMaxValues(0.1, 1.0)
    delaySlider:SetValueStep(0.1)
    local delayText = delaySlider:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    delayText:SetPoint("TOP", delaySlider, "BOTTOM", 0, -5)
    delayText:SetText("Cache delay: " .. string.format("%.1f", ManastormManagerDB.delay or 0.5) .. "s")
    if currentTheme == "elvui" then
        delayText:SetTextColor(1, 1, 1, 1)  -- White for ElvUI
    end
    delaySlider:SetScript("OnValueChanged", function(self, value)
        ManastormManagerDB.delay = value
        delayText:SetText("Cache delay: " .. string.format("%.1f", value) .. "s")
    end)
    local delayLabel = delaySlider:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    delayLabel:SetPoint("BOTTOM", delaySlider, "TOP", 0, 5)
    delayLabel:SetText("Cache opening delay")
    if currentTheme == "elvui" then
        delayLabel:SetTextColor(1, 1, 1, 1)  -- White for ElvUI
    end
    
    -- Vendor delay slider
    local vendorDelaySlider = CreateFrame("Slider", "ManastormManagerVendorDelaySlider", optionsFrame, "OptionsSliderTemplate")
    vendorDelaySlider:SetPoint("TOPLEFT", 30, -350)
    vendorDelaySlider:SetSize(200, 20)
    vendorDelaySlider:SetMinMaxValues(0.1, 1.0)
    vendorDelaySlider:SetValueStep(0.1)
    local vendorDelayText = vendorDelaySlider:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    vendorDelayText:SetPoint("TOP", vendorDelaySlider, "BOTTOM", 0, -5)
    vendorDelayText:SetText("Vendor delay: " .. string.format("%.1f", ManastormManagerDB.vendorDelay or 0.2) .. "s")
    if currentTheme == "elvui" then
        vendorDelayText:SetTextColor(1, 1, 1, 1)  -- White for ElvUI
    end
    vendorDelaySlider:SetScript("OnValueChanged", function(self, value)
        ManastormManagerDB.vendorDelay = value
        vendorDelayText:SetText("Vendor delay: " .. string.format("%.1f", value) .. "s")
    end)
    local vendorDelayLabel = vendorDelaySlider:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    vendorDelayLabel:SetPoint("BOTTOM", vendorDelaySlider, "TOP", 0, 5)
    vendorDelayLabel:SetText("Vendor item delay")
    if currentTheme == "elvui" then
        vendorDelayLabel:SetTextColor(1, 1, 1, 1)  -- White for ElvUI
    end
    
    -- Track original theme value
    local originalTheme = nil
    
    -- Save button
    local saveButton
    if currentTheme == "elvui" then
        saveButton = CreateElvUIButton(optionsFrame, "Save", false)  -- No border like main dock buttons
        saveButton:SetSize(100, 25)
        saveButton:SetPoint("BOTTOM", -60, 20)
    else
        saveButton = CreateFrame("Button", nil, optionsFrame, "UIPanelButtonTemplate")
        saveButton:SetSize(100, 25)
        saveButton:SetPoint("BOTTOM", -60, 20)
        saveButton:SetText("Save")
    end
    saveButton:SetScript("OnClick", function()
        -- Check if theme has changed
        if originalTheme and originalTheme ~= ManastormManagerDB.dockTheme then
            -- Create reload dialog
            StaticPopupDialogs["MANASTORM_RELOAD_UI"] = {
                text = "The client must reload to apply theme changes.",
                button1 = "Reload Now",
                button2 = "Cancel",
                OnAccept = function()
                    ReloadUI()
                end,
                OnCancel = function()
                    -- Revert theme change
                    ManastormManagerDB.dockTheme = originalTheme
                    UIDropDownMenu_SetText(themeDropdown, originalTheme == "elvui" and "ElvUI Style" or "Blizzard Classic")
                    Print("Theme change cancelled. Reverting to previous theme.")
                end,
                timeout = 0,
                whileDead = true,
                hideOnEscape = true,
                preferredIndex = 3,
            }
            StaticPopup_Show("MANASTORM_RELOAD_UI")
        else
            -- No theme change, just save normally
            Print("My magnificent settings have been preserved for eternity!")
        end
        optionsFrame:Hide()
    end)
    
    -- Cancel button
    local cancelButton
    if currentTheme == "elvui" then
        cancelButton = CreateElvUIButton(optionsFrame, "Cancel", false)  -- No border like main dock buttons
        cancelButton:SetSize(100, 25)
        cancelButton:SetPoint("BOTTOM", 60, 20)
    else
        cancelButton = CreateFrame("Button", nil, optionsFrame, "UIPanelButtonTemplate")
        cancelButton:SetSize(100, 25)
        cancelButton:SetPoint("BOTTOM", 60, 20)
        cancelButton:SetText("Cancel")
    end
    cancelButton:SetScript("OnClick", function()
        -- Revert theme if changed
        if originalTheme and originalTheme ~= ManastormManagerDB.dockTheme then
            ManastormManagerDB.dockTheme = originalTheme
            -- Update dock if it's visible
            if dockFrame then
                ApplyDockTheme(dockFrame)
                dockFrame:Hide()
                dockFrame = nil
                ShowDock()
            end
        end
        -- Restore original values and close
        optionsFrame.UpdateValues()
        optionsFrame:Hide()
    end)
    
    -- Protected Items button
    local protectedButton
    if currentTheme == "elvui" then
        protectedButton = CreateElvUIButton(optionsFrame, "Protected Items >>", false)
        protectedButton:SetSize(120, 25)
        protectedButton:SetPoint("TOPRIGHT", -20, -60)
    else
        protectedButton = CreateFrame("Button", nil, optionsFrame, "UIPanelButtonTemplate")
        protectedButton:SetSize(120, 25)
        protectedButton:SetPoint("TOPRIGHT", -20, -60)
        protectedButton:SetText("Protected Items >>")
    end
    protectedButton:SetScript("OnClick", function()
        ShowProtectedItemsGUI()
    end)
    
    -- Auto-Vending button
    local autoVendingButton
    if currentTheme == "elvui" then
        autoVendingButton = CreateElvUIButton(optionsFrame, "Auto-Vending >>", false)
        autoVendingButton:SetSize(120, 25)
        autoVendingButton:SetPoint("TOPRIGHT", -20, -95)
    else
        autoVendingButton = CreateFrame("Button", nil, optionsFrame, "UIPanelButtonTemplate")
        autoVendingButton:SetSize(120, 25)
        autoVendingButton:SetPoint("TOPRIGHT", -20, -95)
        autoVendingButton:SetText("Auto-Vending >>")
    end
    autoVendingButton:SetScript("OnClick", function()
        ShowAutoVendingGUI()
    end)
    
    -- Sell All section (bottom right area)
    local sellAllLabel = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    sellAllLabel:SetPoint("TOPRIGHT", -80, -240)
    sellAllLabel:SetText("Sell All:")
    if currentTheme == "elvui" then
        sellAllLabel:SetTextColor(1, 1, 1, 1)  -- White for ElvUI
    else
        sellAllLabel:SetTextColor(1, 0.82, 0, 1)  -- Gold for Blizzard
    end
    
    -- Create rarity checkboxes with appropriate colors
    local raritySettings = {
        {key = "sellTrash", label = "Trash Gear", color = {0.5, 0.5, 0.5}, yOffset = 0},      -- Gray
        {key = "sellCommon", label = "Common Gear", color = {1, 1, 1}, yOffset = -25},        -- White
        {key = "sellUncommon", label = "Uncommon Gear", color = {0.1, 1, 0}, yOffset = -50},   -- Green
        {key = "sellRare", label = "Rare Gear", color = {0, 0.44, 0.87}, yOffset = -75},      -- Blue
        {key = "sellEpic", label = "Epic Gear", color = {0.64, 0.21, 0.93}, yOffset = -100}   -- Purple
    }
    
    for _, rarity in ipairs(raritySettings) do
        local check = CreateFrame("CheckButton", nil, optionsFrame, "UICheckButtonTemplate")
        check:SetPoint("TOPRIGHT", -120, -265 + rarity.yOffset)
        check:SetScript("OnClick", function()
            ManastormManagerDB[rarity.key] = check:GetChecked() and true or false
        end)
        
        local label = check:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        label:SetPoint("LEFT", check, "RIGHT", 5, 0)
        label:SetText(rarity.label)
        label:SetTextColor(rarity.color[1], rarity.color[2], rarity.color[3], 1)
        
        -- Store checkbox reference for UpdateValues
        if not optionsFrame.rarityChecks then
            optionsFrame.rarityChecks = {}
        end
        optionsFrame.rarityChecks[rarity.key] = check
    end
    
    -- Function to update GUI values
    optionsFrame.UpdateValues = function()
        verboseCheck:SetChecked(ManastormManagerDB.verbose == true)
        autoOpenCheck:SetChecked(ManastormManagerDB.autoOpen == true)
        adventureModeCheck:SetChecked(ManastormManagerDB.adventureMode == true)
        showDockCheck:SetChecked(ManastormManagerDB.showDock ~= false)  -- Default true unless explicitly false
        
        -- Update rarity checkboxes
        if optionsFrame.rarityChecks then
            optionsFrame.rarityChecks.sellTrash:SetChecked(ManastormManagerDB.sellTrash ~= false)
            optionsFrame.rarityChecks.sellCommon:SetChecked(ManastormManagerDB.sellCommon ~= false)
            optionsFrame.rarityChecks.sellUncommon:SetChecked(ManastormManagerDB.sellUncommon ~= false)
            optionsFrame.rarityChecks.sellRare:SetChecked(ManastormManagerDB.sellRare ~= false)
            optionsFrame.rarityChecks.sellEpic:SetChecked(ManastormManagerDB.sellEpic == true)
        end
        delaySlider:SetValue(ManastormManagerDB.delay or 0.4)
        vendorDelaySlider:SetValue(ManastormManagerDB.vendorDelay or 0.2)
        delayText:SetText("Cache delay: " .. string.format("%.1f", ManastormManagerDB.delay or 0.4) .. "s")
        vendorDelayText:SetText("Vendor delay: " .. string.format("%.1f", ManastormManagerDB.vendorDelay or 0.2) .. "s")
        UIDropDownMenu_SetText(themeDropdown, ManastormManagerDB.dockTheme == "elvui" and "ElvUI Style" or "Blizzard Classic")
        -- Store original theme when opening
        originalTheme = ManastormManagerDB.dockTheme
    end
    
    return optionsFrame
end

-- Show options GUI
ShowOptionsGUI = function()
    local frame = CreateOptionsGUI()
    frame.UpdateValues()
    frame:Show()
end

-- Protected Items management frame
local protectedItemsFrame = nil

-- Create Protected Items GUI
local function CreateProtectedItemsGUI()
    if protectedItemsFrame then
        -- Make sure RefreshList is still attached (safety check)
        if not protectedItemsFrame.RefreshList then
            -- Reattach RefreshList if it's missing
            local function RefreshList()
                -- Clear existing items
                local children = {protectedItemsFrame.listFrame:GetChildren()}
                for i, child in ipairs(children) do
                    child:Hide()
                    child:SetParent(nil)
                end
                
                -- Add current protected items
                local yOffset = 0
                for i, itemName in ipairs(ManastormManagerDB.protectedItems) do
                    local itemFrame = CreateFrame("Frame", nil, protectedItemsFrame.listFrame)
                    itemFrame:SetSize(270, 25)
                    itemFrame:SetPoint("TOPLEFT", 5, yOffset)
                    
                    -- Item name text
                    local nameText = itemFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                    nameText:SetPoint("LEFT", 5, 0)
                    nameText:SetText(itemName)
                    nameText:SetJustifyH("LEFT")
                    
                    yOffset = yOffset - 30
                end
            end
            protectedItemsFrame.RefreshList = RefreshList
        end
        return protectedItemsFrame
    end
    
    -- Main frame
    protectedItemsFrame = CreateFrame("Frame", "ManastormManagerProtectedItemsFrame", UIParent)
    protectedItemsFrame:SetSize(350, 400)
    protectedItemsFrame:SetPoint("TOPLEFT", optionsFrame, "TOPRIGHT", 5, 0)  -- Positioned to the right of parent options frame
    
    -- Apply theming
    local currentTheme = ManastormManagerDB.dockTheme or "blizzard"
    if currentTheme == "elvui" then
        protectedItemsFrame:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Buttons\\WHITE8X8",
            tile = false, tileSize = 0, edgeSize = 2,
            insets = { left = 2, right = 2, top = 2, bottom = 2 }
        })
        protectedItemsFrame:SetBackdropColor(0.1, 0.1, 0.1, 0.95)
        protectedItemsFrame:SetBackdropBorderColor(0, 0, 0, 1)
    else
        protectedItemsFrame:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 32,
            insets = { left = 11, right = 12, top = 12, bottom = 11 }
        })
    end
    
    protectedItemsFrame:SetMovable(true)
    protectedItemsFrame:EnableMouse(true)
    protectedItemsFrame:RegisterForDrag("LeftButton")
    protectedItemsFrame:SetScript("OnDragStart", protectedItemsFrame.StartMoving)
    protectedItemsFrame:SetScript("OnDragStop", protectedItemsFrame.StopMovingOrSizing)
    protectedItemsFrame:Hide()
    
    -- Title
    local title = protectedItemsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -20)
    title:SetText("Protected Items")
    if currentTheme == "elvui" then
        title:SetTextColor(0, 0.9, 1, 1)  -- Cyan for ElvUI
    else
        title:SetTextColor(1, 0.82, 0, 1)  -- Gold for Blizzard
    end
    
    -- Close button
    local closeButton = CreateFrame("Button", nil, protectedItemsFrame, "UIPanelCloseButton")
    closeButton:SetPoint("TOPRIGHT", -5, -5)
    
    -- Instructions
    local instructions = protectedItemsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    instructions:SetPoint("TOP", 0, -80)
    instructions:SetText("Items in this list will never be sold by the vendor system.\nSupports wildcards: use * for partial matches (e.g., \"Tome of*\")")
    instructions:SetJustifyH("CENTER")
    if currentTheme == "elvui" then
        instructions:SetTextColor(0.8, 0.8, 0.8, 1)  -- Light gray for ElvUI
    end
    
    -- Add item input
    local addLabel = protectedItemsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    addLabel:SetPoint("TOPLEFT", 20, -110)
    addLabel:SetText("Add Item:")
    if currentTheme == "elvui" then
        addLabel:SetTextColor(1, 1, 1, 1)  -- White for ElvUI
    end
    
    local addInput = CreateFrame("EditBox", nil, protectedItemsFrame, "InputBoxTemplate")
    addInput:SetSize(200, 20)
    addInput:SetPoint("LEFT", addLabel, "RIGHT", 10, 0)
    addInput:SetAutoFocus(false)
    
    local addButton
    if currentTheme == "elvui" then
        addButton = CreateElvUIButton(protectedItemsFrame, "Add", false)
        addButton:SetSize(50, 22)
        addButton:SetPoint("LEFT", addInput, "RIGHT", 10, 0)
    else
        addButton = CreateFrame("Button", nil, protectedItemsFrame, "UIPanelButtonTemplate")
        addButton:SetSize(50, 22)
        addButton:SetPoint("LEFT", addInput, "RIGHT", 10, 0)
        addButton:SetText("Add")
    end
    
    -- Import/Export buttons (top-left)
    local exportButton
    if currentTheme == "elvui" then
        exportButton = CreateElvUIButton(protectedItemsFrame, "Export", false)
        exportButton:SetSize(60, 22)
        exportButton:SetPoint("TOPLEFT", 20, -50)
    else
        exportButton = CreateFrame("Button", nil, protectedItemsFrame, "UIPanelButtonTemplate")
        exportButton:SetSize(60, 22)
        exportButton:SetPoint("TOPLEFT", 20, -50)
        exportButton:SetText("Export")
    end
    exportButton:SetScript("OnClick", function()
        ExportProtectedItems()
    end)
    
    local importButton
    if currentTheme == "elvui" then
        importButton = CreateElvUIButton(protectedItemsFrame, "Import", false)
        importButton:SetSize(60, 22)
        importButton:SetPoint("TOPLEFT", 85, -50)
    else
        importButton = CreateFrame("Button", nil, protectedItemsFrame, "UIPanelButtonTemplate")
        importButton:SetSize(60, 22)
        importButton:SetPoint("TOPLEFT", 85, -50)
        importButton:SetText("Import")
    end
    importButton:SetScript("OnClick", function()
        ShowImportExportWindow("Import Protected Items", "", true, "PROTECTED")
    end)
    
    -- Scroll frame for list
    local scrollFrame = CreateFrame("ScrollFrame", nil, protectedItemsFrame, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 20, -145)
    scrollFrame:SetPoint("BOTTOMRIGHT", -40, 60)
    
    local listFrame = CreateFrame("Frame", nil, scrollFrame)
    listFrame:SetSize(280, 1)  -- Height will be dynamic
    scrollFrame:SetScrollChild(listFrame)
    
    -- Store listFrame reference for later access
    if protectedItemsFrame then
        protectedItemsFrame.listFrame = listFrame
    elseif autoVendingFrame then
        autoVendingFrame.listFrame = listFrame
    end
    
    -- Function to refresh the list
    local function RefreshList()
        -- Clear existing items
        local children = {listFrame:GetChildren()}
        for i, child in ipairs(children) do
            child:Hide()
            child:SetParent(nil)
        end
        
        -- Add current protected items
        local yOffset = 0
        for i, itemName in ipairs(ManastormManagerDB.protectedItems) do
            local itemFrame = CreateFrame("Frame", nil, listFrame)
            itemFrame:SetSize(270, 25)
            itemFrame:SetPoint("TOPLEFT", 5, yOffset)
            
            -- Item name text
            local nameText = itemFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            nameText:SetPoint("LEFT", 5, 0)
            nameText:SetText(itemName)
            nameText:SetJustifyH("LEFT")
            if currentTheme == "elvui" then
                nameText:SetTextColor(1, 1, 1, 1)  -- White for ElvUI
            end
            
            -- Remove button
            local removeButton
            if currentTheme == "elvui" then
                removeButton = CreateElvUIButton(itemFrame, "X", true)  -- Light border for remove button
                removeButton:SetSize(20, 20)
                removeButton:SetPoint("RIGHT", -5, 0)
            else
                removeButton = CreateFrame("Button", nil, itemFrame, "UIPanelButtonTemplate")
                removeButton:SetSize(20, 20)
                removeButton:SetPoint("RIGHT", -5, 0)
                removeButton:SetText("X")
            end
            
            removeButton:SetScript("OnClick", function()
                table.remove(ManastormManagerDB.protectedItems, i)
                RefreshList()
            end)
            
            yOffset = yOffset - 30
        end
        
        listFrame:SetHeight(math.max(1, table.getn(ManastormManagerDB.protectedItems) * 30))
    end
    
    -- Add button functionality
    addButton:SetScript("OnClick", function()
        local itemName = addInput:GetText()
        if itemName and itemName ~= "" then
            -- Check if already in list
            local alreadyExists = false
            for i, existing in ipairs(ManastormManagerDB.protectedItems) do
                if string.lower(existing) == string.lower(itemName) then
                    alreadyExists = true
                    break
                end
            end
            
            if not alreadyExists then
                table.insert(ManastormManagerDB.protectedItems, itemName)
                addInput:SetText("")
                RefreshList()
                Print("Added '" .. itemName .. "' to protected items list.")
            else
                Print("'" .. itemName .. "' is already in the protected items list.")
            end
        end
    end)
    
    -- Enter key support for input
    addInput:SetScript("OnEnterPressed", function()
        addButton:GetScript("OnClick")()
    end)
    
    protectedItemsFrame.RefreshList = RefreshList
    return protectedItemsFrame
end

-- Show Protected Items GUI
ShowProtectedItemsGUI = function()
    -- Try to get the frame by its global name if our reference is nil
    if not protectedItemsFrame then
        protectedItemsFrame = _G["ManastormManagerProtectedItemsFrame"]
    end
    
    -- Check if this window is already open
    local wasOpen = protectedItemsFrame and protectedItemsFrame:IsVisible()
    
    -- Debug output
    if ManastormManagerDB.verbose then
        Print("Protected Items button clicked. Was open: " .. tostring(wasOpen))
        Print("protectedItemsFrame exists: " .. tostring(protectedItemsFrame ~= nil))
        if autoVendingFrame then
            Print("Auto-Vending frame exists. Is visible: " .. tostring(autoVendingFrame:IsVisible()))
        end
    end
    
    -- Always close both windows first
    CloseBothManagementWindows()
    
    -- If it wasn't open before, open it now
    if not wasOpen then
        local frame = CreateProtectedItemsGUI()
        protectedItemsFrame = frame  -- Ensure we store the reference
        if frame.RefreshList then
            frame.RefreshList()
        else
            Print("Warning: RefreshList not found on Protected Items frame")
        end
        frame:Show()
        
        if ManastormManagerDB.verbose then
            Print("Protected Items window opened")
        end
    end
end

-- Auto-Vending management frame
local autoVendingFrame = nil

-- Create Auto-Vending GUI
local function CreateAutoVendingGUI()
    if autoVendingFrame then
        return autoVendingFrame
    end
    
    -- Main frame
    autoVendingFrame = CreateFrame("Frame", "ManastormManagerAutoVendingFrame", UIParent)
    autoVendingFrame:SetSize(350, 400)
    autoVendingFrame:SetPoint("TOPLEFT", optionsFrame, "TOPRIGHT", 5, 0)  -- Positioned to the right of parent options frame
    
    -- Apply theming
    local currentTheme = ManastormManagerDB.dockTheme or "blizzard"
    if currentTheme == "elvui" then
        autoVendingFrame:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Buttons\\WHITE8X8",
            tile = false, tileSize = 0, edgeSize = 2,
            insets = { left = 2, right = 2, top = 2, bottom = 2 }
        })
        autoVendingFrame:SetBackdropColor(0.1, 0.1, 0.1, 0.95)
        autoVendingFrame:SetBackdropBorderColor(0, 0, 0, 1)
    else
        autoVendingFrame:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 32,
            insets = { left = 11, right = 12, top = 12, bottom = 11 }
        })
    end
    
    autoVendingFrame:SetMovable(true)
    autoVendingFrame:EnableMouse(true)
    autoVendingFrame:RegisterForDrag("LeftButton")
    autoVendingFrame:SetScript("OnDragStart", autoVendingFrame.StartMoving)
    autoVendingFrame:SetScript("OnDragStop", autoVendingFrame.StopMovingOrSizing)
    autoVendingFrame:Hide()
    
    -- Title
    local title = autoVendingFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -20)
    title:SetText("Auto-Vending Items")
    if currentTheme == "elvui" then
        title:SetTextColor(0, 0.9, 1, 1)  -- Cyan for ElvUI
    else
        title:SetTextColor(1, 0.82, 0, 1)  -- Gold for Blizzard
    end
    
    -- Close button
    local closeButton = CreateFrame("Button", nil, autoVendingFrame, "UIPanelCloseButton")
    closeButton:SetPoint("TOPRIGHT", -5, -5)
    
    -- Instructions
    local instructions = autoVendingFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    instructions:SetPoint("TOP", 0, -80)
    instructions:SetText("Items in this list will be sold regardless of quality.\nSupports wildcards: use * for partial matches (e.g., \"Potion of*\")")
    instructions:SetJustifyH("CENTER")
    if currentTheme == "elvui" then
        instructions:SetTextColor(0.8, 0.8, 0.8, 1)  -- Light gray for ElvUI
    end
    
    -- Add item input
    local addLabel = autoVendingFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    addLabel:SetPoint("TOPLEFT", 20, -110)
    addLabel:SetText("Add Item:")
    if currentTheme == "elvui" then
        addLabel:SetTextColor(1, 1, 1, 1)  -- White for ElvUI
    end
    
    local addInput = CreateFrame("EditBox", nil, autoVendingFrame, "InputBoxTemplate")
    addInput:SetSize(200, 20)
    addInput:SetPoint("LEFT", addLabel, "RIGHT", 10, 0)
    addInput:SetAutoFocus(false)
    
    local addButton
    if currentTheme == "elvui" then
        addButton = CreateElvUIButton(autoVendingFrame, "Add", false)
        addButton:SetSize(50, 22)
        addButton:SetPoint("LEFT", addInput, "RIGHT", 10, 0)
    else
        addButton = CreateFrame("Button", nil, autoVendingFrame, "UIPanelButtonTemplate")
        addButton:SetSize(50, 22)
        addButton:SetPoint("LEFT", addInput, "RIGHT", 10, 0)
        addButton:SetText("Add")
    end
    
    -- Import/Export buttons (top-left)
    local exportButton
    if currentTheme == "elvui" then
        exportButton = CreateElvUIButton(autoVendingFrame, "Export", false)
        exportButton:SetSize(60, 22)
        exportButton:SetPoint("TOPLEFT", 20, -50)
    else
        exportButton = CreateFrame("Button", nil, autoVendingFrame, "UIPanelButtonTemplate")
        exportButton:SetSize(60, 22)
        exportButton:SetPoint("TOPLEFT", 20, -50)
        exportButton:SetText("Export")
    end
    exportButton:SetScript("OnClick", function()
        ExportAutoSellItems()
    end)
    
    local importButton
    if currentTheme == "elvui" then
        importButton = CreateElvUIButton(autoVendingFrame, "Import", false)
        importButton:SetSize(60, 22)
        importButton:SetPoint("TOPLEFT", 85, -50)
    else
        importButton = CreateFrame("Button", nil, autoVendingFrame, "UIPanelButtonTemplate")
        importButton:SetSize(60, 22)
        importButton:SetPoint("TOPLEFT", 85, -50)
        importButton:SetText("Import")
    end
    importButton:SetScript("OnClick", function()
        ShowImportExportWindow("Import Auto-Sell Items", "", true, "AUTOSELL")
    end)
    
    -- Scroll frame for list
    local scrollFrame = CreateFrame("ScrollFrame", nil, autoVendingFrame, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 20, -145)
    scrollFrame:SetPoint("BOTTOMRIGHT", -40, 60)
    
    local listFrame = CreateFrame("Frame", nil, scrollFrame)
    listFrame:SetSize(280, 1)  -- Height will be dynamic
    scrollFrame:SetScrollChild(listFrame)
    
    -- Store listFrame reference for later access
    if protectedItemsFrame then
        protectedItemsFrame.listFrame = listFrame
    elseif autoVendingFrame then
        autoVendingFrame.listFrame = listFrame
    end
    
    -- Function to refresh the list
    local function RefreshList()
        -- Clear existing items
        local children = {listFrame:GetChildren()}
        for i, child in ipairs(children) do
            child:Hide()
            child:SetParent(nil)
        end
        
        -- Add current auto-sell items
        local yOffset = 0
        for i, itemName in ipairs(ManastormManagerDB.autoSellItems) do
            local itemFrame = CreateFrame("Frame", nil, listFrame)
            itemFrame:SetSize(270, 25)
            itemFrame:SetPoint("TOPLEFT", 5, yOffset)
            
            -- Item name text
            local nameText = itemFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            nameText:SetPoint("LEFT", 5, 0)
            nameText:SetText(itemName)
            nameText:SetJustifyH("LEFT")
            if currentTheme == "elvui" then
                nameText:SetTextColor(1, 1, 1, 1)  -- White for ElvUI
            end
            
            -- Remove button
            local removeButton
            if currentTheme == "elvui" then
                removeButton = CreateElvUIButton(itemFrame, "X", true)  -- Light border for remove button
                removeButton:SetSize(20, 20)
                removeButton:SetPoint("RIGHT", -5, 0)
            else
                removeButton = CreateFrame("Button", nil, itemFrame, "UIPanelButtonTemplate")
                removeButton:SetSize(20, 20)
                removeButton:SetPoint("RIGHT", -5, 0)
                removeButton:SetText("X")
            end
            
            removeButton:SetScript("OnClick", function()
                table.remove(ManastormManagerDB.autoSellItems, i)
                RefreshList()
            end)
            
            yOffset = yOffset - 30
        end
        
        listFrame:SetHeight(math.max(1, table.getn(ManastormManagerDB.autoSellItems) * 30))
    end
    
    -- Add button functionality
    addButton:SetScript("OnClick", function()
        local itemName = addInput:GetText()
        if itemName and itemName ~= "" then
            -- Check if already in list
            local alreadyExists = false
            for i, existing in ipairs(ManastormManagerDB.autoSellItems) do
                if string.lower(existing) == string.lower(itemName) then
                    alreadyExists = true
                    break
                end
            end
            
            if not alreadyExists then
                table.insert(ManastormManagerDB.autoSellItems, itemName)
                addInput:SetText("")
                RefreshList()
                Print("Added '" .. itemName .. "' to auto-vending list.")
            else
                Print("'" .. itemName .. "' is already in the auto-vending list.")
            end
        end
    end)
    
    -- Enter key support for input
    addInput:SetScript("OnEnterPressed", function()
        addButton:GetScript("OnClick")()
    end)
    
    autoVendingFrame.RefreshList = RefreshList
    return autoVendingFrame
end

-- Show Auto-Vending GUI
ShowAutoVendingGUI = function()
    -- Try to get the frame by its global name if our reference is nil
    if not autoVendingFrame then
        autoVendingFrame = _G["ManastormManagerAutoVendingFrame"]
    end
    
    -- Check if this window is already open
    local wasOpen = autoVendingFrame and autoVendingFrame:IsVisible()
    
    -- Debug output
    if ManastormManagerDB.verbose then
        Print("Auto-Vending button clicked. Was open: " .. tostring(wasOpen))
        Print("autoVendingFrame exists: " .. tostring(autoVendingFrame ~= nil))
        if protectedItemsFrame then
            Print("Protected Items frame exists. Is visible: " .. tostring(protectedItemsFrame:IsVisible()))
        end
    end
    
    -- Always close both windows first
    CloseBothManagementWindows()
    
    -- If it wasn't open before, open it now
    if not wasOpen then
        local frame = CreateAutoVendingGUI()
        autoVendingFrame = frame  -- Ensure we store the reference
        if frame.RefreshList then
            frame.RefreshList()
        else
            Print("Warning: RefreshList not found on Auto-Vending frame")
        end
        frame:Show()
        
        if ManastormManagerDB.verbose then
            Print("Auto-Vending window opened")
        end
    end
end

-- Create main UI panel
local function CreateMainUI()
    if mainFrame then
        return mainFrame
    end
    
    -- Main frame
    mainFrame = CreateFrame("Frame", "ManastormManagerMainFrame", UIParent)
    mainFrame:SetSize(300, 280)
    mainFrame:SetPoint("CENTER")
    mainFrame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 }
    })
    mainFrame:SetMovable(true)
    mainFrame:EnableMouse(true)
    mainFrame:RegisterForDrag("LeftButton")
    mainFrame:SetScript("OnDragStart", mainFrame.StartMoving)
    mainFrame:SetScript("OnDragStop", mainFrame.StopMovingOrSizing)
    mainFrame:Hide()
    
    -- Title
    local title = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -20)
    title:SetText("Manastorm Manager")
    
    -- Close button
    local closeButton = CreateFrame("Button", nil, mainFrame, "UIPanelCloseButton")
    closeButton:SetPoint("TOPRIGHT", -5, -5)
    
    -- Open Caches button
    local openButton = CreateFrame("Button", nil, mainFrame, "UIPanelButtonTemplate")
    openButton:SetSize(180, 25)
    openButton:SetPoint("TOP", 0, -60)
    openButton:SetText("Open All Caches")
    mainOpenButton = openButton  -- Store reference for status updates
    openButton:SetScript("OnClick", function()
        OpenManastormCaches()
    end)
    
    -- Stop Opening button
    local stopButton = CreateFrame("Button", nil, mainFrame, "UIPanelButtonTemplate")
    stopButton:SetSize(180, 25)
    stopButton:SetPoint("TOP", 0, -90)
    stopButton:SetText("Stop Opening")
    stopButton:SetScript("OnClick", function()
        StopOpening()
    end)
    
    -- Count Caches button
    local countButton = CreateFrame("Button", nil, mainFrame, "UIPanelButtonTemplate")
    countButton:SetSize(180, 25)
    countButton:SetPoint("TOP", 0, -120)
    countButton:SetText("Count Caches")
    countButton:SetScript("OnClick", function()
        CountCaches()
    end)
    
    -- Vendor Equipment button
    local vendorButton = CreateFrame("Button", nil, mainFrame, "UIPanelButtonTemplate")
    vendorButton:SetSize(180, 25)
    vendorButton:SetPoint("TOP", 0, -150)
    vendorButton:SetText("Vendor Equipment")
    vendorButton:SetScript("OnClick", function()
        VendorEquipment()
    end)
    
    -- Count Vendor Items button
    local countVendorButton = CreateFrame("Button", nil, mainFrame, "UIPanelButtonTemplate")
    countVendorButton:SetSize(180, 25)
    countVendorButton:SetPoint("TOP", 0, -180)
    countVendorButton:SetText("Count Vendor Items")
    countVendorButton:SetScript("OnClick", function()
        CountVendorItems()
    end)
    
    -- Options button
    local optionsButton = CreateFrame("Button", nil, mainFrame, "UIPanelButtonTemplate")
    optionsButton:SetSize(180, 25)
    optionsButton:SetPoint("TOP", 0, -210)
    optionsButton:SetText("Options")
    optionsButton:SetScript("OnClick", function()
        ShowOptionsGUI()
    end)
    
    -- Status text
    local statusText = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    statusText:SetPoint("BOTTOM", 0, 20)
    statusText:SetText("Ready")
    
    -- Function to update status
    mainFrame.UpdateStatus = function()
        local status = "Ready"
        if isOpening then
            status = "Opening caches... (" .. currentlyOpening .. "/" .. totalCaches .. ")"
        elseif isVendoring then
            status = "Vendoring items... (" .. currentlyVendoring .. "/" .. totalVendorItems .. ")"
        end
        statusText:SetText(status)
    end
    
    return mainFrame
end

-- Show main UI
ShowMainUI = function()
    local frame = CreateMainUI()
    frame.UpdateStatus()
    frame:Show()
end

-- Create main UI dock
-- Apply theme to dock
-- Function to save dock position
local function SaveDockPosition()
    if dockFrame then
        local point, relativeTo, relativePoint, x, y = dockFrame:GetPoint()
        ManastormManagerDB.dockPoint = point
        ManastormManagerDB.dockRelativePoint = relativePoint
        ManastormManagerDB.dockX = x
        ManastormManagerDB.dockY = y
    end
end

local function CreateMainDock()
    if dockFrame then
        ApplyDockTheme(dockFrame)
        return dockFrame
    end
    
    -- Main dock frame
    dockFrame = CreateFrame("Frame", "ManastormManagerDock", UIParent)
    dockFrame:SetSize(220, 70)  -- Reduced height since we removed a row of buttons
    -- Use saved position or default
    dockFrame:SetPoint(
        ManastormManagerDB.dockPoint or "CENTER",
        UIParent,
        ManastormManagerDB.dockRelativePoint or "CENTER",
        ManastormManagerDB.dockX or 200,
        ManastormManagerDB.dockY or 200
    )
    dockFrame:SetMovable(true)
    dockFrame:EnableMouse(true)
    dockFrame:RegisterForDrag("LeftButton")
    dockFrame:SetScript("OnDragStart", dockFrame.StartMoving)
    dockFrame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SaveDockPosition()  -- Save position when drag stops
    end)
    dockFrame:SetFrameStrata("MEDIUM")
    dockFrame:SetClampedToScreen(true)
    
    -- Apply the selected theme
    ApplyDockTheme(dockFrame)
    
    local theme = ManastormManagerDB.dockTheme or "blizzard"
    
    -- Title
    local title = dockFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    if theme == "elvui" then
        title:SetPoint("TOP", 0, -6)
        title:SetTextColor(0, 0.9, 1, 1)  -- Cyan color for ElvUI theme
    else
        title:SetPoint("TOP", 0, -15)
        title:SetTextColor(1, 0.82, 0, 1)  -- Gold color for Blizzard theme
    end
    title:SetText("Manastorm Manager")
    
    -- Create buttons based on theme
    local openButton, vendorButton
    
    if theme == "elvui" then
        -- ElvUI style buttons (no border)
        openButton = CreateElvUIButton(dockFrame, "Open Caches", false)
        openButton:SetSize(90, 22)
        openButton:SetPoint("TOPLEFT", 12, -28)
        dockOpenButton = openButton  -- Store reference for status updates
        
        vendorButton = CreateElvUIButton(dockFrame, "Sell Equipment", false)
        vendorButton:SetSize(90, 22)
        vendorButton:SetPoint("TOPRIGHT", -12, -28)
    else
        -- Blizzard style buttons
        openButton = CreateFrame("Button", nil, dockFrame, "UIPanelButtonTemplate")
        openButton:SetSize(90, 22)
        openButton:SetPoint("TOPLEFT", 18, -35)
        openButton:SetText("Open Caches")
        dockOpenButton = openButton  -- Store reference for status updates
        
        vendorButton = CreateFrame("Button", nil, dockFrame, "UIPanelButtonTemplate")
        vendorButton:SetSize(90, 22)
        vendorButton:SetPoint("TOPRIGHT", -18, -35)
        vendorButton:SetText("Sell Equipment")
    end
    
    openButton:SetScript("OnClick", function()
        OpenManastormCaches()
    end)
    
    vendorButton:SetScript("OnClick", function()
        VendorEquipment()
    end)
    
    -- Options button - small 'O' in top-right corner
    local optionsButton
    if theme == "elvui" then
        optionsButton = CreateElvUIButton(dockFrame, "O", true)  -- Light gray border
        optionsButton:SetSize(18, 18)
        optionsButton:SetPoint("TOPRIGHT", -4, -4)
    else
        optionsButton = CreateFrame("Button", nil, dockFrame, "UIPanelButtonTemplate")
        optionsButton:SetSize(20, 20)
        optionsButton:SetPoint("TOPRIGHT", -8, -8)
        optionsButton:SetText("O")
    end
    
    optionsButton:SetScript("OnClick", function()
        ShowOptionsGUI()
    end)
    
    -- Add tooltip to options button
    if theme == "elvui" then
        -- For ElvUI button, we need to add to existing OnEnter/OnLeave
        local originalOnEnter = optionsButton:GetScript("OnEnter")
        local originalOnLeave = optionsButton:GetScript("OnLeave")
        
        optionsButton:SetScript("OnEnter", function(self)
            originalOnEnter(self)  -- Trigger hover effect
            GameTooltip:SetOwner(self, "ANCHOR_LEFT")
            GameTooltip:SetText("Options", 1, 1, 1)
            GameTooltip:Show()
        end)
        
        optionsButton:SetScript("OnLeave", function(self)
            originalOnLeave(self)  -- Reset hover effect
            GameTooltip:Hide()
        end)
    else
        optionsButton:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_LEFT")
            GameTooltip:SetText("Options", 1, 1, 1)
            GameTooltip:Show()
        end)
        
        optionsButton:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)
    end
    
    -- NPC scan toggle button - small 'N' on the left side
    local npcButton
    if theme == "elvui" then
        -- Create ElvUI-style NPC button with state styling
        npcButton = CreateFrame("Button", nil, dockFrame)
        npcButton:SetNormalFontObject("GameFontNormal")
        npcButton:SetHighlightFontObject("GameFontHighlight")
        npcButton:SetSize(18, 18)
        npcButton:SetPoint("TOPLEFT", 4, -4)
        
        -- Create backdrop
        npcButton:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Buttons\\WHITE8X8",
            tile = false, tileSize = 0, edgeSize = 1,
            insets = { left = 0, right = 0, top = 0, bottom = 0 }
        })
        
        npcButton:SetText("N")
        local fontString = npcButton:GetFontString()
        fontString:SetPoint("CENTER", 0, 0)
        
        -- Function to update button appearance based on NPC detection state
        local function UpdateNPCDetectionState()
            local enabled = ManastormManagerDB.npcDetection
            if enabled then
                -- Enabled state: white background, black text, light gray border
                npcButton:SetBackdropColor(1, 1, 1, 0.9)  -- White background
                npcButton:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)  -- Light gray border
                fontString:SetTextColor(0, 0, 0, 1)  -- Black text
            else
                -- Disabled state: dark background, white text, light gray border
                npcButton:SetBackdropColor(0.1, 0.1, 0.1, 0.8)  -- Dark background
                npcButton:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)  -- Light gray border
                fontString:SetTextColor(1, 1, 1, 1)  -- White text
            end
        end
        
        -- Store the update function so we can call it externally
        npcButton.UpdateNPCDetectionState = UpdateNPCDetectionState
        
        -- Initial state
        UpdateNPCDetectionState()
        
        -- Hover effect
        npcButton:SetScript("OnEnter", function(self)
            local enabled = ManastormManagerDB.npcDetection
            if enabled then
                -- When enabled, hover gives a subtle cyan tint to white background
                self:SetBackdropColor(0.9, 0.95, 1, 0.9)
            else
                -- When disabled, hover gives a subtle highlight to dark background
                self:SetBackdropColor(0.2, 0.2, 0.2, 0.9)
            end
        end)
        
        npcButton:SetScript("OnLeave", function(self)
            -- Restore original state
            UpdateNPCDetectionState()
        end)
    else
        npcButton = CreateFrame("Button", nil, dockFrame, "UIPanelButtonTemplate")
        npcButton:SetSize(20, 20)
        npcButton:SetPoint("TOPLEFT", 8, -8)
        npcButton:SetText("N")
        
        -- Set initial color based on detection state
        npcButton:SetNormalFontObject("GameFontNormalSmall")
        local fontString = npcButton:GetFontString()
        if fontString then
            if ManastormManagerDB.npcDetection then
                fontString:SetTextColor(0, 1, 0, 1)  -- Green when enabled
            else
                fontString:SetTextColor(1, 0.82, 0, 1)  -- Yellow/gold when disabled
            end
        end
    end
    
    -- Store reference for updating
    dockFrame.npcButton = npcButton
    
    -- NPC button functionality
    npcButton:SetScript("OnClick", function(self)
        ManastormManagerDB.npcDetection = not ManastormManagerDB.npcDetection
        
        local currentTheme = ManastormManagerDB.dockTheme or "blizzard"
        
        if ManastormManagerDB.npcDetection then
            StartNPCDetection()
            Print("NPC Detection |cff00ff00ENABLED|r! My arcane senses are now scanning for rare spawns!")
            
            -- Update button appearance based on theme
            if currentTheme == "elvui" then
                -- Use the new state update function
                if self.UpdateNPCDetectionState then
                    self.UpdateNPCDetectionState()
                end
            else
                -- For Blizzard theme, update text color to green
                self:SetNormalFontObject("GameFontNormalSmall")
                local fontString = self:GetFontString()
                if fontString then
                    fontString:SetTextColor(0, 1, 0, 1)  -- Green
                end
            end
        else
            StopNPCDetection()
            Print("NPC Detection |cffff0000DISABLED|r. My magical surveillance has been suspended.")
            
            -- Update button appearance based on theme
            if currentTheme == "elvui" then
                -- Use the new state update function
                if self.UpdateNPCDetectionState then
                    self.UpdateNPCDetectionState()
                end
            else
                -- For Blizzard theme, update text color to yellow/gold
                self:SetNormalFontObject("GameFontNormalSmall")
                local fontString = self:GetFontString()
                if fontString then
                    fontString:SetTextColor(1, 0.82, 0, 1)  -- Yellow/gold when disabled
                end
            end
        end
    end)
    
    -- Add tooltip to NPC button
    npcButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if ManastormManagerDB.npcDetection then
            GameTooltip:SetText("NPC Detection: ON", 0, 1, 0)
            GameTooltip:AddLine("Click to disable rare spawn detection", 1, 1, 1)
        else
            GameTooltip:SetText("NPC Detection: OFF", 1, 0, 0)
            GameTooltip:AddLine("Click to enable rare spawn detection", 1, 1, 1)
        end
        GameTooltip:AddLine("Scans for: Clepto the Cardnapper & Greedy Demon", 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    
    npcButton:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    
    -- Lock button - small 'L' next to Options button
    local lockButton
    if theme == "elvui" then
        lockButton = CreateElvUILockButton(dockFrame, "L")
        lockButton:SetSize(18, 18)
        lockButton:SetPoint("TOPRIGHT", -26, -4)  -- 22px to the left of Options button
    else
        lockButton = CreateFrame("Button", nil, dockFrame, "UIPanelButtonTemplate")
        lockButton:SetSize(20, 20)
        lockButton:SetPoint("TOPRIGHT", -30, -8)  -- 22px to the left of Options button
        lockButton:SetText("L")
        
        -- Set initial color based on lock state
        lockButton:SetNormalFontObject("GameFontNormalSmall")
        local fontString = lockButton:GetFontString()
        if fontString then
            if ManastormManagerDB.dockLocked then
                fontString:SetTextColor(0, 1, 0, 1)  -- Green when locked
            else
                fontString:SetTextColor(1, 0.82, 0, 1)  -- Yellow/gold when unlocked
            end
        end
    end
    
    -- Lock button functionality
    lockButton:SetScript("OnClick", function(self)
        -- Save current position before toggling lock
        SaveDockPosition()
        
        ManastormManagerDB.dockLocked = not ManastormManagerDB.dockLocked
        
        -- Update dock movability
        if ManastormManagerDB.dockLocked then
            dockFrame:SetMovable(false)
            dockFrame:RegisterForDrag()  -- Clear drag registration
            if ManastormManagerDB.verbose then
                Print("Magnificent! My control dock is now locked in place with my superior magic!")
            end
        else
            dockFrame:SetMovable(true)
            dockFrame:RegisterForDrag("LeftButton")
            if ManastormManagerDB.verbose then
                Print("Very well! My dock may now be repositioned as you see fit, mortal!")
            end
        end
        
        -- Update button appearance based on theme
        local currentTheme = ManastormManagerDB.dockTheme or "blizzard"
        if currentTheme == "elvui" then
            if self.UpdateLockState then
                self.UpdateLockState()
            end
        else
            -- For Blizzard theme, update text color
            self:SetNormalFontObject("GameFontNormalSmall")
            local fontString = self:GetFontString()
            if fontString then
                if ManastormManagerDB.dockLocked then
                    fontString:SetTextColor(0, 1, 0, 1)  -- Green when locked
                else
                    fontString:SetTextColor(1, 0.82, 0, 1)  -- Yellow/gold when unlocked
                end
            end
        end
    end)
    
    -- Add tooltip to lock button
    if theme == "elvui" then
        -- For ElvUI button, we need to add to existing OnEnter/OnLeave
        local originalOnEnter = lockButton:GetScript("OnEnter")
        local originalOnLeave = lockButton:GetScript("OnLeave")
        
        lockButton:SetScript("OnEnter", function(self)
            if originalOnEnter then originalOnEnter(self) end  -- Trigger hover effect
            GameTooltip:SetOwner(self, "ANCHOR_LEFT")
            local tooltipText = ManastormManagerDB.dockLocked and "Unlock Dock" or "Lock Dock"
            GameTooltip:SetText(tooltipText, 1, 1, 1)
            GameTooltip:Show()
        end)
        
        lockButton:SetScript("OnLeave", function(self)
            if originalOnLeave then originalOnLeave(self) end  -- Reset hover effect
            GameTooltip:Hide()
        end)
    else
        lockButton:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_LEFT")
            local tooltipText = ManastormManagerDB.dockLocked and "Unlock Dock" or "Lock Dock"
            GameTooltip:SetText(tooltipText, 1, 1, 1)
            GameTooltip:Show()
        end)
        
        lockButton:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)
    end
    
    -- Auto-Open button - small 'A' in top-left corner
    local autoOpenButton
    if theme == "elvui" then
        -- Create ElvUI-style auto-open button with state styling
        autoOpenButton = CreateFrame("Button", nil, dockFrame)
        autoOpenButton:SetNormalFontObject("GameFontNormal")
        autoOpenButton:SetHighlightFontObject("GameFontHighlight")
        autoOpenButton:SetSize(18, 18)
        autoOpenButton:SetPoint("TOPLEFT", 26, -4)  -- 22px to the right of N button
        
        -- Create backdrop
        autoOpenButton:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Buttons\\WHITE8X8",
            tile = false, tileSize = 0, edgeSize = 1,
            insets = { left = 0, right = 0, top = 0, bottom = 0 }
        })
        
        autoOpenButton:SetText("A")
        local fontString = autoOpenButton:GetFontString()
        fontString:SetPoint("CENTER", 0, 0)
        
        -- Function to update button appearance based on auto-open state
        local function UpdateAutoOpenState()
            local enabled = ManastormManagerDB.autoOpen
            if enabled then
                -- Enabled state: white background, black text, light gray border
                autoOpenButton:SetBackdropColor(1, 1, 1, 0.9)  -- White background
                autoOpenButton:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)  -- Light gray border
                fontString:SetTextColor(0, 0, 0, 1)  -- Black text
            else
                -- Disabled state: dark background, white text, light gray border
                autoOpenButton:SetBackdropColor(0.1, 0.1, 0.1, 0.8)  -- Dark background
                autoOpenButton:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)  -- Light gray border
                fontString:SetTextColor(1, 1, 1, 1)  -- White text
            end
        end
        
        -- Store the update function so we can call it externally
        autoOpenButton.UpdateAutoOpenState = UpdateAutoOpenState
        
        -- Initial state
        UpdateAutoOpenState()
        
        -- Hover effect
        autoOpenButton:SetScript("OnEnter", function(self)
            local enabled = ManastormManagerDB.autoOpen
            if enabled then
                -- When enabled, hover gives a subtle cyan tint to white background
                self:SetBackdropColor(0.9, 0.95, 1, 0.9)
                self:SetBackdropBorderColor(0, 0.7, 0.9, 1)
            else
                -- When disabled, normal cyan hover
                self:SetBackdropColor(0, 0.7, 0.9, 0.3)
                self:SetBackdropBorderColor(0, 0.7, 0.9, 1)
                fontString:SetTextColor(0, 0.9, 1, 1)
            end
        end)
        
        autoOpenButton:SetScript("OnLeave", function(self)
            UpdateAutoOpenState()  -- Return to proper state
        end)
        
        -- Click effect
        autoOpenButton:SetScript("OnMouseDown", function(self)
            fontString:SetPoint("CENTER", 1, -1)
        end)
        
        autoOpenButton:SetScript("OnMouseUp", function(self)
            fontString:SetPoint("CENTER", 0, 0)
        end)
    else
        autoOpenButton = CreateFrame("Button", nil, dockFrame, "UIPanelButtonTemplate")
        autoOpenButton:SetSize(20, 20)
        autoOpenButton:SetPoint("TOPLEFT", 30, -8)  -- 22px to the right of N button
        autoOpenButton:SetText("A")
        
        -- Set initial color based on auto-open state
        autoOpenButton:SetNormalFontObject("GameFontNormalSmall")
        local fontString = autoOpenButton:GetFontString()
        if fontString then
            if ManastormManagerDB.autoOpen then
                fontString:SetTextColor(0, 1, 0, 1)  -- Green when enabled
            else
                fontString:SetTextColor(1, 0.82, 0, 1)  -- Yellow/gold when disabled
            end
        end
    end
    
    -- Auto-Open button functionality
    autoOpenButton:SetScript("OnClick", function(self)
        ManastormManagerDB.autoOpen = not ManastormManagerDB.autoOpen
        
        if ManastormManagerDB.verbose then
            Print("Auto-open " .. (ManastormManagerDB.autoOpen and "enabled" or "disabled") .. ".")
        end
        
        if ManastormManagerDB.autoOpen then
            -- Reset cache count when enabling auto-open
            local caches, totalCount = FindManastormCaches()
            lastCacheCount = totalCount or 0
        end
        
        -- Update button appearance based on theme
        local currentTheme = ManastormManagerDB.dockTheme or "blizzard"
        if currentTheme == "elvui" then
            if self.UpdateAutoOpenState then
                self.UpdateAutoOpenState()
            end
        else
            -- For Blizzard theme, update text color
            self:SetNormalFontObject("GameFontNormalSmall")
            local fontString = self:GetFontString()
            if fontString then
                if ManastormManagerDB.autoOpen then
                    fontString:SetTextColor(0, 1, 0, 1)  -- Green when enabled
                else
                    fontString:SetTextColor(1, 0.82, 0, 1)  -- Yellow/gold when disabled
                end
            end
        end
    end)
    
    -- Add tooltip to auto-open button
    if theme == "elvui" then
        -- For ElvUI button, we need to add to existing OnEnter/OnLeave
        local originalOnEnter = autoOpenButton:GetScript("OnEnter")
        local originalOnLeave = autoOpenButton:GetScript("OnLeave")
        
        autoOpenButton:SetScript("OnEnter", function(self)
            if originalOnEnter then originalOnEnter(self) end  -- Trigger hover effect
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            local tooltipText = ManastormManagerDB.autoOpen and "Disable Auto-Open" or "Enable Auto-Open"
            GameTooltip:SetText(tooltipText, 1, 1, 1)
            GameTooltip:Show()
        end)
        
        autoOpenButton:SetScript("OnLeave", function(self)
            if originalOnLeave then originalOnLeave(self) end  -- Reset hover effect
            GameTooltip:Hide()
        end)
    else
        autoOpenButton:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            local tooltipText = ManastormManagerDB.autoOpen and "Disable Auto-Open" or "Enable Auto-Open"
            GameTooltip:SetText(tooltipText, 1, 1, 1)
            GameTooltip:Show()
        end)
        
        autoOpenButton:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)
    end
    
    -- Set initial dock lock state
    if ManastormManagerDB.dockLocked then
        dockFrame:SetMovable(false)
        dockFrame:RegisterForDrag()  -- Clear drag registration
    end
    
    -- Auto-loot reminder text at bottom
    local autoLootText = dockFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    autoLootText:SetPoint("BOTTOM", 0, 3)
    autoLootText:SetTextColor(1, 1, 1, 0.7)  -- Small white text with slight transparency
    autoLootText:SetText("Auto-Loot must be Enabled!")
    
    return dockFrame
end

-- Show/Hide dock functions
local function ShowDock()
    local dock = CreateMainDock()
    if ManastormManagerDB.showDock then
        dock:Show()
    else
        dock:Hide()
    end
end

local function HideDock()
    if dockFrame then
        dockFrame:Hide()
    end
    ManastormManagerDB.showDock = false
    Print("Very well! My magnificent dock shall remain hidden until you require my services again! Use '/ms show' when you need my power!")
end

local function ToggleDock()
    ManastormManagerDB.showDock = not ManastormManagerDB.showDock
    if ManastormManagerDB.showDock then
        ShowDock()
        Print("Behold! My magnificent control dock has appeared for your convenience!")
    else
        HideDock()
    end
end

-- Check if main bag is open
local function IsBagOpen()
    return ContainerFrame1 and ContainerFrame1:IsVisible()
end

-- REMOVED CheckBagsClosed function - it was incorrectly stopping cache opening when loot windows appeared
-- The function would trigger during normal cache opening because loot windows aren't bag windows

-- Check for new caches and auto-open if enabled
local function CheckAutoOpen()
    if ManastormManagerDB.autoOpen and not isOpening and not InCombatLockdown() then
        -- Check bag space before auto-opening
        local emptySlots = GetEmptyBagSlots()
        if emptySlots <= 1 then
            DebugPrint("Auto-open skipped: Only " .. emptySlots .. " empty bag slots remaining")
            return
        end
        
        local caches, currentCacheCount = FindManastormCaches()
        currentCacheCount = currentCacheCount or 0
        
        -- If we found new caches, auto-open them
        if currentCacheCount > lastCacheCount and currentCacheCount > 0 then
            DebugPrint("Auto-open detected " .. (currentCacheCount - lastCacheCount) .. " new caches")
            -- Display random Millhouse quote in orange text when auto-opening
            print("|cffff8800" .. GetRandomMillhouseQuote() .. "|r")
            OpenManastormCaches(true)
        end
        
        lastCacheCount = currentCacheCount
    end
end

-- Slash command handler
local function SlashCommandHandler(msg)
    local command = string.lower(msg or "")
    
    if command == "" or command == "open" then
        OpenManastormCaches()
    elseif command == "stop" then
        StopOpening()
    elseif command == "count" then
        CountCaches()
    elseif command == "vendor" then
        VendorEquipment()
    elseif command == "stopvendor" then
        StopVendoring()
    elseif command == "countvendor" then
        CountVendorItems()
    elseif command == "debug" then
        ManastormManagerDB.verbose = not ManastormManagerDB.verbose
        Print("Debug mode " .. (ManastormManagerDB.verbose and "enabled" or "disabled"))
    elseif command == "status" then
        if isOpening then
            Print("Currently opening caches: " .. table.getn(openQueue) .. " in queue, " .. currentlyOpening .. " opened so far")
        else
            Print("Not currently opening caches")
        end
    elseif command == "help" then
        Print("Available commands:")
        print("  |cffff9933/ms|r or |cffff9933/ms open|r - Open all Manastorm Caches")
        print("  |cffff9933/ms stop|r - Stop opening caches")
        print("  |cffff9933/ms count|r - Count caches in bags")
        print("  |cffff9933/ms vendor|r - Vendor all items based on quality settings (at vendor)")
        print("  |cffff9933/ms stopvendor|r - Stop vendoring items")
        print("  |cffff9933/ms countvendor|r - Count items that would be vendored")
        print("  |cffff9933/ms debug|r - Toggle debug mode for troubleshooting")
        print("  |cffff9933/ms config|r - Show configuration options")
        print("  |cffff9933/ms gui|r - Show options GUI")
        print("  |cffff9933/ms ui|r - Show main UI panel")
        print("  |cffff9933/ms hide|r - Hide the dock")
        print("  |cffff9933/ms show|r - Show the dock")
        print("  |cffff9933/ms theme|r - Toggle dock theme (Blizzard/ElvUI)")
        print("  |cffff9933/ms theme <blizzard|elvui>|r - Set specific theme")
        print("  |cffff9933/ms help|r - Show this help")
        print("  |cffff9933/ms protect <item>|r - Add item to protected list")
        print("  |cffff9933/ms unprotect <item>|r - Remove item from protected list")
        print("  |cffff9933/ms autosell <item>|r - Add item to auto-sell list")
        print("  |cffff9933/ms unautosell <item>|r - Remove item from auto-sell list")
        print("  |cffff9933/ms listprotected|r - Show protected items")
        print("  |cffff9933/ms listautosell|r - Show auto-sell items")
        print("  |cffff9933/ms exportprotected|r - Export protected items list")
        print("  |cffff9933/ms exportautosell|r - Export auto-sell items list")
        print("  |cffff9933/ms import <string>|r - Import items list from string")
        print("  |cffff9933/ms npc|r - Check NPC detection status")
        print("  |cffff9933/ms npc on|r - Enable NPC detection for rare spawns")
        print("  |cffff9933/ms npc off|r - Disable NPC detection")
        print("  |cffff9933/ms npc test|r - Test the NPC alert system")
        print("  |cffff9933/ms npc clear|r - Clear NPC detection memory")
        print("  |cffff9933/ms toast reset|r - Reset toast notification position")
    elseif command == "config" then
        Print("Configuration:")
        print("  Delay between opens: |cffff9933" .. ManastormManagerDB.delay .. "s|r")
        print("  Vendor delay: |cffff9933" .. ManastormManagerDB.vendorDelay .. "s|r")
        print("  Auto-open new caches: |cffff9933" .. (ManastormManagerDB.autoOpen and "ON" or "OFF") .. "|r")
        print("  Verbose logging: |cffff9933" .. (ManastormManagerDB.verbose and "ON" or "OFF") .. "|r")
        print("  NPC Detection: |cffff9933" .. (ManastormManagerDB.npcDetection and "ON" or "OFF") .. "|r")
        if ManastormManagerDB.npcDetection then
            print("    Scan interval: |cffff9933" .. ManastormManagerDB.npcScanInterval .. "s|r")
            print("    Alert sound: |cffff9933" .. (ManastormManagerDB.npcAlertSound and "ON" or "OFF") .. "|r")
            print("    Flash screen: |cffff9933" .. (ManastormManagerDB.npcFlashScreen and "ON" or "OFF") .. "|r")
            print("    Mark targets: |cffff9933" .. (ManastormManagerDB.npcMarkTarget and "ON" or "OFF") .. "|r")
        end
        print("  Sell gear rarities:")
        print("    Trash (gray): |cffff9933" .. (ManastormManagerDB.sellTrash ~= false and "YES" or "NO") .. "|r")
        print("    Common (white): |cffff9933" .. (ManastormManagerDB.sellCommon ~= false and "YES" or "NO") .. "|r")
        print("    Uncommon (green): |cffff9933" .. (ManastormManagerDB.sellUncommon ~= false and "YES" or "NO") .. "|r")
        print("    Rare (blue): |cffff9933" .. (ManastormManagerDB.sellRare ~= false and "YES" or "NO") .. "|r")
        print("    Epic (purple): |cffff9933" .. (ManastormManagerDB.sellEpic == true and "YES" or "NO") .. "|r")
        print("Use |cffff9933/ms delay X|r to set delay (0.1-1.0 seconds)")
        print("Use |cffff9933/ms verbose|r to toggle verbose mode")
        print("Use |cffff9933/ms autoopen|r to toggle auto-opening new caches")
    elseif string.sub(command, 1, 5) == "delay" then
        local delayStr = string.sub(command, 7)
        local delay = tonumber(delayStr)
        if delay and delay >= 0.1 and delay <= 1.0 then
            ManastormManagerDB.delay = delay
            Print("Delay set to " .. delay .. " seconds.")
        else
            Print("Invalid delay. Use a number between 0.1 and 1.0 seconds.")
        end
    elseif command == "verbose" then
        ManastormManagerDB.verbose = not ManastormManagerDB.verbose
        Print("Verbose mode " .. (ManastormManagerDB.verbose and "enabled" or "disabled") .. ".")
    elseif command == "autoopen" then
        ManastormManagerDB.autoOpen = not ManastormManagerDB.autoOpen
        Print("Auto-open " .. (ManastormManagerDB.autoOpen and "enabled" or "disabled") .. ".")
        if ManastormManagerDB.autoOpen then
            -- Reset cache count when enabling auto-open
            local caches, totalCount = FindManastormCaches()
            lastCacheCount = totalCount or 0
            DebugPrint("Auto-open initialized with " .. lastCacheCount .. " existing caches")
        end
    elseif string.sub(command, 1, 7) == "protect" then
        local itemName = string.sub(command, 9)  -- Skip "protect "
        if itemName and itemName ~= "" then
            -- Check if already protected
            local alreadyProtected = false
            for i, protectedName in ipairs(ManastormManagerDB.protectedItems) do
                if string.lower(protectedName) == string.lower(itemName) then
                    alreadyProtected = true
                    break
                end
            end
            
            if not alreadyProtected then
                table.insert(ManastormManagerDB.protectedItems, itemName)
                Print("Added '" .. itemName .. "' to protected items list.")
            else
                Print("'" .. itemName .. "' is already in protected items list.")
            end
        else
            Print("Usage: /ms protect <item name or pattern>")
        end
    elseif string.sub(command, 1, 9) == "unprotect" then
        local itemName = string.sub(command, 11)  -- Skip "unprotect "
        if itemName and itemName ~= "" then
            local removed = false
            for i = table.getn(ManastormManagerDB.protectedItems), 1, -1 do
                if string.lower(ManastormManagerDB.protectedItems[i]) == string.lower(itemName) then
                    table.remove(ManastormManagerDB.protectedItems, i)
                    removed = true
                end
            end
            
            if removed then
                Print("Removed '" .. itemName .. "' from protected items list.")
            else
                Print("'" .. itemName .. "' was not found in protected items list.")
            end
        else
            Print("Usage: /ms unprotect <item name or pattern>")
        end
    elseif string.sub(command, 1, 8) == "autosell" then
        local itemName = string.sub(command, 10)  -- Skip "autosell "
        if itemName and itemName ~= "" then
            -- Check if already in auto-sell list
            local alreadyInList = false
            for i, autoSellName in ipairs(ManastormManagerDB.autoSellItems) do
                if string.lower(autoSellName) == string.lower(itemName) then
                    alreadyInList = true
                    break
                end
            end
            
            if not alreadyInList then
                table.insert(ManastormManagerDB.autoSellItems, itemName)
                Print("Added '" .. itemName .. "' to auto-sell items list.")
            else
                Print("'" .. itemName .. "' is already in auto-sell items list.")
            end
        else
            Print("Usage: /ms autosell <item name or pattern>")
        end
    elseif string.sub(command, 1, 10) == "unautosell" then
        local itemName = string.sub(command, 12)  -- Skip "unautosell "
        if itemName and itemName ~= "" then
            local removed = false
            for i = table.getn(ManastormManagerDB.autoSellItems), 1, -1 do
                if string.lower(ManastormManagerDB.autoSellItems[i]) == string.lower(itemName) then
                    table.remove(ManastormManagerDB.autoSellItems, i)
                    removed = true
                end
            end
            
            if removed then
                Print("Removed '" .. itemName .. "' from auto-sell items list.")
            else
                Print("'" .. itemName .. "' was not found in auto-sell items list.")
            end
        else
            Print("Usage: /ms unautosell <item name or pattern>")
        end
    elseif command == "listprotected" then
        if table.getn(ManastormManagerDB.protectedItems) > 0 then
            Print("Protected items:")
            for i, itemName in ipairs(ManastormManagerDB.protectedItems) do
                print("  |cffcccccc" .. itemName .. "|r")
            end
        else
            Print("No protected items configured.")
        end
    elseif command == "listautosell" then
        if table.getn(ManastormManagerDB.autoSellItems) > 0 then
            Print("Auto-sell items:")
            for i, itemName in ipairs(ManastormManagerDB.autoSellItems) do
                print("  |cffcccccc" .. itemName .. "|r")
            end
        else
            Print("No auto-sell items configured.")
        end
    elseif command == "exportprotected" then
        ExportProtectedItems()
    elseif command == "exportautosell" then
        ExportAutoSellItems()
    elseif string.sub(command, 1, 6) == "import" then
        local importStr = string.sub(command, 8)  -- Skip "import "
        if importStr and importStr ~= "" then
            local success, message = ImportItemList(importStr)
            Print(message)
        else
            Print("Usage: /ms import <import string>")
            print("Example: /ms import MS:50524f54454354...")
        end
    elseif command == "gui" or command == "options" then
        ShowOptionsGUI()
    elseif command == "ui" then
        ShowMainUI()
    elseif command == "hide" then
        HideDock()
    elseif command == "show" then
        ManastormManagerDB.showDock = true
        ShowDock()
        Print("Excellent choice! My magnificent dock has returned to serve your every need!")
    elseif command == "theme" then
        -- Toggle theme
        if ManastormManagerDB.dockTheme == "elvui" then
            ManastormManagerDB.dockTheme = "blizzard"
            Print("Ah yes, the classic Blizzard theme - timeless as my own magnificence!")
        else
            ManastormManagerDB.dockTheme = "elvui"
            Print("ElvUI theme activated! Modern aesthetics befitting a genius of my caliber!")
        end
        -- Recreate dock with new theme
        if dockFrame then
            dockFrame:Hide()
            dockFrame = nil
            ShowDock()
        end
    elseif string.sub(command, 1, 5) == "theme" and string.len(command) > 6 then
        local themeName = string.sub(command, 7)
        if themeName == "blizzard" or themeName == "classic" then
            ManastormManagerDB.dockTheme = "blizzard"
            Print("Ah yes, the classic Blizzard theme - timeless as my own magnificence!")
            if dockFrame then
                dockFrame:Hide()
                dockFrame = nil
                ShowDock()
            end
        elseif themeName == "elvui" or themeName == "modern" then
            ManastormManagerDB.dockTheme = "elvui"
            Print("ElvUI theme activated! Modern aesthetics befitting a genius of my caliber!")
            if dockFrame then
                dockFrame:Hide()
                dockFrame = nil
                ShowDock()
            end
        else
            Print("Unknown theme! Use 'blizzard' or 'elvui'. Even my incredible intellect has limits!")
        end
    elseif command == "npc" or command == "scan" then
        if ManastormManagerDB.npcDetection then
            Print("NPC Detection is |cff00ff00ENABLED|r. I am vigilantly watching for Clepto the Cardnapper and Greedy Demon!")
        else
            Print("NPC Detection is |cffff0000DISABLED|r. Use |cffff9933/ms npc on|r to enable my watchful eye!")
        end
    elseif command == "npc on" or command == "scan on" then
        ManastormManagerDB.npcDetection = true
        StartNPCDetection()
        Print("NPC Detection |cff00ff00ENABLED|r! My arcane senses are now attuned to detect those elusive creatures!")
        Print("I will alert you when Clepto the Cardnapper or Greedy Demon are spotted!")
    elseif command == "npc off" or command == "scan off" then
        ManastormManagerDB.npcDetection = false
        StopNPCDetection()
        Print("NPC Detection |cffff0000DISABLED|r. My magical surveillance has been suspended.")
    elseif command == "npc test" then
        Print("Testing NPC alert system...")
        Print("|cffff0000RARE SPAWN DETECTED:|r |cffffee00Test NPC|r has been found!")
        Print("The magnificent Millhouse has marked this creature for your convenience!")
        FlashScreen()
        PlayAlertSound()
        
        -- Force show toast for testing (bypass detection check)
        Print("Creating toast notification...")
        local toast = CreateToastNotification()
        if not toast then
            Print("ERROR: Failed to create toast!")
            return
        end
        
        Print("Setting up toast...")
        currentToastUnit = "player"
        toast.npcName:SetText("Test NPC")
        
        -- Try to set the model using player
        if toast.modelFrame and UnitExists("player") then
            Print("Setting player model...")
            toast.modelFrame:SetUnit("player")
            toast.modelFrame:SetCamera(0)
            toast.modelFrame:SetPosition(0, 0, 0)
            toast.modelFrame:SetFacing(0)
        else
            Print("WARNING: Model frame or player not found!")
        end
        
        -- Set up the secure targeting macro for the test
        if toast.targetButton then
            -- For test, target the player
            toast.targetButton:SetAttribute("macrotext", "/target player")
        end
        
        -- Show the toast
        Print("Showing toast...")
        toast:Show()
        toast:StartAutoHide(15)
        
        Print("Alert test complete! Toast should appear above the dock.")
    elseif command == "npc clear" or command == "npc reset" then
        detectedNPCs = {}
        detectedGUIDs = {}
        Print("My memory of previously detected NPCs has been wiped clean! I shall alert you anew when they appear!")
    elseif command == "toast reset" then
        -- Reset toast position
        ManastormManagerDB.toastPoint = nil
        ManastormManagerDB.toastRelativePoint = nil
        ManastormManagerDB.toastX = nil
        ManastormManagerDB.toastY = nil
        Print("Toast position reset! Next toast will appear above the dock.")
    else
        Print("Unknown command: " .. command .. ". Use |cffff9933/ms help|r for available commands.")
    end
end

-- Dock lock/unlock slash command handler
local function DockSlashCommandHandler(msg)
    local command = string.lower(msg or "")
    
    if command == "lock" then
        if not ManastormManagerDB.dockLocked then
            SaveDockPosition()  -- Save current position before locking
            ManastormManagerDB.dockLocked = true
            if dockFrame then
                dockFrame:SetMovable(false)
                dockFrame:RegisterForDrag()  -- Clear drag registration
            end
            if ManastormManagerDB.verbose then
                Print("Magnificent! My control dock is now locked in place with my superior magic!")
            end
        else
            Print("My dock is already locked in place, as it should be!")
        end
    elseif command == "unlock" then
        if ManastormManagerDB.dockLocked then
            SaveDockPosition()  -- Save current position before unlocking
            ManastormManagerDB.dockLocked = false
            if dockFrame then
                dockFrame:SetMovable(true)
                dockFrame:RegisterForDrag("LeftButton")
            end
            if ManastormManagerDB.verbose then
                Print("Very well! My dock may now be repositioned as you see fit, mortal!")
            end
        else
            Print("My dock is already unlocked and ready to be moved!")
        end
    else
        Print("Dock commands:")
        print("  |cffff9933/msdock lock|r - Lock the dock in place")
        print("  |cffff9933/msdock unlock|r - Unlock the dock for moving")
    end
end

-- Event handler
local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_REGEN_DISABLED")
frame:RegisterEvent("BAG_UPDATE")
frame:RegisterEvent("MERCHANT_CLOSED")
frame:RegisterEvent("PLAYER_TARGET_CHANGED")
frame:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
frame:RegisterEvent("UNIT_DIED")
frame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" and select(1, ...) == addonName then
        -- Initialize settings with defaults
        InitializeSettings()
        
        Print("The magnificent Millhouse Manastorm is at your service! Type |cffff9933/ms help|r to witness my incredible abilities!")
        print("|cffff8800I wonder if this world has any world-destroying artifacts? ...We can't allow them to fall into the hands of the enemy, you know!|r")
        
        -- Register slash commands
        SLASH_MANASTORM1 = "/ms"
        SlashCmdList["MANASTORM"] = SlashCommandHandler
        
        SLASH_MSDOCK1 = "/msdock"
        SlashCmdList["MSDOCK"] = DockSlashCommandHandler
        
        -- Initialize cache count for auto-open
        local caches, totalCount = FindManastormCaches()
        lastCacheCount = totalCount or 0
        
        -- Initialize dock
        ShowDock()
        
        -- Start NPC detection if enabled
        if ManastormManagerDB.npcDetection then
            StartNPCDetection()
            DebugPrint("NPC Detection automatically started on addon load")
        end
        
    elseif event == "PLAYER_REGEN_DISABLED" then
        -- Entered combat - stop opening if we were doing so
        if isOpening then
            Print("Combat interrupts my magical concentration! I must cease my cache-opening demonstration!")
            StopOpening()
        end
        
    elseif event == "BAG_UPDATE" then
        -- Don't check for bag closure during cache opening - it interferes with the loot process
        -- CheckBagsClosed() -- DISABLED: This was stopping cache opening when loot windows appeared
        
        -- Delay the auto-open check slightly to avoid spam during looting
        if autoOpenTimer then
            autoOpenTimer:SetScript("OnUpdate", nil)
        end
        
        autoOpenTimer = CreateFrame("Frame")
        local elapsed = 0
        autoOpenTimer:SetScript("OnUpdate", function(self, elapsedTime)
            elapsed = elapsed + elapsedTime
            if elapsed >= 1.0 then  -- 1 second delay
                autoOpenTimer:SetScript("OnUpdate", nil)
                CheckAutoOpen()
                
                -- Adventure Mode: Check for duplicate hearthstones
                if ManastormManagerDB.adventureMode then
                    CleanupExtraHearthstones()
                end
            end
        end)
        
    elseif event == "MERCHANT_CLOSED" then
        -- Automatically stop vendoring when merchant window closes
        if isVendoring then
            -- Silently stop the vendor process
            sessionGoldEarned = sessionGoldEarned + totalGoldEarned
            isVendoring = false
            vendorQueue = {}
            totalGoldEarned = 0
            
            -- Update main UI if it exists
            if mainFrame then
                mainFrame.UpdateStatus()
            end
        end
        
        -- Show session total when merchant window closes
        ShowVendorSessionTotal()
        
    elseif event == "PLAYER_TARGET_CHANGED" then
        -- Check if player targeted one of our special NPCs
        if ManastormManagerDB.npcDetection and UnitExists("target") then
            local targetName = UnitName("target")
            local targetNPCs = {"Clepto the Cardnapper", "Greedy Demon"}
            
            for _, npcName in ipairs(targetNPCs) do
                if targetName == npcName then
                    -- Immediate check when targeting
                    ScanForTargetNPCs()
                    break
                end
            end
        end
        
    elseif event == "UPDATE_MOUSEOVER_UNIT" then
        -- Check if player moused over one of our special NPCs
        if ManastormManagerDB.npcDetection and UnitExists("mouseover") then
            local mouseoverName = UnitName("mouseover")
            local targetNPCs = {"Clepto the Cardnapper", "Greedy Demon"}
            
            for _, npcName in ipairs(targetNPCs) do
                if mouseoverName == npcName then
                    -- Immediate check when mousing over
                    ScanForTargetNPCs()
                    break
                end
            end
        end
        
    elseif event == "UNIT_DIED" then
        -- Check if the died unit was one of our tracked NPCs
        local unitGUID = select(1, ...)
        if unitGUID and detectedNPCs then
            -- Try to get the name from the GUID (if available in 3.3.5a)
            local targetNPCs = {"Clepto the Cardnapper", "Greedy Demon"}
            for _, npcName in ipairs(targetNPCs) do
                if detectedNPCs[npcName] then
                    -- Clear this NPC from detection since we got a death event
                    -- We can't be 100% sure it's the right one without GUID parsing
                    -- but if player is in combat with it, it's likely the one
                    if UnitExists("target") and UnitIsDead("target") and UnitName("target") == npcName then
                        detectedNPCs[npcName] = nil
                        DebugPrint("Cleared " .. npcName .. " from detection (unit died)")
                    end
                end
            end
        end
        
    end
end)