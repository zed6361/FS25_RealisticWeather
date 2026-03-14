-- RW_PhysicsCore.lua
-- Simulazione fisica realistica per i veicoli motorizzati di Farming Simulator.
-- Calcola resistenza di traino (draft), slittamento ruote, trasferimento di peso,
-- efficienza della trasmissione e consumo carburante realistico in base a:
--   - categoria dell'attrezzo agganciato (aratro, erpice, seminatrice, ecc.)
--   - umidità del terreno sotto il veicolo
--   - velocità, massa, pendenza e carico del motore
-- Trasmette i dati calcolati a VCA e CVTaddon tramite sendCrossModData.
-- Si auto-disabilita se il mod MoreRealistic è attivo, per evitare conflitti fisici.
--
-- Hook registrati:
--   Vehicle.onLoad        → inizializza la spec rwPhysicsCore su ogni veicolo motorizzato
--   Vehicle.onUpdateTick  → esegue computeVehicleLoad ogni TICK_INTERVAL_MS
--   Baler.onLoad          → inizializza il buffer di umidità per la pressa
--   Baler.dropBale        → applica il peso extra dovuto all'umidità alla balla espulsa

RW_PhysicsCore = {}

RW_PhysicsCore.MOD_NAME = "RealisticWeather"
RW_PhysicsCore.SPEC_KEY = "rwPhysicsCore"           -- chiave della spec nel veicolo
RW_PhysicsCore.TICK_INTERVAL_MS = 120               -- intervallo di aggiornamento in millisecondi
RW_PhysicsCore.HEAVY_MASS_THRESHOLD_T = 32          -- soglia in tonnellate per la modalità "veicolo pesante"

-- Cache delle funzioni globali del motore di gioco per accesso rapido e sicuro.
local getWorldTranslationFn = rawget(_G, "getWorldTranslation")
local localDirectionToWorldFn = rawget(_G, "localDirectionToWorld")
local getMassFn = rawget(_G, "getMass")
local setMassFn = rawget(_G, "setMass")
local entityExistsFn = rawget(_G, "entityExists")

-- Funzione di logging interna con prefisso [PhysicsCore].
local function rwLog(msg)
    print(string.format("[%s][PhysicsCore] %s", RW_PhysicsCore.MOD_NAME, tostring(msg)))
end

-- Clamp locale per evitare la dipendenza da math.clamp in tutti i calcoli.
local function clamp(value, minValue, maxValue)
    return math.max(minValue, math.min(maxValue, value))
end

-- Verifica se il mod MoreRealistic è attivo controllando i nomi comuni con cui può essere caricato.
local function isMoreRealisticActive()
    local loadedMods = rawget(_G, "g_modIsLoaded")
    if loadedMods == nil then
        return false
    end

    return loadedMods["morerealistic_25"] == true
        or loadedMods["FS25_moreRealistic"] == true
        or loadedMods["MoreRealistic"] == true
        or loadedMods["FS25_MoreRealistic"] == true
end

-- Restituisce true se il modulo è abilitato (nessun conflitto con MoreRealistic).
function RW_PhysicsCore.isEnabled()
    return not RW_PhysicsCore.disabledByConflict
end

-- Assicura che il moistureSystem esponga il metodo getMoistureAtWorldPos.
-- Se il metodo non esiste (versioni più vecchie del mod), lo aggiunge dinamicamente.
-- Registra anche il riferimento in g_realisticWeather.moistureSystem se mancante.
-- @return il moistureSystem con getMoistureAtWorldPos garantito, o nil se non disponibile
function RW_PhysicsCore.ensureMoistureAPI()
    local moistureSystem = g_realisticWeather ~= nil and g_realisticWeather.moistureSystem or nil
    if moistureSystem == nil then
        moistureSystem = g_currentMission ~= nil and g_currentMission.moistureSystem or nil
    end
    if moistureSystem == nil then
        return nil
    end

    if moistureSystem.getMoistureAtWorldPos == nil then
        function moistureSystem:getMoistureAtWorldPos(x, z)
            if self.getValuesAtCoords == nil then
                return 0
            end

            local values = self:getValuesAtCoords(x, z, { "moisture" })
            if values ~= nil and values.moisture ~= nil then
                return clamp(values.moisture, 0, 1)
            end

            return 0
        end
    end

    if g_realisticWeather ~= nil and g_realisticWeather.moistureSystem == nil then
        g_realisticWeather.moistureSystem = moistureSystem
    end

    return moistureSystem
end

-- Calcola larghezza e profondità di lavoro da un singolo oggetto (attrezzo o veicolo).
-- Itera sulle workArea dell'oggetto e restituisce la somma delle larghezze e la media delle profondità.
-- @return width (m), depth (m)
local function getWorkAreaWidthAndDepthFromObject(object)
    local width = 0
    local depth = 0.15

    if object == nil or object.spec_workArea == nil or object.spec_workArea.workAreas == nil then
        return width, depth
    end

    local count = 0
    for _, workArea in pairs(object.spec_workArea.workAreas) do
        if workArea ~= nil and workArea.start ~= nil and workArea.width ~= nil and workArea.height ~= nil then
            if getWorldTranslationFn == nil then
                break
            end

            local sx, _, sz = getWorldTranslationFn(workArea.start)
            local wx, _, wz = getWorldTranslationFn(workArea.width)
            local hx, _, hz = getWorldTranslationFn(workArea.height)

            local workWidth = MathUtil.vector2Length(wx - sx, wz - sz)
            local workDepth = MathUtil.vector2Length(hx - sx, hz - sz)

            if workWidth > 0 then
                width = width + workWidth
            end
            if workDepth > 0 then
                depth = depth + workDepth
                count = count + 1
            end
        end
    end

    if count > 0 then
        depth = depth / count
    end

    return width, math.max(0.05, depth)
end

-- Raccoglie larghezza totale, profondità media e categoria dell'attrezzo agganciato al veicolo.
-- La categoria è letta da spec_storeItem.storeItem.categoryName dell'attrezzo.
-- @return workWidth (m), workDepth (m), toolCategory (stringa, default "cultivators")
local function getActiveImplementData(vehicle)
    local workWidth = 0
    local workDepth = 0.15
    local toolCategory = "cultivators"

    if vehicle == nil or vehicle.getAttachedImplements == nil then
        return workWidth, workDepth, toolCategory
    end

    local attachedImplements = {}
    vehicle:getAttachedImplements(attachedImplements)

    local depthCount = 0
    for _, attach in ipairs(attachedImplements) do
        local implement = attach.object
        if implement ~= nil then
            local width, depth = getWorkAreaWidthAndDepthFromObject(implement)
            workWidth = workWidth + width
            if depth > 0 then
                workDepth = workDepth + depth
                depthCount = depthCount + 1
            end

            if implement.spec_storeItem ~= nil and implement.spec_storeItem.storeItem ~= nil then
                local categoryName = implement.spec_storeItem.storeItem.categoryName
                if categoryName ~= nil then
                    toolCategory = categoryName
                end
            end
        end
    end

    if depthCount > 0 then
        workDepth = workDepth / depthCount
    end

    return workWidth, math.max(0.05, workDepth), toolCategory
