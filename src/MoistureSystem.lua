-- =============================================================================
-- MoistureSystem.lua
-- Sistema principale di gestione dell'umidità del terreno per RealisticWeather.
-- Gestisce una griglia di celle su tutta la mappa, aggiornando i valori
-- di umidità in base alle condizioni meteo e all'irrigazione. Propagando
-- appassimento delle colture e creazione di pozzanghere.
-- Supporta il multiplayer tramite sincronizzazione a sequenze numerate.
-- =============================================================================

MoistureSystem = {}

MoistureSystem.VERSION = "1.2.1.0"

-- Aggiunge la statistica "irrigationUpkeep" al sistema finanziario di FS
table.insert(FinanceStats.statNames, "irrigationUpkeep")
FinanceStats.statNameToIndex["irrigationUpkeep"] = #FinanceStats.statNames

-- Dimensioni delle celle della griglia di umidità (in metri) per livello di performance
-- Indice più alto = celle più piccole = più precisione = più carico CPU
MoistureSystem.CELL_WIDTH = {
    [1] = 15, [2] = 12, [3] = 10, [4] = 7, [5] = 5, [6] = 4
}
MoistureSystem.CELL_HEIGHT = {
    [1] = 15, [2] = 12, [3] = 10, [4] = 7, [5] = 5, [6] = 4
}

-- Indice di stato predefinito (1–9) nella lista valori dell'impostazione performanceIndex.
-- Viene usato come indice nell'array { 2,3,4,5,6,7,8,9,10 }; il valore selezionato
-- determina il numero di updater tramite state^2 (es. values[2]=3 → 9 updater).
-- Hardware più potente (ULTRA) → indice basso → pochi updater → aggiornamento mappa più frequente.
-- Hardware più debole (VERY_LOW) → indice alto → molti updater → carico distribuito su più tick.
-- NOTA: questo NON è un indice in CELL_WIDTH; le dimensioni delle celle si basano su Utils.getPerformanceClassId().
MoistureSystem.DEFAULT_PERFORMANCE_INDEXES = {
    [GS_PROFILE_ULTRA] = 2,
    [GS_PROFILE_VERY_HIGH] = 3,
    [GS_PROFILE_HIGH] = 4,
    [GS_PROFILE_MEDIUM] = 5,
    [GS_PROFILE_LOW] = 8,
    [GS_PROFILE_VERY_LOW] = 9
}

MoistureSystem.MAP_WIDTH = 2048               -- larghezza di default della mappa (metri)
MoistureSystem.MAP_HEIGHT = 2048              -- altezza di default della mappa (metri)
MoistureSystem.TICKS_PER_UPDATE = 60          -- tick tra un aggiornamento completo e il successivo
MoistureSystem.IRRIGATION_FACTOR = 0.0000008  -- incremento di umidità per tick per cella irrigata
MoistureSystem.SPRAY_FACTOR = {               -- guadagno umidità per tipo di spray applicato
    ["slurry"] = 0.000045,
    ["fertilizer"] = 0.000015
}
MoistureSystem.IRRIGATION_BASE_COST = 0.00000025 -- costo base irrigazione per cella per secondo

local moistureSystem_mt = Class(MoistureSystem)


-- -----------------------------------------------------------------------------
-- MoistureSystem.new()
-- Costruttore. Inizializza la griglia, registra i test di performance,
-- configura il doppio buffer di aggiornamento, e si abbona agli eventi
-- di gioco (ora, giorno, entrata/uscita veicolo).
-- -----------------------------------------------------------------------------
function MoistureSystem.new()

    local self = setmetatable({}, moistureSystem_mt)

    g_optimisationTest:registerTest("Moisture Update Queue")
    g_optimisationTest:registerTest("Moisture Update")
    g_optimisationTest:registerTest("Moisture Calc 1")
    g_optimisationTest:registerTest("Moisture Calc 2")
    g_optimisationTest:registerTest("Moisture Calc 3")

    self.mission = g_currentMission
    self.rows = {}              -- griglia [x][z] = { moisture, retention, trend, witherChance }
    self.isServer = self.mission:getIsServer()
    self.lastMoistureDelta = 0
    self.ticksSinceLastUpdate = MoistureSystem.TICKS_PER_UPDATE + 1  -- forza aggiornamento al primo tick
    self.currentHourlyUpdateQuarter = 1
    self.numRows = 0
    self.numColumns = 0
    self.cellWidth, self.cellHeight = MoistureSystem.CELL_WIDTH[4], MoistureSystem.CELL_HEIGHT[4]
    self.mapWidth, self.mapHeight = MoistureSystem.MAP_WIDTH, MoistureSystem.MAP_HEIGHT
    self.isShowingIrrigationInput = false
    self.irrigationEventId = RW_PlayerInputComponent.IRRIGATION_EVENT_ID
    self.isSaving = false       -- blocca aggiornamenti durante il salvataggio

    self.pendingIrrigationCosts = 0
    self.irrigatingFields = {}  -- { [fieldId] = { id, pendingCost, isActive } }
    self.irrigationInputField = nil

    -- Stato sincronizzazione multiplayer
    self.needsSync = false
    self.syncSequence = 0
    self.lastAppliedSyncSequence = 0

    -- Impostazioni configurabili dall'utente
    self.witheringEnabled = true
    self.witheringChance = 1
    self.performanceIndex = 4
    self.moistureGainModifier = 1
    self.moistureLossModifier = 1
    self.moistureOverlayBehaviour = 3
    self.moistureFrameBehaviour = 1

    -- Doppio buffer: permette di aggiornare una metà della mappa per volta
    self.currentHourlyUpdateIteration = 1
    self.currentUpdateIteration = 1
    self.updateIterations = {
        { ["moistureDelta"] = 0, ["timeSinceLastUpdate"] = 0, ["cacheUpdatePending"] = true, ["pendingSync"] = { ["numRows"] = 0 } },
        { ["moistureDelta"] = 0, ["timeSinceLastUpdate"] = 0, ["cacheUpdatePending"] = true, ["pendingSync"] = { ["numRows"] = 0 } }
    }

    self.updateQueue = {}

    -- Registra il tipo di spesa irrigazione nel sistema finanziario
    MoneyType.IRRIGATION_UPKEEP = MoneyType.register("irrigationUpkeep", "rw_ui_irrigationUpkeep")
    MoneyType.LAST_ID = MoneyType.LAST_ID + 1

    g_messageCenter:subscribe(MessageType.HOUR_CHANGED, self.onHourChanged, self)
    g_messageCenter:subscribe(MessageType.DAY_CHANGED, self.onDayChanged, self)
    g_messageCenter:subscribe(MessageType.OWN_PLAYER_ENTERED, self.onEnterVehicle, self)
    g_messageCenter:subscribe(MessageType.OWN_PLAYER_LEFT, self.onLeaveVehicle, self)

    return self

