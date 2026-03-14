-- RW_HarvesterDynamics.lua
-- Simulazione dinamica delle mietitrebbie per il mod RealisticWeather.
-- Calcola ogni 500ms (SAMPLE_INTERVAL_MS):
--   - portata istantanea in litri/s (incomingLps) dalla somma delle aree tagliate
--   - umidità combinata: suolo (45%) + coltura PF (40%) + meteo (15%)
--   - capacità di separazione della mietitrebbia in base a potenza e tipo di coltura
--   - loadRatio = portata aggiustata / capacità → overload → clogResistance
--   - speedReductionFactor = 1 - clogResistance*0.65, clampato [0.28, 1]
--   - limite RPM motore proporzionale al clog, applicato a setRpmLimit
-- Trasmette i dati a CVTaddon tramite updateCVTSignal.
-- Hook registrati:
--   Combine.onLoad         → inizializza la spec rwHarvesterDynamics
--   Combine.addCutterArea  → accumula litri e aggiorna fruitTypeIndex per tick
--   Combine.onUpdateTick   → esegue il campionamento ogni SAMPLE_INTERVAL_MS
--   Vehicle.getSpeedLimit  → applica dynamicSpeedLimitKph al limite di velocità

RW_HarvesterDynamics = {}

RW_HarvesterDynamics.MOD_NAME = "RealisticWeather"
RW_HarvesterDynamics.SAMPLE_INTERVAL_MS = 500       -- intervallo di campionamento in ms
RW_HarvesterDynamics.WET_CROP_THRESHOLD = 0.2        -- soglia umidità coltura per "coltura bagnata"

-- Cache della funzione getWorldTranslation per accesso rapido.
local getWorldTranslationFn = rawget(_G, "getWorldTranslation")

-- Accesso sicuro al gestore dei tipi di frutto.
local function getFruitTypeManager()
    return rawget(_G, "g_fruitTypeManager")
end

-- Accesso sicuro al mod PrecisionFarming.
local function getPrecisionFarming()
    return rawget(_G, "g_precisionFarming")
end

-- Clamp locale per evitare dipendenze esterne nei calcoli interni.
local function clamp(value, minValue, maxValue)
    return math.max(minValue, math.min(maxValue, value))
end

-- Funzione di logging interna con prefisso [HarvesterDynamics].
local function rwLog(msg)
    print(string.format("[%s][HarvesterDynamics] %s", RW_HarvesterDynamics.MOD_NAME, tostring(msg)))
end

-- Verifica se il mod PrecisionFarming è attivo e caricato.
local function isPrecisionFarmingActive()
    if getPrecisionFarming() == nil then
        return false
    end

    if RW_FSBaseMission ~= nil and RW_FSBaseMission.isPrecisionFarmingLoaded ~= nil then
        return RW_FSBaseMission.isPrecisionFarmingLoaded == true
    end

    return true
end

-- Restituisce l'ID del campo nella posizione mondo (x, z).
-- @return fieldId numerico, 0 se non disponibile
local function getFieldIdAtWorldPosition(x, z)
    local fieldManager = rawget(_G, "g_fieldManager")
    if fieldManager ~= nil and fieldManager.getFieldIdAtWorldPosition ~= nil then
        local ok, fieldId = pcall(fieldManager.getFieldIdAtWorldPosition, fieldManager, x, z)
        if ok and fieldId ~= nil then
            return fieldId
        end
    end

    return 0
end

-- Legge il fattore di umidità meteo corrente dall'ambiente di missione.
-- Prova in ordine: cropMoisture, humidity, currentRain, rainScale, getIsRaining.
-- @return umidità meteo [0, 1]
local function getWeatherWetnessFactor()
    local mission = rawget(_G, "g_currentMission")
    if mission == nil or mission.environment == nil or mission.environment.weather == nil then
        return 0
    end

    local weather = mission.environment.weather

    if type(weather.cropMoisture) == "number" then
        return clamp(weather.cropMoisture, 0, 1)
    end

    if type(weather.humidity) == "number" then
        return clamp(weather.humidity, 0, 1)
    end

    if type(weather.currentRain) == "number" then
        return clamp(weather.currentRain, 0, 1)
    end

    if type(weather.rainScale) == "number" then
        return clamp(weather.rainScale, 0, 1)
    end

    if weather.getIsRaining ~= nil then
        local ok, isRaining = pcall(weather.getIsRaining, weather)
        if ok and isRaining then
            return 1
        end
    end

    return 0
