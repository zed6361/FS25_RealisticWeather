-- PlayerHUDUpdater.lua (RW_PlayerHUDUpdater)
-- Estensione dell'HUD informativo del player per visualizzare i dati RW
-- relativi all'umidità del terreno, all'irrigazione e al contenuto delle andane.
--
-- Funzioni registrate:
--   PlayerHUDUpdater.showFieldInfo         (append)  → RW_PlayerHUDUpdater.showFieldInfo
--   PlayerHUDUpdater.setCurrentRaycastFillTypeCoords  → RW_PlayerHUDUpdater.setCurrentRaycastFillTypeCoords
--   PlayerHUDUpdater.showFillTypeInfo                 → RW_PlayerHUDUpdater.showFillTypeInfo
--   PlayerHUDUpdater.update                (append via DensityMapHeightManager) → chiama showFillTypeInfo
--   PlayerHUDUpdater.delete                (append)  → distrugge i box HUD RW
--
-- showFieldInfo:
--   Crea/aggiorna un box HUD personalizzato (RW_InfoDisplayKeyValueBox) con:
--     - Umidità attuale del terreno (con irrigationFactor×retention già incluso)
--     - Colore verde/rosso basato su distanza dall'umidità ideale della coltura
--     - Range umidità ideale e perfetta per la coltura corrente
--     - Resa corrente (getHarvestScaleMultiplier) se la coltura è piantata
--     - Rischio appassimento (witherChance) con colore proporzionale
--     - Ritenzione idrica con colore proporzionale
--     - Stato irrigazione (attivo/inattivo) e costo pendente
--   Gestisce anche la visibilità e il testo dell'action event irrigazione:
--     - Solo se il player è proprietario del farmland corrente
--     - Aggiorna il testo "Avvia irrigazione" / "Interrompi irrigazione"
--
-- showFillTypeInfo:
--   Identifica il tipo di materiale a terra sotto il look ray del player.
--   Aggiorna i dati ogni TICKS_PER_FILLTYPE_UPDATE=50 tick per performance.
--   Per GRASS_WINDROW: mostra quantità, umidità e se richiede voltaggio.
--   Per altri tipi: svuota il box.
--
-- setCurrentRaycastFillTypeCoords:
--   Sostituzione completa del metodo vanilla.
--   Aggiorna le coordinate del look ray solo se cambiate (ottimizzazione).
--   Resetta a nil se le coordinate non sono valide.

RW_PlayerHUDUpdater = {}
RW_PlayerHUDUpdater.TICKS_PER_FILLTYPE_UPDATE = 50  -- intervallo tick tra un aggiornamento fill type e il successivo


-- Helper locale: verifica se il farmland con l'id dato appartiene al player locale.
-- @param id  farmlandId da verificare
-- @return true se il player locale è proprietario del farmland
local function resolveOwnerFarm(id)
    local ownerFarmId = g_farmlandManager:getFarmlandOwner(id)

    if ownerFarmId == nil or ownerFarmId == FarmlandManager.NO_OWNER_FARM_ID or ownerFarmId == FarmManager.SPECTATOR_FARM_ID or ownerFarmId == FarmManager.INVALID_FARM_ID then return false end

    if g_localPlayer == nil then return false end

    return g_localPlayer:getFarmId() == ownerFarmId
end


