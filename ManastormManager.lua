-- Manastorm Manager - Automatically opens Manastorm Caches
-- Compatible with WoW 3.3.5a and Lua 5.1

local addonName = "ManastormManager"
local version = "1.0"

-- Addon variables
local isOpening = false
local openQueue = {}
local currentlyOpening = 0
local totalCaches = 0

-- Vendor variables
local isVendoring = false
local vendorQueue = {}
local currentlyVendoring = 0
local totalVendorItems = 0
local totalGoldEarned = 0

-- Default settings
ManastormManagerDB = ManastormManagerDB or {
    delay = 0.5,  -- Delay between opening caches (seconds)
    verbose = true,  -- Show detailed messages
    vendorDelay = 0.2,  -- Delay between vendoring items (seconds)
    keepRares = true,  -- Keep rare (blue) items when vendoring
    protectedItems = {},  -- List of item names to never sell
    autoSellItems = {},  -- List of item names to always sell
    autoOpen = false  -- Automatically open caches when found
}

-- Print function with addon prefix
local function Print(msg)
    print("|cff00ff00[" .. addonName .. "]|r " .. msg)
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
        return false
    end
    
    -- Convert to lowercase for case-insensitive matching
    local lowerItem = string.lower(itemName)
    local lowerPattern = string.lower(pattern)
    
    -- If no wildcards, do exact match
    if not string.find(lowerPattern, "*", 1, true) then
        return lowerItem == lowerPattern
    end
    
    -- Convert wildcard pattern to Lua pattern
    -- Escape special Lua pattern characters except *
    local luaPattern = string.gsub(lowerPattern, "([%^%$%(%)%%%.%[%]%+%-%?])", "%%%1")
    -- Replace * with .*
    luaPattern = string.gsub(luaPattern, "%*", ".*")
    -- Anchor the pattern to match the entire string
    luaPattern = "^" .. luaPattern .. "$"
    
    return string.find(lowerItem, luaPattern) ~= nil
end

-- Countdown print function
local function CountdownPrint(remaining)
    print("|cff00ff00[" .. addonName .. "]|r Opening... |cffff9933" .. remaining .. "|r Manastorm Cache" .. (remaining > 1 and "s" or "") .. " remaining")
end

-- Find all Manastorm Caches in bags
local function FindManastormCaches()
    local caches = {}
    
    -- Scan all bags (0-4: backpack + 4 bags)
    for bag = 0, 4 do
        local numSlots = GetContainerNumSlots(bag)
        if numSlots then
            for slot = 1, numSlots do
                local itemLink = GetContainerItemLink(bag, slot)
                if itemLink then
                    local itemName = GetItemInfo(itemLink)
                    if itemName and string.find(itemName, "Manastorm Cache") then
                        local texture, itemCount, locked, quality, readable = GetContainerItemInfo(bag, slot)
                        if not locked and itemCount and itemCount > 0 then
                            table.insert(caches, {bag = bag, slot = slot, count = itemCount, name = itemName})
                            DebugPrint("Found " .. itemCount .. "x " .. itemName .. " in bag " .. bag .. " slot " .. slot)
                        end
                    end
                end
            end
        end
    end
    
    return caches
end

-- Open a single cache
local function OpenCache(bag, slot)
    UseContainerItem(bag, slot)
    currentlyOpening = currentlyOpening + 1
    local remaining = totalCaches - currentlyOpening
    
    if remaining > 0 then
        CountdownPrint(remaining)
    else
        -- This was the last cache
        print("|cffff8800I wonder if this world has any world-destroying artifacts? ...We can't allow them to fall into the hands of the enemy, you know!|r")
    end
end