end

-- Calcola il moltiplicatore di resistenza di traino (draft) in base alla categoria dell'attrezzo,
-- alla velocità di lavoro e all'umidità del terreno.
-- Ogni categoria ha una curva diversa (lineare, quadratica o a tratti) per replicare
-- il comportamento reale degli attrezzi agricoli.
-- A velocità < 3 km/h viene applicato un bonus di resistenza statica (avvio da fermo).
-- @param toolCategory  categoria dell'attrezzo (es. "plows", "cultivators", ecc.)
-- @param speedKph      velocità del veicolo in km/h
-- @param wetness       umidità normalizzata del terreno [0, 1]
-- @return moltiplicatore >= 0.2
function RW_PhysicsCore.getDraftForceMultiplier(toolCategory, speedKph, wetness)
    local multiplier = 1

    if toolCategory == "plows" then
        -- Aratro: resistenza cresce linearmente con la velocità, leggera riduzione sotto i 2 km/h.
        if speedKph < 2 then
            multiplier = 0.8
        else
            multiplier = 0.7336 + 0.0333 * speedKph
        end
    elseif toolCategory == "cultivators" then
        -- Erpice a denti: curva a tre segmenti con amplificazione per terreno bagnato.
        if speedKph < 8 then
            multiplier = 0.8 + 0.025 * speedKph
        elseif speedKph < 12 then
            multiplier = 0.6 + 0.05 * speedKph
        else
            multiplier = 0.48 + 0.06 * speedKph
        end
        multiplier = multiplier * (1 + 0.25 * wetness)
    elseif toolCategory == "discHarrows" then
        -- Erpice a dischi: resistenza moderata con forte amplificazione per umidità.
        if speedKph < 12 then
            multiplier = 0.9 + 0.0084 * speedKph
        else
            multiplier = 0.7008 + 0.025 * speedKph
        end
        multiplier = multiplier * (1 + wetness)
    elseif toolCategory == "powerHarrows" then
        -- Erpice rotante: cresce quadraticamente ad alta velocità.
        if speedKph < 10 then
            multiplier = 0.65 + 0.04 * speedKph
        else
            multiplier = 1.05 * (speedKph / 10) ^ 2
        end
        multiplier = multiplier * (1 + 0.3 * wetness)
    elseif toolCategory == "seeders" then
        -- Seminatrice: crescita moderata con amplificazione per umidità.
        if speedKph < 10 then
            multiplier = 0.9 + 0.01 * speedKph
        else
            multiplier = 0.7 + 0.03 * speedKph
        end
        multiplier = multiplier * (1 + 0.3 * wetness)
    elseif toolCategory == "planters" then
        -- Piantatrice: simile alla seminatrice ma con curva più piatta.
        if speedKph < 8 then
            multiplier = 0.92 + 0.01 * speedKph
        else
            multiplier = 0.76 + 0.03 * speedKph
        end
        multiplier = multiplier * (1 + 0.2 * wetness)
    elseif toolCategory == "subsoilers" then
        -- Ripuntatore (lavorazione profonda): curva a tre segmenti con pendenza ripida.
        if speedKph < 8 then
            multiplier = 0.8 + 0.025 * speedKph
        elseif speedKph < 12 then
            multiplier = 0.52 + 0.06 * speedKph
        else
            multiplier = 0.34 + 0.075 * speedKph
        end
        multiplier = multiplier * (1 + 0.175 * wetness)
    elseif toolCategory == "spaders" then
        -- Vangatore: crescita quadratica sopra i 7 km/h (attrezzo ad alta resistenza).
        if speedKph < 7 then
            multiplier = 0.65 + 0.05 * speedKph
        else
            multiplier = (speedKph / 7) ^ 2
        end
    end

    -- Bonus resistenza statica: a velocità molto basse (< 3 km/h) la forza di avvio è maggiore.
    if speedKph < 3 then
        multiplier = multiplier * (1.249 - speedKph * 0.083)
    end

    return math.max(0.2, multiplier)
end

-- Legge l'umidità del terreno nella posizione corrente del veicolo.
-- @return umidità [0, 1], 0 se il moistureSystem non è disponibile
local function getMoistureAtVehiclePos(vehicle)
    local moistureSystem = RW_PhysicsCore.ensureMoistureAPI()
    if moistureSystem == nil then
        return 0
    end

    if getWorldTranslationFn == nil then
        return 0
    end

    local x, _, z = getWorldTranslationFn(vehicle.rootNode)
    local moisture = moistureSystem:getMoistureAtWorldPos(x, z)
    return clamp(moisture or 0, 0, 1)
end

-- Legge il moltiplicatore di resa del campo dalla posizione mondo (x, z) tramite PrecisionFarming.
-- Prova prima il metodo getYieldMultiplier, poi accede direttamente alla yieldMap.
-- @return moltiplicatore resa [0.3, 2], default 1 se PrecisionFarming non è disponibile
local function getFieldYieldMultiplierAtWorldPos(x, z)
    local pf = rawget(_G, "g_precisionFarming")
    if pf == nil then
        return 1
    end

    if pf.getYieldMultiplier ~= nil then
        local farmId = 0
        local fieldId = 0
        local fieldManager = rawget(_G, "g_fieldManager")
        if fieldManager ~= nil and fieldManager.getFieldIdAtWorldPosition ~= nil then
            local okField, detectedFieldId = pcall(fieldManager.getFieldIdAtWorldPosition, fieldManager, x, z)
            if okField and detectedFieldId ~= nil then
                fieldId = detectedFieldId
            end
        end

        local okYield, multiplier = pcall(pf.getYieldMultiplier, pf, farmId, fieldId, x, z)
        if okYield and type(multiplier) == "number" then
            return clamp(multiplier, 0.3, 2)
        end
    end

    -- Fallback: accesso diretto alla yieldMap con diversi nomi di metodo possibili.
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
                local okMap, value = pcall(yieldMap[methodName], yieldMap, x, z)
                if okMap and type(value) == "number" then
                    local normalized = value
                    -- Normalizza se il valore è in percentuale (> 3 → dividi per 100).
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

