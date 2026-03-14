-- WeatherStateEvent.lua (RW_WeatherStateEvent)
-- Override completo di WeatherStateEvent per estendere il payload di sincronizzazione
-- con i dati del MoistureSystem e i campi aggiuntivi di RealisticWeather.
--
-- Rispetto all'evento vanilla, aggiunge:
--   snowHeight, timeSinceLastRain  → già presenti nel vanilla
--   lastFogDay                     → giorno dell'ultimo evento nebbia (per regola anti-consecutiva)
--   cellWidth, cellHeight          → dimensioni celle della griglia umidità
--   mapWidth, mapHeight            → dimensioni totali della mappa in celle
--   currentHourlyUpdateQuarter     → quarto d'ora corrente nell'aggiornamento orario
--   numRows, numColumns            → dimensioni del payload griglia
--   rows                           → griglia celle con moisture, retention, trend, witherChance
--   irrigatingFields               → mappa dei campi in irrigazione con pendingCost e isActive
--
-- Hook registrati:
--   WeatherStateEvent.new        (replace)   → RW_WeatherStateEvent.new
--   WeatherStateEvent.readStream (overwrite) → RW_WeatherStateEvent.readStream
--   WeatherStateEvent.writeStream(overwrite) → RW_WeatherStateEvent.writeStream
--   WeatherStateEvent.run        (overwrite) → RW_WeatherStateEvent.run

RW_WeatherStateEvent = {}


-- Costruttore sostitutivo di WeatherStateEvent.new.
-- Accetta tutti i parametri RW aggiuntivi e li salva nell'istanza.
-- Usa WeatherStateEvent.emptyNew() per creare l'istanza base.
-- @param snowHeight                 altezza neve corrente
-- @param timeSinceLastRain          minuti dall'ultima pioggia
-- @param cellWidth, cellHeight      dimensioni celle griglia umidità
-- @param mapWidth, mapHeight        dimensioni totali mappa
-- @param currentHourlyUpdateQuarter quarto d'ora corrente aggiornamento orario
-- @param numRows, numColumns        dimensioni payload griglia
-- @param rows                       tabella celle umidità
-- @param irrigatingFields           tabella campi in irrigazione
-- @param lastFogDay                 giorno dell'ultimo evento nebbia
function RW_WeatherStateEvent.new(snowHeight, timeSinceLastRain, cellWidth, cellHeight, mapWidth, mapHeight, currentHourlyUpdateQuarter, numRows, numColumns, rows, irrigatingFields, lastFogDay)
    local self = WeatherStateEvent.emptyNew()
    self.snowHeight = snowHeight
    self.timeSinceLastRain = timeSinceLastRain

    self.cellWidth, self.cellHeight, self.mapWidth, self.mapHeight, self.currentHourlyUpdateQuarter, self.numRows, self.numColumns, self.rows, self.irrigatingFields, self.lastFogDay = cellWidth, cellHeight, mapWidth, mapHeight, currentHourlyUpdateQuarter, numRows, numColumns, rows, irrigatingFields, lastFogDay
    return self
end

WeatherStateEvent.new = RW_WeatherStateEvent.new


-- Override di WeatherStateEvent.readStream.
-- Deserializza il payload esteso dallo stream di rete.
-- Pipeline:
--   1. Legge snowHeight, timeSinceLastRain, lastFogDay
--   2. Legge i parametri della griglia umidità (dimensioni e configurazione)
--   3. Legge le celle (x → row → z → {moisture, retention, trend, witherChance})
--   4. Legge i campi in irrigazione (id, pendingCost, isActive)
--   5. Chiama run()
function RW_WeatherStateEvent:readStream(_, streamId, connection)
    self.snowHeight = streamReadFloat32(streamId)
    self.timeSinceLastRain = streamReadFloat32(streamId)
    self.lastFogDay = streamReadUInt16(streamId)

    self.cellWidth = streamReadFloat32(streamId)
    self.cellHeight = streamReadFloat32(streamId)
    self.mapWidth = streamReadFloat32(streamId)
    self.mapHeight = streamReadFloat32(streamId)
    self.currentHourlyUpdateQuarter = streamReadUInt8(streamId)
    self.numRows = streamReadUInt16(streamId)
    self.numColumns = streamReadUInt16(streamId)

    local rows = {}

    if self.numRows > 0 and self.numColumns > 0 then

        for i = 1, self.numRows do

            local x = streamReadFloat32(streamId)

            local row = { ["x"] = x, ["columns"] = {} }

            for j = 1, self.numColumns do

                local z = streamReadFloat32(streamId)
                local moisture = streamReadFloat32(streamId)
                local retention = streamReadFloat32(streamId)
                local trend = streamReadFloat32(streamId)
                local witherChance = streamReadFloat32(streamId)

                -- Ogni cella contiene: coordinate z, umidità, ritenzione, trend e rischio appassimento.
                row.columns[z] = { ["z"] = z, ["moisture"] = moisture, ["witherChance"] = witherChance, ["retention"] = retention, ["trend"] = trend }

            end

            rows[x] = row

        end

    end

    self.rows = rows

    local numIrrigatingFields = streamReadUInt16(streamId)

    local irrigatingFields = {}

    if numIrrigatingFields > 0 then

        for i = 1, numIrrigatingFields do

            local id = streamReadUInt16(streamId)
            local pendingCost = streamReadFloat32(streamId)
            local isActive = streamReadBool(streamId)

            irrigatingFields[id] = {
                ["id"] = id,
                ["pendingCost"] = pendingCost,
                ["isActive"] = isActive
            }

        end

    end

    self.irrigatingFields = irrigatingFields

    self:run(connection)