-- Process the opening queue
local function ProcessQueue()
    if not isOpening then
        return
    end
    
    if table.getn(openQueue) == 0 then
        -- We're done - show the special completion message
        isOpening = false
        print("|cffff8800I wonder if this world has any world-destroying artifacts? ...We can't allow them to fall into the hands of the enemy, you know!|r")
        currentlyOpening = 0
        totalCaches = 0
        
        -- Update main UI if it exists
        if mainFrame then
            mainFrame.UpdateStatus()
        end
        return
    end
    
    -- Get next cache from queue
    local cache = table.remove(openQueue, 1)
    if cache then
        -- Verify the cache is still there and not locked
        local texture, itemCount, locked = GetContainerItemInfo(cache.bag, cache.slot)
        if texture and not locked and itemCount and itemCount > 0 then
            OpenCache(cache.bag, cache.slot)
        else
            -- Cache no longer available, adjust remaining count
            totalCaches = totalCaches - 1
            DebugPrint("Cache at bag " .. cache.bag .. " slot " .. cache.slot .. " is no longer available")
        end
    end
    
    -- Schedule next opening
    if table.getn(openQueue) > 0 then
        local timer = CreateFrame("Frame")
        timer:RegisterEvent("ADDON_LOADED")
        local elapsed = 0
        timer:SetScript("OnUpdate", function(self, elapsedTime)
            elapsed = elapsed + elapsedTime
            if elapsed >= ManastormManagerDB.delay then
                timer:SetScript("OnUpdate", nil)
                ProcessQueue()
            end
        end)
    end
end

-- Main function to start opening caches
local function OpenManastormCaches()
    if isOpening then
        Print("Already opening caches! Use /ms stop to cancel.")
        return
    end
    
    if InCombatLockdown() then
        Print("Cannot open caches while in combat!")
        return
    end
    
    local caches = FindManastormCaches()
    
    if table.getn(caches) == 0 then
        Print("No Manastorm Caches found in your bags.")
        return
    end
    
    -- Build the opening queue
    openQueue = {}
    totalCaches = 0
    
    for i, cache in ipairs(caches) do
        -- Add each individual cache (accounting for stacks)
        for j = 1, cache.count do
            table.insert(openQueue, {bag = cache.bag, slot = cache.slot})
            totalCaches = totalCaches + 1
        end
    end
    
    Print("Found " .. totalCaches .. " Manastorm Caches. Opening them with " .. ManastormManagerDB.delay .. "s delay...")
    CountdownPrint(totalCaches)  -- Show initial countdown
    
    isOpening = true
    currentlyOpening = 0
    ProcessQueue()
    
    -- Update main UI if it exists
    if mainFrame then
        mainFrame.UpdateStatus()
    end
end

-- Stop opening caches
local function StopOpening()
    if isOpening then
        Print("Stopped opening caches. Opened " .. currentlyOpening .. " out of " .. totalCaches .. " caches.")
        isOpening = false
        openQueue = {}
        currentlyOpening = 0
        totalCaches = 0
        
        -- Update main UI if it exists
        if mainFrame then
            mainFrame.UpdateStatus()
        end
    else
        Print("Not currently opening caches.")
    end
end

-- Count caches in bags
local function CountCaches()
    local caches = FindManastormCaches()
    local count = 0
    
    for i, cache in ipairs(caches) do
        count = count + cache.count
    end
    
    if count > 0 then
        Print("Found " .. count .. " Manastorm Cache" .. (count > 1 and "s" or "") .. " in your bags.")
    else
        Print("No Manastorm Caches found in your bags.")
    end
end

