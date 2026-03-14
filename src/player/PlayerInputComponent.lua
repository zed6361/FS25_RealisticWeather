-- PlayerInputComponent.lua (RW_PlayerInputComponent)
-- Estensione di PlayerInputComponent per integrare due funzionalità RW:
--   1. Aggiornamento dei fill type coords del raycast (per l'HUD del fieno)
--   2. Registrazione dell'action event globale per l'irrigazione
--
-- Hook registrati:
--   PlayerInputComponent.update                       (append via DensityMapHeightManager)
--     → RW_PlayerInputComponent.update
--   PlayerInputComponent.registerGlobalPlayerActionEvents (append)
--     → RW_PlayerInputComponent.registerGlobalPlayerActionEvents
--
-- Nota: l'hook su update viene agganciato in DensityMapHeightManager.lua
-- (solo sul server) tramite Utils.appendedFunction, non in questo file.

RW_PlayerInputComponent = {}
RW_PlayerInputComponent.IRRIGATION_EVENT_ID = nil  -- ID dell'action event irrigazione (condiviso)


-- Hook append su PlayerInputComponent.update.
-- Chiamato ogni tick per il player locale.
-- Solo se il player è il proprietario locale e il contesto input è quello del player:
-- legge il look ray (direzione di visuale) e lo passa all'HUD updater
-- tramite setCurrentRaycastFillTypeCoords per l'identificazione del tipo di erba.
function RW_PlayerInputComponent:update()

    -- Solo per il player locale e solo nel contesto input corretto.
    if not self.player.isOwner or g_inputBinding:getContextName() ~= PlayerInputComponent.INPUT_CONTEXT_NAME then return end

    local x, y, z, dirX, dirY, dirZ = self.player:getLookRay()

    if x == nil or y == nil or z == nil or dirX == nil or dirY == nil or dirZ == nil then return end

    -- Aggiorna le coordinate del raycast nell'HUD updater per il prossimo showFillTypeInfo.
    self.player.hudUpdater:setCurrentRaycastFillTypeCoords(x, y, z, dirX, dirY, dirZ)

end


-- Hook append su PlayerInputComponent.registerGlobalPlayerActionEvents.
-- Registra l'action event per attivare/disattivare l'irrigazione di un campo.
-- L'evento è inizialmente inattivo (viene attivato da showFieldInfo quando
-- il player è sopra un campo di sua proprietà con moistureSystem disponibile).
-- L'ID dell'evento viene salvato sia in IRRIGATION_EVENT_ID (globale)
-- che in moistureSystem.irrigationEventId (per l'aggiornamento del testo).
function RW_PlayerInputComponent:registerGlobalPlayerActionEvents()

    local valid, eventId = g_inputBinding:registerActionEvent(
        InputAction.Irrigation,         -- azione definita in inputActions.xml del mod
        MoistureSystem,                 -- oggetto target del callback
        MoistureSystem.irrigationInputCallback,  -- callback chiamato quando l'utente preme il tasto
        false, true, false, true, nil, false
    )

    -- L'evento parte inattivo: viene abilitato solo quando il player è su un campo di proprietà.
    g_inputBinding:setActionEventActive(eventId, false)

    RW_PlayerInputComponent.IRRIGATION_EVENT_ID = eventId

    -- Registra l'ID anche nel moistureSystem per aggiornarne il testo dinamicamente.
    if g_currentMission.moistureSystem ~= nil and valid then g_currentMission.moistureSystem.irrigationEventId = eventId end

end


PlayerInputComponent.registerGlobalPlayerActionEvents = Utils.appendedFunction(PlayerInputComponent.registerGlobalPlayerActionEvents, RW_PlayerInputComponent.registerGlobalPlayerActionEvents)