-- Cerca ricorsivamente una pressa (baler) agganciata al veicolo o ai suoi attrezzi.
-- @return l'oggetto baler trovato, o nil se nessuno è agganciato
local function findAttachedBaler(vehicle)
    if vehicle == nil or vehicle.getAttachedImplements == nil then
        return nil
    end

    local attached = {}
    vehicle:getAttachedImplements(attached)
    for _, entry in ipairs(attached) do
        local implement = entry ~= nil and entry.object or nil
        if implement ~= nil then
            if implement.spec_baler ~= nil then
                return implement
            end

            if implement.getAttachedImplements ~= nil then
                local nested = findAttachedBaler(implement)
                if nested ~= nil then
                    return nested
                end
            end
        end
    end

    return nil
end

-- Calcola la potenza PTO massima disponibile per la pressa agganciata.
-- Prova prima spec_powerConsumer, poi il picco del motore.
-- @return potenza in kW (minimo 1 kW)
local function getPtoPowerBudgetKw(vehicle, motorData)
    local budgetKw = 0

    if vehicle.spec_powerConsumer ~= nil then
        local specPC = vehicle.spec_powerConsumer
        if type(specPC.neededMaxPtoPower) == "number" then
            budgetKw = math.max(budgetKw, specPC.neededMaxPtoPower)
        end

        if type(specPC.sourceMotorPeakPower) == "number" and specPC.sourceMotorPeakPower < math.huge then
            budgetKw = math.max(budgetKw, specPC.sourceMotorPeakPower / 1000)
        end
    end

    if motorData ~= nil then
        local peakKw = (vehicle.spec_motorized ~= nil and vehicle.spec_motorized.motor ~= nil and vehicle.spec_motorized.motor.peakMotorPower or 0) / 1000
        budgetKw = math.max(budgetKw, peakKw)
    end

    return math.max(budgetKw, 1)
end

-- Azzera tutti i dati dinamici dell'attrezzo nella spec e rimuove il limite RPM se attivo.
-- Chiamato quando la pressa non è più agganciata o non sta lavorando.
local function resetToolPowerDynamics(spec, vehicle)
    spec.toolType = nil
    spec.toolPtoTorque = 0
    spec.toolPtoLoadRatio = 0
    spec.toolPtoPulse = 0
    spec.toolNearStall = false
    spec.toolOverload = 0
    spec.toolBaleFillRatio = 0
    spec.toolYieldMultiplier = 1
    spec.toolMoisture = 0

    if spec.toolRpmLimitActive == true and vehicle ~= nil and vehicle.spec_motorized ~= nil and vehicle.spec_motorized.motor ~= nil then
        vehicle.spec_motorized.motor:setRpmLimit(math.huge)
        spec.toolRpmLimitActive = false
    end
end

-- Simula la dinamica di potenza della pressa agganciata al veicolo.
-- Calcola in ogni tick:
--   - portata istantanea in entrata (intakeLps) dal buffer pickUpLitersBuffer
--   - umidità combinata (terreno 80% + meteo 20%)
--   - riempimento camera (baleFillRatio) e tipo (rotoballa vs quadra)
--   - fattori di carico PTO: portata × umidità × resa campo × riempimento camera
--   - pulsazioni meccaniche per le presse quadre (seno con frequenza proporzionale al carico)
--   - overload del PTO → limite RPM motore proporzionale al sovraccarico
-- @param vehicle    veicolo trattore
-- @param spec       spec rwPhysicsCore del veicolo
-- @param motorData  dati motore correnti
-- @param dt         delta time in millisecondi
local function updateToolPowerDynamics(vehicle, spec, motorData, dt)
    local baler = findAttachedBaler(vehicle)
    if baler == nil or baler.spec_baler == nil then
        resetToolPowerDynamics(spec, vehicle)
        return
    end

    local balerSpec = baler.spec_baler
    local intakeLps = 0
    if balerSpec.pickUpLitersBuffer ~= nil and balerSpec.pickUpLitersBuffer.get ~= nil then
        local okIntake, value = pcall(balerSpec.pickUpLitersBuffer.get, balerSpec.pickUpLitersBuffer, 1000)
        if okIntake and type(value) == "number" then
            intakeLps = math.max(value, 0)
        end
    end

    local maxPickupLps = math.max(balerSpec.maxPickupLitersPerSecond or 500, 1)
    local intakeRatio = intakeLps / maxPickupLps

    -- Legge posizione della pressa per il calcolo della resa del campo.
    local bx, bz = 0, 0
    if getWorldTranslationFn ~= nil and baler.rootNode ~= nil then
        local x, _, z = getWorldTranslationFn(baler.rootNode)
        bx = x or 0
        bz = z or 0
    end
    local yieldMultiplier = getFieldYieldMultiplierAtWorldPos(bx, bz)
    local moisture = getMoistureAtVehiclePos(baler)

    -- Umidità meteo: legge currentRain, rainScale o humidity dall'ambiente di missione.
    local weatherWetness = 0
    local mission = rawget(_G, "g_currentMission")
    if mission ~= nil and mission.environment ~= nil and mission.environment.weather ~= nil then
        local weather = mission.environment.weather
        weatherWetness = clamp((weather.currentRain or weather.rainScale or weather.humidity or 0), 0, 1)
    end
    local combinedMoisture = clamp(moisture * 0.8 + weatherWetness * 0.2, 0, 1)

    -- Inizializza il buffer di accumulo umidità per il calcolo del peso della balla.
    balerSpec.rwToolPower = balerSpec.rwToolPower or {
        moistureLiters = 0,
        moistureWeightedLiters = 0,
        lastWetness = 0,
        lastMassFactor = 1
    }

    -- Accumula litri pesati per umidità: usato da onBalerDropBale per calcolare il peso della balla.
    if intakeLps > 0 and dt > 0 then
        local sampledLiters = intakeLps * (dt / 1000)
        balerSpec.rwToolPower.moistureLiters = balerSpec.rwToolPower.moistureLiters + sampledLiters
        balerSpec.rwToolPower.moistureWeightedLiters = balerSpec.rwToolPower.moistureWeightedLiters + sampledLiters * combinedMoisture
        balerSpec.rwToolPower.lastWetness = combinedMoisture
    end

    -- Legge il riempimento della camera balle.
    local fillUnitIndex = balerSpec.fillUnitIndex or 1
    local baleFillRatio = 0
    if baler.getFillUnitFillLevelPercentage ~= nil then
        local okFill, fillPct = pcall(baler.getFillUnitFillLevelPercentage, baler, fillUnitIndex)
        if okFill and type(fillPct) == "number" then
            baleFillRatio = clamp(fillPct, 0, 1)
        end
    end

    -- Determina se è una rotoballa o una pressa quadra per il calcolo del fattore camera.
    local isRoundBaler = false
    if baler.getIsRoundBaler ~= nil then
        local okRound, isRound = pcall(baler.getIsRoundBaler, baler)
        if okRound then
            isRoundBaler = isRound == true
        end
    end
    if not isRoundBaler then
        isRoundBaler = balerSpec.isRoundBaler == true
    end

    local moistureLoadFactor = 1 + combinedMoisture * 0.45
    local yieldLoadFactor = clamp(yieldMultiplier, 0.45, 1.8)
    local intakeLoadRatio = intakeRatio * moistureLoadFactor * yieldLoadFactor

    -- Fattore camera: la rotoballa ha resistenza crescente con il riempimento (curva più ripida),
    -- la pressa quadra ha resistenza più lineare.
    local chamberFactor
    if isRoundBaler then
        chamberFactor = 0.45 + baleFillRatio * 1.1
    else
        chamberFactor = 0.7 + baleFillRatio * 0.35
    end

    local ptoLoadRatio = intakeLoadRatio * chamberFactor
    local ptoPowerBudgetKw = getPtoPowerBudgetKw(vehicle, motorData)
    local ptoRequiredKw = ptoPowerBudgetKw * ptoLoadRatio
    local overload = math.max(ptoRequiredKw / math.max(ptoPowerBudgetKw, 0.1) - 1, 0)

    -- Simula le pulsazioni meccaniche della pressa quadra con frequenza e ampiezza proporzionali al carico.
    local pulse = 0
    if not isRoundBaler and intakeLoadRatio > 0.08 then
        spec.toolPulseTime = (spec.toolPulseTime or 0) + (dt / 1000)
        local frequencyHz = 1.6 + 1.8 * clamp(intakeLoadRatio, 0, 1.4)
        local amplitude = clamp(0.05 + 0.18 * intakeLoadRatio, 0.05, 0.35)
        pulse = math.sin(spec.toolPulseTime * frequencyHz * math.pi * 2) * amplitude
    else
        spec.toolPulseTime = 0
    end

    local ptoTorqueContribution = clamp(ptoLoadRatio * (1 + math.max(pulse, 0) * 0.25), 0, 2.4)
    local nearStall = overload > 0.05 or ptoLoadRatio > 1

    -- Aggiorna la spec con tutti i dati calcolati per la pressa.
    spec.toolType = "baler"
    spec.toolPtoTorque = ptoTorqueContribution
    spec.toolPtoLoadRatio = ptoLoadRatio
    spec.toolPtoPulse = pulse
    spec.toolNearStall = nearStall
    spec.toolOverload = overload
    spec.toolBaleFillRatio = baleFillRatio
    spec.toolYieldMultiplier = yieldMultiplier
    spec.toolMoisture = combinedMoisture

    -- Se in overload, limita gli RPM del motore proporzionalmente al sovraccarico.
    if overload > 0 and vehicle.spec_motorized ~= nil and vehicle.spec_motorized.motor ~= nil then
        local motor = vehicle.spec_motorized.motor
        local minRpm = motor.minRpm or 700
        local maxRpm = motor.maxRpm or 2200
        local rpmLimitFactor = clamp(1 - overload * 0.7, 0.38, 1)
        local rpmLimit = minRpm + (maxRpm - minRpm) * rpmLimitFactor
        motor:setRpmLimit(rpmLimit)
        spec.toolRpmLimitActive = true
    else
        if spec.toolRpmLimitActive == true and vehicle.spec_motorized ~= nil and vehicle.spec_motorized.motor ~= nil then
            vehicle.spec_motorized.motor:setRpmLimit(math.huge)
            spec.toolRpmLimitActive = false
        end
    end