end

-- Legge l'umidità del suolo sotto la mietitrebbia dal moistureSystem.
-- Prova prima tramite RW_PhysicsCore.ensureMoistureAPI(), poi accesso diretto.
-- @return umidità suolo [0, 1]
local function getSoilMoistureAtVehicle(vehicle)
    local moistureSystem = nil
    if RW_PhysicsCore ~= nil and RW_PhysicsCore.ensureMoistureAPI ~= nil then
        moistureSystem = RW_PhysicsCore.ensureMoistureAPI()
    else
        moistureSystem = g_realisticWeather ~= nil and g_realisticWeather.moistureSystem or nil
        if moistureSystem == nil then
            moistureSystem = g_currentMission ~= nil and g_currentMission.moistureSystem or nil
        end
    end

    if moistureSystem == nil or getWorldTranslationFn == nil or vehicle == nil then
        return 0
    end

    local x, _, z = getWorldTranslationFn(vehicle.rootNode)
    if moistureSystem.getMoistureAtWorldPos ~= nil then
        return clamp(moistureSystem:getMoistureAtWorldPos(x, z) or 0, 0, 1)
    end

    if moistureSystem.getValuesAtCoords ~= nil then
        local values = moistureSystem:getValuesAtCoords(x, z, { "moisture" })
        if values ~= nil and values.moisture ~= nil then
            return clamp(values.moisture, 0, 1)
        end
    end

    return 0
end

-- Restituisce la prima workArea attiva della testata agganciata alla mietitrebbia.
-- Itera sulle testata (attachedCutters) e sulle loro workArea.
local function getActiveCutterWorkArea(combine)
    if combine == nil or combine.spec_combine == nil or combine.spec_combine.attachedCutters == nil then
        return nil
    end

    for cutter, _ in pairs(combine.spec_combine.attachedCutters) do
        if cutter ~= nil and cutter.spec_workArea ~= nil and cutter.spec_workArea.workAreas ~= nil then
            for _, workArea in pairs(cutter.spec_workArea.workAreas) do
                if workArea ~= nil and workArea.start ~= nil and workArea.width ~= nil and workArea.height ~= nil then
                    return workArea
                end
            end
        end
    end

    return nil
end

-- Calcola il centro geometrico della workArea in coordinate mondo.
-- @return x, z del centro (media dei tre punti), o nil, nil se non disponibile
local function getWorkAreaCenter(workArea)
    if workArea == nil or getWorldTranslationFn == nil then
        return nil, nil
    end

    local xs, _, zs = getWorldTranslationFn(workArea.start)
    local xw, _, zw = getWorldTranslationFn(workArea.width)
    local xh, _, zh = getWorldTranslationFn(workArea.height)

    return (xs + xw + xh) / 3, (zs + zw + zh) / 3
end

-- Converte un valore generico in indice di fruitType.
-- Accetta numeri (passthrough), stringhe (lookup per nome) o nil (→ UNKNOWN).
local function toFruitTypeIndex(value)
    if value == nil then
        return FruitType.UNKNOWN
    end

    if type(value) == "number" then
        return value
    end

    if type(value) == "string" then
        local key = string.upper(value)
        local fruitTypeManager = getFruitTypeManager()
        if fruitTypeManager ~= nil and fruitTypeManager.getFruitTypeIndexByName ~= nil then
            local index = fruitTypeManager:getFruitTypeIndexByName(key)
            if index ~= nil then
                return index
            end
        end
    end

    return FruitType.UNKNOWN
end

-- Legge il moltiplicatore di resa del campo dalla posizione mondo tramite PrecisionFarming.
-- Prova prima getYieldMultiplier, poi accede direttamente alla yieldMap.
-- @return moltiplicatore [0.3, 2], default 1 se PF non disponibile
local function getYieldMultiplier(farmId, fieldId, x, z)
    local pf = getPrecisionFarming()
    if pf == nil then
        return 1
    end

    if pf.getYieldMultiplier ~= nil then
        local ok, multiplier = pcall(pf.getYieldMultiplier, pf, farmId, fieldId, x, z)
        if ok and type(multiplier) == "number" then
            return clamp(multiplier, 0.3, 2)
        end
    end

    -- Fallback: accesso diretto alla yieldMap con diversi nomi di metodo.
    local yieldMap = pf.yieldMap
    if yieldMap ~= nil then
        local mapMethods = {
            "getValueAtWorldPos",
            "getValueAtWorldPosition",
            "getValueAtPos",
            "getValueAtPosition"
        }

        for _, methodName in ipairs(mapMethods) do
            if yieldMap[methodName] ~= nil then
                local ok, value = pcall(yieldMap[methodName], yieldMap, x, z)
                if ok and type(value) == "number" then
                    local normalized = value
                    -- Normalizza se il valore è in percentuale (> 3 → divide per 100).
                    if normalized > 3 then
                        normalized = normalized / 100
                    end
                    return clamp(normalized, 0.3, 2)
                end
            end
        end
    end

    return 1