-- Hook append su PlayerHUDUpdater.showFieldInfo.
-- Aggiunge un box HUD con i dati di umidità del MoistureSystem al pannello info campo.
-- Il box viene creato al primo utilizzo e riutilizzato nei tick successivi.
-- Non mostra nulla se:
--   - moistureSystem non è disponibile
--   - moistureOverlayBehaviour == 1 (overlay disabilitato)
--   - il giocatore è su terreno NONE e moistureOverlayBehaviour == 2
-- @param x  coordinata X mondo del punto sotto il player
-- @param z  coordinata Z mondo del punto sotto il player
function RW_PlayerHUDUpdater:showFieldInfo(x, z)

    if self.moistureBox == nil then self.moistureBox = g_currentMission.hud.infoDisplay:createBox(RW_InfoDisplayKeyValueBox) end

    local box = self.moistureBox

    if box == nil then return end

    box:clear()
    local moistureSystem = g_currentMission.moistureSystem

    if moistureSystem == nil or moistureSystem.moistureOverlayBehaviour == 1 or (self.fieldInfo.groundType == FieldGroundType.NONE and moistureSystem.moistureOverlayBehaviour == 2) then return end

    -- Legge umidità, rischio appassimento e ritenzione per la cella corrente.
    local values = moistureSystem:getValuesAtCoords(x, z, { "moisture", "witherChance", "retention" })

    if values == nil then return end

    local moisture, witherChance, retention = values.moisture, values.witherChance, values.retention

    box:setTitle(g_i18n:getText("rw_ui_moisture"))

    -- Calcola il contributo dell'irrigazione attiva all'umidità apparente.
    local isBeingIrrigated, pendingIrrigationCost = moistureSystem:getIsFieldBeingIrrigated(self.fieldInfo.farmlandId)
    local updater = moistureSystem:getUpdaterAtX(x)
    local irrigationFactor = isBeingIrrigated and (MoistureSystem.IRRIGATION_FACTOR * updater.timeSinceLastUpdate * moistureSystem.moistureGainModifier) or 0

    if self.fieldInfo.groundType ~= FieldGroundType.NONE then

        -- Il player è su un campo: mostra dati completi inclusi irrigazione e resa.
        local id = self.fieldInfo.farmlandId
        local isOwner = false

        if id ~= nil then isOwner = resolveOwnerFarm(id) end

        if id == nil or not isOwner then
            -- Non proprietario: nasconde il pulsante irrigazione.
            if moistureSystem.isShowingIrrigationInput then
                moistureSystem.isShowingIrrigationInput = false
                g_inputBinding:setActionEventActive(moistureSystem.irrigationEventId, false)
            end

        else
            -- Proprietario: mostra e aggiorna il testo del pulsante irrigazione.
            if not moistureSystem.isShowingIrrigationInput or moistureSystem:getIrrigationInputField() ~= id then

                moistureSystem.isShowingIrrigationInput = true
                moistureSystem:setIrrigationInputField(id)

                g_inputBinding:setActionEventActive(moistureSystem.irrigationEventId, true)
                g_inputBinding:setActionEventText(moistureSystem.irrigationEventId, g_i18n:getText("rw_ui_irrigation_" .. (isBeingIrrigated and "stop" or "start")))

            elseif moistureSystem.isShowingIrrigationInput and moistureSystem:getIrrigationInputField() == id then

                g_inputBinding:setActionEventActive(moistureSystem.irrigationEventId, true)
                g_inputBinding:setActionEventText(moistureSystem.irrigationEventId, g_i18n:getText("rw_ui_irrigation_" .. (isBeingIrrigated and "stop" or "start")))

            end

        end

        -- Dati coltura per il calcolo del colore e dell'umidità ideale.
        local fruitType = g_fruitTypeManager:getFruitTypeNameByIndex(self.fieldInfo.fruitTypeIndex)
        local fruit = g_fruitTypeManager:getFruitTypeByIndex(self.fieldInfo.fruitTypeIndex)
        local fruitTypeMoistureFactor = RW_FSBaseMission.FRUIT_TYPES_MOISTURE[fruitType] or RW_FSBaseMission.FRUIT_TYPES_MOISTURE.DEFAULT
        local growthState = self.fieldInfo.growthState
        local isPlanted = fruit ~= nil and (fruit:getIsGrowing(growthState) or fruit:getIsPreparable(growthState) or fruit:getIsHarvestable(growthState))

        local colour = nil

        if isPlanted and fruitTypeMoistureFactor ~= nil then
            -- Colore rosso/verde: verde = umidità vicina all'ideale, rosso = troppo alta o troppo bassa.
            -- moistureDiff = 1.0 → perfetto (verde); < 1 → troppo secco; > 1 → troppo bagnato.
            local moistureDiff = math.clamp((moisture + irrigationFactor * retention) / ((fruitTypeMoistureFactor.LOW + fruitTypeMoistureFactor.HIGH) / 2), 0, 2)

            local r, g = 0, 0

            if moistureDiff < 1 then
                r = 1 - moistureDiff   -- troppo secco → rosso crescente
                g = moistureDiff       -- verde crescente verso l'ideale
            else
                r = moistureDiff - 1   -- troppo bagnato → rosso crescente
                g = 2 - moistureDiff   -- verde decrescente sopra l'ideale
            end

            colour = { r, g, 0, 1 }
        end

        box:addLine(g_i18n:getText("rw_ui_moisture"), string.format("%.3f%%", math.clamp(moisture + irrigationFactor * retention, 0, 1) * 100), colour)

        if fruitTypeMoistureFactor ~= nil then
            box:addLine(g_i18n:getText("rw_ui_idealMoisture"), string.format("%.2f", fruitTypeMoistureFactor.LOW * 100) .. "% - " .. string.format("%.2f", fruitTypeMoistureFactor.HIGH * 100) .. "%")
            box:addLine(g_i18n:getText("rw_ui_perfectMoisture"), string.format("%.2f", ((fruitTypeMoistureFactor.LOW + fruitTypeMoistureFactor.HIGH) / 2) * 100) .. "%")
        end

        if isPlanted then
            local yield = self.fieldInfo:getHarvestScaleMultiplier()
            box:addLine(g_i18n:getText("rw_ui_currentYield"), string.format("%.2f", yield * 100) .. "%")
        end

        -- Rischio appassimento: colore rosso proporzionale al valore.
        box:addLine(g_i18n:getText("rw_ui_witherChance"), string.format("%.2f%%", witherChance * 100), { witherChance, 1 - witherChance, 0, 1 })

    else
        -- Il player è su terreno non coltivato: mostra solo umidità base e nasconde irrigazione.
        box:addLine(g_i18n:getText("rw_ui_moisture"), string.format("%.3f%%", math.clamp(moisture + irrigationFactor * retention, 0, 1) * 100), { 1, 1, 1, 1})

        if moistureSystem.isShowingIrrigationInput then
            moistureSystem.isShowingIrrigationInput = false
            g_inputBinding:setActionEventActive(moistureSystem.irrigationEventId, false)
        end

    end

    -- Ritenzione idrica: colore basato su distanza da 1.0 (verde = ideale, rosso = lontano da 1).
    local retentionDiff = math.abs(1 - retention)
    box:addLine(g_i18n:getText("rw_ui_retention"), string.format("%.2f%%", retention * 100), { retentionDiff, 1 - retentionDiff, 0, 1 })
    box:addLine(g_i18n:getText("input_Irrigation"), g_i18n:getText("rw_ui_" .. (isBeingIrrigated and "active" or "inactive")))

    if pendingIrrigationCost > 0 then box:addLine(g_i18n:getText("rw_ui_pendingIrrigationCost"), g_i18n:formatMoney(pendingIrrigationCost, 2, true, true)) end

    box:showNextFrame()

