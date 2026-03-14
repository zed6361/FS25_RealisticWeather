-- MoistureSyncEvent.lua
-- Evento di rete per la sincronizzazione della griglia di umidità del terreno tra server e client.
-- Supporta tre modalità operative:
--   1. isResyncRequest: il client chiede un reset completo al server (in caso di sequenza non allineata)
--   2. isReset=true:    il server invia l'intera griglia (full resync)
--   3. isReset=false:   il server invia solo le celle modificate (aggiornamento incrementale)
-- Le sequenze numeriche (sequence, previousSequence) garantiscono l'ordine deterministico degli aggiornamenti.

MoistureSyncEvent = {}
local moistureSyncEvent_mt = Class(MoistureSyncEvent, Event)
InitEventClass(MoistureSyncEvent, "MoistureSyncEvent")


-- Costruttore base usato internamente dal sistema di eventi di FS.
function MoistureSyncEvent.emptyNew()
    local self = Event.new(moistureSyncEvent_mt)
    return self
end


-- Costruttore principale dell'evento.
-- @param rows             tabella delle righe/celle da trasmettere
-- @param isReset          true = full resync, false = aggiornamento incrementale
-- @param sequence         numero di sequenza corrente (per rilevare mismatch)
-- @param previousSequence numero di sequenza precedente atteso dal destinatario
-- @param isResyncRequest  true = il client sta chiedendo un full resync al server
function MoistureSyncEvent.new(rows, isReset, sequence, previousSequence, isResyncRequest)

    local self = MoistureSyncEvent.emptyNew()

    self.rows = rows
    self.isReset = isReset or false
    self.sequence = sequence or 0
    self.previousSequence = previousSequence or 0
    self.isResyncRequest = isResyncRequest or false

    return self

end

-- Invia una richiesta di resync al server dal client.
-- Viene chiamata automaticamente quando il client rileva un mismatch nella sequenza.
function MoistureSyncEvent.sendResyncRequest()
    if g_client == nil then return end
    g_client:getServerConnection():sendEvent(MoistureSyncEvent.new({}, false, 0, 0, true))
end


-- Deserializza l'evento ricevuto dallo stream di rete.
-- Gestisce le tre modalità: resync request, full reset, aggiornamento incrementale.
function MoistureSyncEvent:readStream(streamId, connection)

    self.isReset = streamReadBool(streamId)
    self.isResyncRequest = streamReadBool(streamId)
    self.sequence = streamReadUInt16(streamId)
    self.previousSequence = streamReadUInt16(streamId)
    local rows = {}

    -- Se è una richiesta di resync dal client, non ci sono dati da leggere.
    if self.isResyncRequest then
        self.rows = rows
        self:run(connection)
        return
    end

    if self.isReset then

        -- Full resync: legge le dimensioni della griglia e tutte le celle con i loro campi.
        local numRows = streamReadUInt16(streamId)
        local numColumns = streamReadUInt16(streamId)
        local cellWidth = streamReadUInt8(streamId)
        local cellHeight = streamReadUInt8(streamId)

        for i = 1, numRows do

            local x = streamReadFloat32(streamId)
            local row = { ["x"] = x, ["columns"] = {} }

            for j = 1, numColumns do

                local z = streamReadFloat32(streamId)
                local moisture = streamReadFloat32(streamId)
                local retention = streamReadFloat32(streamId)
                local trend = streamReadFloat32(streamId)
                local witherChance = streamReadFloat32(streamId)

                -- Ogni cella è indicizzata per coordinata Z e contiene i 4 campi principali.
                row.columns[z] = {
                    ["z"] = z,
                    ["moisture"] = moisture,
                    ["retention"] = retention,
                    ["trend"] = trend,
                    ["witherChance"] = witherChance
                }

            end

            rows[x] = row

        end

        self.numRows = numRows
        self.numColumns = numColumns
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight

    else

        -- Aggiornamento incrementale: legge solo le celle modificate con i delta per campo.
        local numRows = streamReadUInt16(streamId)

        for i = 1, numRows do

            local numColumns = streamReadUInt16(streamId)
            local x = streamReadFloat32(streamId)

            for j = 1, numColumns do

                local z = streamReadFloat32(streamId)

                -- Ogni cella trasmette solo i campi effettivamente cambiati (target = nome campo, value = nuovo valore).
                local numTargets = streamReadUInt8(streamId)
                local targets = {}

                for j = 1, numTargets do

                    local target = streamReadString(streamId)
                    local value = streamReadFloat32(streamId)

                    targets[target] = value

                end

                table.insert(rows, {
                    ["x"] = x,
                    ["z"] = z,
                    ["targets"] = targets
                })

            end

        end

    end

    self.rows = rows
    self:run(connection)