end

-- Hook su Baler.onLoad: inizializza il buffer di accumulo umidità per la pressa.
function RW_PhysicsCore.onBalerLoad(baler)
    if baler ~= nil and baler.spec_baler ~= nil then
        baler.spec_baler.rwToolPower = {
            moistureLiters = 0,
            moistureWeightedLiters = 0,
            lastWetness = 0,
            lastMassFactor = 1
        }
    end
end

-- Override di Baler.dropBale: calcola il peso extra della balla dovuto all'umidità accumulata
-- durante la pressatura e lo applica con setMass dopo che la balla è stata creata.
-- Formula peso: se avgWetness >= 0.2 → moistureFactor = 1.2 + 0.1 * clamp((avgWetness-0.2)/0.8, 0, 1)
--   (da 1.2x a 1.3x rispetto al peso base, per umidità tra 0.2 e 1.0)
-- Dopo l'applicazione, azzera il buffer di accumulo per la balla successiva.
-- @param baler      oggetto pressa
-- @param superFunc  funzione originale Baler.dropBale
-- @param baleIndex  indice della balla da espellere
function RW_PhysicsCore.onBalerDropBale(baler, superFunc, baleIndex)
    local baleObject = nil
    local moistureFactor = 1

    if baler ~= nil and baler.spec_baler ~= nil and baler.spec_baler.bales ~= nil then
        local bale = baler.spec_baler.bales[baleIndex]
        if bale ~= nil then
            baleObject = bale.baleObject
        end

        local toolData = baler.spec_baler.rwToolPower
        if toolData ~= nil then
            -- Calcola umidità media ponderata per litro raccolta durante la pressatura.
            local avgWetness = 0
            if (toolData.moistureLiters or 0) > 0 then
                avgWetness = toolData.moistureWeightedLiters / math.max(toolData.moistureLiters, 0.0001)
            else
                avgWetness = toolData.lastWetness or 0
            end
            avgWetness = clamp(avgWetness, 0, 1)

            -- Applica il fattore peso solo se la balla è sufficientemente bagnata.
            if avgWetness >= 0.2 then
                moistureFactor = 1.2 + 0.1 * clamp((avgWetness - 0.2) / 0.8, 0, 1)
            end
            toolData.lastMassFactor = moistureFactor
        end
    end

    -- Chiama la funzione originale per creare la balla nel mondo.
    superFunc(baler, baleIndex)

    -- Applica il peso extra alla balla appena creata, verificando che il nodo esista ancora.
    if baleObject ~= nil and baleObject.nodeId ~= nil and baleObject.nodeId ~= 0 and getMassFn ~= nil and setMassFn ~= nil then
        local canApply = true
        if entityExistsFn ~= nil then
            canApply = entityExistsFn(baleObject.nodeId)
        end

        if canApply then
            local currentMass = getMassFn(baleObject.nodeId) or 0
            if currentMass > 0 then
                local targetMass = currentMass * moistureFactor
                setMassFn(baleObject.nodeId, targetMass)
                baleObject.defaultMass = targetMass
            end
        end
    end

    -- Azzera il buffer per la prossima balla.
    if baler ~= nil and baler.spec_baler ~= nil and baler.spec_baler.rwToolPower ~= nil then
        baler.spec_baler.rwToolPower.moistureLiters = 0
        baler.spec_baler.rwToolPower.moistureWeightedLiters = 0
    end
