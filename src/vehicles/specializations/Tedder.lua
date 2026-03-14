-- Tedder.lua (RW_Tedder)
-- Override delle funzioni principali del Tedder (voltafieno) per integrare
-- il GrassMoistureSystem di RealisticWeather.
--
-- Override registrati:
--   Tedder.processDropArea   (overwrite) → RW_Tedder.processDropArea
--   Tedder.processTedderArea (overwrite) → RW_Tedder.processTedderArea
--
-- processDropArea:
--   Gestisce il rilascio dell'erba dopo il voltaggio. Solo per GRASS_WINDROW:
--   esegue il tip a terra tramite DensityMapHeightUtil e poi chiama
--   grassMoistureSystem:addArea() con le coordinate della work area,
--   registrando la nuova area di erba nel sistema di tracking umidità.
--   Per DRYGRASS_WINDROW passa direttamente alla funzione vanilla.
--
-- processTedderArea:
--   Reimplementazione completa della logica di voltaggio:
--   1. Calcola la linea di pickup con DensityMapHeightUtil.getLineByAreaDimensions
--   2. Per ogni fillType nel converter: raccoglie (tipToGroundAroundLine con -math.huge)
--   3. Se i litri raccolti sono DRYGRASS, li converte in GRASS prima del drop
--   4. Esegue il drop tramite processDropArea (con la nuova logica RW)
--   5. Gestisce gli effetti particellari e la sincronizzazione MP
--   6. Calcola l'area lavorata come larghezza × lastMovedDistance

RW_Tedder = {}

-- Override di Tedder.processDropArea.
-- Per GRASS_WINDROW: esegue il tip a terra e registra l'area nel GrassMoistureSystem.
-- Per tutti gli altri fillType: delega alla funzione vanilla.
-- @param dropArea  work area di rilascio con nodi start/width/height
-- @param fillType  tipo di riempimento da depositare
-- @param amount    quantità in litri da depositare
-- @return quantità effettivamente depositata
function RW_Tedder:processDropArea(superFunc, dropArea, fillType, amount)

    -- Solo GRASS_WINDROW riceve il trattamento speciale RW.
    if g_fillTypeManager:getFillTypeNameByIndex(fillType) ~= "GRASS_WINDROW" then return superFunc(self, dropArea, fillType, amount) end

    -- Calcola la linea di deposito e deposita l'erba a terra.
    local startX, startY, startZ, endX, endY, endZ, radius = DensityMapHeightUtil.getLineByArea(dropArea.start, dropArea.width, dropArea.height, true)
    local dropped, lineOffset = DensityMapHeightUtil.tipToGroundAroundLine(self, amount, fillType, startX, startY, startZ, endX, endY, endZ, radius, nil, dropArea.lineOffset, false, nil, false)
    dropArea.lineOffset = lineOffset

    -- Legge le coordinate mondo dei tre punti della work area per addArea.
    local sx, _, sz = getWorldTranslation(dropArea.start)
    local wx, _, wz = getWorldTranslation(dropArea.width)
    local hx, _, hz = getWorldTranslation(dropArea.height)

    -- Registra la nuova area di erba nel GrassMoistureSystem con l'umidità terreno corrente.
    g_currentMission.grassMoistureSystem:addArea(sx, sz, wx, wz, hx, hz)

    return dropped

end

Tedder.processDropArea = Utils.overwrittenFunction(Tedder.processDropArea, RW_Tedder.processDropArea)


