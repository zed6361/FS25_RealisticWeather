-- Cutter.lua (RW_Cutter)
-- Override di Cutter.processCutterArea per integrare la logica di umidità
-- di RealisticWeather nel ciclo di raccolta della mietitrebbia.
--
-- Rispetto alla funzione vanilla, questo override:
--   1. Verifica che il moistureSystem sia disponibile (fallback vanilla se assente)
--   2. Esegue FSDensityMapUtil.cutFruitArea per ogni fruitType nella lista di priorità
--   3. Legge l'umidità media del terreno nei tre punti della work area (start/width/height)
--   4. Chiama getHarvestScaleMultiplier con l'umidità come parametro aggiuntivo
--      per scalare lastMultiplierArea (usata dalla mietitrebbia per il calcolo litri)
--   5. Gestisce la logica del chopper area (paglia/stocchi) invariata rispetto al vanilla
--   6. Aggiorna tutti i workAreaParameters di spec_cutter (lastArea, lastMultiplierArea,
--      currentGrowthState, currentInputFruitType, ecc.)
--
-- Solo il primo fruitType che produce area > 0 viene processato (break dopo il primo match).
-- Non chiama la superFunc vanilla se combineVehicle è presente: è una reimplementazione completa.
-- Ritorna (0, 0) se la cutter non è collegata a una mietitrebbia.

RW_Cutter = {}


