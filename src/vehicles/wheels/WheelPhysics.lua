-- WheelPhysics.lua
-- Override delle funzioni WheelPhysics.updatePhysics e WheelPhysics.updateFriction
-- per integrare la fisica realistica delle ruote di RealisticWeather.
-- Auto-disabilitato se RW_PhysicsCore.isEnabled() restituisce false (es. MoreRealistic attivo).
--
-- Funzioni locali di supporto:
--   getMoistureAtWheel     → legge l'umidità terreno sotto la ruota (con fallback API)
--   getPressureFx          → calcola il fattore di pressione al suolo (carico/area contatto)
--   getDryRollingFx        → resistenza al rotolamento su terreno asciutto (per tipo suolo)
--   getWetRollingFx        → resistenza al rotolamento su terreno bagnato
--   getRollingResistanceFx → interpolazione dry/wet in base all'umidità normalizzata (sqrt)
--   getVehicleMudLoad      → legge il targetTorque dal rwPhysicsCore del veicolo
--   getMassDynamics        → restituisce il rwPhysicsCore del veicolo
--   getWheelSideSlip       → legge lo slip laterale dalla fisica della ruota
--   isFrontWheel           → determina se la ruota è anteriore (positionZ > 0)
--   applyWeightTransfer    → applica il trasferimento di peso alle ruote front/rear
--   applyWetSink           → simula l'affondamento delle ruote in terreno umido
--
-- updatePhysics (override):
--   Calcola la forza di resistenza al rotolamento extra in base a:
--     - umidità sotto la ruota
--     - tipo di suolo (field, soft terrain, road)
--     - inerzia, carico, payload, efficienza trasmissione
--     - trasferimento di peso e affondamento nel fango
--   Riduce anche la coppia disponibile per la trazione in proporzione alla resistenza.
--
-- updateFriction (override):
--   Applica un fattore correttivo alla frizione di base calcolata da FS/MoreRealistic
--   in base a: tipo di pneumatico, tipo di suolo, bagnato, neve.
--   Aggiunge riduzione laterale proporzionale allo slip.
--   RW_COMPAT_FIX: evita doppia applicazione con MoreRealistic tramite rwLastAppliedFriction.

local FRICTION_EPSILON = 0.00001
local getWorldTranslationFn = rawget(_G, "getWorldTranslation")
local getWheelShapeContactForceFn = rawget(_G, "getWheelShapeContactForce")
local fieldGroundTypeEnum = rawget(_G, "FieldGroundType")
local wheelContactTypeEnum = rawget(_G, "WheelContactType")

local function clamp(value, minValue, maxValue)
    return math.max(minValue, math.min(maxValue, value))
end

-- Legge l'umidità del terreno sotto il nodo della ruota.
-- Supporta due API: getMoistureAtWorldPos (più recente) e getValuesAtCoords (legacy).
-- Restituisce 0 se il moistureSystem non è disponibile.
local function getMoistureAtWheel(self)
    local moistureSystem = g_realisticWeather ~= nil and g_realisticWeather.moistureSystem or nil
    if moistureSystem == nil then
        moistureSystem = g_currentMission ~= nil and g_currentMission.moistureSystem or nil
    end
    if moistureSystem == nil then
        return 0
    end

    if moistureSystem.getMoistureAtWorldPos ~= nil then
        if getWorldTranslationFn == nil then
            return 0
        end

        local x, _, z = getWorldTranslationFn(self.wheel.node)
        return clamp(moistureSystem:getMoistureAtWorldPos(x, z) or 0, 0, 1)
    end

    if moistureSystem.getValuesAtCoords ~= nil then
        if getWorldTranslationFn == nil then
            return 0
        end

        local x, _, z = getWorldTranslationFn(self.wheel.node)
        local values = moistureSystem:getValuesAtCoords(x, z, { "moisture" })
        if values ~= nil and values.moisture ~= nil then
            return clamp(values.moisture, 0, 1)
        end
    end

    return 0
end

-- Calcola il fattore di pressione specifica del pneumatico al suolo.
-- Formula: pressione = 0.01 × carico / area_contatto
-- area_contatto = width × radius × 0.53 (approssimazione ellissi contatto)
-- @param width   larghezza del pneumatico (m)
-- @param radius  raggio del pneumatico (m)
-- @param load    carico verticale sulla ruota (kN)
local function getPressureFx(width, radius, load)
    if load > 0 and width > 0 and radius > 0 then
        local contactPatch = width * radius * 0.53
        if contactPatch > 0 then
            return 0.01 * load / contactPatch
        end
    end

    return 0
