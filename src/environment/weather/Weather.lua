RW_Weather = {}
RW_Weather.FACTOR =
{
    SNOW_FACTOR = 0.0005,
    SNOW_HEIGHT = 1.0,
    MAX_ANIMALS_SINK = 100
}

RW_Weather.isRealisticLivestockLoaded = false
Weather.blizzardsEnabled = true
Weather.droughtsEnabled = true

local animalStepCount = 0
local animalsToSink = 10
local animalIdToPos = {}
local profile = Utils.getPerformanceClassId()
local RW_WEATHER_ORIGINAL_UPDATE = Weather.update
local WEATHER_TIME_SCALE_DENOMINATOR = 100000
local BLIZZARD_EXTRA_MULTIPLIER = 9

local function updateAnimalSnowTracks(self, indoorMask)
    if profile < 4 or not g_currentMission.missionInfo.isSnowEnabled or self.snowHeight <= SnowSystem.MIN_LAYER_HEIGHT then
        return
    end
    if animalStepCount < math.min(math.max(100, animalsToSink * 4), 500) then
        return
    end

    animalsToSink = 0

    local husbandries = g_currentMission.husbandrySystem.clusterHusbandries
    if husbandries ~= nil then
        local snowSystem = g_currentMission.snowSystem
        local animalsSunk = 0

        for _, husbandry in pairs(husbandries) do
            if RW_Weather.isRealisticLivestockLoaded then
                local husbandryIds = husbandry.husbandryIds or {}

                for i, animalIds in pairs(husbandry.animalIdToCluster) do
                    animalsToSink = animalsToSink + #animalIds
                    if animalIdToPos[husbandryIds[i]] == nil then animalIdToPos[husbandryIds[i]] = {} end

                    for animalId, _ in pairs(animalIds) do
                        local x, _, z = getAnimalPosition(husbandryIds[i], animalId)
                        if indoorMask:getIsIndoorAtWorldPosition(x, z) then continue end
                        local heightUnderAnimal = snowSystem:getSnowHeightAtArea(x, z, x + 1, z + 1, x - 1, z - 1)

                        local oldX, oldZ
                        if animalIdToPos[husbandryIds[i]][animalId] ~= nil then
                            oldX = animalIdToPos[husbandryIds[i]][animalId].x
                            oldZ = animalIdToPos[husbandryIds[i]][animalId].z
                        else
                            animalIdToPos[husbandryIds[i]][animalId] = {}
                        end

                        if heightUnderAnimal > 0.05 and (oldX ~= x or oldZ ~= z) then
                            snowSystem:setSnowHeightAtArea(x, z, x + 1, z + 1, x - 1, z - 1, heightUnderAnimal * 0.75)
                        end

                        animalsSunk = animalsSunk + 1
                        animalIdToPos[husbandryIds[i]][animalId].x = x
                        animalIdToPos[husbandryIds[i]][animalId].z = z

                        if animalsSunk >= RW_Weather.FACTOR.MAX_ANIMALS_SINK then break end
                    end

                    if animalsSunk >= RW_Weather.FACTOR.MAX_ANIMALS_SINK then break end
                end
            else
                animalsToSink = animalsToSink + #husbandry.animalIdToCluster
                if animalIdToPos[husbandry.husbandryId] == nil then animalIdToPos[husbandry.husbandryId] = {} end

                for animalId, _ in pairs(husbandry.animalIdToCluster) do
                    local x, _, z = getAnimalPosition(husbandry.husbandryId, animalId)
                    if indoorMask:getIsIndoorAtWorldPosition(x, z) then continue end
                    local heightUnderAnimal = snowSystem:getSnowHeightAtArea(x, z, x + 1, z + 1, x - 1, z - 1)

                    local oldX, oldZ
                    if animalIdToPos[husbandry.husbandryId][animalId] ~= nil then
                        oldX = animalIdToPos[husbandry.husbandryId][animalId].x
                        oldZ = animalIdToPos[husbandry.husbandryId][animalId].z
                    else
                        animalIdToPos[husbandry.husbandryId][animalId] = {}
                    end

                    if heightUnderAnimal > 0.05 and (oldX ~= x or oldZ ~= z) then
                        snowSystem:setSnowHeightAtArea(x, z, x + 1, z + 1, x - 1, z - 1, heightUnderAnimal * 0.75)
                    end

                    animalsSunk = animalsSunk + 1
                    animalIdToPos[husbandry.husbandryId][animalId].x = x
                    animalIdToPos[husbandry.husbandryId][animalId].z = z

                    if animalsSunk >= RW_Weather.FACTOR.MAX_ANIMALS_SINK then break end
                end
            end

            if animalsSunk >= RW_Weather.FACTOR.MAX_ANIMALS_SINK then break end
        end
    end

    animalStepCount = 0