end

-- Legge l'umidità della coltura dal mod PrecisionFarming per il tipo di frutto dato.
-- Prova prima getFruitMoisture direttamente su pf, poi su pf.harvestExtension.
-- @return umidità [0, 1] o nil se PF non fornisce il dato
local function getFruitMoisture(fruitTypeIndex)
    local pf = getPrecisionFarming()
    if pf == nil then
        return nil
    end

    if pf.getFruitMoisture ~= nil then
        local ok, moisture = pcall(pf.getFruitMoisture, pf, fruitTypeIndex)
        if ok and type(moisture) == "number" then
            return clamp(moisture, 0, 1)
        end
    end

    -- Fallback: cerca il metodo in harvestExtension con nomi alternativi.
    if pf.harvestExtension ~= nil then
        local harvestExtension = pf.harvestExtension
        local methods = {
            "getFruitMoisture",
            "getCropMoistureByFruitType"
        }

        for _, methodName in ipairs(methods) do
            if harvestExtension[methodName] ~= nil then
                local ok, moisture = pcall(harvestExtension[methodName], harvestExtension, fruitTypeIndex)
                if ok and type(moisture) == "number" then
                    return clamp(moisture, 0, 1)
                end
            end
        end
    end

    return nil
end

-- Legge un campione completo di dati harvest dalla posizione (x, z) tramite PrecisionFarming.
-- Prova getHarvestDataAtWorldPosition prima, poi singoli metodi per yield, moisture e fruitType.
-- @return tabella { yieldValue, cropMoisture, fruitTypeIndex } o nil se PF non disponibile
local function readPrecisionFarmingSample(x, z)
    local pf = getPrecisionFarming()
    if pf == nil then
        return nil
    end

    local sample = {}

    if pf.getHarvestDataAtWorldPosition ~= nil then
        local ok, data = pcall(pf.getHarvestDataAtWorldPosition, pf, x, z)
        if ok and type(data) == "table" then
            sample.yieldValue = data.yield or data.yieldValue or data.harvestYield
            sample.cropMoisture = data.cropMoisture or data.moisture or data.harvestMoisture
            sample.fruitTypeIndex = toFruitTypeIndex(data.fruitTypeIndex or data.fruitType or data.fruitName)
        end
    end

    -- Fallback per yield se non trovato nel blocco precedente.
    if sample.yieldValue == nil and pf.getYieldAtWorldPosition ~= nil then
        local ok, value = pcall(pf.getYieldAtWorldPosition, pf, x, z)
        if ok and value ~= nil then
            sample.yieldValue = value
        end
    end

    if sample.cropMoisture == nil and pf.getCropMoistureAtWorldPosition ~= nil then
        local ok, value = pcall(pf.getCropMoistureAtWorldPosition, pf, x, z)
        if ok and value ~= nil then
            sample.cropMoisture = value
        end
    end

    if (sample.fruitTypeIndex == nil or sample.fruitTypeIndex == FruitType.UNKNOWN) and pf.getFruitTypeAtWorldPosition ~= nil then
        local ok, value = pcall(pf.getFruitTypeAtWorldPosition, pf, x, z)
        if ok and value ~= nil then
            sample.fruitTypeIndex = toFruitTypeIndex(value)
        end
    end

    sample.cropMoisture = clamp(sample.cropMoisture or 0, 0, 1)

    return sample
end