end

-- Calcola lo slittamento medio delle ruote del veicolo.
-- Legge longitudinalSlip e lateralSlip da ogni ruota con physics valida.
-- @return slip totale medio, slip longitudinale medio, slip laterale medio (tutti [0, 1.4])
local function estimateAverageWheelSlip(vehicle)
    if vehicle == nil or vehicle.spec_wheels == nil or vehicle.spec_wheels.wheels == nil then
        return 0, 0, 0
    end

    local slip = 0
    local longSlipTotal = 0
    local latSlipTotal = 0
    local count = 0
    for _, wheel in pairs(vehicle.spec_wheels.wheels) do
        if wheel ~= nil and wheel.physics ~= nil then
            local longSlip = math.abs(wheel.physics.longitudinalSlip or wheel.physics.lastLongitudinalSlip or 0)
            local latSlip = math.abs(wheel.physics.lateralSlip or wheel.physics.lastLateralSlip or 0)
            local wheelSlip = math.max(longSlip, latSlip)
            slip = slip + wheelSlip
            longSlipTotal = longSlipTotal + longSlip
            latSlipTotal = latSlipTotal + latSlip
            count = count + 1
        end
    end

    if count == 0 then
        return 0, 0, 0
    end

    return clamp(slip / count, 0, 1), clamp(longSlipTotal / count, 0, 1.4), clamp(latSlipTotal / count, 0, 1.4)
end

-- Legge i dati principali del motore: RPM, coppia applicata, coppia disponibile, carico.
-- Usa pcall per accedere in modo sicuro ai metodi che potrebbero non esistere in tutte le versioni.
-- @return tabella { rpm, maxRpm, currentTorque, maxTorque, loadRatio } o nil se non disponibile
local function getMotorData(vehicle)
    if vehicle == nil or vehicle.spec_motorized == nil or vehicle.spec_motorized.motor == nil then
        return nil
    end

    local motor = vehicle.spec_motorized.motor
    local rpm = 0
    if motor.getLastMotorRpm ~= nil then
        rpm = motor:getLastMotorRpm() or 0
    elseif motor.lastMotorRpm ~= nil then
        rpm = motor.lastMotorRpm
    end

    local maxRpm = math.max(motor.maxRpm or 0, 1)
    local appliedTorque = 0
    local availableTorque = 0

    if motor.getMotorAppliedTorque ~= nil then
        appliedTorque = math.max(motor:getMotorAppliedTorque() or 0, 0)
    elseif motor.motorAppliedTorque ~= nil then
        appliedTorque = math.max(motor.motorAppliedTorque or 0, 0)
    end

    if motor.getMotorAvailableTorque ~= nil then
        availableTorque = math.max(motor:getMotorAvailableTorque() or 0, 0)
    elseif motor.motorAvailableTorque ~= nil then
        availableTorque = math.max(motor.motorAvailableTorque or 0, 0)
    end

    local maxTorque = math.max(motor.peakMotorTorque or availableTorque or 0, 0.0001)
    local currentTorque = math.max(appliedTorque, 0)

    return {
        rpm = rpm,
        maxRpm = maxRpm,
        currentTorque = currentTorque,
        maxTorque = maxTorque,
        loadRatio = clamp(currentTorque / maxTorque, 0, 1.35)
    }
end

-- Scala il consumo carburante dei consumer permanenti (diesel/elettrico/metano)
-- applicando il flowScale calcolato in computeVehicleLoad.
-- Memorizza il consumo base originale in consumer.rwBaseUsage per permettere la scalatura.
-- @return consumo base totale (litri/s) prima della scalatura
local function applyFuelFlowToConsumers(vehicle, flowScale)
    if vehicle == nil or vehicle.spec_motorized == nil or vehicle.spec_motorized.consumers == nil then
        return 0
    end

    local totalBaseUsage = 0
    for _, consumer in pairs(vehicle.spec_motorized.consumers) do
        if consumer ~= nil and consumer.permanentConsumption and consumer.usage ~= nil and consumer.usage > 0 then
            if consumer.fillType == FillType.DIESEL or consumer.fillType == FillType.ELECTRICCHARGE or consumer.fillType == FillType.METHANE then
                consumer.rwBaseUsage = consumer.rwBaseUsage or consumer.usage
                totalBaseUsage = totalBaseUsage + consumer.rwBaseUsage
                consumer.usage = consumer.rwBaseUsage * flowScale
            end
        end
    end

    return totalBaseUsage
end

-- Gestisce l'anti-stall VCA: disabilita temporaneamente l'idleThrottle quando il motore
-- è sotto i 500 RPM con alto carico e bassa velocità, per permettere al VCA di intervenire.
-- Ripristina l'idleThrottle quando il motore si stabilizza (RPM > 650 e carico < 0.45).
local function updateVCAAntiStall(vehicle, spec, motorData, speedKph)
    if vehicle == nil or vehicle.spec_vca == nil or vehicle.vcaSetState == nil or motorData == nil then
        return
    end

    local rpm = motorData.rpm or 0
    local torqueLoad = clamp(motorData.loadRatio or 0, 0, 1.5)
    local shouldDisableIdleThrottle = rpm > 0 and rpm < 500 and torqueLoad > 0.62 and speedKph < 5

    if shouldDisableIdleThrottle and vehicle.spec_vca.idleThrottle == true then
        spec.vcaIdleThrottleRestore = true
        vehicle:vcaSetState("idleThrottle", false)
    elseif spec.vcaIdleThrottleRestore and vehicle.spec_vca.idleThrottle == false then
        if rpm > 650 and torqueLoad < 0.45 then
            vehicle:vcaSetState("idleThrottle", true)
            spec.vcaIdleThrottleRestore = false
        end
    end
end

-- Aggiorna la tabella di debug globale g_realisticWeather.physicsDebug con i dati del veicolo.
-- Usato per il pannello di debug visivo del mod.
local function updatePhysicsDebug(vehicle, spec)
    if g_realisticWeather == nil then
        return
    end

    g_realisticWeather.physicsDebug = g_realisticWeather.physicsDebug or {}
    g_realisticWeather.physicsDebug.vehicleId = vehicle ~= nil and vehicle.id or nil
    g_realisticWeather.physicsDebug.sideSlip = spec.sideSlip or 0
    g_realisticWeather.physicsDebug.powerLoss = spec.powerLoss or 0
    g_realisticWeather.physicsDebug.realFuelFlow = spec.realFuelFlowLph or 0
end

