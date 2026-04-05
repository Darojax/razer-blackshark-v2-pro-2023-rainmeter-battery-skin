local state = {
    value = 0,
    isCharging = false,
    isDisconnected = false,
    lastPollTime = 0,
    lastLifecyclePollTime = 0,
    lastBoltColor = "",
    boltHidden = true,
    lastStaleColor = "",
    staleHidden = true,
    historyEntries = nil,
    lastHistoryScan = 0,
    lastObservedLogPath = "",
    lastObservedLogSize = nil,
    lastLifecycleEvent = nil,
    lastReading = nil,
}

local palette = {
    neutral = "110,110,110,255",
    good = "74,222,128,255",
    warn = "250,204,21,255",
    orange = "251,146,60,255",
    low = "248,113,113,255",
    stale = "251,191,36,255",
    disconnected = "170,170,170,255",
    missing = "140,140,140,255",
}

local developerContextEntries = {
    { index = 4, title = "Preview Green", action = "[!CommandMeasure MeasureBattery \"PreviewPreset('Green')\"]" },
    { index = 5, title = "Preview Yellow", action = "[!CommandMeasure MeasureBattery \"PreviewPreset('Yellow')\"]" },
    { index = 6, title = "Preview Orange", action = "[!CommandMeasure MeasureBattery \"PreviewPreset('Orange')\"]" },
    { index = 7, title = "Preview Red", action = "[!CommandMeasure MeasureBattery \"PreviewPreset('Red')\"]" },
    { index = 8, title = "Preview Charging", action = "[!CommandMeasure MeasureBattery \"PreviewPreset('Charging')\"]" },
    { index = 9, title = "Preview Stale Green", action = "[!CommandMeasure MeasureBattery \"PreviewPreset('StaleGreen')\"]" },
    { index = 10, title = "Preview Stale Yellow", action = "[!CommandMeasure MeasureBattery \"PreviewPreset('StaleYellow')\"]" },
    { index = 11, title = "Preview Stale Orange", action = "[!CommandMeasure MeasureBattery \"PreviewPreset('StaleOrange')\"]" },
    { index = 12, title = "Preview Stale Red", action = "[!CommandMeasure MeasureBattery \"PreviewPreset('StaleRed')\"]" },
    { index = 13, title = "Preview Full Charge", action = "[!CommandMeasure MeasureBattery \"PreviewPreset('FullCharge')\"]" },
    { index = 14, title = "Preview Disconnected", action = "[!CommandMeasure MeasureBattery \"PreviewPreset('Disconnected')\"]" },
    { index = 15, title = "Preview No Estimate", action = "[!CommandMeasure MeasureBattery \"PreviewPreset('NoEstimate')\"]" },
    { index = 16, title = "Return To Live", action = "[!CommandMeasure MeasureBattery \"PreviewPreset('Live')\"]" },
}

function Initialize()
    RefreshSettings()
    SetMissingState("Waiting for Synapse", "Open Synapse once with the headset connected")
    RefreshNow()
end

function Update()
    if settings then
        local now = os.time()
        if settings.pollSeconds > 0 and (state.lastPollTime == 0 or (now - state.lastPollTime) >= settings.pollSeconds) then
            RefreshNow()
        elseif not settings.devMode and settings.lifecyclePollSeconds > 0 and (state.lastLifecyclePollTime == 0 or (now - state.lastLifecyclePollTime) >= settings.lifecyclePollSeconds) then
            CheckQuickLifecycle(now)
        end
    end
    return state.value
end

function RefreshNow()
    RefreshSettings()

    local reading = nil
    if settings.devMode then
        reading = BuildPreviewReading()
    else
        reading = ReadLatestBattery(settings.logFile, settings.devicePattern, settings.tailBytes)
    end

    if reading then
        ApplyReading(reading)
    else
        SetMissingState("No Synapse battery entry", "Open Synapse once with the headset connected")
    end

    state.lastPollTime = os.time()
    state.lastLifecyclePollTime = state.lastPollTime
    UpdateObservedLogSignature(settings.logFile)

    return state.value
end

function CheckQuickLifecycle(now)
    state.lastLifecyclePollTime = now or os.time()

    if not settings or settings.devMode then
        return
    end

    if not HasObservedLogChanged(settings.logFile) then
        return
    end

    UpdateObservedLogSignature(settings.logFile)
    local lifecycleEvent = ReadLatestLifecycleEvent(settings.logFile, settings.devicePattern, settings.lifecycleTailBytes)
    if not lifecycleEvent or IsSameLifecycleEvent(lifecycleEvent, state.lastLifecycleEvent) then
        return
    end

    state.lastLifecycleEvent = CloneLifecycleEvent(lifecycleEvent)

    if lifecycleEvent.status == "connected" then
        RefreshNow()
        return
    end

    if lifecycleEvent.status == "disconnected" and state.lastReading then
        local quickReading = CloneReading(state.lastReading)
        if not quickReading then
            return
        end

        quickReading.lifecycleEvent = CloneLifecycleEvent(lifecycleEvent)
        ApplyReading(quickReading)
    end