end


-- -----------------------------------------------------------------------------
-- MoistureSystem:delete()
-- Distrugge l'istanza del sistema di umidità.
-- -----------------------------------------------------------------------------
function MoistureSystem:delete()
    self = nil
end


-- -----------------------------------------------------------------------------
-- MoistureSystem:saveToXMLFile(path)
-- Salva la griglia di umidità e i campi irrigati in un file XML.
-- Imposta isSaving=true per bloccare gli aggiornamenti durante il salvataggio.
-- -----------------------------------------------------------------------------
function MoistureSystem:saveToXMLFile(path)

    if path == nil then return end

    local xmlFile = XMLFile.create("moistureXML", path, "moisture")
    if xmlFile == nil then return end

    self.isSaving = true

    local key = "moisture"

    xmlFile:setFloat(key .. "#cellWidth", self.cellWidth or 5)
    xmlFile:setFloat(key .. "#cellHeight", self.cellHeight or 5)
    xmlFile:setFloat(key .. "#mapWidth", self.mapWidth or 2048)
    xmlFile:setFloat(key .. "#mapHeight", self.mapHeight or 2048)

    -- Salva i campi irrigati
    xmlFile:setTable(key .. ".irrigation.field", self.irrigatingFields, function (irrigationKey, field)
        xmlFile:setInt(irrigationKey .. "#id", field.id)
        xmlFile:setFloat(irrigationKey .. "#pending", field.pendingCost)
        xmlFile:setBool(irrigationKey .. "#active", field.isActive)
    end)

    -- Salva righe e colonne della griglia
    xmlFile:setTable(key .. ".rows.row", self.rows, function (rowKey, row)
        xmlFile:setFloat(rowKey .. "#x", row.x)
        xmlFile:setTable(rowKey .. ".columns.column", row.columns, function (columnKey, column)
            xmlFile:setFloat(columnKey .. "#z", column.z)
            xmlFile:setFloat(columnKey .. "#m", column.moisture)
            xmlFile:setFloat(columnKey .. "#r", column.retention)
            xmlFile:setFloat(columnKey .. "#t", column.trend)
            -- Salva witherChance solo se diverso da 0 (risparmio spazio)
            if column.witherChance ~= nil and column.witherChance ~= 0 then xmlFile:setFloat(columnKey .. "#w", column.witherChance) end
        end)
    end)

    xmlFile:save(false, true)
    xmlFile:delete()
    self.isSaving = false

end


-- -----------------------------------------------------------------------------
-- MoistureSystem:loadFromXMLFile(mapXmlFile)
-- Carica la griglia dal file XML della partita salvata.
-- Se il file non esiste, genera una nuova mappa procedurale.
-- Parametri:
--   mapXmlFile : XML della mappa (usato per le dimensioni in caso di nuova generazione)
-- -----------------------------------------------------------------------------
function MoistureSystem:loadFromXMLFile(mapXmlFile)

    local savegameIndex = g_careerScreen.savegameList.selectedIndex
    local savegame = g_savegameController:getSavegame(savegameIndex)

    if savegame == nil or savegame.savegameDirectory == nil then
        self:generateNewMapMoisture(mapXmlFile)
        table.sort(self.rows)
        return
    end

    local path = savegame.savegameDirectory .. "/moisture.xml"
    local xmlFile = XMLFile.loadIfExists("moistureXML", path)

    if xmlFile == nil then
        self:generateNewMapMoisture(mapXmlFile)
    else

        local numRows = 0
        local numColumns = 0
        local key = "moisture"

        self.cellWidth, self.cellHeight = xmlFile:getFloat(key .. "#cellWidth", 5), xmlFile:getFloat(key .. "#cellHeight", 5)
        self.mapWidth, self.mapHeight = xmlFile:getFloat(key .. "#mapWidth", 2048), xmlFile:getFloat(key .. "#mapHeight", 2048)

        xmlFile:iterate(key .. ".irrigation.field", function (_, irrigationKey)
            local id = xmlFile:getInt(irrigationKey .. "#id", 1)
            local field = {
                ["id"] = id,
                ["pendingCost"] = xmlFile:getFloat(irrigationKey .. "#pending", 0),
                ["isActive"] = xmlFile:getBool(irrigationKey .. "#active", true)
            }
            self.irrigatingFields[id] = field
        end)

        xmlFile:iterate(key .. ".rows.row", function (_, rowKey)
            local x = xmlFile:getFloat(rowKey .. "#x", 0)
            local row = { ["x"] = x, ["columns"] = {} }

            xmlFile:iterate(rowKey .. ".columns.column", function (_, columnKey)
                local z = xmlFile:getFloat(columnKey .. "#z", 0)
                local moisture = xmlFile:getFloat(columnKey .. "#m", 0)
                local retention = xmlFile:getFloat(columnKey .. "#r", 1)
                local trend = xmlFile:getFloat(columnKey .. "#t", moisture)
                local witherChance = xmlFile:getFloat(columnKey .. "#w", 0)

                if numRows == 0 then numColumns = numColumns + 1 end
                row.columns[z] = { ["z"] = z, ["moisture"] = math.clamp(moisture, 0, 1), ["witherChance"] = witherChance, ["retention"] = retention, ["trend"] = trend }
            end)

            self.rows[x] = row
            numRows = numRows + 1
        end)

        self.numRows = numRows
        self.numColumns = numColumns
        xmlFile:delete()

    end

    table.sort(self.rows)

end


-- -----------------------------------------------------------------------------
-- MoistureSystem:sendInitialState(connection)
-- Placeholder per l'invio dello stato iniziale ai client (attualmente non usato,
-- sostituito da MoistureSyncEvent).
-- -----------------------------------------------------------------------------
function MoistureSystem:sendInitialState(connection)
    --connection:sendEvent(MoistureStateEvent.new(...))
end