-- Legge la massa totale del veicolo in modo sicuro tramite pcall.
-- Prova prima con il parametro onlyGivenVehicle, poi senza.
-- @return massa in tonnellate, 0 se non disponibile
local function getTotalMassSafe(vehicle, onlyGivenVehicle)
    if vehicle == nil or vehicle.getTotalMass == nil then
        return 0
    end

    local ok, value = pcall(vehicle.getTotalMass, vehicle, onlyGivenVehicle)
    if ok and value ~= nil then
        return math.max(0, value)
    end

    local okNoArg, valueNoArg = pcall(vehicle.getTotalMass, vehicle)
    if okNoArg and valueNoArg ~= nil then
        return math.max(0, valueNoArg)
    end

    return 0
end

-- Calcola il rapporto di riempimento (payload ratio) di un oggetto che ha fillUnit.
-- Considera anche gli attrezzi agganciati per il massimo payload.
-- @return rapporto [0, 1]
local function getFillPayloadRatioForObject(object)
    if object == nil or object.spec_fillUnit == nil or object.spec_fillUnit.fillUnits == nil then
        return 0
    end

    local totalCapacity = 0
    local totalLevel = 0

    for i, fillUnit in ipairs(object.spec_fillUnit.fillUnits) do
        local capacity = fillUnit ~= nil and (fillUnit.capacity or 0) or 0
        local level = fillUnit ~= nil and (fillUnit.fillLevel or 0) or 0

        if capacity <= 0 and object.getFillUnitCapacity ~= nil then
            local okCap, cap = pcall(object.getFillUnitCapacity, object, i)
            if okCap and cap ~= nil then
                capacity = cap
            end
        end

        if level <= 0 and object.getFillUnitFillLevel ~= nil then
            local okLvl, lvl = pcall(object.getFillUnitFillLevel, object, i)
            if okLvl and lvl ~= nil then
                level = lvl
            end
        end

        if capacity > 0 then
            totalCapacity = totalCapacity + capacity
            totalLevel = totalLevel + math.max(0, level)
        end
    end

    if totalCapacity <= 0 then
        return 0
    end

    return clamp(totalLevel / totalCapacity, 0, 1)
end

-- Raccoglie tutti i dati di massa dinamica del veicolo:
--   - massa propria (solo veicolo)
--   - massa totale (veicolo + attrezzi + carico)
--   - massRatio: rapporto massa totale / massa propria, clampato [0.65, 4.5]
--   - payloadRatio: riempimento massimo tra veicolo e attrezzi agganciati [0, 1]
-- Il massRatio è usato per scalare trasferimento di peso, slittamento laterale e frenata.
local function getDynamicMassData(vehicle)
    local ownMass = getTotalMassSafe(vehicle, true)
    local totalMass = getTotalMassSafe(vehicle, false)
    if totalMass <= 0 then
        totalMass = ownMass
    end

    local payloadRatio = getFillPayloadRatioForObject(vehicle)
    local attachedImplements = {}
    if vehicle ~= nil and vehicle.getAttachedImplements ~= nil then
        vehicle:getAttachedImplements(attachedImplements)
        for _, attach in ipairs(attachedImplements) do
            local object = attach ~= nil and attach.object or nil
            if object ~= nil then
                payloadRatio = math.max(payloadRatio, getFillPayloadRatioForObject(object))
            end
        end
    end

    local referenceMass = ownMass
    if referenceMass <= 0 then
        referenceMass = math.max(4, totalMass * 0.7)
    end

    local massRatio = clamp(totalMass / math.max(referenceMass, 0.1), 0.65, 4.5)

    return {
        totalMass = totalMass,
        ownMass = ownMass,
        referenceMass = referenceMass,
        massRatio = massRatio,
        payloadRatio = clamp(payloadRatio, 0, 1),
        attachedCount = #attachedImplements
    }
end

-- Calcola il fattore di pendenza del veicolo proiettando il vettore avanti (0,0,1 in locale)
-- in coordinate mondo e leggendo la componente Y. Valori negativi = salita, positivi = discesa.
-- @return fattore pendenza clampato [-0.35, 0.35]
local function getSlopeFactor(vehicle)
    if vehicle == nil or vehicle.components == nil or vehicle.components[1] == nil then
        return 0
    end

    if localDirectionToWorldFn == nil then
        return 0
    end

    local _, y, _ = localDirectionToWorldFn(vehicle.components[1].node, 0, 0, 1)
    if y == nil then
        return 0
    end

    return clamp(-y, -0.35, 0.35)
end

-- Trasmette i dati fisici calcolati ai mod VCA e CVTaddon tramite le loro API.
-- VCA riceve: slip, sideSlip, draftTorque, powerLoss, fuelFlow, toolLoad, toolPulse,
--             toolNearStall, antiSlip, massRatio, heavyBrakeNeeded, brakeForceFactor
-- CVTaddon riceve: targetTorque, mudLoad, slip, sideSlip, powerLoss, heavyMass,
--                  massRatio, accelRamp, turboFatigue, toolLoad, toolPulse, toolNearStall, baleChamber
-- accelRamp = clamp((massRatio-1)*0.75, 0, 2.25): rampa di accelerazione proporzionale alla massa
-- turboFatigue = clamp((totalMass-32)/18, 0, 1): affaticamento turbo per veicoli molto pesanti
local function sendCrossModData(vehicle, spec)
    local targetTorque = (spec.targetTorque or 0) + (spec.toolPtoTorque or 0)
    local slipRatio = spec.slipRatio or 0
    local massRatio = spec.inertiaMassRatio or 1
    local totalMass = spec.dynamicMass or 0
    local heavyMassMode = totalMass >= RW_PhysicsCore.HEAVY_MASS_THRESHOLD_T

    if vehicle.spec_vca ~= nil and vehicle.vcaSetState ~= nil then
        vehicle:vcaSetState("rwSlip", slipRatio)
        vehicle:vcaSetState("rwSideSlip", spec.sideSlip or 0)
        vehicle:vcaSetState("rwDraftTorque", targetTorque)
        vehicle:vcaSetState("rwPowerLoss", spec.powerLoss or 0)
        vehicle:vcaSetState("rwRealFuelFlow", spec.realFuelFlowLph or 0)
        vehicle:vcaSetState("rwToolLoad", spec.toolPtoLoadRatio or 0)
        vehicle:vcaSetState("rwToolPulse", spec.toolPtoPulse or 0)
        vehicle:vcaSetState("rwToolNearStall", spec.toolNearStall == true)
        vehicle:vcaSetState("antiSlip", slipRatio > 0.12)
        vehicle:vcaSetState("rwMassRatio", massRatio)
        vehicle:vcaSetState("rwHeavyBrakeNeeded", spec.heavyBrakeDemand == true)
        vehicle:vcaSetState("rwBrakeForceFactor", spec.brakeDemandFactor or 1)
    end

    if vehicle.spec_CVTaddon ~= nil then
        local cvtSpec = vehicle.spec_CVTaddon
        cvtSpec.targetTorque = targetTorque
        cvtSpec.rwMudLoad = targetTorque
        cvtSpec.rwSlip = slipRatio
        cvtSpec.rwSideSlip = spec.sideSlip or 0
        cvtSpec.rwPowerLoss = spec.powerLoss or 0
        cvtSpec.rwHeavyMass = heavyMassMode
        cvtSpec.rwMassRatio = massRatio
        cvtSpec.rwAccelRamp = clamp((massRatio - 1) * 0.75, 0, 2.25)
        cvtSpec.rwTurboFatigue = clamp((totalMass - RW_PhysicsCore.HEAVY_MASS_THRESHOLD_T) / 18, 0, 1)
        cvtSpec.rwToolLoad = spec.toolPtoLoadRatio or 0
        cvtSpec.rwToolPulse = spec.toolPtoPulse or 0
        cvtSpec.rwToolNearStall = spec.toolNearStall == true
        cvtSpec.rwBaleChamber = spec.toolBaleFillRatio or 0
    end
