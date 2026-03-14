-- NewPuddleEvent.lua
-- Evento di rete per la creazione di una nuova pozzanghera sui client.
-- Il server crea la pozzanghera localmente, poi la trasmette a tutti i client
-- tramite broadcastEvent. I client la deserializzano, la aggiungono al puddleSystem
-- e la inizializzano nella scena 3D.

NewPuddleEvent = {}

local NewPuddleEvent_mt = Class(NewPuddleEvent, Event)
InitEventClass(NewPuddleEvent, "NewPuddleEvent")


-- Costruttore base usato internamente dal sistema di eventi di FS.
function NewPuddleEvent.emptyNew()
    local self = Event.new(NewPuddleEvent_mt)
    return self
end


-- Costruttore principale dell'evento.
-- @param puddle  istanza di Puddle da trasmettere ai client
function NewPuddleEvent.new(puddle)

    local self = NewPuddleEvent.emptyNew()

    self.puddle = puddle

    return self

end


-- Deserializza la pozzanghera dallo stream di rete.
-- Se la deserializzazione ha successo, esegue la logica applicativa.
function NewPuddleEvent:readStream(streamId, connection)
    
    local puddle = Puddle.new()
    local success = puddle:readStream(streamId)

    if success then
        self.puddle = puddle
        self:run(connection)
    end

end


-- Serializza la pozzanghera nello stream di rete.
function NewPuddleEvent:writeStream(streamId, connection)
        
    self.puddle:writeStream(streamId)

end


-- Esegue la logica applicativa sul client:
-- aggiunge la pozzanghera al sistema e la inizializza nella scena 3D.
-- Sul server non fa nulla (la pozzanghera è già stata creata localmente).
function NewPuddleEvent:run(connection)

    if g_server ~= nil then return end

    g_currentMission.puddleSystem:addPuddle(self.puddle)
    self.puddle:initialize()

end


-- Metodo statico di invio: trasmette l'evento a tutti i client connessi.
-- Viene chiamato dal server ogni volta che viene creata una nuova pozzanghera.
function NewPuddleEvent.sendEvent(puddle)
	if g_server ~= nil then g_server:broadcastEvent(NewPuddleEvent.new(puddle)) end
end