end

-- Resistenza al rotolamento su terreno asciutto per tipo di suolo.
-- GROUND_FIELD con groundSubType=0 (terreno arato): amplificato ×1.25
-- GROUND_FIELD con groundSubType!=0 (prato/stoppie): valori standard
-- GROUND_SOFT_TERRAIN: soglie diverse
-- @param pressureFx    fattore di pressione calcolato da getPressureFx
-- @param groundType    tipo di suolo (WheelsUtil.GROUND_*)
-- @param groundSubType sottotipo (0 = arato, altri = prato/stoppie)
local function getDryRollingFx(pressureFx, groundType, groundSubType)
    local fx = 1
    if groundType == WheelsUtil.GROUND_FIELD then
        if groundSubType == 0 then
            if pressureFx <= 0.6 then
                fx = 0.8
            elseif pressureFx <= 1.6 then
                fx = 0.68 + pressureFx * 0.2
            else
                fx = 0.6 + pressureFx * 0.25
            end
            fx = fx * 1.25
        else
            if pressureFx <= 1 then
                fx = 0.8
            elseif pressureFx <= 2.25 then
                fx = 0.64 + pressureFx * 0.16
            else
                fx = 0.55 + pressureFx * 0.2
            end
        end
    elseif groundType == WheelsUtil.GROUND_SOFT_TERRAIN then
        if pressureFx <= 1.5 then
            fx = 0.8
        elseif pressureFx <= 3.1 then
            fx = 0.6125 + pressureFx * 0.125
        else
            fx = 0.504 + pressureFx * 0.16
        end
    end

    return fx
end

-- Resistenza al rotolamento su terreno bagnato.
-- Generalmente più alta del secco perché il fango aumenta la resistenza.
local function getWetRollingFx(pressureFx, groundType, groundSubType)
    local fx = 1
    if groundType == WheelsUtil.GROUND_FIELD then
        if groundSubType == 0 then
            fx = (0.8 + pressureFx * 0.25) * 1.25
        else
            fx = 0.8 + pressureFx * 0.2
        end
    elseif groundType == WheelsUtil.GROUND_SOFT_TERRAIN then
        fx = 0.8 + pressureFx * 0.13
    end

    return fx
end

-- Interpolazione tra resistenza asciutta e bagnata in base all'umidità.
-- wetness viene normalizzata con sqrt per un effetto più progressivo.
-- Solo su GROUND_FIELD e GROUND_SOFT_TERRAIN; su strada ritorna 1.
local function getRollingResistanceFx(width, radius, load, groundType, groundSubType, wetness)
    local rrFx = 1
    local normalizedWetness = math.sqrt(clamp(wetness, 0, 1))

    if groundType == WheelsUtil.GROUND_FIELD or groundType == WheelsUtil.GROUND_SOFT_TERRAIN then
        local pressureFx = math.min(getPressureFx(width, radius, load), 7)
        local dryFx = getDryRollingFx(pressureFx, groundType, groundSubType)
        local wetFx = getWetRollingFx(pressureFx, groundType, groundSubType)
        rrFx = (1 - normalizedWetness) * dryFx + normalizedWetness * wetFx
    end

    return rrFx
end

-- Legge il targetTorque dal rwPhysicsCore del veicolo (come proxy del carico nel fango).
local function getVehicleMudLoad(self)
    local vehicle = self.vehicle
    if vehicle == nil or vehicle.rwPhysicsCore == nil then
        return 0
    end

    return math.max(vehicle.rwPhysicsCore.targetTorque or 0, 0)
end

-- Restituisce il rwPhysicsCore del veicolo (dati di massa e dinamica calcolati da RW_PhysicsCore).
local function getMassDynamics(self)
    if self == nil or self.vehicle == nil then
        return nil
    end

    return self.vehicle.rwPhysicsCore
end

-- Legge lo slip laterale assoluto dalla fisica della ruota (lateralSlip o lastLateralSlip).
local function getWheelSideSlip(self)
    if self == nil or self.wheel == nil or self.wheel.physics == nil then
        return 0
    end

    local physics = self.wheel.physics
    local lateral = math.abs(physics.lateralSlip or physics.lastLateralSlip or 0)
    return clamp(lateral, 0, 1.6)
