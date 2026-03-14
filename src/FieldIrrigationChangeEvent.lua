-- FieldIrrigationChangeEvent.lua
-- Evento di rete per sincronizzare le modifiche allo stato dell'irrigazione di un campo
-- dal client al server. Gestisce tre operazioni distinte tramite i flag remove/create/active:
--   - create=true:  aggiunge il campo alla lista irrigatingFields del moistureSystem
--   - remove=true:  rimuove il campo dalla lista irrigatingFields
--   - altrimenti:   aggiorna il flag isActive del campo già esistente
--
-- Viene inviato solo dal client al server (sendEvent su g_client.serverConnection).
-- Il server applica la modifica e la propaga agli altri sistemi tramite il normale flusso di update.

FieldIrrigationChangeEvent = {}
local fieldIrrigationChangeEvent_mt = Class(FieldIrrigationChangeEvent, Event)
InitEventClass(FieldIrrigationChangeEvent, "FieldIrrigationChangeEvent")


-- Costruttore base usato internamente dal sistema di eventi di FS.
function FieldIrrigationChangeEvent.emptyNew()
    local self = Event.new(fieldIrrigationChangeEvent_mt)
    return self
end


-- Costruttore principale dell'evento.
-- @param id      ID del campo irrigato (UInt16)
-- @param remove  true = rimuovi il campo dalla lista di irrigazione
-- @param active  true = irrigazione attiva, false = in pausa (usato solo se remove=false e create=false)
-- @param create  true = crea una nuova entry per questo campo nella lista di irrigazione
function FieldIrrigationChangeEvent.new(id, remove, active, create)

    local self = FieldIrrigationChangeEvent.emptyNew()

    self.id = id
    self.remove = remove
    self.active = active
    self.create = create

    return self

end


-- Deserializza l'evento dallo stream di rete ed esegue la logica applicativa.
function FieldIrrigationChangeEvent:readStream(streamId, connection)
    self.id = streamReadUInt16(streamId)
    self.remove = streamReadBool(streamId)
    self.active = streamReadBool(streamId)
    self.create = streamReadBool(streamId)

    self:run(connection)
end


-- Serializza l'evento nello stream di rete.
function FieldIrrigationChangeEvent:writeStream(streamId, connection)
    streamWriteUInt16(streamId, self.id)
    streamWriteBool(streamId, self.remove or false)
    streamWriteBool(streamId, self.active or false)
    streamWriteBool(streamId, self.create or false)
end


-- Applica la modifica al moistureSystem del server in base ai flag ricevuti.
-- Tre modalità:
--   remove=true  → rimuove il campo dalla lista irrigatingFields
--   create=true  → crea una nuova entry {id, pendingCost=0, isActive=true}
--   altrimenti   → aggiorna isActive del campo esistente
function FieldIrrigationChangeEvent:run(connection)

    local moistureSystem = g_currentMission.moistureSystem

    if moistureSystem == nil then return end

    if self.remove then
        if moistureSystem.irrigatingFields[self.id] ~= nil then table.removeElement(moistureSystem.irrigatingFields, self.id) end
    elseif not self.create and moistureSystem.irrigatingFields[self.id] ~= nil then
        moistureSystem.irrigatingFields[self.id].isActive = self.active
    elseif self.create and moistureSystem.irrigatingFields[self.id] == nil then
        moistureSystem.irrigatingFields[self.id] = {
            ["id"] = self.id,
            ["pendingCost"] = 0,
            ["isActive"] = true
        }
    end

end


-- Metodo statico di invio: trasmette l'evento dal client al server.
-- Non fa nulla se siamo già sul server.
-- @param id      ID del campo
-- @param remove  true = rimuovi
-- @param active  nuovo stato attivo/inattivo
-- @param create  true = crea
function FieldIrrigationChangeEvent.sendEvent(id, remove, active, create)

    if g_server == nil and g_client ~= nil then g_client:getServerConnection():sendEvent(FieldIrrigationChangeEvent.new(id, remove, active, create)) end

end