end

function RefreshSettings()
    local localAppData = os.getenv("LOCALAPPDATA") or ""
    local resolvedFolder = localAppData ~= "" and (localAppData .. "\\Razer\\Synapse3\\Log\\") or ""
    local resolvedFile = resolvedFolder ~= "" and (resolvedFolder .. "Razer Synapse 3.log") or ""
    local yellowThreshold = Clamp(tonumber(SKIN:GetVariable("YellowThreshold", "30")) or 30, 0, 100)
    local orangeThreshold = Clamp(tonumber(SKIN:GetVariable("OrangeThreshold", "20")) or 20, 0, yellowThreshold)
    local redThreshold = Clamp(tonumber(SKIN:GetVariable("RedThreshold", "10")) or 10, 0, orangeThreshold)

    settings = {
        logFolder = ResolvePathVariable(SKIN:GetVariable("LogFolder"), resolvedFolder),
        logFile = ResolvePathVariable(SKIN:GetVariable("LogFile"), resolvedFile),
        devicePattern = string.lower(SKIN:GetVariable("DevicePattern", "BlackShark V2 Pro")),
        tailBytes = tonumber(SKIN:GetVariable("TailBytes", "524288")) or 524288,
        pollSeconds = tonumber(SKIN:GetVariable("PollSeconds", "60")) or 60,
        lifecyclePollSeconds = tonumber(SKIN:GetVariable("LifecyclePollSeconds", "5")) or 5,
        lifecycleTailBytes = tonumber(SKIN:GetVariable("LifecycleTailBytes", "32768")) or 32768,
        staleMinutes = tonumber(SKIN:GetVariable("StaleMinutes", "180")) or 180,
        disconnectDebounceSeconds = tonumber(SKIN:GetVariable("DisconnectDebounceSeconds", "15")) or 15,
        historyDays = tonumber(SKIN:GetVariable("HistoryDays", "21")) or 21,
        historyRefreshHours = tonumber(SKIN:GetVariable("HistoryRefreshHours", "6")) or 6,
        yellowThreshold = yellowThreshold,
        orangeThreshold = orangeThreshold,
        redThreshold = redThreshold,
        estimateRecentHours = tonumber(SKIN:GetVariable("EstimateRecentHours", "12")) or 12,
        estimateMediumHours = tonumber(SKIN:GetVariable("EstimateMediumHours", "168")) or 168,
        estimateLongHours = tonumber(SKIN:GetVariable("EstimateLongHours", "504")) or 504,
        estimateMaxGapHours = tonumber(SKIN:GetVariable("EstimateMaxGapHours", "3")) or 3,
        estimateMinTotalDrop = tonumber(SKIN:GetVariable("EstimateMinTotalDrop", "3")) or 3,
        previewFullChargeHours = tonumber(SKIN:GetVariable("PreviewFullChargeHours", "48")) or 48,
        showDeveloperPreviews = (tonumber(SKIN:GetVariable("ShowDeveloperPreviews", "0")) or 0) > 0,
        devMode = (tonumber(SKIN:GetVariable("DevMode", "0")) or 0) > 0,
        devBatteryPercent = Clamp(tonumber(SKIN:GetVariable("DevBatteryPercent", "75")) or 75, 0, 100),
        devBatteryState = SKIN:GetVariable("DevBatteryState", "NotCharging"),
        devForceStale = (tonumber(SKIN:GetVariable("DevForceStale", "0")) or 0) > 0,
        devForceDisconnected = (tonumber(SKIN:GetVariable("DevForceDisconnected", "0")) or 0) > 0,
        devForceEstimateUnavailable = (tonumber(SKIN:GetVariable("DevForceEstimateUnavailable", "0")) or 0) > 0,
        fillMaxWidth = ReadFormulaNumberVariable("FillMaxW", 20),
    }

    SetVariable("LogFolder", settings.logFolder)
    SetVariable("LogFile", settings.logFile)
    ConfigureDeveloperContextMenu()
end

function BuildPreviewReading()
    local timestamp = os.time()
    if settings.devForceStale then
        timestamp = timestamp - ((settings.staleMinutes + 5) * 60)
    end

    return {
        timestamp = timestamp,
        timestampText = BuildPreviewTimestampText(),
        name = "BlackShark V2 Pro",
        percent = settings.devBatteryPercent,
        batteryState = settings.devBatteryState,
        isPreview = true,
    }
end