end

PlayerHUDUpdater.showFieldInfo = Utils.appendedFunction(PlayerHUDUpdater.showFieldInfo, RW_PlayerHUDUpdater.showFieldInfo)


-- Sostituzione completa di PlayerHUDUpdater.setCurrentRaycastFillTypeCoords.
-- Aggiorna le coordinate del look ray del player per il prossimo ciclo showFillTypeInfo.
-- Resetta a nil se le coordinate non sono valide (player non in game o fuori mappa).
-- Ottimizzazione: aggiorna solo se le coordinate sono cambiate rispetto al tick precedente.
-- @param x,y,z        posizione origine del look ray
-- @param dirX,dirY,dirZ  direzione del look ray
function RW_PlayerHUDUpdater:setCurrentRaycastFillTypeCoords(x, y, z, dirX, dirY, dirZ)

    if x == nil or y == nil or z == nil or dirX == nil or dirY == nil or dirZ == nil then
        self.currentRaycastFillTypeCoords = nil
        return
    end

    if self.currentRaycastFillTypeCoords ~= nil then
        local curX, curY, curZ, curDirX, curDirY, curDirZ = unpack(self.currentRaycastFillTypeCoords)
        -- Nessun aggiornamento se le coordinate non sono cambiate.
        if curX == x and curY == y and curZ == z and curDirX == dirX and curDirY == dirY and curDirZ == dirZ then return end
    end

    self.currentRaycastFillTypeCoords = table.pack(x, y, z, dirX, dirY, dirZ)

end

PlayerHUDUpdater.setCurrentRaycastFillTypeCoords = RW_PlayerHUDUpdater.setCurrentRaycastFillTypeCoords


