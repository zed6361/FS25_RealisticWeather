-- FireEvent.lua
-- Evento di rete per la sincronizzazione dello stato completo del FireSystem.
-- Viene trasmesso in due occasioni:
--   1. Al join di un nuovo client (da FSBaseMission.sendInitialClientState)
--   2. All'avvio di un nuovo incendio (da FireSystem.startFire)
-- Trasmette: indice round-robin, tempo accumulato, ID del campo in fiamme e lista di tutti i fuochi.
-- Sul client, run() sostituisce lo stato del fireSystem locale e inizializza i fuochi nella scena.

FireEvent = {}

local FireEvent_mt = Class(FireEvent, Event)
InitEventClass(FireEvent, "FireEvent")


-- Costruttore base usato internamente dal sistema di eventi di FS.
function FireEvent.emptyNew()
    local self = Event.new(FireEvent_mt)
    return self
end


-- Costruttore principale dell'evento.
-- @param updateIteration      indice round-robin corrente del FireSystem
-- @param timeSinceLastUpdate  tempo accumulato dall'ultimo update
-- @param fieldId              ID del campo attualmente in fiamme (nil se nessun incendio)
-- @param fires                lista dei fuochi da trasmettere
function FireEvent.new(updateIteration, timeSinceLastUpdate, fieldId, fires)

    local self = FireEvent.emptyNew()

    self.updateIteration, self.timeSinceLastUpdate, self.fieldId, self.fires = updateIteration, timeSinceLastUpdate, fieldId, fires

    return self

end


-- Deserializza lo stato del FireSystem dallo stream di rete.
-- fieldId == 0 viene interpretato come "nessun incendio" (nil).
function FireEvent:readStream(streamId, connection)

    local numFires = streamReadUInt8(streamId)
    
    self.updateIteration = streamReadUInt8(streamId)
    self.fieldId = streamReadUInt16(streamId)

    -- fieldId 0 significa nessun incendio attivo.
    if self.fieldId == 0 then self.fieldId = nil end

    self.timeSinceLastUpdate = streamReadFloat32(streamId)
    
    self.fires = {}

    for i = 1, numFires do

        local fire = Fire.new()
        local success = fire:readStream(streamId)

        if success then table.insert(self.fires, fire) end

    end

    self:run(connection)

end


-- Serializza lo stato del FireSystem nello stream di rete.
-- fieldId nil viene trasmesso come 0.
function FireEvent:writeStream(streamId, connection)
        
    streamWriteUInt8(streamId, #self.fires)

    streamWriteUInt8(streamId, self.updateIteration)
    streamWriteUInt16(streamId, self.fieldId or 0)
    streamWriteFloat32(streamId, self.timeSinceLastUpdate)

    for i = 1, #self.fires do
        self.fires[i]:writeStream(streamId)
    end

end


-- Esegue la logica applicativa sul client:
-- sostituisce lo stato del fireSystem locale con i dati ricevuti
-- e inizializza tutti i fuochi nella scena 3D.
function FireEvent:run(connection)

    local fireSystem = g_currentMission.fireSystem

    fireSystem.updateIteration = self.updateIteration
    fireSystem.timeSinceLastUpdate = self.timeSinceLastUpdate
    fireSystem.fires = self.fires
    fireSystem.fieldId = self.fieldId

    fireSystem:initialize()

end
