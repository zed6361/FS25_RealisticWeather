-- FieldState.lua (RW_FieldState)
-- Estensione di FieldState per integrare l'umidità del terreno di RealisticWeather
-- nel calcolo della resa e nelle informazioni visualizzate nell'HUD del campo.
--
-- Hook registrati:
--   FieldState.update                (append)   → RW_FieldState.update
--   FieldState.getHarvestScaleMultiplier (override via g_realisticWeather:registerFunction)
--
-- FieldState.update (append):
--   Chiamato ogni volta che FS aggiorna lo stato di un campo (es. quando il player
--   ci cammina sopra o quando l'HUD richiede i dati del campo).
--   Salva le coordinate x/z nel FieldState, poi legge umidità e ritenzione
--   dal MoistureSystem per quelle coordinate.
--   Se il campo è sotto irrigazione attiva, calcola il contributo dell'irrigazione:
--     irrigationFactor = IRRIGATION_FACTOR × timeSinceLastUpdate
--   e lo somma all'umidità: moisture += irrigationFactor × retention
--   Il risultato è clampato in [0, 1].
--   self.moisture = nil se il moistureSystem non è disponibile o non ha dati per quella cella.
--
-- FieldState.getHarvestScaleMultiplier (override):
--   Prima di chiamare la funzione vanilla, salva self.moisture in g_realisticWeather.fieldMoisture.
--   Questo valore viene letto da FSBaseMission.getHarvestScaleMultiplier (override in
--   RealisticWeather.lua) per scalare la resa in base all'umidità del campo.
--   Dopo la chiamata, reimposta fieldMoisture a nil per evitare contaminazioni
--   tra chiamate consecutive.

RW_FieldState = {}


-- Hook append su FieldState.update.
-- Aggiorna self.moisture con il valore letto dal MoistureSystem (+ contributo irrigazione).
-- @param x  coordinata X mondo del punto del campo
-- @param z  coordinata Z mondo del punto del campo
function RW_FieldState:update(x, z)

    local moistureSystem = g_currentMission.moistureSystem

    -- Salva le coordinate per uso successivo (es. da getHarvestScaleMultiplier e HUD).
    self.x, self.z = x, z

    if moistureSystem == nil then return end

    local values = moistureSystem:getValuesAtCoords(x, z, { "moisture", "retention" } )

    if values == nil or values.moisture == nil then
        -- Cella non presente nella griglia: nessun dato di umidità disponibile.
        self.moisture = nil
    else
        self.moisture = values.moisture
        -- Calcola il contributo dell'irrigazione attiva: IRRIGATION_FACTOR × timeSinceLastUpdate.
        local isBeingIrrigated, _ = moistureSystem:getIsFieldBeingIrrigated(self.farmlandId)
        local updater = moistureSystem:getUpdaterAtX(x)
        local irrigationFactor = isBeingIrrigated and (MoistureSystem.IRRIGATION_FACTOR * updater.timeSinceLastUpdate) or 0
        -- Somma irrigazione scalata per la ritenzione idrica del terreno, clampata in [0,1].
        self.moisture = math.clamp(self.moisture + irrigationFactor * (values.retention or 1), 0, 1)
    end

end

FieldState.update = Utils.appendedFunction(FieldState.update, RW_FieldState.update)

-- Override di FieldState.getHarvestScaleMultiplier tramite il sistema registerFunction di RW.
-- Espone self.moisture al sistema di calcolo della resa di FSBaseMission
-- tramite la variabile globale temporanea g_realisticWeather.fieldMoisture.
-- La variabile viene resettata a nil subito dopo la chiamata vanilla
-- per garantire che non influenzi altre chiamate non correlate.
function FieldState:getHarvestScaleMultiplier()

    -- Rende l'umidità del campo disponibile all'override di getHarvestScaleMultiplier
    -- in FSBaseMission, che la usa per calcolare il moltiplicatore di resa RW.
    g_realisticWeather.fieldMoisture = self.moisture

    local yield = g_currentMission:getHarvestScaleMultiplier(
        self.fruitTypeIndex,
        self.sprayLevel,
        self.plowLevel,
        self.limeLevel,
        self.weedFactor,
        self.stubbleShredLevel,
        self.rollerLevel,
        0,
        self.moisture
    )
    -- Pulizia: evita che il valore rimanga accessibile dopo la chiamata.
    g_realisticWeather.fieldMoisture = nil

    return yield

end
