-- PuddleSystemStateEvent.lua
-- Evento di rete per la sincronizzazione dello stato completo del PuddleSystem
-- al momento del join di un nuovo client in una sessione multiplayer.
-- Trasmette la lista di tutte le pozzanghere attive, l'iterazione round-robin corrente
-- e il tempo accumulato dall'ultimo aggiornamento, in modo che il client parta
-- con uno stato identico a quello del server.

PuddleSystemStateEvent = {}

local PuddleSystemStateEvent_mt = Class(PuddleSystemStateEvent, Event)
InitEventClass(PuddleSystemStateEvent, "PuddleSystemStateEvent")


-- Costruttore base usato internamente dal sistema di eventi di FS.
function PuddleSystemStateEvent.emptyNew()
    local self = Event.new(PuddleSystemStateEvent_mt)
    return self
end


-- Costruttore principale dell'evento.
-- @param updateIteration      indice round-robin corrente del PuddleSystem
-- @param timeSinceLastUpdate  tempo accumulato dall'ultimo update
-- @param puddles              lista delle pozzanghere attive da trasmettere
function PuddleSystemStateEvent.new(updateIteration, timeSinceLastUpdate, puddles)

    local self = PuddleSystemStateEvent.emptyNew()

    self.updateIteration, self.timeSinceLastUpdate, self.puddles = updateIteration, timeSinceLastUpdate, puddles

    return self

end


-- Deserializza lo stato completo del PuddleSystem dallo stream di rete.
-- Legge il numero di pozzanghere, lo stato del sistema e tutte le istanze di Puddle.
function PuddleSystemStateEvent:readStream(streamId, connection)
    
    local puddleSystem = g_currentMission.puddleSystem
    local numPuddles = streamReadUInt8(streamId)
    self.updateIteration = streamReadUInt8(streamId)
    self.timeSinceLastUpdate = streamReadFloat32(streamId)
    
    self.puddles = {}

    for i = 1, numPuddles do

        local puddle = Puddle.new()
        local success = puddle:readStream(streamId)

        if success then table.insert(self.puddles, puddle) end

    end

    self:run(connection)

end


-- Serializza lo stato completo del PuddleSystem nello stream di rete.
-- Scrive il numero di pozzanghere, lo stato del sistema e i dati di ogni pozzanghera.
function PuddleSystemStateEvent:writeStream(streamId, connection)
        
    streamWriteUInt8(streamId, #self.puddles)
    streamWriteUInt8(streamId, self.updateIteration)
    streamWriteFloat32(streamId, self.timeSinceLastUpdate)

    for i = 1, #self.puddles do
        self.puddles[i]:writeStream(streamId)
    end

end


-- Esegue la logica applicativa sul client dopo la deserializzazione:
-- sostituisce la lista delle pozzanghere nel PuddleSystem locale e le inizializza nella scena 3D.
function PuddleSystemStateEvent:run(connection)

    local puddleSystem = g_currentMission.puddleSystem

    puddleSystem.puddles = self.puddles
    puddleSystem:initialize()

end