end


function RW_Weather:update(superFunc, dT)
    -- RW_CRITICAL_FIX: call base GIANTS update first and keep fallback safety
    local okBase = pcall(RW_WEATHER_ORIGINAL_UPDATE or superFunc, self, dT)
    if not okBase then return end

    local okCustom = pcall(function()
        local timescale = dT * g_currentMission:getEffectiveTimeScale()
        local _, currentWeather = self.forecast:dataForTime(self.owner.currentMonotonicDay, self.owner.dayTime)
        local minTemp, maxTemp = self.temperatureUpdater:getCurrentValues()

        if currentWeather ~= nil and currentWeather.isBlizzard and self.blizzardsEnabled and (maxTemp > 0 or minTemp > -8) then
            minTemp = math.random(-15, -8)
            maxTemp = math.random(minTemp + 3, minTemp + 8)
            self.temperatureUpdater:setTargetValues(minTemp, maxTemp, true)
        end

        if currentWeather ~= nil and currentWeather.isDraught and self.droughtsEnabled and (maxTemp < 35 or minTemp < 30) then
            minTemp = math.random(30, 35)
            maxTemp = math.random(minTemp + 5, minTemp + 15)
            self.temperatureUpdater:setTargetValues(minTemp, maxTemp, true)
        end

        -- RW_COMPAT_FIX: additive snow extension without overriding SnowSystem.MAX_HEIGHT globally
        self.isBlizzard = currentWeather ~= nil and currentWeather.isBlizzard and self.blizzardsEnabled
        if g_currentMission.missionInfo.isSnowEnabled and self:getIsSnowing() and self.isBlizzard then
            local temperature = self.temperatureUpdater:getTemperatureAtTime(self.owner.dayTime)
            if temperature < 10 then
                local extraSnow = RW_Weather.FACTOR.SNOW_FACTOR * (timescale / WEATHER_TIME_SCALE_DENOMINATOR) * self:getSnowFallScale() * BLIZZARD_EXTRA_MULTIPLIER
                self.snowHeight = math.clamp(self.snowHeight + extraSnow, 0, RW_Weather.FACTOR.SNOW_HEIGHT)
                g_currentMission.snowSystem:setSnowHeight(self.snowHeight)
            end
        end

        local indoorMask = g_currentMission.indoorMask
        local hail = self:getHailFallScale()
        if hail > 0 then
            local vehicles = g_currentMission.vehicleSystem.vehicles
            for _, vehicle in pairs(vehicles) do
                local wearable = vehicle.spec_wearable
                if wearable == nil then continue end
                local x, _, z = getWorldTranslation(vehicle.rootNode)
                if x == nil or z == nil then continue end
                if indoorMask:getIsIndoorAtWorldPosition(x, z) then continue end

                local damageAmount = hail * 0.0006 * (timescale / 100000)
                local wearAmount = hail * 0.0018 * (timescale / 100000)
                wearable:addWearAmount(wearAmount, true)
                wearable:addDamageAmount(damageAmount, true)
            end
        end

        local rainfall = self:getRainFallScale()
        local snowfall = self:getSnowFallScale()
        local hailfall = self:getHailFallScale()
        if rainfall > 0 or snowfall > 0 then
            local items = g_currentMission.itemSystem.itemByUniqueId
            local balesToDelete = {}
            for _, item in pairs(items) do
                if g_currentMission.objectsToClassName[item] == "Bale" and item.fillLevel ~= nil and item.nodeId ~= 0 and item.wrappingState == 0 and (item.fillType == FillType.SILAGE or item.fillType == FillType.GRASS_WINDROW or item.fillType == FillType.DRYGRASS_WINDROW) then
                    local x, _, z = getWorldTranslation(item.nodeId)
                    if indoorMask:getIsIndoorAtWorldPosition(x, z) then continue end
                    item.fillLevel = math.max(item.fillLevel - (rainfall + (snowfall * 0.4)) * 0.0001 * timescale, 0)
                    if item.fillLevel <= 0 then table.insert(balesToDelete, item) end
                end
            end
            for i = #balesToDelete, 1, -1 do balesToDelete[i]:delete() end
        end

        local draughtFactor = currentWeather ~= nil and currentWeather.isDraught and self.droughtsEnabled and 1.33 or 1
        local temp = self.temperatureUpdater:getTemperatureAtTime(self.owner.dayTime)
        local hour = math.floor(self.owner:getMinuteOfDay() / 60)
        local daylightStart, dayLightEnd, _, _ = self.owner.daylight:getDaylightTimes()
        local moistureSystem = g_currentMission.moistureSystem
        local moistureDelta = math.clamp((rainfall + snowfall * 0.75 + hailfall * 0.15) * 0.009 * (timescale / 100000), 0, 0.00005) * moistureSystem.moistureGainModifier
        local sunFactor = (hour >= daylightStart and hour < dayLightEnd and 1) or 0.33

        if temp >= 45 then
            moistureDelta = moistureDelta - (temp * 0.000012 * (timescale / 100000) * sunFactor * draughtFactor) * moistureSystem.moistureLossModifier
        elseif temp >= 35 then
            moistureDelta = moistureDelta - (temp * 0.0000088 * (timescale / 100000) * sunFactor * draughtFactor) * moistureSystem.moistureLossModifier
        elseif temp >= 25 then
            moistureDelta = moistureDelta - (temp * 0.0000038 * (timescale / 100000) * sunFactor * draughtFactor) * moistureSystem.moistureLossModifier
        elseif temp >= 15 then
            moistureDelta = moistureDelta - (temp * 0.0000012 * (timescale / 100000) * sunFactor * draughtFactor) * moistureSystem.moistureLossModifier
        elseif temp > 0 then
            moistureDelta = moistureDelta - (temp * 0.0000005 * (timescale / 100000) * sunFactor * draughtFactor) * moistureSystem.moistureLossModifier
        end

        g_currentMission.grassMoistureSystem:update(moistureDelta)
        moistureSystem:update(moistureDelta, timescale)
        updateAnimalSnowTracks(self, indoorMask)
    end)

    if not okCustom then
        -- RW_CRITICAL_FIX: custom weather extension must never break base weather update
        return
    end
    animalStepCount = animalStepCount + 1