-- Find all equipment items under epic rarity in bags
local function FindVendorItems()
    local items = {}
    
    -- Quality levels: 0=poor(gray), 1=common(white), 2=uncommon(green), 3=rare(blue), 4=epic(purple), 5=legendary(orange)
    local keepRares = ManastormManagerDB.keepRares ~= false  -- Default true if not set
    local maxQuality = keepRares and 2 or 3  -- Keep rares or vendor them too
    
    -- Scan all bags (0-4: backpack + 4 bags)
    for bag = 0, 4 do
        local numSlots = GetContainerNumSlots(bag)
        if numSlots then
            for slot = 1, numSlots do
                local texture, itemCount, locked, quality, readable = GetContainerItemInfo(bag, slot)
                if texture and not locked and quality and quality <= maxQuality then
                    local itemLink = GetContainerItemLink(bag, slot)
                    if itemLink then
                        local itemName, _, itemQuality, itemLevel, itemMinLevel, itemType, itemSubType, itemStackCount, itemEquipLoc, _, vendorPrice = GetItemInfo(itemLink)
                        
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
                                    break
                                end
                            end
                        end
                        
                        -- Vendor if: (equipment AND has price AND not protected) OR (is auto-sell AND has price)
                        if vendorPrice and vendorPrice > 0 and not isProtected and 
                           ((itemEquipLoc and itemEquipLoc ~= "") or isAutoSell) then
                            table.insert(items, {
                                bag = bag, 
                                slot = slot, 
                                count = itemCount or 1, 
                                name = itemName or "Unknown Item",
                                quality = quality,
                                itemType = itemType or "Unknown",
                                vendorPrice = vendorPrice
                            })
                            DebugPrint("Found " .. (itemName or "Unknown") .. " (quality " .. quality .. ", sells for " .. vendorPrice .. ") in bag " .. bag .. " slot " .. slot)
                        elseif itemEquipLoc and itemEquipLoc ~= "" and isProtected then
                            DebugPrint("Skipping " .. (itemName or "Unknown") .. " - item is protected from selling")
                        elseif itemEquipLoc and itemEquipLoc ~= "" and (not vendorPrice or vendorPrice == 0) then
                            DebugPrint("Skipping " .. (itemName or "Unknown") .. " - cannot be sold to vendor")
                        end
                    end
                end
            end
        end
    end
    
    return items
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
        
        Print("Sold |cffcccccc" .. item.name .. "|r for " .. FormatMoney(vendorPrice) .. " (" .. remaining .. " remaining)")
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
        -- We're done - show total and quote
        isVendoring = false
        Print("Finished vendoring " .. currentlyVendoring .. " items!")
        Print("Total gold earned: " .. FormatMoney(totalGoldEarned))
        print("|cffff8800If you have any excess priceless artifacts that were lost in time, I'm making a collection.|r")
        currentlyVendoring = 0
        totalVendorItems = 0
        totalGoldEarned = 0
        
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
        Print("Already vendoring items! Use /ms stopvendor to cancel.")
        return
    end
    
    if InCombatLockdown() then
        Print("Cannot vendor items while in combat!")
        return
    end
    
    -- Check if merchant window is open
    if not MerchantFrame or not MerchantFrame:IsVisible() then
        Print("You must be at a vendor to use this command!")
        return
    end
    
    local items = FindVendorItems()
    
    if table.getn(items) == 0 then
        local keepRares = ManastormManagerDB.keepRares ~= false
        local qualityText = keepRares and "green and below" or "rare and below"
        Print("No sellable " .. qualityText .. " equipment found in your bags.")
        return
    end
    
    -- Build the vendor queue
    vendorQueue = {}
    totalVendorItems = 0
    
    for i, item in ipairs(items) do
        table.insert(vendorQueue, item)
        totalVendorItems = totalVendorItems + 1
    end
    
    local keepRares = ManastormManagerDB.keepRares ~= false
    local qualityText = keepRares and "green and below" or "rare and below"
    Print("Found " .. totalVendorItems .. " sellable " .. qualityText .. " equipment items. Vendoring them...")
    
    isVendoring = true
    currentlyVendoring = 0
    totalGoldEarned = 0
    ProcessVendorQueue()
    
    -- Update main UI if it exists
    if mainFrame then
        mainFrame.UpdateStatus()
    end
end

-- Stop vendoring items
local function StopVendoring()
    if isVendoring then
        Print("Stopped vendoring items. Sold " .. currentlyVendoring .. " out of " .. totalVendorItems .. " items.")
        if totalGoldEarned > 0 then
            Print("Gold earned before stopping: " .. FormatMoney(totalGoldEarned))
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
        Print("Not currently vendoring items.")
    end
end