-- Override di Tedder.processTedderArea.
-- Reimplementazione completa della logica di voltaggio per integrare il drop RW.
-- La differenza chiave rispetto al vanilla:
--   - DRYGRASS_WINDROW viene convertito in GRASS_WINDROW prima del drop
--     (il voltaggio "riattiva" l'erba secca per permettere al GrassMoistureSystem
--      di tracciarne nuovamente l'umidità)
--   - Il drop chiama self:processDropArea (con l'override RW) invece del vanilla
--
-- @param workArea  work area del tedder con pickup/drop e offsets
-- @param dt        delta time in ms
-- @return area lavorata, area totale
function RW_Tedder:processTedderArea(_, workArea, dt)
    local spec = self.spec_tedder
    local workAreaSpec = self.spec_workArea

    local sx, sy, sz = getWorldTranslation(workArea.start)
    local wx, wy, wz = getWorldTranslation(workArea.width)
    local hx, hy, hz = getWorldTranslation(workArea.height)

    -- Calcola la linea di pickup dalle dimensioni della work area.
    local lsx, lsy, lsz, lex, ley, lez, lineRadius = DensityMapHeightUtil.getLineByAreaDimensions(sx, sy, sz, wx, wy, wz, hx, hy, hz, true)

    for targetFillType, inputFillTypes in pairs(spec.fillTypeConvertersReverse) do
        local pickedUpLiters = 0
        -- Raccoglie tutti i fillType compatibili per questo converter.
        for _, inputFillType in ipairs(inputFillTypes) do
            pickedUpLiters = pickedUpLiters + DensityMapHeightUtil.tipToGroundAroundLine(self, -math.huge, inputFillType, lsx, lsy, lsz, lex, ley, lez, lineRadius, nil, nil, false, nil)
        end

        if pickedUpLiters == 0 and workArea.lastDropFillType ~= FillType.UNKNOWN then
            targetFillType = workArea.lastDropFillType
        end

        workArea.lastPickupLiters = -pickedUpLiters
        workArea.litersToDrop = workArea.litersToDrop + workArea.lastPickupLiters

        -- Fase di drop: deposita l'erba voltata nell'area di drop.
        local dropArea = workAreaSpec.workAreas[workArea.dropWindrowWorkAreaIndex]
        if dropArea ~= nil and workArea.litersToDrop > 0 then

            local dropped

            -- DRYGRASS_WINDROW viene convertito in GRASS_WINDROW per il voltaggio:
            -- questo permette al GrassMoistureSystem di re-iniziare il tracking umidità.
            if g_fillTypeManager:getFillTypeNameByIndex(targetFillType) == "DRYGRASS_WINDROW" then

                local grassFillTypeIndex = g_fillTypeManager:getFillTypeIndexByName("GRASS_WINDROW")
                dropped = self:processDropArea(dropArea, grassFillTypeIndex, workArea.litersToDrop)

            else
                dropped = self:processDropArea(dropArea, targetFillType, workArea.litersToDrop)
            end

            workArea.lastDropFillType = targetFillType
            workArea.lastDroppedLiters = dropped
            spec.lastDroppedLiters = spec.lastDroppedLiters + dropped
            workArea.litersToDrop = workArea.litersToDrop - dropped

            if self.isServer then
                -- Gestione effetti particellari: attiva solo se il veicolo si muove.
                local lastSpeed = self:getLastSpeed(true)
                if dropped > 0 and lastSpeed > 0.5 then
                    local changedFillType = false
                    if spec.tedderWorkAreaFillTypes[workArea.tedderWorkAreaIndex] ~= targetFillType then
                        spec.tedderWorkAreaFillTypes[workArea.tedderWorkAreaIndex] = targetFillType
                        self:raiseDirtyFlags(spec.fillTypesDirtyFlag)
                        changedFillType = true
                    end

                    local effects = spec.workAreaToEffects[workArea.index]
                    if effects ~= nil then
                        for _, effect in ipairs(effects) do
                            effect.activeTime = g_currentMission.time + effect.activeTimeDuration

                            -- Sincronizzazione MP: segnala che l'effetto è attivo.
                            if not effect.isActiveSent then
                                effect.isActiveSent = true
                                self:raiseDirtyFlags(spec.effectDirtyFlag)
                            end

                            if changedFillType then
                                g_effectManager:setEffectTypeInfo(effect.effects, targetFillType)
                            end

                            if not effect.isActive then
                                g_effectManager:setEffectTypeInfo(effect.effects, targetFillType)
                                g_effectManager:startEffects(effect.effects)
                            end

                            g_effectManager:setDensity(effect.effects, math.max(lastSpeed / self:getSpeedLimit(), 0.6))

                            effect.isActive = true
                        end
                    end
                end
            end
        end
    end

    if self:getLastSpeed() > 0.5 then
        spec.stoneLastState = FSDensityMapUtil.getStoneArea(sx, sz, wx, wz, hx, hz)
    else
        spec.stoneLastState = 0
    end

    -- Area lavorata: larghezza della linea × distanza percorsa nell'ultimo frame.
    local areaWidth = MathUtil.vector3Length(lsx-lex, lsy-ley, lsz-lez)
    local area = areaWidth * self.lastMovedDistance

    return area, area
end

Tedder.processTedderArea = Utils.overwrittenFunction(Tedder.processTedderArea, RW_Tedder.processTedderArea)
