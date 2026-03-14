-- Weather.lua (RW_Weather)
-- Modulo principale di integrazione di RealisticWeather con il sistema meteo di FS25.
-- Estende il ciclo di aggiornamento del Weather con logica custom per:
--   - Blizzard: forza temperature estreme (−15/−8°C) e accumulo extra di neve
--   - Siccità (draught): forza temperature elevate (30/50°C) durante i periodi secchi
--   - Grandine: applica usura e danni proporzionali ai veicoli scoperti
--   - Balle: degrada il fillLevel di balle non avvolte esposte a pioggia/neve
--   - Umidità: calcola moistureDelta ogni tick in base a precipitazioni e temperatura
--     (scalato per ore diurne/notturne) e lo propaga a moistureSystem e grassMoistureSystem
--   - Tracce animali nella neve: compatta il manto nevoso sotto gli animali in movimento
--
-- Hook registrati:
--   Weather.update              (overwrite) → RW_Weather.update
--   Weather.fillWeatherForecast (overwrite) → RW_Weather.fillWeatherForecast
--   Weather.randomizeFog        (overwrite) → RW_Weather.randomizeFog
--   Weather.sendInitialState    (overwrite) → RW_Weather.sendInitialState
--   Weather.setInitialState     (overwrite) → RW_Weather.setInitialState
--   Weather.saveToXMLFile       (append)    → RW_Weather.saveToXMLFile
--   Weather.loadFromXMLFile     (prepend)   → RW_Weather.loadFromXMLFile
--
-- Costanti:
--   SNOW_FACTOR = 0.0005         → incremento neve per tick durante blizzard
--   SNOW_HEIGHT = 1.0            → altezza massima neve aggiuntiva blizzard
--   MAX_ANIMALS_SINK = 100       → numero massimo di animali processati per batch
--   BLIZZARD_EXTRA_MULTIPLIER = 9 → moltiplicatore accumulo neve blizzard
--   WEATHER_TIME_SCALE_DENOMINATOR = 100000 → normalizzatore timescale per formule

RW_Weather = {}
RW_Weather.FACTOR =
{
    SNOW_FACTOR = 0.0005,       -- incremento base di snowHeight per tick durante blizzard
    SNOW_HEIGHT = 1.0,          -- limite massimo di snowHeight aggiuntivo (1 metro)
    MAX_ANIMALS_SINK = 100      -- massimo animali processati per batch di compattazione neve
}

RW_Weather.isRealisticLivestockLoaded = false  -- flag compatibilità FS25_RealisticLivestock
Weather.blizzardsEnabled = true                -- abilita/disabilita la logica blizzard
Weather.droughtsEnabled = true                 -- abilita/disabilita la logica siccità

local animalStepCount = 0                       -- contatore tick tra un batch di compattazione e il successivo
local animalsToSink = 10                        -- numero di animali nel batch corrente (aggiornato dinamicamente)
local animalIdToPos = {}                        -- cache posizioni precedenti degli animali per rilevare il movimento
local profile = Utils.getPerformanceClassId()   -- classe grafica (1-6): usata per abilitare le tracce animali solo su profili alti
local RW_WEATHER_ORIGINAL_UPDATE = Weather.update  -- riferimento alla funzione originale per il fallback in pcall
local WEATHER_TIME_SCALE_DENOMINATOR = 100000
local BLIZZARD_EXTRA_MULTIPLIER = 9