-- Count vendorable items
local function CountVendorItems()
    local items = FindVendorItems()
    local count = table.getn(items)
    local keepRares = ManastormManagerDB.keepRares ~= false
    local qualityText = keepRares and "green and below" or "rare and below"
    
    if count > 0 then
        Print("Found " .. count .. " sellable " .. qualityText .. " equipment item" .. (count > 1 and "s" or "") .. " to vendor.")
    else
        Print("No sellable " .. qualityText .. " equipment found in your bags.")
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
    elseif command == "help" then
        Print("Available commands:")
        print("  |cffff9933/ms|r or |cffff9933/ms open|r - Open all Manastorm Caches")
        print("  |cffff9933/ms stop|r - Stop opening caches")
        print("  |cffff9933/ms count|r - Count caches in bags")
        print("  |cffff9933/ms vendor|r - Vendor all equipment under epic rarity (at vendor)")
        print("  |cffff9933/ms stopvendor|r - Stop vendoring items")
        print("  |cffff9933/ms countvendor|r - Count items that would be vendored")
        print("  |cffff9933/ms config|r - Show configuration options")
        print("  |cffff9933/ms gui|r - Show options GUI")
        print("  |cffff9933/ms ui|r - Show main UI panel")
        print("  |cffff9933/ms help|r - Show this help")
        print("  |cffff9933/ms protect <item>|r - Add item to protected list")
        print("  |cffff9933/ms unprotect <item>|r - Remove item from protected list")
        print("  |cffff9933/ms autosell <item>|r - Add item to auto-sell list")
        print("  |cffff9933/ms unautosell <item>|r - Remove item from auto-sell list")
        print("  |cffff9933/ms listprotected|r - Show protected items")
        print("  |cffff9933/ms listautosell|r - Show auto-sell items")
    elseif command == "config" then
        Print("Configuration:")
        print("  Delay between opens: |cffff9933" .. ManastormManagerDB.delay .. "s|r")
        print("  Vendor delay: |cffff9933" .. ManastormManagerDB.vendorDelay .. "s|r")
        print("  Keep rare items: |cffff9933" .. (ManastormManagerDB.keepRares and "ON" or "OFF") .. "|r")
        print("  Auto-open new caches: |cffff9933" .. (ManastormManagerDB.autoOpen and "ON" or "OFF") .. "|r")
        print("  Verbose logging: |cffff9933" .. (ManastormManagerDB.verbose and "ON" or "OFF") .. "|r")
        print("Use |cffff9933/ms delay X|r to set delay (0.1-5.0 seconds)")
        print("Use |cffff9933/ms verbose|r to toggle verbose mode")
        print("Use |cffff9933/ms keeprares|r to toggle keeping rare items when vendoring")
        print("Use |cffff9933/ms autoopen|r to toggle auto-opening new caches")
    elseif string.sub(command, 1, 5) == "delay" then
        local delayStr = string.sub(command, 7)
        local delay = tonumber(delayStr)
        if delay and delay >= 0.1 and delay <= 5.0 then
            ManastormManagerDB.delay = delay
            Print("Delay set to " .. delay .. " seconds.")
        else
            Print("Invalid delay. Use a number between 0.1 and 5.0 seconds.")
        end
    elseif command == "verbose" then
        ManastormManagerDB.verbose = not ManastormManagerDB.verbose
        Print("Verbose mode " .. (ManastormManagerDB.verbose and "enabled" or "disabled") .. ".")
    elseif command == "keeprares" then
        ManastormManagerDB.keepRares = not ManastormManagerDB.keepRares
        local qualityText = ManastormManagerDB.keepRares and "green and below" or "rare and below"
        Print("Will now vendor " .. qualityText .. " equipment items.")
    elseif command == "autoopen" then
        ManastormManagerDB.autoOpen = not ManastormManagerDB.autoOpen
        Print("Auto-open " .. (ManastormManagerDB.autoOpen and "enabled" or "disabled") .. ".")
        if ManastormManagerDB.autoOpen then
            -- Reset cache count when enabling auto-open
            local caches = FindManastormCaches()
            lastCacheCount = 0
            for i, cache in ipairs(caches) do
                lastCacheCount = lastCacheCount + cache.count
            end
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
    elseif command == "gui" or command == "options" then
        ShowOptionsGUI()
    elseif command == "ui" or command == "show" then
        ShowMainUI()
    else
        Print("Unknown command: " .. command .. ". Use |cffff9933/ms help|r for available commands.")
    end
end