function PreviewPreset(name)
    RefreshSettings()

    local preset = string.lower(name or "")
    if preset == "live" then
        SetVariable("DevMode", "0")
        SetVariable("DevForceStale", "0")
        SetVariable("DevForceDisconnected", "0")
        SetVariable("DevForceEstimateUnavailable", "0")
        RefreshNow()
        return
    end

    local percent = GetPreviewPercent(preset)
    local batteryState = "NotCharging"
    local forceStale = "0"
    local forceDisconnected = "0"
    local forceEstimateUnavailable = "0"

    if preset == "charging" then
        batteryState = "Charging"
    elseif preset == "fullcharge" then
        percent = 100
        batteryState = "FullyCharged"
    elseif preset == "disconnected" then
        percent = GetPreviewPercent("green")
        forceDisconnected = "1"
    elseif preset == "noestimate" then
        percent = GetPreviewPercent("green")
        forceEstimateUnavailable = "1"
    elseif IsStalePreset(preset) then
        forceStale = "1"
    end

    SetVariable("DevMode", "1")
    SetVariable("DevBatteryPercent", tostring(percent))
    SetVariable("DevBatteryState", batteryState)
    SetVariable("DevForceStale", forceStale)
    SetVariable("DevForceDisconnected", forceDisconnected)
    SetVariable("DevForceEstimateUnavailable", forceEstimateUnavailable)
    RefreshNow()
end

function GetPreviewPercent(preset)
    local colorPreset = NormalizePreviewColorPreset(preset)

    if colorPreset == "red" then
        return math.max(0, math.floor(settings.redThreshold / 2))
    end

    if colorPreset == "orange" then
        return Midpoint(settings.redThreshold + 1, settings.orangeThreshold)
    end

    if colorPreset == "yellow" then
        return Midpoint(settings.orangeThreshold + 1, settings.yellowThreshold)
    end

    if colorPreset == "green" or colorPreset == "charging" or colorPreset == "stale" then
        return Midpoint(settings.yellowThreshold + 1, 100)
    end

    if colorPreset == "fullcharge" then
        return 100
    end

    return Clamp(settings.devBatteryPercent or 75, 0, 100)
end

function NormalizePreviewColorPreset(preset)
    if IsStalePreset(preset) then
        local suffix = preset:gsub("^stale", "")
        if suffix == "" then
            return "green"
        end

        return suffix
    end

    return preset
end

function IsStalePreset(preset)
    return preset == "stale" or preset:find("^stale") ~= nil
end

function ReadLatestBattery(path, devicePattern, tailBytes)
    local content = ReadTail(path, tailBytes)
    if not content or content == "" then
        return nil
    end

    content = content:gsub("\r\n", "\n")
    local latest = nil
    local latestLifecycle = nil
    local current = nil
    local lineIndex = 0

    for line in content:gmatch("([^\n]*)\n?") do
        lineIndex = lineIndex + 1
        if line ~= "" then
            if IsTimestampLine(line) then
                latest = CommitReading(latest, current, devicePattern)
                current = nil

                local lifecycleEvent = ParseLifecycleEvent(line, devicePattern, lineIndex)
                if lifecycleEvent then
                    latestLifecycle = lifecycleEvent
                end

                if line:find("Battery Get By Device Handle:", 1, true) then
                    local timestamp = ParseTimestamp(line)
                    if timestamp then
                        current = {
                            timestamp = timestamp,
                            timestampText = FormatExactTimestamp(timestamp),
                            order = lineIndex,
                        }
                    end
                end
            elseif current then
                local name = line:match("^Name:%s*(.+)$")
                if name and not current.name then
                    current.name = name
                end

                local percent = line:match("^Battery Percentage:%s*(%d+)$")
                if percent then
                    current.percent = tonumber(percent)
                end

                local batteryState = line:match("^Battery State:%s*(%S+)$")
                if batteryState then
                    current.batteryState = batteryState
                end
            end
        end
    end

    latest = CommitReading(latest, current, devicePattern)
    if latest then
        latest.lifecycleEvent = latestLifecycle
    end
    return latest
end

function CommitReading(latest, current, devicePattern)
    if not current or not current.timestamp or not current.name or current.percent == nil or not current.batteryState then
        return latest
    end

    if not string.find(string.lower(current.name), devicePattern, 1, true) then
        return latest
    end

    return current
end

function ParseLifecycleEvent(line, devicePattern, order)
    local eventName = nil
    local status = nil

    if line:find("_OnDeviceLoaded:Name:", 1, true) then
        eventName = line:match("_OnDeviceLoaded:Name:%s*(.+)$")
        status = "connected"
    elseif line:find("_OnDeviceRemoved:Name:", 1, true) then
        eventName = line:match("_OnDeviceRemoved:Name:%s*(.+)$")
        status = "disconnected"
    end

    if not eventName or not status then
        return nil
    end

    if not string.find(string.lower(eventName), devicePattern, 1, true) then
        return nil
    end

    local timestamp = ParseTimestamp(line)
    if not timestamp then
        return nil
    end

    return {
        status = status,
        timestamp = timestamp,
        timestampText = FormatExactTimestamp(timestamp),
        order = order or 0,
    }
end