-- Mostra le informazioni sul materiale a terra sotto il look ray del player.
-- Aggiorna i dati ogni TICKS_PER_FILLTYPE_UPDATE=50 tick per non sovraccaricare.
-- Identifica il fillType a terra tramite DensityMapHeightUtil.getFillTypeAtArea.
-- Per GRASS_WINDROW mostra: titolo, quantità, umidità corrente e umidità richiesta (HAY_MOISTURE),
--   e se l'andana necessita di voltaggio (moisture == nil → non tracciata dal GrassMoistureSystem).
-- Per altri fillType: svuota il box (non mostra nulla).
function RW_PlayerHUDUpdater:showFillTypeInfo()

    if self.currentRaycastFillTypeCoords == nil then return end

    if self.ticksSinceLastFillTypeUpdate == nil then self.ticksSinceLastFillTypeUpdate = RW_PlayerHUDUpdater.TICKS_PER_FILLTYPE_UPDATE + 1 end
    if self.currentRaycastFillType == nil then
        self.currentRaycastFillType = {
            name = "UNKNOWN",
            title = "Unknown"
        }
    end

    -- Aggiorna i dati solo ogni TICKS_PER_FILLTYPE_UPDATE tick.
    if self.ticksSinceLastFillTypeUpdate >= RW_PlayerHUDUpdater.TICKS_PER_FILLTYPE_UPDATE then

        self.ticksSinceLastFillTypeUpdate = 0

        local x, y, z, dirX, dirY, dirZ = unpack(self.currentRaycastFillTypeCoords)
        -- Campiona un'area 4×4 metri centrata sul punto del look ray.
        local fillTypeIndex = DensityMapHeightUtil.getFillTypeAtArea(x, z, x - 2, z - 2, x + 2, z + 2)
        local fillType = g_fillTypeManager:getFillTypeNameByIndex(fillTypeIndex)

        if fillType ~= "GRASS_WINDROW" then
            -- Materiale non-erba: salva solo il nome, nessun dato extra.
            self.currentRaycastFillType = {
                name = fillType
            }
        else
            -- Erba: calcola quantità e umidità tramite i sistemi RW.
            local amount = DensityMapHeightUtil.getFillLevelAtArea(fillTypeIndex, x, z, x - 2, z - 2, x + 2, z + 2)
            local found, moisture = g_currentMission.grassMoistureSystem:getMoistureAtArea(x, z)
            local title = g_fillTypeManager:getFillTypeTitleByIndex(fillTypeIndex)

            self.currentRaycastFillType = {
                name = fillType,
                title = title,
                amount = amount
            }

            -- moisture è nil se l'andana non è stata creata con RW (es. esisteva prima del caricamento del mod).
            if found then self.currentRaycastFillType.moisture = moisture end
        end

    end

    self.ticksSinceLastFillTypeUpdate = self.ticksSinceLastFillTypeUpdate + 1

    if self.fillTypeBox == nil then self.fillTypeBox = g_currentMission.hud.infoDisplay:createBox(InfoDisplayKeyValueBox) end

    local box = self.fillTypeBox
    if box == nil then return end

    -- Mostra il box solo per GRASS_WINDROW.
    if self.currentRaycastFillType.name ~= "GRASS_WINDROW" then
        box:clear()
        return
    end

    local fillType = self.currentRaycastFillType

    box:clear()
    box:setTitle(fillType.title)
    box:addLine(g_i18n:getText("rw_ui_amount"), g_i18n:formatVolume(fillType.amount, 0))
    if fillType.moisture ~= nil then
        -- Andana tracciata dal GrassMoistureSystem: mostra umidità corrente e soglia fieno.
        box:addLine(g_i18n:getText("rw_ui_moisture"), string.format("%.2f%%", fillType.moisture * 100))
        box:addLine(g_i18n:getText("rw_ui_requiredMoisture"), string.format("%.2f%%", GrassMoistureSystem.HAY_MOISTURE * 100))
        box:addLine(g_i18n:getText("rw_ui_needsTedding"), g_i18n:getText("rw_ui_no"))
    else
        -- Andana non tracciata: necessita voltaggio per essere gestita correttamente.
        box:addLine(g_i18n:getText("rw_ui_needsTedding"), g_i18n:getText("rw_ui_yes"))
    end

    box:showNextFrame()

end

PlayerHUDUpdater.showFillTypeInfo = RW_PlayerHUDUpdater.showFillTypeInfo


-- Aggiornamento chiamato ogni tick (agganciato via DensityMapHeightManager).
-- Delega a showFillTypeInfo per aggiornare il box del fill type.
function RW_PlayerHUDUpdater:update(_, _, _, _, _)

    self:showFillTypeInfo()

end


-- Hook append su PlayerHUDUpdater.delete.
-- Distrugge i box HUD RW quando il PlayerHUDUpdater viene eliminato (fine sessione).
function RW_PlayerHUDUpdater:delete()

    if self.fillTypeBox ~= nil then g_currentMission.hud.infoDisplay:destroyBox(self.fillTypeBox) end
    if self.moistureBox ~= nil then g_currentMission.hud.infoDisplay:destroyBox(self.moistureBox) end

end

PlayerHUDUpdater.delete = Utils.appendedFunction(PlayerHUDUpdater.delete, RW_PlayerHUDUpdater.delete)