-- Auto-open timer variables
local autoOpenTimer = nil
local lastCacheCount = 0

-- GUI variables
local optionsFrame = nil
local mainFrame = nil

-- Forward declarations for GUI functions
local ShowOptionsGUI
local ShowMainUI

-- Create options GUI
local function CreateOptionsGUI()
    if optionsFrame then
        return optionsFrame
    end
    
    -- Main frame
    optionsFrame = CreateFrame("Frame", "ManastormManagerOptionsFrame", UIParent)
    optionsFrame:SetSize(400, 350)
    optionsFrame:SetPoint("CENTER")
    optionsFrame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 }
    })
    optionsFrame:SetMovable(true)
    optionsFrame:EnableMouse(true)
    optionsFrame:RegisterForDrag("LeftButton")
    optionsFrame:SetScript("OnDragStart", optionsFrame.StartMoving)
    optionsFrame:SetScript("OnDragStop", optionsFrame.StopMovingOrSizing)
    optionsFrame:Hide()
    
    -- Title
    local title = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -20)
    title:SetText("Manastorm Manager Options")
    
    -- Close button
    local closeButton = CreateFrame("Button", nil, optionsFrame, "UIPanelCloseButton")
    closeButton:SetPoint("TOPRIGHT", -5, -5)
    
    -- Verbose checkbox
    local verboseCheck = CreateFrame("CheckButton", nil, optionsFrame, "UICheckButtonTemplate")
    verboseCheck:SetPoint("TOPLEFT", 30, -60)
    verboseCheck:SetScript("OnClick", function()
        ManastormManagerDB.verbose = verboseCheck:GetChecked()
        Print("Verbose mode " .. (ManastormManagerDB.verbose and "enabled" or "disabled") .. ".")
    end)
    local verboseLabel = verboseCheck:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    verboseLabel:SetPoint("LEFT", verboseCheck, "RIGHT", 5, 0)
    verboseLabel:SetText("Verbose logging")
    
    -- Auto-open checkbox
    local autoOpenCheck = CreateFrame("CheckButton", nil, optionsFrame, "UICheckButtonTemplate")
    autoOpenCheck:SetPoint("TOPLEFT", 30, -90)
    autoOpenCheck:SetScript("OnClick", function()
        ManastormManagerDB.autoOpen = autoOpenCheck:GetChecked()
        Print("Auto-open " .. (ManastormManagerDB.autoOpen and "enabled" or "disabled") .. ".")
        if ManastormManagerDB.autoOpen then
            -- Reset cache count when enabling auto-open
            local caches = FindManastormCaches()
            lastCacheCount = 0
            for i, cache in ipairs(caches) do
                lastCacheCount = lastCacheCount + cache.count
            end
        end
    end)
    local autoOpenLabel = autoOpenCheck:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    autoOpenLabel:SetPoint("LEFT", autoOpenCheck, "RIGHT", 5, 0)
    autoOpenLabel:SetText("Auto-open new caches")
    
    -- Keep rares checkbox
    local keepRaresCheck = CreateFrame("CheckButton", nil, optionsFrame, "UICheckButtonTemplate")
    keepRaresCheck:SetPoint("TOPLEFT", 30, -120)
    keepRaresCheck:SetScript("OnClick", function()
        ManastormManagerDB.keepRares = keepRaresCheck:GetChecked()
        local qualityText = ManastormManagerDB.keepRares and "green and below" or "rare and below"
        Print("Will now vendor " .. qualityText .. " equipment items.")
    end)
    local keepRaresLabel = keepRaresCheck:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    keepRaresLabel:SetPoint("LEFT", keepRaresCheck, "RIGHT", 5, 0)
    keepRaresLabel:SetText("Keep rare (blue) items when vendoring")
    
    -- Delay slider
    local delaySlider = CreateFrame("Slider", nil, optionsFrame, "OptionsSliderTemplate")
    delaySlider:SetPoint("TOPLEFT", 30, -160)
    delaySlider:SetSize(200, 20)
    delaySlider:SetMinMaxValues(0.1, 5.0)
    delaySlider:SetValueStep(0.1)
    delaySlider:SetScript("OnValueChanged", function(self, value)
        ManastormManagerDB.delay = value
        getglobal(delaySlider:GetName() .. "Text"):SetText("Cache delay: " .. string.format("%.1f", value) .. "s")
    end)
    local delayLabel = delaySlider:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    delayLabel:SetPoint("BOTTOM", delaySlider, "TOP", 0, 5)
    delayLabel:SetText("Cache opening delay")
    
    -- Vendor delay slider
    local vendorDelaySlider = CreateFrame("Slider", nil, optionsFrame, "OptionsSliderTemplate")
    vendorDelaySlider:SetPoint("TOPLEFT", 30, -210)
    vendorDelaySlider:SetSize(200, 20)
    vendorDelaySlider:SetMinMaxValues(0.1, 2.0)
    vendorDelaySlider:SetValueStep(0.1)
    vendorDelaySlider:SetScript("OnValueChanged", function(self, value)
        ManastormManagerDB.vendorDelay = value
        getglobal(vendorDelaySlider:GetName() .. "Text"):SetText("Vendor delay: " .. string.format("%.1f", value) .. "s")
    end)
    local vendorDelayLabel = vendorDelaySlider:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    vendorDelayLabel:SetPoint("BOTTOM", vendorDelaySlider, "TOP", 0, 5)
    vendorDelayLabel:SetText("Vendor item delay")
    
    -- Function to update GUI values
    optionsFrame.UpdateValues = function()
        verboseCheck:SetChecked(ManastormManagerDB.verbose)
        autoOpenCheck:SetChecked(ManastormManagerDB.autoOpen)
        keepRaresCheck:SetChecked(ManastormManagerDB.keepRares)
        delaySlider:SetValue(ManastormManagerDB.delay)
        vendorDelaySlider:SetValue(ManastormManagerDB.vendorDelay)
        getglobal(delaySlider:GetName() .. "Text"):SetText("Cache delay: " .. string.format("%.1f", ManastormManagerDB.delay) .. "s")
        getglobal(vendorDelaySlider:GetName() .. "Text"):SetText("Vendor delay: " .. string.format("%.1f", ManastormManagerDB.vendorDelay) .. "s")
    end
    
    return optionsFrame