end

-- Calcola e aggiorna tutti i parametri fisici del veicolo per questo tick.
-- Pipeline di calcolo:
--   1. Velocità (m/s e km/h), umidità terreno, massa dinamica
--   2. wetness = umidità normalizzata per il draft (attiva solo sopra 0.5)
--   3. Dati attrezzo agganciato → moltiplicatore draft → forza di traino target
--   4. Slittamento ruote (longitudinale e laterale)
--   5. Accelerazione longitudinale e fattore pendenza → trasferimento di peso
--   6. Slittamento laterale corretto per umidità e pendenza
--   7. Efficienza trasmissione = 0.9 - perdite umidità - perdite slip - perdite idrauliche CVT
--   8. Flusso carburante realistico = RPM × coppia × consumo_base × (1 + powerLoss*1.25)
--   9. Anti-stall VCA, frenata pesante, dinamica pressa
--  10. Salvataggio di tutti i valori nella spec e invio a VCA/CVTaddon
-- @param vehicle  veicolo motorizzato da aggiornare
function RW_PhysicsCore.computeVehicleLoad(vehicle)
    local spec = vehicle[RW_PhysicsCore.SPEC_KEY]
    if spec == nil then
        return
    end

    local speedMps = math.max(0, vehicle.getLastSpeed ~= nil and vehicle:getLastSpeed() or 0)
    local speedKph = speedMps * 3.6
    local moisture = getMoistureAtVehiclePos(vehicle)
    local massData = getDynamicMassData(vehicle)

    -- wetness è attiva solo quando l'umidità supera il 50% (terreno mediamente bagnato).
    local wetness = 0
    if moisture > 0.5 then
        wetness = (moisture - 0.5) * 2
    end

    local width, depth, toolCategory = getActiveImplementData(vehicle)
    local draftMultiplier = RW_PhysicsCore.getDraftForceMultiplier(toolCategory, speedKph, wetness)

    -- Forza di traino base: larghezza × profondità × costante empirica, scalata per la massa totale.
    local baseDraft = math.max(0, width * depth * 3.4)
    local targetTorque = baseDraft * draftMultiplier * (1 + 0.00004 * massData.totalMass)

    local slipRatio, longSlipRatio, latSlipRatio = estimateAverageWheelSlip(vehicle)
    local dtSec = math.max((RW_PhysicsCore.TICK_INTERVAL_MS or 120) / 1000, 0.001)
    local longAcceleration = (speedMps - (spec.lastSpeedMps or speedMps)) / dtSec
    local slopeFactor = getSlopeFactor(vehicle)

    local inertiaMassRatio = massData.massRatio
    local accelResistanceFactor = inertiaMassRatio
    local brakeDemandFactor = math.max(1, 1 + (inertiaMassRatio - 1) * 0.9)

    -- Trasferimento di peso: combinazione di decelerazione/accelerazione e pendenza.
    local transferByAccel = clamp(-longAcceleration / 3.2, -1, 1)
    local transferBySlope = slopeFactor * 1.8
    local weightTransfer = clamp((transferByAccel + transferBySlope) * (0.55 + 0.45 * inertiaMassRatio), -1.35, 1.35)

    -- Slittamento laterale amplificato da umidità (terreno scivoloso) e pendenza laterale.
    local sideSlip = clamp(latSlipRatio * (1 + math.max(0, moisture - 0.4) * 1.4 + math.abs(slopeFactor) * 0.65), 0, 1.5)

    -- Calcola il carico del motore dal loadRatio.
    local motorData = getMotorData(vehicle)
    local loadRatio = motorData ~= nil and clamp(motorData.loadRatio or 0, 0, 1.5) or 0

    -- Perdite idrauliche CVT: maggiori a bassa velocità e alto carico (il convertitore lavora di più).
    local lowSpeedFactor = clamp((7 - speedKph) / 7, 0, 1)
    local cvtHydraulicLoss = clamp(0.012 + 0.075 * lowSpeedFactor * loadRatio, 0.01, 0.12)

    -- Efficienza trasmissione: parte da 0.9, ridotta da umidità, slittamento laterale e perdite CVT.
    local baseEfficiency = 0.9 - 0.025 * math.max(0, moisture - 0.45) - 0.02 * sideSlip
    local transmissionEfficiency = clamp(baseEfficiency - cvtHydraulicLoss, 0.78, 0.92)
    local powerLoss = clamp(1 - transmissionEfficiency, 0.08, 0.22)

    -- Legge il consumo base dei consumer permanenti del motore.
    local baseFuelConsumption = 0
    if vehicle.spec_motorized ~= nil and vehicle.spec_motorized.consumers ~= nil then
        for _, consumer in pairs(vehicle.spec_motorized.consumers) do
            if consumer ~= nil and consumer.permanentConsumption and consumer.usage ~= nil and consumer.usage > 0 then
                if consumer.fillType == FillType.DIESEL or consumer.fillType == FillType.ELECTRICCHARGE or consumer.fillType == FillType.METHANE then
                    consumer.rwBaseUsage = consumer.rwBaseUsage or consumer.usage
                    baseFuelConsumption = baseFuelConsumption + consumer.rwBaseUsage
                end
            end
        end
    end

    -- Flusso carburante realistico: RPM_factor × torque_factor × consumo_base × (1 + powerLoss*1.25)
    -- flowScale viene poi applicato ai consumer per sovrascrivere il consumo di FS.
    local realFuelFlowRaw = 0
    local flowScale = 1
    if motorData ~= nil and baseFuelConsumption > 0 then
        local rpmFactor = clamp(motorData.rpm / math.max(motorData.maxRpm, 1), 0, 1.2)
        local torqueFactor = clamp(motorData.currentTorque / math.max(motorData.maxTorque, 0.0001), 0, 1.3)
        realFuelFlowRaw = rpmFactor * torqueFactor * baseFuelConsumption
        realFuelFlowRaw = realFuelFlowRaw * (1 + powerLoss * 1.25)
        flowScale = clamp(realFuelFlowRaw / math.max(baseFuelConsumption, 0.000001), 0.35, 2.4)
        applyFuelFlowToConsumers(vehicle, flowScale)
    end

    updateVCAAntiStall(vehicle, spec, motorData, speedKph)

    -- Frenata pesante: attivata quando la massa supera la soglia e il motore non sta frenando.
    local engineBrakeActive = vehicle.spec_motorized ~= nil and vehicle.spec_motorized.mrEngineIsBraking == true
    local heavyBrakeDemand = (massData.totalMass >= RW_PhysicsCore.HEAVY_MASS_THRESHOLD_T) and not engineBrakeActive

    updateToolPowerDynamics(vehicle, spec, motorData, dtSec * 1000)

    -- Salva tutti i valori calcolati nella spec del veicolo.
    spec.moisture = moisture
    spec.toolCategory = toolCategory
    spec.workWidth = width
    spec.workDepth = depth
    spec.draftMultiplier = draftMultiplier
    spec.targetTorque = targetTorque
    spec.slipRatio = slipRatio
    spec.longSlip = longSlipRatio
    spec.latSlip = latSlipRatio
    spec.sideSlip = sideSlip
    spec.dynamicMass = massData.totalMass
    spec.dynamicBaseMass = massData.referenceMass
    spec.dynamicOwnMass = massData.ownMass
    spec.payloadRatio = massData.payloadRatio
    spec.inertiaMassRatio = inertiaMassRatio
    spec.accelResistanceFactor = accelResistanceFactor
    spec.brakeDemandFactor = brakeDemandFactor
    spec.weightTransfer = weightTransfer
    spec.longAcceleration = longAcceleration
    spec.slopeFactor = slopeFactor
    spec.transmissionEfficiency = transmissionEfficiency
    spec.powerLoss = powerLoss
    spec.realFuelFlow = realFuelFlowRaw
    spec.realFuelFlowLph = realFuelFlowRaw * 1000 * 60 * 60  -- conversione da L/s a L/h
    spec.fuelFlowScale = flowScale
    spec.heavyBrakeDemand = heavyBrakeDemand
    spec.lastSpeedMps = speedMps
    spec.heavyMassMode = massData.totalMass >= RW_PhysicsCore.HEAVY_MASS_THRESHOLD_T

    sendCrossModData(vehicle, spec)
    updatePhysicsDebug(vehicle, spec)