end

WeatherStateEvent.readStream = Utils.overwrittenFunction(WeatherStateEvent.readStream, RW_WeatherStateEvent.readStream)


-- Override di WeatherStateEvent.writeStream.
-- Serializza il payload esteso nello stream di rete.
-- Nota: i parametri sono invertiti rispetto alla convenzione standard
-- (connection è il secondo parametro, _ è il primo) — comportamento specifico di WeatherStateEvent.
-- Scrive prima i campi scalari, poi la griglia celle e infine i campi in irrigazione.
-- Se irrigatingFields è nil, scrive 0 come conteggio.
function RW_WeatherStateEvent:writeStream(_, connection, _)
    streamWriteFloat32(connection, self.snowHeight)
    streamWriteFloat32(connection, self.timeSinceLastRain)
    streamWriteUInt16(connection, self.lastFogDay)

    -- Parametri griglia con valori di default nel caso il moistureSystem non sia ancora inizializzato.
    streamWriteFloat32(connection, self.cellWidth or 5)
    streamWriteFloat32(connection, self.cellHeight or 5)
    streamWriteFloat32(connection, self.mapWidth or 2048)
    streamWriteFloat32(connection, self.mapHeight or 2048)
    streamWriteUInt8(connection, self.currentHourlyUpdateQuarter or 1)
    streamWriteUInt16(connection, self.numRows or 0)
    streamWriteUInt16(connection, self.numColumns or 0)

    if self.rows ~= nil then

        for x, row in pairs(self.rows) do

            if row.columns ~= nil then

                streamWriteFloat32(connection, x)

                for z, column in pairs(row.columns) do

                    streamWriteFloat32(connection, column.z)
                    streamWriteFloat32(connection, column.moisture)
                    streamWriteFloat32(connection, column.retention)
                    streamWriteFloat32(connection, column.trend)
                    streamWriteFloat32(connection, column.witherChance or 0)

                end

            end

        end

    end

    if self.irrigatingFields ~= nil then

        -- Conta i campi in irrigazione prima di serializzarli (tabella non ha #).
        local numIrrigatingFields = 0
        for _, field in pairs(self.irrigatingFields) do numIrrigatingFields = numIrrigatingFields + 1 end

        streamWriteUInt16(connection, numIrrigatingFields)

        for id, field in pairs(self.irrigatingFields) do
            streamWriteUInt16(connection, id)
            streamWriteFloat32(connection, field.pendingCost or 0)
            streamWriteBool(connection, field.isActive or false)
        end

    else
        streamWriteUInt16(connection, 0)
    end

end

WeatherStateEvent.writeStream = Utils.overwrittenFunction(WeatherStateEvent.writeStream, RW_WeatherStateEvent.writeStream)


-- Override di WeatherStateEvent.run.
-- Chiamato sul client dopo la deserializzazione.
-- Applica lo stato meteo base (snowHeight, timeSinceLastRain, lastFogDay) al Weather
-- e inizializza il moistureSystem con la griglia e i campi di irrigazione ricevuti.
function RW_WeatherStateEvent:run(_, _)
    g_currentMission.environment.weather:setInitialState(self.snowHeight, self.timeSinceLastRain, self.lastFogDay)
    g_currentMission.moistureSystem:setInitialState(self.cellWidth, self.cellHeight, self.mapWidth, self.mapHeight, self.currentHourlyUpdateQuarter, self.numRows, self.numColumns, self.rows, self.irrigatingFields)
end

WeatherStateEvent.run = Utils.overwrittenFunction(WeatherStateEvent.run, RW_WeatherStateEvent.run)