-- Stima l'umidità della coltura quando PrecisionFarming non è disponibile.
-- Usa la tabella FRUIT_TYPES_MOISTURE di RW_FSBaseMission (range LOW/HIGH per coltura).
-- Formula: media tra umidità suolo e centro del range di umidità tipico per quella coltura.
-- @return umidità stimata [0, 1]
local function getFallbackCropMoisture(fruitTypeIndex, soilMoisture)
    if fruitTypeIndex == nil or fruitTypeIndex == FruitType.UNKNOWN or RW_FSBaseMission == nil then
        return clamp(soilMoisture, 0, 1)
    end

    local fruitTypeManager = getFruitTypeManager()
    local fruitName = fruitTypeManager ~= nil and fruitTypeManager:getFruitTypeNameByIndex(fruitTypeIndex) or nil
    local range = RW_FSBaseMission.FRUIT_TYPES_MOISTURE ~= nil and RW_FSBaseMission.FRUIT_TYPES_MOISTURE[fruitName] or nil
    if range == nil then
        range = RW_FSBaseMission.FRUIT_TYPES_MOISTURE ~= nil and RW_FSBaseMission.FRUIT_TYPES_MOISTURE.DEFAULT or nil
    end

    if range ~= nil and range.LOW ~= nil and range.HIGH ~= nil then
        local center = (range.LOW + range.HIGH) * 0.5
        return clamp((soilMoisture + center) * 0.5, 0, 1)
    end

    return clamp(soilMoisture, 0, 1)
end

-- Calcola la capacità di separazione della mietitrebbia in litri/s.
-- Formula: tonsPerHour = max(8, peakKw * 0.42), litersPerSecond = tonsPerHour * 0.35 * fruitFx
-- Se la coltura è bagnata, la capacità viene ridotta al 70% (straw più pesante, più resistente).
-- fruitFx è letto da fruitDesc.mrCapacityFx se disponibile (fattore specifico per coltura).
-- @return capacità in L/s (minimo 0.25)
local function getHarvesterCapacityLps(combine, fruitTypeIndex, cropWet)
    local peakPowerKw = 0
    if combine.spec_powerConsumer ~= nil and combine.spec_powerConsumer.sourceMotorPeakPower ~= nil then
        peakPowerKw = combine.spec_powerConsumer.sourceMotorPeakPower / 1000
    elseif combine.spec_motorized ~= nil and combine.spec_motorized.motor ~= nil then
        local motor = combine.spec_motorized.motor
        peakPowerKw = (motor.peakMotorPower or 0) / 1000
    end

    local fruitFx = 1
    local fruitTypeManager = getFruitTypeManager()
    if fruitTypeIndex ~= nil and fruitTypeIndex ~= FruitType.UNKNOWN and fruitTypeManager ~= nil then
        local fruitDesc = fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)
        if fruitDesc ~= nil and fruitDesc.mrCapacityFx ~= nil then
            fruitFx = fruitDesc.mrCapacityFx
        end
    end

    local tonsPerHour = math.max(8, peakPowerKw * 0.42)
    local litersPerSecond = tonsPerHour * 0.35 * fruitFx

    if cropWet then
        litersPerSecond = litersPerSecond * 0.7
    end

    return math.max(litersPerSecond, 0.25)
end

-- Calcola il budget di potenza PTO disponibile per la mietitrebbia.
-- Prova in ordine: sourceMotorPeakPower, neededMaxPtoPower, peakMotorPower.
-- @return potenza in kW (minimo 1 kW)
local function getHarvesterPowerBudgetKw(combine)
    local budgetKw = 0

    if combine.spec_powerConsumer ~= nil then
        local specPC = combine.spec_powerConsumer
        if type(specPC.sourceMotorPeakPower) == "number" and specPC.sourceMotorPeakPower < math.huge then
            budgetKw = math.max(budgetKw, specPC.sourceMotorPeakPower / 1000)
        end

        if type(specPC.neededMaxPtoPower) == "number" then
            budgetKw = math.max(budgetKw, specPC.neededMaxPtoPower)
        end
    end

    if combine.spec_motorized ~= nil and combine.spec_motorized.motor ~= nil then
        budgetKw = math.max(budgetKw, (combine.spec_motorized.motor.peakMotorPower or 0) / 1000)
    end

    return math.max(budgetKw, 1)
end

-- Calcola la potenza richiesta dalla mietitrebbia in base al throughputRatio.
-- Usa neededMaxPtoPower se disponibile, altrimenti stima dal budget.
-- @return potenza richiesta in kW (minimo 0)
local function getHarvesterRequiredPowerKw(combine, throughputRatio)
    local requiredKw = 0

    if combine.spec_powerConsumer ~= nil and combine.spec_powerConsumer.neededMaxPtoPower ~= nil then
        requiredKw = combine.spec_powerConsumer.neededMaxPtoPower * math.max(throughputRatio, 0)
    else
        requiredKw = getHarvesterPowerBudgetKw(combine) * math.max(throughputRatio, 0)
    end

    return math.max(requiredKw, 0)