function ReadLatestLifecycleEvent(path, devicePattern, tailBytes)
    local content = ReadTail(path, tailBytes)
    if not content or content == "" then
        return nil
    end

    content = content:gsub("\r\n", "\n")
    local latestLifecycle = nil
    local lineIndex = 0

    for line in content:gmatch("([^\n]*)\n?") do
        lineIndex = lineIndex + 1
        if line ~= "" and IsTimestampLine(line) then
            local lifecycleEvent = ParseLifecycleEvent(line, devicePattern, lineIndex)
            if lifecycleEvent then
                latestLifecycle = lifecycleEvent
            end
        end
    end

    return latestLifecycle
end

function CloneLifecycleEvent(event)
    if not event then
        return nil
    end

    return {
        status = event.status,
        timestamp = event.timestamp,
        timestampText = event.timestampText,
        order = event.order,
    }
end

function CloneReading(reading)
    if not reading then
        return nil
    end

    return {
        timestamp = reading.timestamp,
        timestampText = reading.timestampText,
        name = reading.name,
        percent = reading.percent,
        batteryState = reading.batteryState,
        isPreview = reading.isPreview,
        order = reading.order,
        lifecycleEvent = CloneLifecycleEvent(reading.lifecycleEvent),
    }
end

function IsSameLifecycleEvent(left, right)
    if not left and not right then
        return true
    end

    if not left or not right then
        return false
    end

    return left.status == right.status
        and left.timestamp == right.timestamp
        and (left.order or 0) == (right.order or 0)
end

function ApplyReading(reading)
    local percent = Clamp(reading.percent or 0, 0, 100)
    local ageMinutes = GetAgeMinutes(reading.timestamp)
    local disconnectedInfo = GetDisconnectedInfo(reading)
    local isDisconnected = disconnectedInfo.isDisconnected
    local displayState = isDisconnected and "Disconnected" or HumanizeBatteryState(reading.batteryState)
    local batteryColor = isDisconnected and palette.disconnected or PickBatteryColor(percent, reading.batteryState)
    local isCharging = (not isDisconnected) and IsChargingState(reading.batteryState)
    local ageText, isStale
    if reading.isPreview then
        ageText = reading.timestampText
        isStale = settings.devForceStale
    else
        ageText, isStale = BuildAgeText(ageMinutes, settings.staleMinutes)
    end
    if isDisconnected then
        ageText = string.format("Disconnected at %s", disconnectedInfo.timestampText)
        isStale = false
    end
    local outlineColor = isDisconnected and palette.disconnected or (isStale and palette.stale or batteryColor)
    local fillWidth = math.floor((percent / 100) * settings.fillMaxWidth + 0.5)
    local estimate = isDisconnected
        and { available = false, reason = "disconnected", text = "Headset disconnected; showing last known battery" }
        or GetEstimate(reading, isStale)

    state.value = percent
    state.isCharging = isCharging
    state.isDisconnected = isDisconnected
    state.lastReading = CloneReading(reading)
    state.lastLifecycleEvent = CloneLifecycleEvent(reading.lifecycleEvent)

    SetVariable("BatteryDisplay", string.format("%d%%", percent))
    SetVariable("BatteryStatus", displayState)
    SetVariable("BatteryTimestamp", ageText)
    SetVariable("BatteryColor", batteryColor)
    SetVariable("BatteryOutlineColor", outlineColor)
    SetVariable("BatteryCapColor", outlineColor)
    SetVariable("BatteryTextColor", outlineColor)
    SetVariable("LabelColor", outlineColor)
    SetChargeBoltState(isCharging and not isStale and not isDisconnected, true)
    SetStaleMarkState(isStale and not isDisconnected, true)
    SetVariable("BatteryFillW", tostring(fillWidth))
    SetVariable("EstimateText", estimate.text)
    SetVariable("EstimateDisplay", BuildEstimateDisplay(estimate))
    if isDisconnected then
        if reading.isPreview then
            SetVariable("BatteryTooltip", string.format("%d%%\nDisconnected\n%s\nShowing last known battery", percent, reading.timestampText))
        else
            SetVariable("BatteryTooltip", string.format("%d%%\nDisconnected\nDisconnected: %s\nLast battery reading: %s\nLog file: %s", percent, disconnectedInfo.timestampText, reading.timestampText, settings.logFile))
        end
    elseif reading.isPreview then
        SetVariable("BatteryTooltip", string.format("%d%%\n%s\n%s\n%s", percent, displayState, ageText, estimate.text))
    else
        SetVariable("BatteryTooltip", string.format("%d%%\n%s\n%s\nLast Synapse reading: %s\nLog file: %s", percent, displayState, estimate.text, reading.timestampText, settings.logFile))
    end
    RefreshSkin()
end