-- Override di Cutter.processCutterArea.
-- @param workArea  work area della cutter con nodi start/width/height
-- @param dt        delta time in ms
-- @return lastArea accumulata, lastTotalArea dell'ultimo fruitType processato
function RW_Cutter:processCutterArea(superFunc, workArea, dt)

    local moistureSystem = g_currentMission.moistureSystem

    -- Se il moistureSystem non è disponibile, usa la logica vanilla.
    if moistureSystem == nil then return superFunc(self, workArea, dt) end

    local spec = self.spec_cutter

    -- La logica RW si attiva solo quando la cutter è collegata a una mietitrebbia.
    if spec.workAreaParameters.combineVehicle ~= nil then
        local fieldGroundSystem = g_currentMission.fieldGroundSystem

        local xs, _, zs = getWorldTranslation(workArea.start)
        local xw, _, zw = getWorldTranslation(workArea.width)
        local xh, _, zh = getWorldTranslation(workArea.height)

        local lastArea = 0
        local lastMultiplierArea = 0
        local lastTotalArea = 0

        -- Itera sui fruitType in ordine di priorità; si ferma al primo che produce area.
        for _, fruitTypeIndex in ipairs(spec.workAreaParameters.fruitTypeIndicesToUse) do
            local fruitTypeDesc = g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)
            local excludedSprayType = fieldGroundSystem:getChopperTypeValue(fruitTypeDesc.chopperType)
            local area, totalArea, sprayFactor, plowFactor, limeFactor, weedFactor, stubbleFactor, rollerFactor, beeYieldBonusPerc, growthState, _, terrainDetailPixelsSum = FSDensityMapUtil.cutFruitArea(fruitTypeIndex, xs,zs, xw,zw, xh,zh, true, spec.allowsForageGrowthState, excludedSprayType)

            if area > 0 then
                lastTotalArea = lastTotalArea + totalArea

                if self.isServer then
                    -- Aggiornamento growthState con debounce: cambia solo dopo 500ms o 1s di stabilità.
                    if growthState ~= spec.currentGrowthState then
                        spec.currentGrowthStateTimer = spec.currentGrowthStateTimer + dt
                        if spec.currentGrowthStateTimer > 500 or spec.currentGrowthStateTime + 1000 < g_time then
                            spec.currentGrowthState = growthState
                            spec.currentGrowthStateTimer = 0
                        end
                    else
                        spec.currentGrowthStateTimer = 0
                        spec.currentGrowthStateTime = g_time
                    end

                    -- Cambio fruitType: aggiorna outputFillType, conversionFactor e altezza di taglio.
                    if fruitTypeIndex ~= spec.currentInputFruitType then
                        spec.currentInputFruitType = fruitTypeIndex
                        spec.currentGrowthState = growthState

                        spec.currentOutputFillType = g_fruitTypeManager:getFillTypeIndexByFruitTypeIndex(spec.currentInputFruitType)
                        if spec.fruitTypeConverters[spec.currentInputFruitType] ~= nil then
                            spec.currentOutputFillType = spec.fruitTypeConverters[spec.currentInputFruitType].fillTypeIndex
                            spec.currentConversionFactor = spec.fruitTypeConverters[spec.currentInputFruitType].conversionFactor
                        end

                        local cutHeight = g_fruitTypeManager:getCutHeightByFruitTypeIndex(fruitTypeIndex, spec.allowsForageGrowthState)
                        self:setCutterCutHeight(cutHeight)
                    end

                    self:setTestAreaRequirements(fruitTypeIndex, nil, spec.allowsForageGrowthState)

                    if terrainDetailPixelsSum > 0 then
                        spec.currentInputFruitTypeAI = fruitTypeIndex
                    end
                    spec.currentInputFillType = g_fruitTypeManager:getFillTypeIndexByFruitTypeIndex(fruitTypeIndex)
                    spec.useWindrow = false
                end

                -- Lettura umidità media nei tre punti della work area.
                local target = { "moisture" }

                local startMoistureValues = moistureSystem:getValuesAtCoords(xs, zs, target)
                local widthMoistureValues = moistureSystem:getValuesAtCoords(xw, zw, target)
                local heightMoistureValues = moistureSystem:getValuesAtCoords(xh, zh, target)

                local startMoisture, widthMoisture, heightMoisture = 0, 0, 0

                if startMoistureValues ~= nil and startMoistureValues.moisture ~= nil then startMoisture = startMoistureValues.moisture end
                if widthMoistureValues ~= nil and widthMoistureValues.moisture ~= nil then widthMoisture = widthMoistureValues.moisture end
                if heightMoistureValues ~= nil and heightMoistureValues.moisture ~= nil then heightMoisture = heightMoistureValues.moisture end

                local averageMoisture = (startMoisture + widthMoisture + heightMoisture) / 3

                -- Il moltiplicatore include l'umidità del terreno come fattore aggiuntivo.
                local multiplier = g_currentMission:getHarvestScaleMultiplier(fruitTypeIndex, sprayFactor, plowFactor, limeFactor, weedFactor, stubbleFactor, rollerFactor, beeYieldBonusPerc, averageMoisture)

                lastArea = area
                lastMultiplierArea = area * multiplier

                spec.workAreaParameters.lastFruitType = fruitTypeIndex
                break  -- Processa solo il primo fruitType che produce area.
            end
        end

        -- Gestione chopper area: deposita paglia/stocchi o haulm dopo il taglio.
        if lastArea > 0 then
            if workArea.chopperAreaIndex ~= nil and spec.workAreaParameters.lastFruitType ~= nil then
                local chopperWorkArea = self:getWorkAreaByIndex(workArea.chopperAreaIndex)
                if chopperWorkArea ~= nil then
                    xs, _, zs = getWorldTranslation(chopperWorkArea.start)
                    xw, _, zw = getWorldTranslation(chopperWorkArea.width)
                    xh, _, zh = getWorldTranslation(chopperWorkArea.height)

                    local fruitTypeDesc = g_fruitTypeManager:getFruitTypeByIndex(spec.workAreaParameters.lastFruitType)
                    if fruitTypeDesc.chopperType ~= nil then
                        -- Deposita il tipo di suolo del chopper (es. paglia tritata).
                        local strawGroundType = FieldChopperType.getValueByType(fruitTypeDesc.chopperType)
                        if strawGroundType ~= nil then
                            FSDensityMapUtil.setGroundTypeLayerArea(xs, zs, xw, zw, xh, zh, strawGroundType)
                        end
                    elseif fruitTypeDesc.chopperUseHaulm then
                        -- Deposita le foglie/stocchi (haulm) e rimuove le tracce dei pneumatici.
                        local area = FSDensityMapUtil.updateFruitHaulmArea(spec.workAreaParameters.lastFruitType, xs, zs, xw, zw, xh, zh)

                        if area > 0 then
                            -- remove tireTracks since the haulm drops on top of it
                            FSDensityMapUtil.eraseTireTrack(xs, zs, xw, zw, xh, zh)
                        end
                    end
                else
                    Logging.xmlWarning(self.xmlFile, "Invalid chopperAreaIndex '%d' for workArea '%d'!", workArea.chopperAreaIndex, workArea.index)
                    workArea.chopperAreaIndex = nil
                end
            end

            spec.stoneLastState = FSDensityMapUtil.getStoneArea(xs, zs, xw, zw, xh, zh)
            spec.isWorking = true
        end

        -- Accumula lastArea e lastMultiplierArea nei workAreaParameters.
        spec.workAreaParameters.lastArea = spec.workAreaParameters.lastArea + lastArea
        spec.workAreaParameters.lastMultiplierArea = spec.workAreaParameters.lastMultiplierArea + lastMultiplierArea

        return spec.workAreaParameters.lastArea, lastTotalArea
    end

    -- Se non collegata a una mietitrebbia, non processa nulla.
    return 0, 0
end

Cutter.processCutterArea = Utils.overwrittenFunction(Cutter.processCutterArea, RW_Cutter.processCutterArea)