-- -----------------------------------------------------------------------------
-- MoistureSystem:setInitialState(...)
-- Imposta lo stato iniziale ricevuto dal server (usato dal client al join MP).
-- -----------------------------------------------------------------------------
function MoistureSystem:setInitialState(cellWidth, cellHeight, mapWidth, mapHeight, currentHourlyUpdateQuarter, numRows, numColumns, rows, irrigatingFields)
    self.cellWidth, self.cellHeight, self.mapWidth, self.mapHeight, self.currentHourlyUpdateQuarter, self.numRows, self.numColumns, self.rows, self.irrigatingFields = cellWidth, cellHeight, mapWidth, mapHeight, currentHourlyUpdateQuarter, numRows, numColumns, rows, irrigatingFields
end


-- -----------------------------------------------------------------------------
-- MoistureSystem:generateNewMapMoisture(xmlFile, force)
-- Genera proceduralmente una nuova griglia di umidità.
-- I valori sono semi-casuali ma spazialmente coerenti: ogni cella dipende
-- dalle celle vicine per creare variazioni naturali (zone secche/umide).
-- Con force=true rigenera in-game e sincronizza la nuova mappa in MP.
-- Parametri:
--   xmlFile : XML della mappa (per leggere dimensioni)
--   force   : se true, forza la rigenerazione a partita in corso
-- -----------------------------------------------------------------------------
function MoistureSystem:generateNewMapMoisture(xmlFile, force)

    print(string.format("--- RealisticWeather (%s) ---", MoistureSystem.VERSION), "--- Generating map moisture cell system")

    self.updateQueue = {}

    if not force then

        if xmlFile == nil then return end

        local performanceIndex = Utils.getPerformanceClassId()

        -- In modalità server multiplayer, forza un minimo di performance per evitare lag
        if g_server ~= nil and g_server.netIsRunning and performanceIndex <= 3 then
            performanceIndex = 4
            self.performanceIndex = 4
            print("--- Generating on server mode")
        end

        self.cellWidth, self.cellHeight = MoistureSystem.CELL_WIDTH[performanceIndex], MoistureSystem.CELL_HEIGHT[performanceIndex]

        -- Scala le celle in base alle dimensioni reali della mappa
        local width, height = getXMLInt(xmlFile, "map#width"), getXMLInt(xmlFile, "map#height")
        self.mapWidth, self.mapHeight = width, height
        self.cellWidth, self.cellHeight = self.cellWidth * (self.mapWidth / 2048), self.cellHeight * (self.mapHeight / 2048)

    else

        print("--- Force deleting and rebuilding moisture map")
        self.rows = {}
        self.isSaving = true

        for _, updateIteration in pairs(self.updateIterations) do
            updateIteration.moistureDelta = 0
            updateIteration.timeSinceLastUpdate = 0
            updateIteration.cacheUpdatePending = true
            updateIteration.pendingSync = { ["numRows"] = 0 }
        end

        self.currentUpdateIteration = 1
        for _, irrigatingField in pairs(self.irrigatingFields) do irrigatingField.isActive = false end

    end

    print(string.format("--- Map dimensions: %sx%s", self.mapWidth, self.mapHeight), string.format("--- Cell dimensions: %sx%s", self.cellWidth, self.cellHeight))

    local firstRow = true
    local numRows = 0
    local numColumns = 0
    local baseMoisture = math.random(125, 200) / 1000  -- umidità base casuale tra 12.5% e 20%
    local i = 0

    for x = -self.mapWidth / 2, self.mapWidth / 2, self.cellWidth do

        local row = { ["x"] = x, ["columns"] = {} }
        local firstColumn = true

        local currentTime = tonumber(getDate("%Y%m%d%H%M%S") or "10000000")
        i = i + math.random() * (x + 1.5 * math.abs(x))
        math.randomseed(i + currentTime)

        for z = -self.mapHeight / 2, self.mapHeight / 2, self.cellHeight do

            local moisture
            if firstRow then numColumns = numColumns + 1 end

            local isIncrease = math.random() >= 0.5
            local seconds = getTimeSec() * 1000000
            local seed = (seconds % math.random(3, 30)) * (math.random(500, 1500) / 1000)

            if firstRow and firstColumn then
                -- Prima cella: usa l'umidità base con piccola variazione
                firstColumn = false
                moisture = (isIncrease and math.random(baseMoisture * 1000, baseMoisture * 1015) or math.random(baseMoisture * 985, baseMoisture * 1000)) / 1000
            else
                if firstColumn then
                    -- Prima colonna: basata sulla cella della riga precedente
                    firstColumn = false
                    local downMoisture = self.rows[x - self.cellWidth].columns[z].moisture
                    moisture = (isIncrease and math.random(downMoisture * 1000, downMoisture * 1015) or math.random(downMoisture * 985, downMoisture * 1000)) / 1000
                elseif firstRow then
                    -- Prima riga: basata sulla cella a sinistra
                    local leftMoisture = row.columns[z - self.cellHeight].moisture
                    moisture = (isIncrease and math.random(leftMoisture * 1000, leftMoisture * 1015) or math.random(leftMoisture * 985, leftMoisture * 1000)) / 1000
                else
                    -- Celle interne: interpolate tra cella sinistra e cella sotto
                    local leftMoisture = row.columns[z - self.cellHeight].moisture * 1000
                    local downMoisture = self.rows[x - self.cellWidth].columns[z].moisture * 1000
                    if leftMoisture > downMoisture then
                        moisture = (isIncrease and math.random(downMoisture * 1, leftMoisture * 1.015) or math.random(downMoisture * 0.985, leftMoisture * 1)) / 1000
                    else
                        moisture = (isIncrease and math.random(leftMoisture * 1, downMoisture * 1.015) or math.random(leftMoisture * 0.985, downMoisture * 1)) / 1000
                    end
                end
            end

            -- Variazioni locali: zone molto secche (seed<1) o molto umide (seed>=22)
            if seed < 1 then
                moisture = moisture * (math.random(250, 500) / 1000)
            elseif seed >= 22 then
                moisture = moisture * (math.random(1500, 1750) / 1000)
            end

            moisture = math.clamp(moisture, 0, 1)
            moisture = math.clamp(moisture, baseMoisture * 0.25, baseMoisture * 1.75)

            row.columns[z] = {
                ["z"] = z,
                ["moisture"] = moisture,
                ["witherChance"] = 0,
                ["retention"] = math.clamp(moisture / baseMoisture, 0.25, 1.75),  -- capacità di trattenere/perdere umidità
                ["trend"] = moisture
            }

        end

        self.rows[x] = row
        numRows = numRows + 1
        firstRow = false

    end

    self.numRows = numRows
    self.numColumns = numColumns
    self.isSaving = false

    print(string.format("--- Generated %s rows with %s columns each", numRows, numColumns))

    -- Se forzato, sincronizza la nuova mappa con i client MP
    if force then
        self.syncSequence = self.syncSequence + 1
        local event = MoistureSyncEvent.new(self.rows, true, self.syncSequence, self.syncSequence)
        if self.isServer then
            g_server:broadcastEvent(event)
        else
            g_client:getServerConnection():sendEvent(event)
        end
    end