end

-- Determina se la ruota è anteriore (positionZ > 0 o startPositionZ > 0).
local function isFrontWheel(self)
    if self == nil then
        return false
    end

    if self.positionZ ~= nil then
        return self.positionZ > 0
    end

    if self.wheel ~= nil and self.wheel.startPositionZ ~= nil then
        return self.wheel.startPositionZ > 0
    end

    return false
end

-- Applica il trasferimento di peso alle ruote anteriori e posteriori.
-- weightTransfer > 0 → frena (più carico sul posteriore, meno sull'anteriore).
-- Scala maxFriction e springRestingCompression proporzionalmente.
-- Ritorna il frictionScale applicato.
local function applyWeightTransfer(self)
    local dynamics = getMassDynamics(self)
    if dynamics == nil then
        return 1
    end

    local transfer = clamp(dynamics.weightTransfer or 0, -1.35, 1.35)
    local isFront = isFrontWheel(self)
    -- Il segno è invertito per ruote posteriori: frenata scarica il posteriore.
    local signedTransfer = isFront and transfer or -transfer

    local frictionScale = 1 + signedTransfer * 0.12
    frictionScale = clamp(frictionScale, 0.74, 1.42)

    if self.maxFriction ~= nil then
        self.maxFriction = self.maxFriction * frictionScale
    end

    local compressionScale = 1 + signedTransfer * 0.1
    compressionScale = clamp(compressionScale, 0.75, 1.35)

    if self.springRestingCompression ~= nil then
        self.springRestingCompression = self.springRestingCompression * compressionScale
    end

    return frictionScale
end

-- Simula l'affondamento della ruota in terreno umido (groundDepth).
-- L'affondamento dipende da massa del veicolo, carico sulla ruota, payload e umidità.
-- Si attiva solo su terreno bagnato (moisture > 0.35).
-- @param moisture     umidità sotto la ruota [0,1]
-- @param tireLoad     carico verticale (kN)
-- @param payloadRatio rapporto di carico utile [0,1]
local function applyWetSink(self, moisture, tireLoad, payloadRatio)
    if not self.hasGroundContact then
        return
    end

    local mass = self.vehicle ~= nil and self.vehicle:getTotalMass() or 0
    local normalizedMass = clamp(mass / 50, 0, 1)
    local normalizedLoad = clamp((tireLoad or 0) / 80, 0, 1)
    local payload = clamp(payloadRatio or 0, 0, 1)
    local sinkWetness = math.max(0, moisture - 0.35)
    local sink = sinkWetness * (0.004 + 0.046 * normalizedMass) * (0.35 + normalizedLoad) * (0.45 + payload)

    if sink > 0 then
        self.groundDepth = math.max(self.groundDepth or 0, sink)
    end
end

-- Override di WheelPhysics.updatePhysics.
-- Calcola la resistenza al rotolamento extra e la sottrae dalla coppia disponibile.
-- Pipeline:
--   1. Legge umidità, carico pneumatico, tipo di suolo
--   2. Calcola baseRrForce = carico × 0.01 × coeff_attrito × rrFx
--   3. Applica trasferimento di peso (applyWeightTransfer)
--   4. Calcola sinkPenalty (affondamento nel fango) proporzionale a payload × umidità > 0.4
--   5. Calcola extraBrakeForce = baseRrForce × massRollingScale × sinkPenalty + mudLoad
--   6. Applica applyWetSink per aggiornare groundDepth
--   7. Aggiunge extraBrakeForce al brakeForce e riduce il torque per accelResistance
local function rwUpdatePhysics(self, superFunc, brakeForce, torque)
    if RW_PhysicsCore ~= nil and not RW_PhysicsCore.isEnabled() then
        return superFunc(self, brakeForce, torque)
    end

    local moisture = getMoistureAtWheel(self)
    local tireLoad = 0
    if self.wheelShapeCreated then
        if getWheelShapeContactForceFn ~= nil then
            tireLoad = getWheelShapeContactForceFn(self.wheel.node, self.wheelShape) or 0
        end
    end

    local rrCoeff = self.tireGroundFrictionCoeff or 1
    local width = math.max(self.width or 0.5, 0.2)
    local radius = self.radius or 0.7
    local groundType = self.vehicle ~= nil and self.vehicle.lastGroundType or WheelsUtil.GROUND_ROAD
    local groundSubType = self.vehicle ~= nil and self.vehicle.lastGroundSubType or 0
    local rrFx = getRollingResistanceFx(width, radius, tireLoad, groundType, groundSubType, moisture)

    local baseRrForce = tireLoad * 0.01 * rrCoeff * rrFx
    local mudLoad = getVehicleMudLoad(self)
    local dynamics = getMassDynamics(self)
    local inertiaRatio = dynamics ~= nil and clamp(dynamics.inertiaMassRatio or 1, 0.65, 4.5) or 1
    local brakeDemandFactor = dynamics ~= nil and clamp(dynamics.brakeDemandFactor or 1, 1, 4) or 1
    local payloadRatio = dynamics ~= nil and clamp(dynamics.payloadRatio or 0, 0, 1) or 0
    local transmissionEfficiency = dynamics ~= nil and clamp(dynamics.transmissionEfficiency or 0.9, 0.75, 0.95) or 0.9

    local frictionScale = applyWeightTransfer(self)
    -- sinkPenalty: aumenta la resistenza quando si è carichi e il terreno è bagnato (> 40%).
    local sinkPenalty = 1 + payloadRatio * math.max(0, moisture - 0.4) * 1.8
    local massRollingScale = 1 + (inertiaRatio - 1) * 0.85

    local extraBrakeForce = baseRrForce * massRollingScale * sinkPenalty
    extraBrakeForce = extraBrakeForce + mudLoad * (0.02 + 0.06 * payloadRatio)
    extraBrakeForce = extraBrakeForce * brakeDemandFactor / math.max(frictionScale, 0.1)

    applyWetSink(self, moisture, tireLoad, payloadRatio)

    local totalBrakeForce = (brakeForce or 0) + extraBrakeForce
    local effectiveTorque = torque
    if effectiveTorque ~= nil then
        -- Riduce la coppia per la resistenza di accelerazione e l'efficienza della trasmissione.
        local accelResistance = dynamics ~= nil and clamp(dynamics.accelResistanceFactor or 1, 0.65, 4.5) or 1
        effectiveTorque = (effectiveTorque / accelResistance) * transmissionEfficiency
    end

    return superFunc(self, totalBrakeForce, effectiveTorque)
end

-- Calcola il fattore correttivo RW per la frizione del pneumatico.
-- Considera: tipo di pneumatico, tipo di suolo, bagnato/neve.
-- In caso di neve: aggiunge snowFactor basato sull'altezza del manto.
-- Normalizza la frizione per la larghezza del pneumatico.
-- Per veicoli leggeri su neve, applica un fattore basato su widthToMassRatio.
-- Penalizza la frizione sulla neve in base a timeSinceLastRain (neve fresca = più scivolosa).
-- @return ratio rwFriction / vanillaFriction (fattore moltiplicativo da applicare alla base)
local function getRWAdditionalFrictionFactor(self, groundWetness)
    local noneType = fieldGroundTypeEnum ~= nil and fieldGroundTypeEnum.NONE or 0
    local densityType = self.densityType ~= noneType
    local snowFactor = 0

    if self.hasSnowContact then
        if self.snowHeight ~= nil then
            snowFactor = 1 + (self.snowHeight * 0.33)
        else
            snowFactor = 1
        end
        groundWetness = 0  -- neve non è acqua: azzera bagnato per il calcolo frizione
    end

    local wheelContactGround = wheelContactTypeEnum ~= nil and wheelContactTypeEnum.GROUND or 1
    local ground = WheelsUtil.getGroundType(densityType, self.contact ~= wheelContactGround, self.groundDepth)
    local rwFriction = WheelsUtil.getTireFriction(self.tireType, ground, groundWetness, snowFactor)
    local vanillaFriction = WheelsUtil.getTireFriction(self.tireType, ground, groundWetness, 0)

    if vanillaFriction == nil or vanillaFriction == 0 then
        return 1
    end

    local width = self.width
    local mass = self.vehicle:getTotalMass()
    local wheels = self.vehicle.spec_wheels ~= nil and self.vehicle.spec_wheels.wheels ~= nil and #self.vehicle.spec_wheels.wheels or 1
    local widthToMassRatio = math.min(width / (mass / math.max(wheels, 1)), 1)

    -- Normalizzazione per larghezza: pneumatici più larghi hanno più grip su neve.
    rwFriction = rwFriction / (1.5 - math.min(width, 1))
    vanillaFriction = vanillaFriction / (1.5 - math.min(width, 1))

    -- Veicoli leggeri (mass < 8t) su neve: corregge in base al rapporto larghezza/massa.
    if self.hasSnowContact and mass < 8 then
        local widthFactor = widthToMassRatio > 0.06 and widthToMassRatio < 0.12 and (1 + (width / 5)) or (1 - (width / 5))
        rwFriction = rwFriction * widthFactor
        vanillaFriction = vanillaFriction * widthFactor
    end

    -- Penalità per neve fresca: più scivolosa nei minuti successivi alla nevicata.
    if self.hasSnowContact then
        local timeSinceLastRain = g_currentMission.environment.weather.timeSinceLastRain or 0
        local wetPenalty = clamp(timeSinceLastRain / 1440, 1, 3)
        rwFriction = rwFriction / wetPenalty
        vanillaFriction = vanillaFriction / wetPenalty
    end

    return math.max(rwFriction / vanillaFriction, 0.01)
end

-- Override di WheelPhysics.updateFriction.
-- Pipeline:
--   1. Chiama la funzione base con pcall (RW_COMPAT_FIX: preserva la pipeline GIANTS/MoreRealistic)
--   2. Se la velocità è <= 0.2 km/h, salta (nessun effetto a veicolo fermo)
--   3. Applica il fattore correttivo RW alla frizione base calcolata dal vanilla
--   4. Aggiunge riduzione laterale proporzionale allo slip (amplificata da umidità > 0.35)
--      - Su strada: riduzione dimezzata (×0.45)
--   5. RW_COMPAT_FIX: se MoreRealistic è attivo e rwLastAppliedFriction coincide,
--      salta per evitare doppia moltiplicazione
local function rwUpdateFriction(self, superFunc, groundType, groundWetness)
    if RW_PhysicsCore ~= nil and not RW_PhysicsCore.isEnabled() then
        return superFunc(self, groundType, groundWetness)
    end

    -- RW_COMPAT_FIX: preserve GIANTS/MoreRealistic friction pipeline first
    local ok = pcall(superFunc, self, groundType, groundWetness)
    if not ok then return end

    if self.vehicle:getLastSpeed() <= 0.2 then return end

    local baseFriction = self.tireGroundFrictionCoeff
    if baseFriction == nil then return end

    local rwFactor = getRWAdditionalFrictionFactor(self, groundWetness)
    local friction = baseFriction * rwFactor

    local dynamics = getMassDynamics(self)
    if dynamics ~= nil then
        local moisture = getMoistureAtWheel(self)
        local wheelSideSlip = getWheelSideSlip(self)
        local sideSlip = math.max(wheelSideSlip, dynamics.sideSlip or 0)
        local wetFactor = clamp((moisture - 0.35) / 0.65, 0, 1)
        -- Riduzione laterale: più aggressiva su terreno bagnato.
        local sideReduction = sideSlip * (0.08 + wetFactor * 0.3)

        -- Su asfalto/strada: la riduzione laterale è dimezzata.
        if self.vehicle ~= nil and self.vehicle.lastGroundType ~= WheelsUtil.GROUND_FIELD and self.vehicle.lastGroundType ~= WheelsUtil.GROUND_SOFT_TERRAIN then
            sideReduction = sideReduction * 0.45
        end

        friction = friction * clamp(1 - sideReduction, 0.58, 1)
    end

    -- RW_COMPAT_FIX: avoid deterministic double-multiplication with MoreRealistic
    local loadedMods = rawget(_G, "g_modIsLoaded")
    if loadedMods ~= nil and loadedMods["morerealistic_25"] and self.rwLastAppliedFriction ~= nil and math.abs(baseFriction - self.rwLastAppliedFriction) < FRICTION_EPSILON then
        return
    end

    if friction ~= self.tireGroundFrictionCoeff then
        self.tireGroundFrictionCoeff = friction
        self.rwLastAppliedFriction = friction
        self.isFrictionDirty = true
    end

end

WheelPhysics.updateFriction = Utils.overwrittenFunction(WheelPhysics.updateFriction, rwUpdateFriction)
WheelPhysics.updatePhysics = Utils.overwrittenFunction(WheelPhysics.updatePhysics, rwUpdatePhysics)