end

-- Trasmette i dati di carico alla spec CVTaddon della mietitrebbia, se presente.
-- Aggiorna: rwHarvesterLoad, rwHarvesterNearClog, rwHarvesterRoar.
-- @param data  tabella con powerLoadRatio, loadRatio, clogResistance, exceedsPowerBudget
local function updateCVTSignal(combine, data)
    if combine.spec_CVTaddon == nil then
        return
    end

    local cvtSpec = combine.spec_CVTaddon
    cvtSpec.rwHarvesterLoad = data.powerLoadRatio or data.loadRatio
    cvtSpec.rwHarvesterNearClog = (data.exceedsPowerBudget == true) or (data.loadRatio > 0.9)
    cvtSpec.rwHarvesterRoar = clamp(data.clogResistance, 0, 1)
end

-- Hook su Combine.onLoad: inizializza la spec rwHarvesterDynamics con tutti i campi di stato.
function RW_HarvesterDynamics.onCombineLoad(combine)
    if combine.spec_combine == nil then
        return
    end

    combine.spec_combine.rwHarvesterDynamics = {
        timer = 0,
        incomingLiters = 0,            -- litri accumulati nell'intervallo corrente
        incomingLps = 0,               -- portata in litri/s calcolata nell'ultimo campionamento
        yieldValue = 0,                -- resa istantanea dal campo (litri/m²)
        yieldMultiplier = 1,           -- moltiplicatore resa da PrecisionFarming
        fruitTypeIndex = FruitType.UNKNOWN,
        soilMoisture = 0,              -- umidità suolo [0, 1]
        cropMoisture = 0,              -- umidità coltura [0, 1]
        combinedMoisture = 0,          -- umidità combinata pesata [0, 1]
        cropWet = false,               -- true se cropMoisture >= WET_CROP_THRESHOLD
        separationCapacityLps = 0.5,   -- capacità separazione in L/s
        loadRatio = 0,                 -- rapporto portata/capacità
        requiredPowerKw = 0,
        powerBudgetKw = 1,
        powerLoadRatio = 0,            -- rapporto potenza richiesta/budget
        exceedsPowerBudget = false,
        clogResistance = 0,            -- resistenza al clog [0, 1.4] (formula exp)
        dynamicSpeedLimitKph = math.huge,
        dynamicRpmLimit = math.huge,
        speedReductionFactor = 1
    }
end

-- Hook su Combine.addCutterArea: accumula i litri raccolti e aggiorna fruitTypeIndex.
-- Viene chiamato ad ogni aggiornamento di area tagliata dalla testata.
function RW_HarvesterDynamics.onCombineAddCutterArea(combine, superFunc, area, liters, inputFruitType, outputFillType, strawRatio, farmId, cutterLoad)
    local delta = superFunc(combine, area, liters, inputFruitType, outputFillType, strawRatio, farmId, cutterLoad)

    local spec = combine.spec_combine
    local dynamics = spec ~= nil and spec.rwHarvesterDynamics or nil
    if dynamics == nil then
        return delta
    end

    if liters ~= nil and liters > 0 then
        dynamics.incomingLiters = dynamics.incomingLiters + liters
        if area ~= nil and area > 0 then
            dynamics.yieldValue = liters / area
        end
    end

    if inputFruitType ~= nil and inputFruitType ~= FruitType.UNKNOWN then
        dynamics.fruitTypeIndex = inputFruitType
    end

    return delta
end