end


---Get target values at coordinates
-- @param float x x coordinate
-- @param float z z coordinate
-- @param table values values in the format { "key" }
-- @return boolean values values in the format { ["key"] = value }
-- -----------------------------------------------------------------------------
-- MoistureSystem:getValuesAtCoords(x, z, values)
-- Legge i valori richiesti dalla cella più vicina alle coordinate date.
-- Per "moisture" applica il delta corrente e un safeZoneFactor che evita
-- valori estremi. Restituisce nil se fuori griglia o durante il salvataggio.
-- Parametri:
--   x      : coordinata X nel mondo
--   z      : coordinata Z nel mondo
--   values : tabella di chiavi da leggere, es. { "moisture", "retention" }
-- -----------------------------------------------------------------------------
function MoistureSystem:getValuesAtCoords(x, z, values)

    if values == nil or #values == 0 or self.isSaving then return nil end

    -- Allinea le coordinate alla griglia di celle
    x = math.ceil(x)
    z = math.ceil(z)
    x = x - math.fmod(x + self.mapWidth / 2, self.cellWidth)
    z = z - math.fmod(z + self.mapHeight / 2, self.cellHeight)

    local row = self.rows[x]
    if row == nil or row.columns == nil then return nil end

    local column = row.columns[z]

    if column ~= nil then

        local returnValues = {}

        for _, value in pairs(values) do

            returnValues[value] = value == "retention" and column[value] or math.clamp(column[value] or 0, 0, 1)

            if value == "moisture" then

                local delta = self:getUpdaterAtX(row.x).moistureDelta
                local safeZoneFactor = 1

                -- Rallenta la perdita quando l'umidità è quasi esaurita
                if column.moisture < 0.06 and delta < 0 then
                    safeZoneFactor = (2 - column.retention) * column.moisture * 20
                -- Rallenta il guadagno quando l'umidità è già alta
                elseif column.moisture > 0.275 and delta > 0 then
                    safeZoneFactor = (column.retention / column.moisture) * 0.05
                end

                if delta >= 0 then
                    returnValues[value] = returnValues[value] + delta * column.retention * safeZoneFactor
                else
                    returnValues[value] = returnValues[value] + delta * (2 - column.retention) * safeZoneFactor
                end

            end

            if not self.witheringEnabled and value == "witherChance" then returnValues[value] = 0 end

        end

        return returnValues

    end

    return nil

end


---Set target values at coordinates
-- @param float x x coordinate
-- @param float z z coordinate
-- @param table values values in the format { ["key"] = value } (aggiunto al valore corrente)
-- @param boolean addToPendingSync accoda la modifica per sync MP
-- -----------------------------------------------------------------------------
-- MoistureSystem:setValuesAtCoords(x, z, values, addToPendingSync)
-- Somma i valori dati alla cella della griglia alle coordinate indicate.
-- Se addToPendingSync=true, accoda la modifica per la sincronizzazione MP.
-- -----------------------------------------------------------------------------
function MoistureSystem:setValuesAtCoords(x, z, values, addToPendingSync)

    if values == nil or self.isSaving then return end

    x = math.ceil(x)
    z = math.ceil(z)
    x = x - math.fmod(x + self.mapWidth / 2, self.cellWidth)
    z = z - math.fmod(z + self.mapHeight / 2, self.cellHeight)

    local row = self.rows[x]
    if row == nil or row.columns == nil then return end

    local column = row.columns[z]
    if column == nil then return end

    for target, value in pairs(values) do
        if column[target] == nil then
            column[target] = value
        else
            column[target] = math.clamp(column[target] + value, 0, 1)
        end

        if addToPendingSync then

            local updater = self:getUpdaterAtX(x)

            if updater ~= nil then

                if updater.pendingSync[x] == nil then
                    updater.pendingSync[x] = { ["numColumns"] = 0 }
                    updater.pendingSync.numRows = updater.pendingSync.numRows + 1
                end

                if updater.pendingSync[x][z] == nil then
                    updater.pendingSync[x][z] = { [target] = value }
                    updater.pendingSync[x].numColumns = updater.pendingSync[x].numColumns + 1
                elseif updater.pendingSync[x][z][target] == nil then
                    updater.pendingSync[x][z][target] = value
                else
                    updater.pendingSync[x][z][target] = updater.pendingSync[x][z][target] + value
                end

            end

        end

    end

end