end

Weather.update = Utils.overwrittenFunction(Weather.update, RW_Weather.update)


function RW_Weather:fillWeatherForecast(_, isInitialSync)
    self:updateAvailableWeatherObjects()

    local lastItem = self.forecastItems[#self.forecastItems]
    local maxNumOfforecastItemsItems = 2 ^ Weather.SEND_BITS_NUM_OBJECTS - 1
    local newObjects = {}

    while (lastItem == nil or lastItem.startDay < self.owner.currentMonotonicDay + 9) and #self.forecastItems < maxNumOfforecastItemsItems do

        local startDay = self.owner.currentMonotonicDay
        local startDayTime = self.owner.dayTime

        if lastItem ~= nil then
            startDay = lastItem.startDay
            startDayTime = lastItem.startDayTime + lastItem.duration
        end

        local endDay, endDayTime = self.owner:getDayAndDayTime(startDayTime, startDay)
        local newObject = self:createRandomWeatherInstance(self.owner:getVisualSeasonAtDay(endDay), endDay, endDayTime, false)

        local object = self:getWeatherObjectByIndex(newObject.season, newObject.objectIndex)

        if g_currentMission.missionInfo.isSnowEnabled and self.blizzardsEnabled and object.weatherType == WeatherType.SNOW and math.random() >= 0.985 then

            newObject.isBlizzard = true
            local minTemp = math.random(-15, -8)
            local maxTemp = math.random(minTemp + 3, minTemp + 8)
            object.temperatureUpdater:setTargetValues(minTemp, maxTemp, false)

        end

        if object.weatherType == WeatherType.SUN and self.droughtsEnabled and object.season == 2 and math.random() >= 0.985 then

            newObject.isDraught = true
            local minTemp = math.random(30, 35)
            local maxTemp = math.random(minTemp + 5, minTemp + 15)
            object.temperatureUpdater:setTargetValues(minTemp, maxTemp, false)

            local wind = math.random(0, 200) / 100
            object.windUpdater.targetVelocity = wind

            object.rainUpdater.rainfallScale = 0

        end

        self:addWeatherForecast(newObject)
        table.insert(newObjects, newObject)
        lastItem = self.forecastItems[#self.forecastItems]

    end

    if #newObjects > 0 then g_server:broadcastEvent(WeatherAddObjectEvent.new(newObjects, isInitialSync or false), false) end
end

Weather.fillWeatherForecast = Utils.overwrittenFunction(Weather.fillWeatherForecast, RW_Weather.fillWeatherForecast)


function RW_Weather:randomizeFog(_, time)
    
    if not g_currentMission:getIsServer() then return end

    local season = self.owner.currentSeason
    local seasonToFog = self.seasonToFog[season]

    local currentDay = g_currentMission.environment.currentMonotonicDay

    local fog

    self.lastFogDay = self.lastFogDay or 0

    if seasonToFog == nil or currentDay == self.lastFogDay + 1 then
        fog = nil
    else
        fog = seasonToFog:createFromTemplate()

        if season ~= 2 and math.random() >= 0.92 then

            fog.groundFogCoverageEdge0 = math.random(5, 10) / 100
            fog.groundFogCoverageEdge1 = math.random(90, 95) / 100
            fog.groundFogExtraHeight = math.random(25, 35)
            fog.groundFogGroundLevelDensity = math.random(85, 200) / 100
            fog.heightFogMaxHeight = math.random(650, 800)
            fog.heightFogGroundLevelDensity = math.random(75, 190) / 100
            fog.groundFogEndDayTimeMinutes = math.min(math.random(fog.groundFogStartDayTimeMinutes + 120, fog.groundFogStartDayTimeMinutes + 860), 1439)

            fog.groundFogWeatherTypes[WeatherType.SNOW] = true
            fog.groundFogWeatherTypes[WeatherType.RAIN] = true

            self.lastFogDay = currentDay

        end
    end

    self.fogUpdater:setTargetFog(fog, time)

end

Weather.randomizeFog = Utils.overwrittenFunction(Weather.randomizeFog, RW_Weather.randomizeFog)


function RW_Weather:sendInitialState(_, connection)

    local moistureSystem = g_currentMission.moistureSystem

    connection:sendEvent(WeatherStateEvent.new(self.snowHeight, self.timeSinceLastRain, moistureSystem.cellWidth, moistureSystem.cellHeight, moistureSystem.mapWidth, moistureSystem.mapHeight, moistureSystem.currentHourlyUpdateQuarter, moistureSystem.numRows, moistureSystem.numColumns, moistureSystem.rows, moistureSystem.irrigatingFields, self.lastFogDay))
    connection:sendEvent(WeatherAddObjectEvent.new(self.forecastItems, true, true))
    connection:sendEvent(FogStateEvent.new(self.fogUpdater))

end

Weather.sendInitialState = Utils.overwrittenFunction(Weather.sendInitialState, RW_Weather.sendInitialState)

function RW_Weather:setInitialState(_, snowHeight, timeSinceLastRain, lastFogDay)

    self.snowHeight = snowHeight
    self.timeSinceLastRain = timeSinceLastRain
    self.lastFogDay = lastFogDay

    g_currentMission.snowSystem:setSnowHeight(self.snowHeight)

end

Weather.setInitialState = Utils.overwrittenFunction(Weather.setInitialState, RW_Weather.setInitialState)


function RW_Weather:saveToXMLFile(handle, key)

    local xmlFile = XMLFile.wrap(handle)

    if xmlFile == nil then return end

    xmlFile:setInt(key .. "#lastFogDay", self.lastFogDay or 0)
    xmlFile:save(false, true)

    xmlFile:delete()

end

Weather.saveToXMLFile = Utils.appendedFunction(Weather.saveToXMLFile, RW_Weather.saveToXMLFile)


function RW_Weather:loadFromXMLFile(handle, key)

    local xmlFile = XMLFile.wrap(handle)

    if xmlFile == nil then return end

    self.lastFogDay = xmlFile:getInt(key .. "#lastFogDay", 0)

    xmlFile:delete()

end

Weather.loadFromXMLFile = Utils.prependedFunction(Weather.loadFromXMLFile, RW_Weather.loadFromXMLFile)


function RW_Weather.onSettingChanged(name, state)
    Weather[name] = state
end