-- Hook su Combine.onUpdateTick: esegue il campionamento ogni SAMPLE_INTERVAL_MS.
-- Pipeline per ogni campionamento:
--   1. Calcola incomingLps dall'accumulatore litri
--   2. Se PF attivo: legge resa, umidità coltura, fruitType e yieldMultiplier dalla posizione
--   3. Legge umidità suolo e umidità coltura (PF o fallback da tabella RW)
--   4. Calcola combinedMoisture = suolo*0.45 + coltura*0.4 + meteo*0.15
--   5. Calcola separationCapacityLps, loadRatio, powerLoadRatio
--   6. clogResistance = clamp((exp(overload*3)-1)/8, 0, 1.4)
--   7. speedReductionFactor = clamp(1 - clogResistance*0.65, 0.28, 1)
--   8. Applica limite RPM al motore e aggiorna debug/CVT
--   Se la mietitrebbia non sta lavorando, azzera tutti i limiti.
function RW_HarvesterDynamics.onCombineUpdateTick(combine, dt)
    if combine.spec_combine == nil or combine.spec_combine.rwHarvesterDynamics == nil then
        return
    end

    local dynamics = combine.spec_combine.rwHarvesterDynamics
    local isWorking = combine:getIsTurnedOn() and combine.spec_combine.lastCuttersAreaTime + 500 > g_currentMission.time

    dynamics.timer = dynamics.timer + dt
    if dynamics.timer < RW_HarvesterDynamics.SAMPLE_INTERVAL_MS then
        return
    end

    local sampleMs = dynamics.timer
    dynamics.timer = 0

    -- Calcola la portata media nell'intervallo di campionamento.
    dynamics.incomingLps = 1000 * dynamics.incomingLiters / math.max(sampleMs, 1)
    dynamics.incomingLiters = 0

    local workArea = getActiveCutterWorkArea(combine)
    local x, z = getWorkAreaCenter(workArea)

    -- Campionamento dati PrecisionFarming se disponibile.
    if isPrecisionFarmingActive() and x ~= nil and z ~= nil then
        local pfSample = readPrecisionFarmingSample(x, z)
        if pfSample ~= nil then
            dynamics.yieldValue = pfSample.yieldValue or dynamics.yieldValue
            if pfSample.fruitTypeIndex ~= nil and pfSample.fruitTypeIndex ~= FruitType.UNKNOWN then
                dynamics.fruitTypeIndex = pfSample.fruitTypeIndex
            end
            dynamics.cropMoisture = pfSample.cropMoisture or dynamics.cropMoisture
        end

        local farmId = combine.getActiveFarm ~= nil and combine:getActiveFarm() or 0
        local fieldId = getFieldIdAtWorldPosition(x, z)
        dynamics.yieldMultiplier = getYieldMultiplier(farmId, fieldId, x, z)
    end

    -- Fallback fruitType: usa l'ultimo tipo tagliato dalla testata se ancora sconosciuto.
    if dynamics.fruitTypeIndex == FruitType.UNKNOWN and combine.spec_combine.lastCuttersInputFruitType ~= nil then
        dynamics.fruitTypeIndex = combine.spec_combine.lastCuttersInputFruitType
    end

    dynamics.soilMoisture = getSoilMoistureAtVehicle(combine)

    -- Umidità coltura: priorità PF, poi fallback da tabella RW, poi umidità suolo.
    local fruitMoisture = getFruitMoisture(dynamics.fruitTypeIndex)
    if fruitMoisture ~= nil then
        dynamics.cropMoisture = fruitMoisture
    elseif dynamics.cropMoisture == 0 then
        dynamics.cropMoisture = getFallbackCropMoisture(dynamics.fruitTypeIndex, dynamics.soilMoisture)
    end

    dynamics.cropMoisture = clamp(dynamics.cropMoisture, 0, 1)

    -- Umidità combinata: media pesata tra suolo, coltura e condizioni meteo.
    local weatherWetness = getWeatherWetnessFactor()
    dynamics.combinedMoisture = clamp(dynamics.soilMoisture * 0.45 + dynamics.cropMoisture * 0.4 + weatherWetness * 0.15, 0, 1)
    dynamics.cropWet = dynamics.cropMoisture >= RW_HarvesterDynamics.WET_CROP_THRESHOLD

    dynamics.separationCapacityLps = getHarvesterCapacityLps(combine, dynamics.fruitTypeIndex, dynamics.cropWet)

    -- adjustedIncomingLps: portata corretta per la resa del campo (campo più produttivo = più carico).
    local adjustedIncomingLps = dynamics.incomingLps * math.max(dynamics.yieldMultiplier, 0.3)
    dynamics.loadRatio = adjustedIncomingLps / math.max(dynamics.separationCapacityLps, 0.01)

    dynamics.requiredPowerKw = getHarvesterRequiredPowerKw(combine, dynamics.loadRatio)
    dynamics.powerBudgetKw = getHarvesterPowerBudgetKw(combine)
    dynamics.powerLoadRatio = dynamics.requiredPowerKw / math.max(dynamics.powerBudgetKw, 0.1)
    dynamics.exceedsPowerBudget = dynamics.requiredPowerKw > dynamics.powerBudgetKw

    -- clogResistance: funzione esponenziale dell'overload per simulare il progressivo intasamento.
    -- overload = max(loadRatio, powerLoadRatio) - 1 (zero se sotto capacità)
    local overload = math.max(math.max(dynamics.loadRatio, dynamics.powerLoadRatio) - 1, 0)
    dynamics.clogResistance = clamp((math.exp(overload * 3) - 1) / 8, 0, 1.4)

    -- Fattore di riduzione velocità: da 1 (nessun clog) a 0.28 (clog massimo).
    dynamics.speedReductionFactor = clamp(1 - dynamics.clogResistance * 0.65, 0.28, 1)
    dynamics.dynamicSpeedLimitKph = 60 * dynamics.speedReductionFactor

    if isWorking then
        -- Limita gli RPM proporzionalmente al clog: più intasata = RPM più bassi.
        local minRpm = combine.spec_motorized ~= nil and combine.spec_motorized.motor ~= nil and combine.spec_motorized.motor.minRpm or 700
        local maxRpm = combine.spec_motorized ~= nil and combine.spec_motorized.motor ~= nil and combine.spec_motorized.motor.maxRpm or 2200
        dynamics.dynamicRpmLimit = minRpm + (maxRpm - minRpm) * clamp(1 - dynamics.clogResistance * 0.5, 0.45, 1)
    else
        -- Se non sta lavorando, azzera tutti i limiti e i dati di carico.
        dynamics.dynamicSpeedLimitKph = math.huge
        dynamics.dynamicRpmLimit = math.huge
        dynamics.loadRatio = 0
        dynamics.powerLoadRatio = 0
        dynamics.requiredPowerKw = 0
        dynamics.exceedsPowerBudget = false
        dynamics.clogResistance = 0
    end

    if combine.spec_motorized ~= nil and combine.spec_motorized.motor ~= nil then
        combine.spec_motorized.motor:setRpmLimit(dynamics.dynamicRpmLimit)
    end

    -- Aggiorna la tabella debug globale.
    if g_realisticWeather ~= nil then
        g_realisticWeather.physicsDebug = g_realisticWeather.physicsDebug or {}
        g_realisticWeather.physicsDebug.harvesterLoadRatio = dynamics.loadRatio
        g_realisticWeather.physicsDebug.harvesterPowerLoadRatio = dynamics.powerLoadRatio
        g_realisticWeather.physicsDebug.harvesterClogResistance = dynamics.clogResistance
        g_realisticWeather.physicsDebug.harvesterCropWet = dynamics.cropWet and 1 or 0
    end

    updateCVTSignal(combine, dynamics)