-- -----------------------------------------------------------------------------
-- MoistureSystem:update(delta, timescale)
-- Chiamata ogni tick. Accumula il delta meteo, costruisce la coda di celle
-- da aggiornare (round-robin su metà mappa per volta), invia sync MP pendenti,
-- e delega l'aggiornamento effettivo a processUpdateQueue().
-- Aggiorna anche pozzanghere e sistema fuoco ogni N tick.
-- Parametri:
--   delta     : variazione umidità atmosferica nel tick (da sistema meteo)
--   timescale : fattore tempo di gioco
-- -----------------------------------------------------------------------------
function MoistureSystem:update(delta, timescale)

    if self.isSaving then return end

    -- Accumula delta e tempo su tutti i buffer
    for _, updateIteration in pairs(self.updateIterations) do
        updateIteration.moistureDelta = updateIteration.moistureDelta + delta
        updateIteration.timeSinceLastUpdate = updateIteration.timeSinceLastUpdate + timescale / (MoistureSystem.TICKS_PER_UPDATE)
    end

    local puddleSystem = g_currentMission.puddleSystem
    local fireSystem = g_currentMission.fireSystem

    if self.ticksSinceLastUpdate >= MoistureSystem.TICKS_PER_UPDATE then

        local isIrrigatingFields = false
        for _, field in pairs(self.irrigatingFields) do
            if field.isActive then isIrrigatingFields = true; break end
        end

        -- Determina la porzione di mappa da aggiornare (round-robin)
        local maxRows = self.numRows / #self.updateIterations
        local i = 0

        if self.currentUpdateIteration > #self.updateIterations then self.currentUpdateIteration = 1 end

        local updaterWidth = self.mapWidth / #self.updateIterations
        local x = -self.mapWidth / 2 + (self.currentUpdateIteration - 1) * updaterWidth

        local updater = self.updateIterations[self.currentUpdateIteration]

        x = math.round(x)

        -- Corregge x se non corrisponde esattamente a una riga della griglia
        for correctionOffset = -self.cellWidth, self.cellWidth do
            if self.rows[x + correctionOffset] ~= nil then
                x = x + correctionOffset
                break
            end
        end

        -- Costruisce la coda di celle da processare
        local updateQueue = {}
        if self.rows[x] ~= nil then
            while i <= maxRows do
                local row = self.rows[x]
                if row == nil then break end
                if row.columns == nil then i = i + 1; x = x + self.cellWidth; continue end
                for z, column in pairs(row.columns) do table.insert(updateQueue, { ["x"] = x, ["z"] = z }) end
                i = i + 1
                x = x + self.cellWidth
            end
        end

        self.updateQueue.queue = updateQueue
        self.updateQueue.count = #updateQueue
        self.updateQueue.cacheUpdatePending = updater.cacheUpdatePending
        self.updateQueue.isIrrigatingFields = isIrrigatingFields

        self.lastMoistureDelta = self.updateIterations[self.currentUpdateIteration].moistureDelta
        self.lastTimeSinceLastUpdate = self.updateIterations[self.currentUpdateIteration].timeSinceLastUpdate

        -- Resetta il buffer corrente
        self.updateIterations[self.currentUpdateIteration].moistureDelta = 0
        self.updateIterations[self.currentUpdateIteration].timeSinceLastUpdate = 0
        self.updateIterations[self.currentUpdateIteration].cacheUpdatePending = false

        -- Invia sync MP per le modifiche accumulate
        if updater.pendingSync ~= nil and updater.pendingSync.numRows ~= nil and updater.pendingSync.numRows > 0 then
            -- RW_PERF_FIX: sync delta-riga con sequenze deterministiche
            self.syncSequence = self.syncSequence + 1
            local event = MoistureSyncEvent.new(updater.pendingSync, false, self.syncSequence, self.syncSequence - 1)
            if self.isServer then
                g_server:broadcastEvent(event)
            else
                g_client:getServerConnection():sendEvent(event)
            end
            updater.pendingSync = { ["numRows"] = 0 }
        end

        self.moistureDelta = 0
        self.ticksSinceLastUpdate = 0
        self.timeSinceLastUpdate = 0
        self.currentUpdateIteration = self.currentUpdateIteration + 1
        if self.currentUpdateIteration > #self.updateIterations then self.currentUpdateIteration = 1 end

        puddleSystem:update(timescale, self)

    else
        puddleSystem.timeSinceLastUpdate = puddleSystem.timeSinceLastUpdate + timescale
    end

    -- Aggiorna il sistema fuoco ogni 10 tick
    if self.ticksSinceLastUpdate % 10 == 0 then
        fireSystem:update(timescale, self.ticksSinceLastUpdate == 0)
    elseif fireSystem.fieldId ~= nil then
        fireSystem.timeSinceLastUpdate = fireSystem.timeSinceLastUpdate + timescale
    end

    self.ticksSinceLastUpdate = self.ticksSinceLastUpdate + 1
    self:processUpdateQueue()

end


-- -----------------------------------------------------------------------------
-- MoistureSystem:processUpdateQueue()
-- Processa una porzione della coda di celle per il tick corrente.
-- Per ogni cella: aggiorna l'umidità con delta + irrigazione + safeZone,
-- e crea pozzanghere se l'umidità supera 0.3 su terreno non nudo.
-- -----------------------------------------------------------------------------
function MoistureSystem:processUpdateQueue()

    local queue = self.updateQueue.queue
    if queue == nil or #queue == 0 then return end

    -- Distribuisce il carico uniformemente su TICKS_PER_UPDATE tick
    local numToProcess = self.updateQueue.count / MoistureSystem.TICKS_PER_UPDATE
    if numToProcess > #queue then numToProcess = #queue end

    local cacheUpdatePending, isIrrigatingFields = self.updateQueue.cacheUpdatePending, self.updateQueue.isIrrigatingFields
    local fieldGroundSystem = g_currentMission.fieldGroundSystem
    local puddleSystem = g_currentMission.puddleSystem
    local canCreatePuddle = puddleSystem:getCanCreatePuddle()
    local moistureDelta, timeSinceLastUpdate = self.lastMoistureDelta, self.lastTimeSinceLastUpdate

    local row, lastX

    for i = 1, numToProcess do

        local x, z = queue[1].x, queue[1].z
        table.remove(queue, 1)

        if lastX ~= x then row = self.rows[x]; lastX = x end

        local column = row.columns[z]
        if column == nil then continue end

        -- Cache: aggiorna tipo terreno e campo di appartenenza una volta al giorno
        if cacheUpdatePending then
            local groundTypeValue = fieldGroundSystem:getValueAtWorldPos(FieldDensityMap.GROUND_TYPE, x, 0, z)
            column.fieldId = g_farmlandManager:getFarmlandIdAtWorldPosition(x, z)
            column.groundType = FieldGroundType.getTypeByValue(groundTypeValue)
        end

        -- Calcola il contributo dell'irrigazione
        local irrigationFactor = 0
        if isIrrigatingFields then
            local fieldId = column.fieldId
            if fieldId ~= nil and self.irrigatingFields[fieldId] ~= nil and self.irrigatingFields[fieldId].isActive then
                irrigationFactor = MoistureSystem.IRRIGATION_FACTOR * timeSinceLastUpdate * self.moistureGainModifier
                self.irrigatingFields[fieldId].pendingCost = self.irrigatingFields[fieldId].pendingCost + self.cellWidth * self.cellHeight * timeSinceLastUpdate * MoistureSystem.IRRIGATION_BASE_COST
            end
        end

        -- SafeZone: evita valori estremi di umidità basandosi sulla retention
        local safeZoneFactor = 1
        if column.moisture < 0.06 and moistureDelta < 0 then
            safeZoneFactor = (2 - column.retention) * column.moisture * 20
        elseif column.moisture > 0.275 and moistureDelta > 0 then
            safeZoneFactor = (column.retention / column.moisture) * 0.05
        end

        -- Applica il delta: retention amplifica guadagni, (2-retention) amplifica perdite
        if moistureDelta >= 0 then
            column.moisture = column.moisture + irrigationFactor * column.retention + moistureDelta * column.retention * safeZoneFactor
        else
            column.moisture = column.moisture + irrigationFactor * column.retention + moistureDelta * (2 - column.retention) * safeZoneFactor
        end

        -- Crea una pozzanghera se umidità >= 0.3 e il terreno è un campo
        if canCreatePuddle and column.moisture >= 0.3 then
            local groundType = column.groundType
            if groundType ~= nil and groundType ~= FieldGroundType.NONE then
                local closestPuddle = puddleSystem:getClosestPuddleToPoint(x, z)
                -- Crea solo se non c'è una pozzanghera nelle vicinanze (>100m)
                if closestPuddle.puddle == nil or closestPuddle.distance > 100 then
                    canCreatePuddle = false
                    local terrainHeight = getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z)
                    local variation = puddleSystem:getRandomVariation()
                    local puddle = Puddle.new(variation.id, terrainHeight)
                    puddleSystem:addPuddle(puddle)
                    puddle:setMoisture(column.moisture)
                    puddle:setPosition(x, terrainHeight + math.clamp((column.moisture - 0.3) * 0.25, 0, 0.2), z)
                    puddle:setScale(column.moisture - 0.3, column.moisture - 0.3)
                    puddle:setRotation(0, math.random(-180, 180) * 0.01, 0)
                    puddle:initialize()
                    NewPuddleEvent.sendEvent(puddle)
                end
            end
        end

    end