-- Funzione locale: compatta il manto nevoso sotto gli animali in movimento.
-- Viene chiamata ogni RW_Weather.update se ci sono precipitazioni.
-- Attiva solo su profilo grafico >= 4 e se la neve è abilitata e presente.
-- Processa al massimo MAX_ANIMALS_SINK animali per batch, poi attende
-- il prossimo batch (quando animalStepCount raggiunge la soglia).
--
-- Supporta due modalità di accesso agli animali:
--   - RealisticLivestock caricato: usa husbandry.husbandryIds e animalIdToCluster
--   - Vanilla: usa husbandry.husbandryId e animalIdToCluster direttamente
--
-- Per ogni animale che si è mosso rispetto alla posizione precedente e si trova
-- all'aperto, riduce la neve nella cella sottostante del 25% (× 0.75).
-- @param self        istanza Weather
-- @param indoorMask  maschera delle aree coperte (per escludere animali al chiuso)
local function updateAnimalSnowTracks(self, indoorMask)
    -- Condizioni di skip: profilo basso, neve disabilitata o manto troppo sottile.
    if profile < 4 or not g_currentMission.missionInfo.isSnowEnabled or self.snowHeight <= SnowSystem.MIN_LAYER_HEIGHT then
        return
    end
    -- Attende che il contatore raggiunga la soglia adattiva (min 100, max 500).
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
                -- Modalità RealisticLivestock: accesso tramite husbandryIds e animalIdToCluster.
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

                        -- Compatta la neve solo se l'animale si è mosso e la neve è significativa.
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
                -- Modalità vanilla: accesso diretto tramite husbandry.husbandryId.
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