end

-- Hook su Vehicle.getSpeedLimit: applica dynamicSpeedLimitKph come limite aggiuntivo.
-- Garantisce che la mietitrebbia rallenti automaticamente quando si avvicina all'intasamento.
function RW_HarvesterDynamics.onGetSpeedLimit(vehicle, superFunc, onlyIfWorking)
    local limit, doCheckSpeedLimit = superFunc(vehicle, onlyIfWorking)

    if vehicle ~= nil and vehicle.spec_combine ~= nil and vehicle.spec_combine.rwHarvesterDynamics ~= nil then
        local dynamics = vehicle.spec_combine.rwHarvesterDynamics
        limit = math.min(limit, dynamics.dynamicSpeedLimitKph or math.huge)
    end

    return limit, doCheckSpeedLimit
end

-- Registrazione degli hook sulle funzioni originali di FS.
Combine.onLoad = Utils.appendedFunction(Combine.onLoad, RW_HarvesterDynamics.onCombineLoad)
Combine.addCutterArea = Utils.overwrittenFunction(Combine.addCutterArea, RW_HarvesterDynamics.onCombineAddCutterArea)
Combine.onUpdateTick = Utils.appendedFunction(Combine.onUpdateTick, RW_HarvesterDynamics.onCombineUpdateTick)
Vehicle.getSpeedLimit = Utils.overwrittenFunction(Vehicle.getSpeedLimit, RW_HarvesterDynamics.onGetSpeedLimit)

rwLog("RW_HarvesterDynamics active: PF core-aware bridge, moisture blend and power-based clogging enabled.")