end


-- -----------------------------------------------------------------------------
-- MoistureSystem:onDayChanged()
-- Al cambio di giorno: forza il refresh della cache del tipo di terreno,
-- aggiorna i trend di umidità, e addebita i costi irrigazione ai proprietari.
-- -----------------------------------------------------------------------------
function MoistureSystem:onDayChanged()

    for _, updater in pairs(self.updateIterations) do updater.cacheUpdatePending = true end

    for _, row in pairs(self.rows) do
        for _, column in pairs(row.columns) do column.trend = column.moisture end
    end

    if self.isServer then

        for id, field in pairs(self.irrigatingFields) do

            if field.pendingCost <= 0 then continue end

            local ownerFarmId = g_farmlandManager:getFarmlandOwner(id)

            -- Salta terreni senza proprietario valido
            if ownerFarmId == nil or ownerFarmId == FarmlandManager.NO_OWNER_FARM_ID or ownerFarmId == FarmManager.SPECTATOR_FARM_ID or ownerFarmId == FarmManager.INVALID_FARM_ID then
                field.pendingCost = 0
                continue
            end

            local ownerFarm = g_farmManager:getFarmById(ownerFarmId)
            if ownerFarm == nil then field.pendingCost = 0; continue end

            g_currentMission:addMoneyChange(0 - field.pendingCost, ownerFarmId, MoneyType.IRRIGATION_UPKEEP, true)
            ownerFarm:changeBalance(0 - field.pendingCost, MoneyType.IRRIGATION_UPKEEP)
            field.pendingCost = 0

        end

    else
        for id, field in pairs(self.irrigatingFields) do field.pendingCost = 0 end
    end

end


-- -----------------------------------------------------------------------------
-- MoistureSystem:onHourChanged()
-- Ogni ora di gioco: calcola il rischio di appassimento per 1/24 della mappa.
-- Condizioni per appassimento: non inverno, >60min senza pioggia, umidità
-- sotto la soglia minima per quel tipo di coltura, stato di crescita adeguato.
-- Limita il numero massimo di appassimenti per ora per evitare lag spike.
-- -----------------------------------------------------------------------------
function MoistureSystem:onHourChanged()

    if self.isSaving or not self.witheringEnabled then return end

    local i = 0
    local maxRows = self.numRows / 24  -- processa 1/24 della mappa per ora

    local x = -self.mapWidth / 2
    local currentHourlyUpdateIteration = self.currentHourlyUpdateIteration
    x = x + ((currentHourlyUpdateIteration - 1) / 24) * self.mapWidth
    x = math.round(x)

    if self.rows[x] == nil then
        for correctionOffset = -self.cellWidth, self.cellWidth do
            if self.rows[x + correctionOffset] ~= nil then
                x = x + correctionOffset
                break
            end
        end
    end

    -- Limite appassimenti per ora (evita lag durante siccità prolungate)
    local maxWithers = math.round(self.numRows * self.numColumns * 0.005)
    local timeSinceLastRain = MathUtil.msToMinutes(g_currentMission.environment.weather.timeSinceLastRain)
    local isWinter = g_currentMission.environment.currentSeason == Season.WINTER

    if self.rows[x] ~= nil then

        local groundTypeNone, groundTypeStubble, groundTypeCultivated, groundTypePlowed, groundTypeGrass, groundTypeCutGrass = FieldGroundType.NONE, FieldGroundType.STUBBLE_TILLAGE, FieldGroundType.CULTIVATED, FieldGroundType.PLOWED, FieldGroundType.GRASS, FieldGroundType.GRASS_CUT

        while i <= maxRows do

            local row = self.rows[x]
            if row == nil then break end
            if row.columns == nil then i = i + 1; x = x + self.cellWidth; continue end

            for z, column in pairs(row.columns) do

                -- Terreni non coltivati o in inverno non appassiscono
                if isWinter or column.groundType == groundTypeNone or column.groundType == groundTypeStubble or column.groundType == groundTypeCultivated or column.groundType == groundTypePlowed or column.groundType == groundTypeGrass or column.groundType == groundTypeCutGrass then
                    column.witherChance = 0
                    continue
                end

                if timeSinceLastRain <= 60 then continue end

                local fruitTypeIndex, densityState = FSDensityMapUtil.getFruitTypeIndexAtWorldPos(x, z)

                if fruitTypeIndex == nil or column.moisture >= 0.08 or densityState == nil then
                    column.witherChance = 0
                    continue
                end

                local fruitType = g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)
                local fruitTypeName = fruitType.name

                -- Erba, colture già tagliate o appassite non rischiano ulteriore appassimento
                if fruitTypeName == "GRASS" or fruitType:getIsCut(densityState) or fruitType:getIsWithered(densityState) then
                    column.witherChance = 0
                    continue
                end

                local lowMoisture = (RW_FSBaseMission.FRUIT_TYPES_MOISTURE[fruitTypeName] or RW_FSBaseMission.FRUIT_TYPES_MOISTURE.DEFAULT).LOW

                if column.moisture >= lowMoisture * 0.33 then
                    column.witherChance = 0
                    continue
                end

                -- Incrementa progressivamente la probabilità di appassimento
                local witherChance = column.witherChance or 0
                witherChance = witherChance + ((lowMoisture * 0.25 - column.moisture) / (lowMoisture * 4)) * 0.25 * self.witheringChance
                witherChance = math.clamp(witherChance, 0, 1)

                -- Solo il server esegue l'appassimento fisico
                if self.isServer and witherChance > 0 and maxWithers > 0 then
                    if math.random() < witherChance then
                        local width = self.cellWidth * math.random()
                        local height = self.cellHeight * math.random()
                        local offsetX = x + self.cellWidth * math.random()
                        local offsetZ = z + self.cellHeight * math.random()
                        RWUtils.witherArea(offsetX, offsetZ, math.clamp(offsetX + width, offsetX, x + self.cellWidth), offsetZ, offsetX, math.clamp(offsetZ + height, offsetZ, z + self.cellHeight))
                        maxWithers = maxWithers - 1
                    end
                end

                column.witherChance = witherChance

            end

            i = i + 1
            x = x + self.cellWidth

        end

    end

    self.currentHourlyUpdateIteration = currentHourlyUpdateIteration + 1
    if self.currentHourlyUpdateIteration > 24 then self.currentHourlyUpdateIteration = 1 end