end

-- Show options GUI
ShowOptionsGUI = function()
    local frame = CreateOptionsGUI()
    frame.UpdateValues()
    frame:Show()
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

-- Check for new caches and auto-open if enabled
local function CheckAutoOpen()
    if ManastormManagerDB.autoOpen and not isOpening and not InCombatLockdown() then
        local caches = FindManastormCaches()
        local currentCacheCount = 0
        
        for i, cache in ipairs(caches) do
            currentCacheCount = currentCacheCount + cache.count
        end
        
        -- If we found new caches, auto-open them
        if currentCacheCount > lastCacheCount and currentCacheCount > 0 then
            DebugPrint("Auto-open detected " .. (currentCacheCount - lastCacheCount) .. " new caches")
            OpenManastormCaches()
        end
        
        lastCacheCount = currentCacheCount
    end
end

-- Event handler
local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_REGEN_DISABLED")
frame:RegisterEvent("BAG_UPDATE")
frame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" and select(1, ...) == addonName then
        Print("v" .. version .. " loaded. Type |cffff9933/ms help|r for commands.")
        print("|cffff8800I wonder if this world has any world-destroying artifacts? ...We can't allow them to fall into the hands of the enemy, you know!|r")
        
        -- Register slash commands
        SLASH_MANASTORM1 = "/ms"
        SlashCmdList["MANASTORM"] = SlashCommandHandler
        
        -- Initialize cache count for auto-open
        local caches = FindManastormCaches()
        for i, cache in ipairs(caches) do
            lastCacheCount = lastCacheCount + cache.count
        end
        
    elseif event == "PLAYER_REGEN_DISABLED" then
        -- Entered combat - stop opening if we were doing so
        if isOpening then
            Print("Entered combat! Stopping cache opening for safety.")
            StopOpening()
        end
        
    elseif event == "BAG_UPDATE" then
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
            end
        end)
    end
end)