function SetMissingState(status, timestampText)
    state.value = 0
    state.isCharging = false
    state.isDisconnected = false
    state.lastReading = nil
    SetVariable("BatteryDisplay", "--%")
    SetVariable("BatteryStatus", status or "No data")
    SetVariable("BatteryTimestamp", timestampText or "Open Synapse once with the headset connected")
    SetVariable("BatteryColor", palette.neutral)
    SetVariable("BatteryOutlineColor", palette.missing)
    SetVariable("BatteryCapColor", palette.missing)
    SetVariable("BatteryTextColor", palette.missing)
    SetVariable("LabelColor", palette.missing)
    SetChargeBoltState(false, true)
    SetStaleMarkState(false, true)
    SetVariable("BatteryFillW", "0")
    SetVariable("EstimateText", "Estimate unavailable: no battery data")
    SetVariable("EstimateDisplay", "Charge left: Insufficient logs")
    SetVariable("BatteryTooltip", string.format("%s\n%s\nEstimate unavailable: no battery data\nLog file: %s", status or "No data", timestampText or "", settings and settings.logFile or "Unavailable"))
    RefreshSkin()
end

function RefreshSkin()
    SKIN:Bang("!UpdateMeter", "*")
    SKIN:Bang("!Redraw")
end

function SetVariable(name, value)
    SKIN:Bang("!SetVariable", name, value)
end

function ConfigureDeveloperContextMenu()
    local showDeveloperPreviews = settings and settings.showDeveloperPreviews

    for _, entry in ipairs(developerContextEntries) do
        SetVariable("DevContextTitle" .. entry.index, showDeveloperPreviews and entry.title or "")
        SetVariable("DevContextAction" .. entry.index, showDeveloperPreviews and entry.action or "")
    end
end

function ReadFormulaNumberVariable(name, fallback)
    local rawValue = SKIN:GetVariable(name, tostring(fallback))
    local numericValue = tonumber(rawValue)
    if numericValue then
        return numericValue
    end

    local ok, parsedValue = pcall(function()
        return SKIN:ParseFormula(rawValue)
    end)

    if ok then
        local parsedNumber = tonumber(parsedValue)
        if parsedNumber then
            return parsedNumber
        end
    end

    return fallback
end

function FileExists(path)
    local file = io.open(path, "rb")
    if file then
        file:close()
        return true
    end

    return false
end

function GetFileSize(path)
    if not path or path == "" then
        return nil
    end

    local file = io.open(path, "rb")
    if not file then
        return nil
    end

    local size = file:seek("end")
    file:close()
    return size
end

function HasObservedLogChanged(path)
    local currentSize = GetFileSize(path)
    if currentSize == nil then
        return false
    end

    if state.lastObservedLogPath ~= path then
        return true
    end

    return state.lastObservedLogSize ~= currentSize
end

function UpdateObservedLogSignature(path)
    state.lastObservedLogPath = path or ""
    state.lastObservedLogSize = GetFileSize(path)
end

function GetEstimate(reading, isStale)
    if reading.isPreview and settings.devForceEstimateUnavailable then
        return { available = false, reason = "insufficient_logs", text = "Estimate unavailable: not enough discharge history yet" }
    end

    if reading.isPreview then
        local previewHours = GetPreviewEstimateHours(reading)
        return {
            available = true,
            hours = previewHours,
            text = string.format("Developer preview charge left: ~%s", FormatHours(previewHours)),
        }
    end

    if isStale then
        return { available = false, reason = "stale", text = "Estimate unavailable: battery reading is stale" }
    end

    EnsureHistoryEntries(reading)
    local entries = state.historyEntries or {}
    if #entries < 3 then
        return { available = false, reason = "insufficient_logs", text = "Estimate unavailable: collecting discharge history" }
    end

    local recent = CalculateDischargeRate(entries, settings.estimateRecentHours)
    local medium = CalculateDischargeRate(entries, settings.estimateMediumHours)
    local long = CalculateDischargeRate(entries, settings.estimateLongHours)
    local rate = CombineRates(recent, medium, long)
    if not rate or rate <= 0 then
        return { available = false, reason = "insufficient_logs", text = "Estimate unavailable: not enough discharge history yet" }
    end

    local hoursRemaining = reading.percent / rate
    return {
        available = true,
        hours = hoursRemaining,
        rate = rate,
        text = string.format("Estimated battery use left: ~%s", FormatHours(hoursRemaining)),
    }
end

function EnsureHistoryEntries(latestReading)
    local now = os.time()
    local refreshSeconds = math.max(1, settings.historyRefreshHours) * 3600
    if (not state.historyEntries) or state.lastHistoryScan == 0 or (now - state.lastHistoryScan) >= refreshSeconds then
        state.historyEntries = LoadHistoryEntries()
        state.lastHistoryScan = now
    end

    if latestReading and state.historyEntries and not latestReading.isPreview then
        AppendHistoryEntry(state.historyEntries, latestReading)
    end
end