end


-- -----------------------------------------------------------------------------
-- MoistureSystem.irrigationInputCallback()
-- Callback del tasto irrigazione. Attiva/disattiva per il campo corrente,
-- solo se il contesto è il giocatore a piedi (non in veicolo).
-- -----------------------------------------------------------------------------
function MoistureSystem.irrigationInputCallback()
    local moistureSystem = g_currentMission.moistureSystem
    if moistureSystem == nil or g_inputBinding:getContextName() ~= PlayerInputComponent.INPUT_CONTEXT_NAME then return end
    local id = moistureSystem:getIrrigationInputField()
    moistureSystem:setFieldIrrigationState(id)
end


-- -----------------------------------------------------------------------------
-- MoistureSystem:setFieldIrrigationState(id)
-- Attiva/disattiva/aggiunge l'irrigazione per il campo indicato.
-- Se già attivo senza costi pendenti, lo rimuove.
-- Invia l'evento di cambio stato in MP.
-- -----------------------------------------------------------------------------
function MoistureSystem:setFieldIrrigationState(id)

    if id == nil then return end

    if self.irrigatingFields[id] ~= nil then

        local field = self.irrigatingFields[id]

        -- Rimuovi se attivo e senza costi pendenti
        if field.isActive and field.pendingCost <= 0 then
            if g_client ~= nil then FieldIrrigationChangeEvent.sendEvent(id, true) end
            table.removeElement(self.irrigatingFields, id)
            return
        end

        -- Toggle attivo/inattivo
        if g_client ~= nil then FieldIrrigationChangeEvent.sendEvent(id, false, not field.isActive) end
        field.isActive = not field.isActive
        return

    end

    -- Nuovo campo: aggiungilo come attivo
    if g_client ~= nil then FieldIrrigationChangeEvent.sendEvent(id, false, true, true) end
    self.irrigatingFields[id] = { ["id"] = id, ["pendingCost"] = 0, ["isActive"] = true }

end


-- -----------------------------------------------------------------------------
-- MoistureSystem:setIrrigationInputField(id) / getIrrigationInputField()
-- Gestione del campo corrente per il tasto irrigazione.
-- -----------------------------------------------------------------------------
function MoistureSystem:setIrrigationInputField(id)
    self.irrigationInputField = id
end

function MoistureSystem:getIrrigationInputField()
    return self.irrigationInputField
end


-- -----------------------------------------------------------------------------
-- MoistureSystem:getIsFieldBeingIrrigated(id)
-- Ritorna lo stato irrigazione e il costo pendente per il campo dato.
-- -----------------------------------------------------------------------------
function MoistureSystem:getIsFieldBeingIrrigated(id)
    if self.irrigatingFields[id] ~= nil then return self.irrigatingFields[id].isActive, self.irrigatingFields[id].pendingCost end
    return false, 0
end


-- -----------------------------------------------------------------------------
-- MoistureSystem:onEnterVehicle() / onLeaveVehicle()
-- Disabilita il pulsante irrigazione quando il giocatore è in veicolo,
-- lo riabilita quando scende.
-- -----------------------------------------------------------------------------
function MoistureSystem:onEnterVehicle()
    self.isShowingIrrigationInput = false
    g_inputBinding:setActionEventActive(self.irrigationEventId, false)
end

function MoistureSystem:onLeaveVehicle()
    g_inputBinding:setActionEventActive(self.irrigationEventId, true)
end


