-- MoistureStateEvent.lua
-- Evento di rete per la sincronizzazione dello stato iniziale del MoistureSystem
-- quando un client si connette a una sessione multiplayer già avviata.
-- Trasmette la configurazione della griglia (dimensioni celle) e un sottoinsieme
-- di celle con i valori correnti di moisture e witherChance.
--
-- A differenza di MoistureSyncEvent (che gestisce aggiornamenti incrementali e full reset),
-- questo evento usa InitStaticEventClass ed è pensato per il bootstrap iniziale:
-- numRows e numColumns indicano quante righe/colonne sono incluse nel payload,
-- permettendo trasmissioni parziali (solo le celle significative, non l'intera griglia).
--
-- run() chiama setInitialState() sul moistureSystem del client, che inizializza
-- la griglia locale con i dati ricevuti.

MoistureStateEvent = {}

local moistureStateEvent_mt = Class(MoistureStateEvent, Event)
InitStaticEventClass(MoistureStateEvent, "MoistureStateEvent")


-- Costruttore base usato internamente dal sistema di eventi di FS.
function MoistureStateEvent.emptyNew()
    return Event.new(moistureStateEvent_mt)
end


-- Costruttore principale dell'evento.
-- @param cellWidth                 larghezza di una cella della griglia in unità mondo
-- @param cellHeight                altezza di una cella della griglia in unità mondo
-- @param moistureDelta             variazione di umidità accumulata nell'ora corrente
-- @param lastMoistureDelta         variazione di umidità dell'ora precedente
-- @param currentHourlyUpdateQuarter quarto d'ora corrente nell'aggiornamento orario [1-4]
-- @param numRows                   numero di righe incluse nel payload
-- @param numColumns                numero di colonne incluse in ogni riga del payload
-- @param rows                      tabella delle celle da trasmettere (indicizzata per x)
function MoistureStateEvent.new(cellWidth, cellHeight, moistureDelta, lastMoistureDelta, currentHourlyUpdateQuarter, numRows, numColumns, rows)
    local self = MoistureStateEvent.emptyNew()

    self.cellWidth, self.cellHeight, self.moistureDelta, self.lastMoistureDelta, self.currentHourlyUpdateQuarter, self.numRows, self.numColumns, self.rows = cellWidth, cellHeight, moistureDelta, lastMoistureDelta, currentHourlyUpdateQuarter, numRows, numColumns, rows

    return self
end


-- Deserializza l'evento dallo stream di rete.
-- Legge prima i parametri di configurazione della griglia, poi le celle se numRows > 0.
-- Ogni cella contiene: coordinata z, moisture e witherChance.
function MoistureStateEvent:readStream(streamId, connection)

    self.cellWidth = streamReadFloat32(streamId)
    self.cellHeight = streamReadFloat32(streamId)
    self.moistureDelta = streamReadFloat32(streamId)
    self.lastMoistureDelta = streamReadFloat32(streamId)
    self.currentHourlyUpdateQuarter = streamReadInt8(streamId)
    self.numRows = streamReadInt8(streamId)
    self.numColumns = streamReadInt8(streamId)

    local rows = {}

    if self.numRows > 0 and self.numColumns > 0 then

        for i = 1, self.numRows do

            local x = streamReadFloat32(streamId)

            -- Ogni riga è indicizzata per la coordinata x e contiene una tabella di colonne.
            local row = { [x] = x, ["columns"] = {} }

            for j = 1, self.numColumns do

                local z = streamReadFloat32(streamId)
                local moisture = streamReadFloat32(streamId)
                local witherChance = streamReadFloat32(streamId)

                row.columns[z] = { ["z"] = z, ["moisture"] = moisture, ["witherChance"] = witherChance }

            end

            rows[x] = row

        end

    end

    self.rows = rows

    self:run(connection)

end


-- Serializza l'evento nello stream di rete.
-- Nota: i parametri di writeStream sono invertiti rispetto alla convenzione standard
-- (connection è il primo parametro, _ è il secondo) — comportamento specifico di questo evento.
function MoistureStateEvent:writeStream(connection, _)

    streamWriteFloat32(connection, self.cellWidth)
    streamWriteFloat32(connection, self.cellHeight)
    streamWriteFloat32(connection, self.moistureDelta or 0)
    streamWriteFloat32(connection, self.lastMoistureDelta or 0)
    streamWriteInt8(connection, self.currentHourlyUpdateQuarter or 1)
    streamWriteInt8(connection, self.numRows or 0)
    streamWriteInt8(connection, self.numColumns or 0)

    for x, row in pairs(self.rows) do

        if row.columns ~= nil then

            streamWriteFloat32(connection, x)

            for z, column in pairs(row.columns) do

                streamWriteFloat32(connection, column.z)
                streamWriteFloat32(connection, column.moisture)
                streamWriteFloat32(connection, column.witherChance or 0)

            end

        end

    end

end


-- Esegue la logica applicativa sul client:
-- chiama setInitialState() sul moistureSystem con tutti i parametri ricevuti.
function MoistureStateEvent:run(_)
    g_currentMission.moistureSystem:setInitialState(self.cellWidth, self.cellHeight, self.moistureDelta, self.lastMoistureDelta, self.currentHourlyUpdateQuarter, self.numRows, self.numColumns, self.rows)
end