end


-- Serializza l'evento nello stream di rete da inviare al destinatario.
-- Gestisce le tre modalità speculari a readStream.
function MoistureSyncEvent:writeStream(streamId, connection)

    streamWriteBool(streamId, self.isReset)
    streamWriteBool(streamId, self.isResyncRequest)
    streamWriteUInt16(streamId, self.sequence or 0)
    streamWriteUInt16(streamId, self.previousSequence or 0)

    -- Resync request: nessun payload aggiuntivo.
    if self.isResyncRequest then
        return
    end

    if self.isReset then

        -- Full resync: scrive dimensioni griglia + tutte le celle.
        local moistureSystem = g_currentMission.moistureSystem

        streamWriteUInt16(streamId, moistureSystem.numRows)
        streamWriteUInt16(streamId, moistureSystem.numColumns)
        streamWriteUInt8(streamId, moistureSystem.cellWidth)
        streamWriteUInt8(streamId, moistureSystem.cellHeight)

        for x, row in pairs(self.rows) do

            streamWriteFloat32(streamId, x)

            for z, column in pairs(row.columns) do

                streamWriteFloat32(streamId, z)
                streamWriteFloat32(streamId, column.moisture)
                streamWriteFloat32(streamId, column.retention)
                streamWriteFloat32(streamId, column.trend)
                streamWriteFloat32(streamId, column.witherChance or 0)

            end

        end

    else

        -- Aggiornamento incrementale: scrive solo le celle modificate e i loro campi delta.
        local numRows = self.rows.numRows

        streamWriteUInt16(streamId, numRows)


        for x, row in pairs(self.rows) do

            if x == "numRows" then continue end

            local numColumns = row.numColumns

            streamWriteUInt16(streamId, numColumns)
            streamWriteFloat32(streamId, x)

            for z, targets in pairs(row) do

                if z == "numColumns" then continue end

                streamWriteFloat32(streamId, z)

                local numTargets = 0

                for target, value in pairs(targets) do numTargets = numTargets + 1 end

                streamWriteUInt8(streamId, numTargets)

                for target, value in pairs(targets) do

                    streamWriteString(streamId, target)
                    streamWriteFloat32(streamId, value)

                end

            end

        end

    end

end


-- Esegue la logica applicativa dell'evento dopo la deserializzazione.
-- Sul server: risponde a una resync request inviando un full reset al client richiedente.
-- Sul client: applica il full reset o l'aggiornamento incrementale al moistureSystem locale.
--   Se l'aggiornamento incrementale fallisce (sequenza non allineata), chiede un nuovo resync.
function MoistureSyncEvent:run(connection)

    local moistureSystem = g_currentMission.moistureSystem

    if moistureSystem == nil then return end

    if self.isResyncRequest and g_server ~= nil and connection ~= nil then
        -- RW_MP_FIX: deterministic fallback full resync for sequence mismatch
        connection:sendEvent(MoistureSyncEvent.new(moistureSystem.rows, true, moistureSystem.syncSequence or 0, moistureSystem.syncSequence or 0, false))
        return
    end

    if self.isReset then
        moistureSystem:applyResetFromSync(self.rows, self.numRows, self.numColumns, self.cellWidth, self.cellHeight, self.sequence)
    else
        local success = moistureSystem:applyUpdaterSync(self.rows, self.sequence, self.previousSequence)
        if not success and g_client ~= nil then
            MoistureSyncEvent.sendResyncRequest()
        end
    end

end