-- -----------------------------------------------------------------------------
-- MoistureSystem:getCellsInsidePolygon(polygon, targets)
-- Restituisce tutte le celle della griglia all'interno del poligono dato.
-- Utile per la GUI della mappa per visualizzare l'umidità su un'area di campo.
-- Parametri:
--   polygon : lista flat [x1,z1, x2,z2, ...] dei vertici del poligono
--   targets : chiavi da leggere (default: moisture, retention, trend, witherChance)
-- -----------------------------------------------------------------------------
function MoistureSystem:getCellsInsidePolygon(polygon, targets)

    local cells = {}
    local cx, cz = 0, 0

    targets = targets or { "moisture", "retention", "trend", "witherChance" }

    -- Calcola il centroide del poligono
    for i = 1, #polygon, 2 do
        local x, z = polygon[i], polygon[i + 1]
        if x == nil or z == nil then break end
        cx = cx + x; cz = cz + z
    end
    cx = cx / (#polygon / 2)
    cz = cz / (#polygon / 2)

    -- Per ogni lato del poligono, raccoglie le celle nel bounding box del triangolo (lato + centroide)
    for i = 1, #polygon, 2 do

        local x, z = polygon[i], polygon[i + 1]
        if x == nil or z == nil then break end

        local nextX = polygon[i + 2] or polygon[1]
        local nextZ = polygon[i + 3] or polygon[2]

        local minX, maxX = math.round(math.min(x, nextX, cx)), math.round(math.max(x, nextX, cx))
        local minZ, maxZ = math.round(math.min(z, nextZ, cz)), math.round(math.max(z, nextZ, cz))

        for px = minX, maxX, self.cellWidth do

            local row = self.rows[px]
            local rowOffset = 1
            while row == nil and rowOffset < self.cellWidth do
                row = self.rows[px - rowOffset]; rowOffset = rowOffset + 1
            end
            if row == nil then break end

            for pz = minZ, maxZ, self.cellHeight do

                local column = row.columns[pz]
                local columnOffset = 1
                while column == nil and columnOffset < self.cellHeight do
                    column = row.columns[pz - columnOffset]; columnOffset = columnOffset + 1
                end
                if column == nil then break end

                local cell = self:getValuesAtCoords(row.x, column.z, targets)
                cell.x = row.x
                cell.z = column.z
                table.insert(cells, cell)

            end

        end

    end

    return cells

end


-- -----------------------------------------------------------------------------
-- MoistureSystem.onSettingChanged(name, state)
-- Callback delle impostazioni. Aggiorna la proprietà corrispondente.
-- Se cambia performanceIndex, ricostruisce il numero di updater (state^2)
-- e sincronizza eventuali modifiche pendenti prima del reset.
-- -----------------------------------------------------------------------------
function MoistureSystem.onSettingChanged(name, state)

    local moistureSystem = g_currentMission.moistureSystem
    if moistureSystem == nil then return end

    moistureSystem[name] = state

    if name == "performanceIndex" then

        local cacheUpdatePending = moistureSystem.updateIterations[1].cacheUpdatePending

        -- Invia sync pendenti prima del reset
        for _, updater in pairs(moistureSystem.updateIterations) do
            if updater.pendingSync == nil or updater.pendingSync.numRows == nil or updater.pendingSync.numRows <= 0 then continue end
            moistureSystem.syncSequence = moistureSystem.syncSequence + 1
            local event = MoistureSyncEvent.new(updater.pendingSync, false, moistureSystem.syncSequence, moistureSystem.syncSequence - 1)
            if moistureSystem.isServer then g_server:broadcastEvent(event)
            else g_client:getServerConnection():sendEvent(event) end
        end

        -- Ricostruisce gli updater: numero = state^2
        moistureSystem.currentUpdateIteration = 1
        moistureSystem.updateIterations = {}
        for i = 1, state * state do
            table.insert(moistureSystem.updateIterations, {
                ["moistureDelta"] = 0, ["timeSinceLastUpdate"] = 0,
                ["cacheUpdatePending"] = cacheUpdatePending, ["pendingSync"] = { ["numRows"] = 0 }
            })
        end

        local default = MoistureSystem.DEFAULT_PERFORMANCE_INDEXES[Utils.getPerformanceClassId()]
        print("RealisticWeather:", string.format("\\___ Default PI: %s", default), string.format("\\___ Current PI: %s", state))

    end

end


-- -----------------------------------------------------------------------------
-- MoistureSystem.onClickRebuildMoistureMap()
-- Apre il dialogo di conferma per la rigenerazione della mappa di umidità.
-- -----------------------------------------------------------------------------
function MoistureSystem.onClickRebuildMoistureMap()
    MoistureArgumentsDialog.show()
end


-- -----------------------------------------------------------------------------
-- MoistureSystem:getUpdaterAtX(x)
-- Restituisce il buffer di aggiornamento responsabile della coordinata X.
-- La mappa è divisa orizzontalmente in tante sezioni quanti sono gli updater.
-- -----------------------------------------------------------------------------
function MoistureSystem:getUpdaterAtX(x)
    local updater = math.floor((x + self.mapWidth / 2) / (self.mapWidth / #self.updateIterations) + 1)
    return self.updateIterations[updater or 1] or self.updateIterations[1]
end


-- -----------------------------------------------------------------------------
-- MoistureSystem:getRandomCell()
-- Restituisce una cella casuale della griglia con tutti i valori.
-- Utile per test o per effetti casuali sulla mappa.
-- -----------------------------------------------------------------------------
function MoistureSystem:getRandomCell()
    local row = math.random(0, self.numRows - 1)
    local column = math.random(0, self.numColumns - 1)
    local x = -self.mapWidth / 2 + row * self.cellWidth
    local z = -self.mapHeight / 2 + column * self.cellHeight
    local cell = self:getValuesAtCoords(x, z, { "moisture", "retention", "trend", "witherChance" })
    if cell == nil then return nil end
    cell.x = x; cell.z = z
    return cell
end


-- -----------------------------------------------------------------------------
-- MoistureSystem:applyUpdaterSync(rows, sequence, previousSequence)
-- Applica un aggiornamento delta ricevuto dal server in MP.
-- Verifica il numero di sequenza: se previousSequence != lastApplied,
-- logga il mismatch e restituisce false per richiedere un resync completo.
-- -----------------------------------------------------------------------------
function MoistureSystem:applyUpdaterSync(rows, sequence, previousSequence)
    -- RW_MP_FIX: rilevamento mismatch di sequenza
    if previousSequence ~= nil and self.lastAppliedSyncSequence ~= nil and previousSequence ~= self.lastAppliedSyncSequence then
        print(string.format("RealisticWeather: moisture sync mismatch (expected prev=%s, got prev=%s, seq=%s)", tostring(self.lastAppliedSyncSequence), tostring(previousSequence), tostring(sequence)))
        return false
    end
    for _, row in pairs(rows) do self:setValuesAtCoords(row.x, row.z, row.targets) end
    self.lastAppliedSyncSequence = sequence or self.lastAppliedSyncSequence
    return true
end


-- -----------------------------------------------------------------------------
-- MoistureSystem:applyResetFromSync(rows, numRows, numColumns, cellWidth, cellHeight, sequence)
-- Applica un reset completo della griglia ricevuto dal server (join o resync).
-- Resetta tutti i buffer e disattiva l'irrigazione su tutti i campi.
-- -----------------------------------------------------------------------------
function MoistureSystem:applyResetFromSync(rows, numRows, numColumns, cellWidth, cellHeight, sequence)
    self.rows, self.numRows, self.numColumns, self.cellWidth, self.cellHeight = rows, numRows, numColumns, cellWidth, cellHeight
    for _, updateIteration in pairs(self.updateIterations) do
        updateIteration.moistureDelta = 0
        updateIteration.timeSinceLastUpdate = 0
        updateIteration.cacheUpdatePending = true
        updateIteration.pendingSync = { ["numRows"] = 0 }
    end
    self.currentUpdateIteration = 1
    self.lastAppliedSyncSequence = sequence or self.lastAppliedSyncSequence
    for _, irrigatingField in pairs(self.irrigatingFields) do irrigatingField.isActive = false end
end


-- -----------------------------------------------------------------------------
-- MoistureSystem.getDefaultPerformanceIndex()
-- Restituisce l'indice di performance di default per il profilo grafico attuale.
-- -----------------------------------------------------------------------------
function MoistureSystem.getDefaultPerformanceIndex()
    return MoistureSystem.DEFAULT_PERFORMANCE_INDEXES[Utils.getPerformanceClassId()]
end