end

-- Hook su Vehicle.onLoad: inizializza la spec rwPhysicsCore su ogni veicolo motorizzato.
-- La spec contiene tutti i campi di stato della simulazione fisica con valori iniziali sicuri.
function RW_PhysicsCore.onVehicleLoad(vehicle)
    if not RW_PhysicsCore.isEnabled() then
        return
    end

    if vehicle.spec_motorized == nil then
        return
    end

    if vehicle[RW_PhysicsCore.SPEC_KEY] == nil then
        vehicle[RW_PhysicsCore.SPEC_KEY] = {
            timer = 0,
            moisture = 0,
            dynamicMass = 0,
            dynamicBaseMass = 0,
            dynamicOwnMass = 0,
            payloadRatio = 0,
            targetTorque = 0,
            slipRatio = 0,
            longSlip = 0,
            latSlip = 0,
            sideSlip = 0,
            inertiaMassRatio = 1,
            accelResistanceFactor = 1,
            brakeDemandFactor = 1,
            weightTransfer = 0,
            longAcceleration = 0,
            slopeFactor = 0,
            transmissionEfficiency = 0.9,
            powerLoss = 0,
            realFuelFlow = 0,
            realFuelFlowLph = 0,
            fuelFlowScale = 1,
            heavyBrakeDemand = false,
            heavyMassMode = false,
            draftMultiplier = 1,
            workWidth = 0,
            workDepth = 0.15,
            toolCategory = "cultivators",
            lastSpeedMps = 0,
            vcaIdleThrottleRestore = false,
            toolType = nil,
            toolPtoTorque = 0,
            toolPtoLoadRatio = 0,
            toolPtoPulse = 0,
            toolNearStall = false,
            toolOverload = 0,
            toolBaleFillRatio = 0,
            toolYieldMultiplier = 1,
            toolMoisture = 0,
            toolPulseTime = 0,
            toolRpmLimitActive = false
        }
    end
end

-- Hook su Vehicle.onUpdateTick: esegue computeVehicleLoad ogni TICK_INTERVAL_MS.
-- Usa un timer interno nella spec per controllare l'intervallo senza dipendere dal dt di FS.
function RW_PhysicsCore.onVehicleUpdateTick(vehicle, dt)
    if not RW_PhysicsCore.isEnabled() then
        return
    end

    if vehicle.spec_motorized == nil then
        return
    end

    local spec = vehicle[RW_PhysicsCore.SPEC_KEY]
    if spec == nil then
        return
    end

    spec.timer = spec.timer + dt
    if spec.timer < RW_PhysicsCore.TICK_INTERVAL_MS then
        return
    end

    spec.timer = 0
    RW_PhysicsCore.computeVehicleLoad(vehicle)
end

-- Funzione di inizializzazione del modulo:
-- verifica il conflitto con MoreRealistic e, se assente, registra tutti gli hook.
-- Viene eseguita immediatamente al caricamento del file.
local function initPhysicsCore()
    RW_PhysicsCore.disabledByConflict = isMoreRealisticActive()

    if RW_PhysicsCore.disabledByConflict then
        rwLog("FS25_moreRealistic detected. RW_PhysicsCore auto-disabled to prevent physics conflicts.")
        return
    end

    Vehicle.onLoad = Utils.appendedFunction(Vehicle.onLoad, RW_PhysicsCore.onVehicleLoad)
    Vehicle.onUpdateTick = Utils.appendedFunction(Vehicle.onUpdateTick, RW_PhysicsCore.onVehicleUpdateTick)

    if rawget(_G, "Baler") ~= nil then
        Baler.onLoad = Utils.appendedFunction(Baler.onLoad, RW_PhysicsCore.onBalerLoad)
        Baler.dropBale = Utils.overwrittenFunction(Baler.dropBale, RW_PhysicsCore.onBalerDropBale)
    end

    rwLog("RW_PhysicsCore active: draft/rolling bridge enabled for motorized vehicles.")
end

initPhysicsCore()