function LoadHistoryEntries()
    local cutoff = os.time() - (math.max(1, settings.historyDays) * 86400)
    local entries = {}
    local seen = {}
    local files = GatherHistoryFiles()

    for _, path in ipairs(files) do
        ParseHistoryFile(path, cutoff, entries, seen)
    end

    table.sort(entries, function(a, b)
        if a.timestamp == b.timestamp then
            if a.percent == b.percent then
                return (a.state or "") < (b.state or "")
            end
            return a.percent < b.percent
        end
        return a.timestamp < b.timestamp
    end)

    return entries
end

function GatherHistoryFiles()
    local files = {}
    if FileExists(settings.logFile) then
        table.insert(files, settings.logFile)
    end

    local archiveDir = settings.logFolder .. "archive\\"
    local misses = 0
    local maxFiles = 512
    local missLimit = 24
    for i = 0, maxFiles do
        local path = archiveDir .. string.format("%07d.log", i)
        if FileExists(path) then
            table.insert(files, 1, path)
            misses = 0
        else
            misses = misses + 1
            if misses >= missLimit and i > 32 then
                break
            end
        end
    end

    return files
end

function ParseHistoryFile(path, cutoffTimestamp, entries, seen)
    local file = io.open(path, "rb")
    if not file then
        return
    end

    local content = file:read("*a")
    file:close()
    if not content or content == "" then
        return
    end

    content = content:gsub("\r\n", "\n")
    local current = nil

    for line in content:gmatch("([^\n]*)\n?") do
        if line ~= "" then
            if IsTimestampLine(line) then
                CommitHistoryEntry(entries, seen, current, cutoffTimestamp)
                current = nil

                if line:find("Battery Get By Device Handle:", 1, true) then
                    local timestamp = ParseTimestamp(line)
                    if timestamp and timestamp >= cutoffTimestamp then
                        current = { timestamp = timestamp }
                    end
                end
            elseif current then
                local name = line:match("^Name:%s*(.+)$")
                if name and not current.name then
                    current.name = name
                end

                local percent = line:match("^Battery Percentage:%s*(%d+)$")
                if percent then
                    current.percent = tonumber(percent)
                end

                local batteryState = line:match("^Battery State:%s*(%S+)$")
                if batteryState then
                    current.batteryState = batteryState
                end
            end
        end
    end

    CommitHistoryEntry(entries, seen, current, cutoffTimestamp)
end

function CommitHistoryEntry(entries, seen, current, cutoffTimestamp)
    if not current or not current.timestamp or current.timestamp < cutoffTimestamp then
        return
    end

    if not current.name or current.percent == nil or not current.batteryState then
        return
    end

    if not string.find(string.lower(current.name), settings.devicePattern, 1, true) then
        return
    end

    local key = string.format("%d|%d|%s", current.timestamp, current.percent, current.batteryState)
    if seen[key] then
        return
    end

    seen[key] = true
    table.insert(entries, {
        timestamp = current.timestamp,
        percent = current.percent,
        state = current.batteryState,
    })
end