-- Override di Weather.update. Chiamato ogni frame del gioco.
-- Struttura con doppio pcall per isolamento degli errori:
--   1. pcall sull'update base di FS (fallback sicuro in caso di errore critico)
--   2. pcall sulla logica custom RW (un errore custom non blocca il meteo base)
--
-- Pipeline logica custom (in ordine):
--   a) Blizzard: se il tempo corrente è blizzard e la temperatura è troppo alta,
--      forza valori estremi al temperatureUpdater.
--      Accumula snowHeight extra (SNOW_FACTOR × timescale × snowFallScale × BLIZZARD_EXTRA_MULTIPLIER).
--   b) Siccità: se isDraught e temperatura troppo bassa, forza valori caldi.
--   c) Grandine: per ogni veicolo scoperti, applica wear (×0.0018) e damage (×0.0006).
--   d) Balle: degrada fillLevel di balle non avvolte in SILAGE/GRASS/DRYGRASS.
--      Perdita: (rainfall + snowfall×0.4) × 0.0001 × timescale.
--   e) moistureDelta: calcolato come somma di gain (pioggia+neve+grandine) meno loss (temperatura).
--      Formula gain: clamp((rainfall + snowfall×0.75 + hailfall×0.15) × 0.009 × (ts/100000), 0, 0.00005)
--      Formula loss per temperatura (scalata per sunFactor e draughtFactor):
--        temp >= 45: × 0.000012
--        temp >= 35: × 0.0000088
--        temp >= 25: × 0.0000038
--        temp >= 15: × 0.0000012
--        temp >  0:  × 0.0000005
--      sunFactor = 1 nelle ore diurne, 0.33 di notte.
--   f) Propaga moistureDelta a grassMoistureSystem e moistureSystem.
--   g) updateAnimalSnowTracks per compattare la neve sotto gli animali.
function RW_Weather:update(superFunc, dT)
    -- RW_CRITICAL_FIX: call base GIANTS update first and keep fallback safety
    local okBase = pcall(RW_WEATHER_ORIGINAL_UPDATE or superFunc, self, dT)
    if not okBase then return end

    local okCustom = pcall(function()
        local timescale = dT * g_currentMission:getEffectiveTimeScale()
        local _, currentWeather = self.forecast:dataForTime(self.owner.currentMonotonicDay, self.owner.dayTime)
        local minTemp, maxTemp = self.temperatureUpdater:getCurrentValues()

        -- Blizzard: forza temperature glaciali se quelle correnti sono troppo alte.
        if currentWeather ~= nil and currentWeather.isBlizzard and self.blizzardsEnabled and (maxTemp > 0 or minTemp > -8) then
            minTemp = math.random(-15, -8)
            maxTemp = math.random(minTemp + 3, minTemp + 8)
            self.temperatureUpdater:setTargetValues(minTemp, maxTemp, true)
        end

        -- Siccità: forza temperature elevate se quelle correnti sono troppo basse.
        if currentWeather ~= nil and currentWeather.isDraught and self.droughtsEnabled and (maxTemp < 35 or minTemp < 30) then
            minTemp = math.random(30, 35)
            maxTemp = math.random(minTemp + 5, minTemp + 15)
            self.temperatureUpdater:setTargetValues(minTemp, maxTemp, true)
        end

        -- RW_COMPAT_FIX: additive snow extension without overriding SnowSystem.MAX_HEIGHT globally
        self.isBlizzard = currentWeather ~= nil and currentWeather.isBlizzard and self.blizzardsEnabled
        if g_currentMission.missionInfo.isSnowEnabled and self:getIsSnowing() and self.isBlizzard then
            local temperature = self.temperatureUpdater:getTemperatureAtTime(self.owner.dayTime)
            -- Accumula neve extra solo se la temperatura è sotto 10°C.
            if temperature < 10 then
                local extraSnow = RW_Weather.FACTOR.SNOW_FACTOR * (timescale / WEATHER_TIME_SCALE_DENOMINATOR) * self:getSnowFallScale() * BLIZZARD_EXTRA_MULTIPLIER
                self.snowHeight = math.clamp(self.snowHeight + extraSnow, 0, RW_Weather.FACTOR.SNOW_HEIGHT)
                g_currentMission.snowSystem:setSnowHeight(self.snowHeight)
            end
        end

        local indoorMask = g_currentMission.indoorMask
        local hail = self:getHailFallScale()
        -- Grandine: applica usura e danni a tutti i veicoli scoperti.
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
        -- Balle all'aperto: riduce il fillLevel sotto pioggia e neve.
        -- Colpite: SILAGE, GRASS_WINDROW, DRYGRASS_WINDROW non avvolte (wrappingState == 0).
        if rainfall > 0 or snowfall > 0 then
            local items = g_currentMission.itemSystem.itemByUniqueId
            local balesToDelete = {}
            for _, item in pairs(items) do
                if g_currentMission.objectsToClassName[item] == "Bale" and item.fillLevel ~= nil and item.nodeId ~= 0 and item.wrappingState == 0 and (item.fillType == FillType.SILAGE or item.fillType == FillType.GRASS_WINDROW or item.fillType == FillType.DRYGRASS_WINDROW) then
                    local x, _, z = getWorldTranslation(item.nodeId)
                    if indoorMask:getIsIndoorAtWorldPosition(x, z) then continue end
                    -- La neve degrada il 40% rispetto alla pioggia.
                    item.fillLevel = math.max(item.fillLevel - (rainfall + (snowfall * 0.4)) * 0.0001 * timescale, 0)
                    if item.fillLevel <= 0 then table.insert(balesToDelete, item) end
                end
            end
            for i = #balesToDelete, 1, -1 do balesToDelete[i]:delete() end
        end

        -- Calcolo moistureDelta: bilancio tra gain (precipitazioni) e loss (temperatura).
        local draughtFactor = currentWeather ~= nil and currentWeather.isDraught and self.droughtsEnabled and 1.33 or 1
        local temp = self.temperatureUpdater:getTemperatureAtTime(self.owner.dayTime)
        local hour = math.floor(self.owner:getMinuteOfDay() / 60)
        local daylightStart, dayLightEnd, _, _ = self.owner.daylight:getDaylightTimes()
        local moistureSystem = g_currentMission.moistureSystem
        -- Gain da precipitazioni: clampato a 0.00005 per tick.
        local moistureDelta = math.clamp((rainfall + snowfall * 0.75 + hailfall * 0.15) * 0.009 * (timescale / 100000), 0, 0.00005) * moistureSystem.moistureGainModifier
        -- sunFactor: riduce la perdita notturna al 33%.
        local sunFactor = (hour >= daylightStart and hour < dayLightEnd and 1) or 0.33

        -- Loss per evapotraspirazione: scala con temperatura, luce solare e siccità.
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

        -- Propaga il delta a erba sfalciata e alla griglia di umidità terreno.
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


-- Override di Weather.fillWeatherForecast.
-- Estende la generazione del forecast meteo con eventi speciali RW:
--   - Blizzard (probabilità 1.5%): solo durante neve, solo se neve abilitata.
--     Forza temperatura −15/−8°C sull'oggetto meteo e imposta isBlizzard=true.
--   - Siccità (probabilità 1.5%): solo durante sole in estate (season == 2).
--     Forza temperatura 30/50°C, vento basso (0-2 m/s), pioggia a 0.
-- Dopo la generazione, trasmette i nuovi oggetti ai client tramite WeatherAddObjectEvent.
function RW_Weather:fillWeatherForecast(_, isInitialSync)
    self:updateAvailableWeatherObjects()

    local lastItem = self.forecastItems[#self.forecastItems]
    local maxNumOfforecastItemsItems = 2 ^ Weather.SEND_BITS_NUM_OBJECTS - 1
    local newObjects = {}

    -- Genera nuovi oggetti finché il forecast non copre almeno 9 giorni futuri.
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

        -- Blizzard: 1.5% di probabilità durante eventi nevosi con neve abilitata.
        if g_currentMission.missionInfo.isSnowEnabled and self.blizzardsEnabled and object.weatherType == WeatherType.SNOW and math.random() >= 0.985 then

            newObject.isBlizzard = true
            local minTemp = math.random(-15, -8)
            local maxTemp = math.random(minTemp + 3, minTemp + 8)
            object.temperatureUpdater:setTargetValues(minTemp, maxTemp, false)

        end

        -- Siccità: 1.5% di probabilità durante sole estivo (season == 2) con siccità abilitata.
        if object.weatherType == WeatherType.SUN and self.droughtsEnabled and object.season == 2 and math.random() >= 0.985 then

            newObject.isDraught = true
            local minTemp = math.random(30, 35)
            local maxTemp = math.random(minTemp + 5, minTemp + 15)
            object.temperatureUpdater:setTargetValues(minTemp, maxTemp, false)

            -- Vento basso e nessuna pioggia durante la siccità.
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


-- Override di Weather.randomizeFog.
-- Genera la nebbia giornaliera con parametri randomizzati, rispettando la regola
-- che la nebbia densa non si ripete due giorni consecutivi (lastFogDay).
-- Solo sul server; in estate (season == 2) non genera nebbia (seasonToFog == nil).
-- Con probabilità 8% (math.random() >= 0.92): genera nebbia densa con:
--   groundFogCoverageEdge: 5-10% / 90-95%
--   groundFogExtraHeight: 25-35m
--   densità terreno e altezza: randomizzate in range realistici
--   weatherTypes attivi: SNOW e RAIN
-- Aggiorna lastFogDay e chiama fogUpdater:setTargetFog() con la nebbia generata.
-- @param time  durata della transizione nebbia (passata a setTargetFog)
function RW_Weather:randomizeFog(_, time)
    
    if not g_currentMission:getIsServer() then return end

    local season = self.owner.currentSeason
    local seasonToFog = self.seasonToFog[season]

    local currentDay = g_currentMission.environment.currentMonotonicDay

    local fog

    self.lastFogDay = self.lastFogDay or 0

    -- Nessuna nebbia se non configurata per la stagione o se ieri c'era già nebbia.
    if seasonToFog == nil or currentDay == self.lastFogDay + 1 then
        fog = nil
    else
        fog = seasonToFog:createFromTemplate()

        -- 8% di probabilità di nebbia densa (esclusa l'estate).
        if season ~= 2 and math.random() >= 0.92 then

            fog.groundFogCoverageEdge0 = math.random(5, 10) / 100
            fog.groundFogCoverageEdge1 = math.random(90, 95) / 100
            fog.groundFogExtraHeight = math.random(25, 35)
            fog.groundFogGroundLevelDensity = math.random(85, 200) / 100
            fog.heightFogMaxHeight = math.random(650, 800)
            fog.heightFogGroundLevelDensity = math.random(75, 190) / 100
            fog.groundFogEndDayTimeMinutes = math.min(math.random(fog.groundFogStartDayTimeMinutes + 120, fog.groundFogStartDayTimeMinutes + 860), 1439)

            -- La nebbia è visibile durante neve e pioggia.
            fog.groundFogWeatherTypes[WeatherType.SNOW] = true
            fog.groundFogWeatherTypes[WeatherType.RAIN] = true

            self.lastFogDay = currentDay

        end
    end

    self.fogUpdater:setTargetFog(fog, time)

end

Weather.randomizeFog = Utils.overwrittenFunction(Weather.randomizeFog, RW_Weather.randomizeFog)


-- Override di Weather.sendInitialState.
-- Chiamato quando un client si connette: trasmette in sequenza:
--   1. WeatherStateEvent: snowHeight, timeSinceLastRain, stato completo del moistureSystem
--      (griglia celle, fields in irrigazione, lastFogDay)
--   2. WeatherAddObjectEvent: tutti i forecastItems correnti (isInitialSync=true)
--   3. FogStateEvent: stato corrente del fogUpdater
-- @param connection  connessione del client che si connette
function RW_Weather:sendInitialState(_, connection)

    local moistureSystem = g_currentMission.moistureSystem

    connection:sendEvent(WeatherStateEvent.new(self.snowHeight, self.timeSinceLastRain, moistureSystem.cellWidth, moistureSystem.cellHeight, moistureSystem.mapWidth, moistureSystem.mapHeight, moistureSystem.currentHourlyUpdateQuarter, moistureSystem.numRows, moistureSystem.numColumns, moistureSystem.rows, moistureSystem.irrigatingFields, self.lastFogDay))
    connection:sendEvent(WeatherAddObjectEvent.new(self.forecastItems, true, true))
    connection:sendEvent(FogStateEvent.new(self.fogUpdater))

end

Weather.sendInitialState = Utils.overwrittenFunction(Weather.sendInitialState, RW_Weather.sendInitialState)


-- Override di Weather.setInitialState.
-- Chiamato sul client alla ricezione di WeatherStateEvent.
-- Ripristina snowHeight, timeSinceLastRain e lastFogDay ricevuti dal server
-- e sincronizza il sistema neve con la nuova altezza.
function RW_Weather:setInitialState(_, snowHeight, timeSinceLastRain, lastFogDay)

    self.snowHeight = snowHeight
    self.timeSinceLastRain = timeSinceLastRain
    self.lastFogDay = lastFogDay

    g_currentMission.snowSystem:setSnowHeight(self.snowHeight)

end

Weather.setInitialState = Utils.overwrittenFunction(Weather.setInitialState, RW_Weather.setInitialState)


-- Hook append su Weather.saveToXMLFile.
-- Salva lastFogDay nel file XML del savegame per mantenere la regola
-- anti-nebbia-consecutiva tra sessioni di gioco.
function RW_Weather:saveToXMLFile(handle, key)

    local xmlFile = XMLFile.wrap(handle)

    if xmlFile == nil then return end

    xmlFile:setInt(key .. "#lastFogDay", self.lastFogDay or 0)
    xmlFile:save(false, true)

    xmlFile:delete()

end

Weather.saveToXMLFile = Utils.appendedFunction(Weather.saveToXMLFile, RW_Weather.saveToXMLFile)


-- Hook prepend su Weather.loadFromXMLFile.
-- Carica lastFogDay dal savegame prima che la funzione base carichi il resto del meteo.
function RW_Weather:loadFromXMLFile(handle, key)

    local xmlFile = XMLFile.wrap(handle)

    if xmlFile == nil then return end

    self.lastFogDay = xmlFile:getInt(key .. "#lastFogDay", 0)

    xmlFile:delete()

end

Weather.loadFromXMLFile = Utils.prependedFunction(Weather.loadFromXMLFile, RW_Weather.loadFromXMLFile)


-- Callback per il cambio delle impostazioni (chiamato da RWSettings).
-- Aggiorna blizzardsEnabled o droughtsEnabled direttamente sulla classe Weather.
-- @param name   nome del campo (es. "blizzardsEnabled")
-- @param state  nuovo valore booleano
function RW_Weather.onSettingChanged(name, state)
    Weather[name] = state
end