function AppendHistoryEntry(entries, reading)
    if not reading or not reading.timestamp or reading.percent == nil or not reading.batteryState then
        return
    end

    local last = entries[#entries]
    if last and last.timestamp == reading.timestamp and last.percent == reading.percent and last.state == reading.batteryState then
        return
    end

    table.insert(entries, {
        timestamp = reading.timestamp,
        percent = reading.percent,
        state = reading.batteryState,
    })
end

function CalculateDischargeRate(entries, windowHours)
    local cutoff = os.time() - (windowHours * 3600)
    local filtered = {}
    for _, entry in ipairs(entries) do
        if entry.timestamp >= cutoff then
            table.insert(filtered, entry)
        end
    end

    if #filtered < 2 then
        return nil
    end

    local totalDrop = 0
    local totalHours = 0
    local sessionStart = nil
    local sessionLast = nil

    local finalizeSession = function()
        if sessionStart and sessionLast and sessionLast.timestamp > sessionStart.timestamp and sessionLast.percent < sessionStart.percent then
            local drop = sessionStart.percent - sessionLast.percent
            local hours = (sessionLast.timestamp - sessionStart.timestamp) / 3600
            if drop > 0 and hours > 0 then
                totalDrop = totalDrop + drop
                totalHours = totalHours + hours
            end
        end
        sessionStart = nil
        sessionLast = nil
    end

    for _, entry in ipairs(filtered) do
        if entry.state ~= "NotCharging" then
            finalizeSession()
        else
            if not sessionStart then
                sessionStart = entry
                sessionLast = entry
            else
                local gapHours = (entry.timestamp - sessionLast.timestamp) / 3600
                if gapHours > settings.estimateMaxGapHours or entry.percent > sessionLast.percent then
                    finalizeSession()
                    sessionStart = entry
                    sessionLast = entry
                else
                    sessionLast = entry
                end
            end
        end
    end

    finalizeSession()

    if totalDrop < settings.estimateMinTotalDrop or totalHours <= 0 then
        return nil
    end

    return {
        rate = totalDrop / totalHours,
        totalDrop = totalDrop,
        totalHours = totalHours,
    }
end

function CombineRates(recent, medium, long)
    local weightedRate = 0
    local totalWeight = 0

    local function addRate(stats, weight)
        if stats and stats.rate and stats.rate > 0 then
            weightedRate = weightedRate + (stats.rate * weight)
            totalWeight = totalWeight + weight
        end
    end

    addRate(recent, 0.6)
    addRate(medium, 0.3)
    addRate(long, 0.1)

    if totalWeight <= 0 then
        return nil
    end

    return weightedRate / totalWeight
end

function FormatHours(hours)
    local roundedMinutes = math.floor((hours * 60) + 0.5)
    local displayHours = math.floor(roundedMinutes / 60)
    local displayMinutes = roundedMinutes % 60

    if displayHours <= 0 then
        return string.format("%dm", math.max(1, displayMinutes))
    end

    if displayMinutes == 0 then
        return string.format("%dh", displayHours)
    end

    return string.format("%dh %dm", displayHours, displayMinutes)
end

function BuildEstimateDisplay(estimate)
    if not estimate or not estimate.available or not estimate.hours then
        if estimate and estimate.reason == "disconnected" then
            return "Disconnected"
        end

        if estimate and estimate.reason == "insufficient_logs" then
            return "Charge left: Insufficient logs"
        end

        return "Charge left: ~--:--"
    end

    return string.format("Charge left: ~%s", FormatEstimateDuration(estimate.hours))
end

function GetPreviewEstimateHours(reading)
    local fullHours = math.max(1, settings.previewFullChargeHours or 48)
    local percent = Clamp(reading.percent or 0, 0, 100)
    local hours = (percent / 100) * fullHours

    if reading.batteryState == "FullyCharged" then
        return fullHours
    end

    return math.max(0, hours)
end

function FormatEstimateDuration(hours)
    local roundedMinutes = math.max(0, math.floor((hours * 60) + 0.5))
    local displayDays = math.floor(roundedMinutes / 1440)
    local remainingMinutes = roundedMinutes % 1440
    local displayHours = math.floor(remainingMinutes / 60)
    local displayMinutes = remainingMinutes % 60

    local parts = {}

    if displayDays > 0 then
        parts[#parts + 1] = string.format("%dd", displayDays)
    end

    if displayHours > 0 then
        parts[#parts + 1] = string.format("%dh", displayHours)
    end

    if displayMinutes > 0 or #parts == 0 then
        parts[#parts + 1] = string.format("%dm", displayMinutes)
    end

    return table.concat(parts, " ")
end

function BuildPreviewTimestampText()
    if settings.devForceDisconnected then
        return "Developer preview (disconnected)"
    end

    if settings.devForceStale then
        return "Developer preview (stale)"
    end

    if settings.devForceEstimateUnavailable then
        return "Developer preview (no estimate)"
    end

    return "Developer preview"
end

function GetDisconnectedInfo(reading)
    if not reading then
        return { isDisconnected = false }
    end

    if reading.isPreview and settings.devForceDisconnected then
        return {
            isDisconnected = true,
            timestamp = os.time(),
            timestampText = "Developer preview",
        }
    end

    local lifecycleEvent = reading.lifecycleEvent
    if not lifecycleEvent or lifecycleEvent.status ~= "disconnected" or not lifecycleEvent.timestamp then
        return { isDisconnected = false }
    end

    local readingTimestamp = reading.timestamp or 0
    local readingOrder = reading.order or 0
    local eventOrder = lifecycleEvent.order or 0
    local eventIsNewer = lifecycleEvent.timestamp > readingTimestamp
        or (lifecycleEvent.timestamp == readingTimestamp and eventOrder > readingOrder)

    if not eventIsNewer then
        return { isDisconnected = false }
    end

    local disconnectAgeSeconds = os.difftime(os.time(), lifecycleEvent.timestamp)
    if disconnectAgeSeconds < math.max(0, settings.disconnectDebounceSeconds or 0) then
        return { isDisconnected = false }
    end

    return {
        isDisconnected = true,
        timestamp = lifecycleEvent.timestamp,
        timestampText = lifecycleEvent.timestampText or FormatExactTimestamp(lifecycleEvent.timestamp),
    }
end

function SetChargeBoltState(isVisible, force)
    if isVisible then
        local color = "74,222,128,255"
        local visibilityChanged = state.boltHidden or force
        local colorChanged = force or color ~= state.lastBoltColor

        state.boltHidden = false
        state.lastBoltColor = color
        SetVariable("ChargeBoltHidden", "0")
        SetVariable("ChargeBoltColor", color)

        if visibilityChanged or colorChanged then
            RefreshChargeBolt()
        end
    else
        if (not state.boltHidden) or force then
            state.boltHidden = true
            state.lastBoltColor = ""
            SetVariable("ChargeBoltHidden", "1")
            SetVariable("ChargeBoltColor", "74,222,128,0")
            RefreshChargeBolt()
        end
    end
end

function SetStaleMarkState(isVisible, force)
    if isVisible then
        local color = palette.stale
        local visibilityChanged = state.staleHidden or force
        local colorChanged = force or color ~= state.lastStaleColor

        state.staleHidden = false
        state.lastStaleColor = color
        SetVariable("StaleMarkHidden", "0")
        SetVariable("StaleMarkColor", color)

        if visibilityChanged or colorChanged then
            RefreshStaleMark()
        end
    else
        if (not state.staleHidden) or force then
            state.staleHidden = true
            state.lastStaleColor = ""
            SetVariable("StaleMarkHidden", "1")
            SetVariable("StaleMarkColor", "251,191,36,0")
            RefreshStaleMark()
        end
    end
end

function RefreshChargeBolt()
    SKIN:Bang("!UpdateMeter", "MeterChargeBolt")
    SKIN:Bang("!Redraw")
end

function RefreshStaleMark()
    SKIN:Bang("!UpdateMeter", "MeterStaleMark")
    SKIN:Bang("!Redraw")
end

function ReadTail(path, tailBytes)
    if not path or path == "" then
        return nil
    end

    local file = io.open(path, "rb")
    if not file then
        return nil
    end

    local size = file:seek("end")
    if not size then
        file:close()
        return nil
    end

    local startPos = 0
    if size > tailBytes then
        startPos = size - tailBytes
    end

    file:seek("set", startPos)
    local content = file:read("*a")
    file:close()
    return content
end

function IsTimestampLine(line)
    return line:match("^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d") ~= nil
end

function ParseTimestamp(line)
    local year, month, day, hour, min, sec = line:match("^(%d%d%d%d)%-(%d%d)%-(%d%d) (%d%d):(%d%d):(%d%d)")
    if not year then
        return nil
    end

    return os.time({
        year = tonumber(year),
        month = tonumber(month),
        day = tonumber(day),
        hour = tonumber(hour),
        min = tonumber(min),
        sec = tonumber(sec),
    })
end

function GetAgeMinutes(timestamp)
    if not timestamp then
        return nil
    end

    local seconds = os.difftime(os.time(), timestamp)
    if seconds < 0 then
        return 0
    end

    return math.floor(seconds / 60)
end

function BuildAgeText(ageMinutes, staleMinutes)
    if not ageMinutes then
        return "Synapse time unknown", false
    end

    local suffix = ageMinutes >= staleMinutes and " (stale)" or ""
    local isStale = ageMinutes >= staleMinutes

    if ageMinutes < 1 then
        return "Synapse just updated" .. suffix, isStale
    end

    if ageMinutes < 60 then
        return string.format("Synapse %dm ago%s", ageMinutes, suffix), isStale
    end

    local hours = math.floor(ageMinutes / 60)
    if ageMinutes < 1440 then
        local minutes = ageMinutes % 60
        if minutes == 0 then
            return string.format("Synapse %dh ago%s", hours, suffix), isStale
        end

        return string.format("Synapse %dh %dm ago%s", hours, minutes, suffix), isStale
    end

    local days = math.floor(ageMinutes / 1440)
    local remHours = math.floor((ageMinutes % 1440) / 60)
    if remHours == 0 then
        return string.format("Synapse %dd ago%s", days, suffix), isStale
    end

    return string.format("Synapse %dd %dh ago%s", days, remHours, suffix), isStale
end

function PickBatteryColor(percent, batteryState)
    local normalizedState = string.lower(batteryState or "")
    if normalizedState == "charging" or normalizedState == "fullycharged" then
        return palette.good
    end

    if percent <= settings.redThreshold then
        return palette.low
    end

    if percent <= settings.orangeThreshold then
        return palette.orange
    end

    if percent <= settings.yellowThreshold then
        return palette.warn
    end

    return palette.good
end

function IsChargingState(batteryState)
    local normalizedState = string.lower(batteryState or "")
    return normalizedState == "charging"
end

function HumanizeBatteryState(input)
    if not input or input == "" then
        return "Unknown"
    end

    local withSpaces = input:gsub("(%l)(%u)", "%1 %2")
    local first = withSpaces:sub(1, 1):upper()
    return first .. withSpaces:sub(2)
end

function FormatExactTimestamp(timestamp)
    return os.date("%Y-%m-%d %H:%M", timestamp)
end

function ResolvePathVariable(value, fallback)
    if value and value ~= "" and not value:find("#", 1, true) then
        return value
    end

    return fallback or ""
end

function Midpoint(minValue, maxValue)
    if maxValue < minValue then
        return minValue
    end

    return math.floor((minValue + maxValue) / 2)
end

function Clamp(value, minValue, maxValue)
    if value < minValue then
        return minValue
    end

    if value > maxValue then
        return maxValue
    end

    return value
end
