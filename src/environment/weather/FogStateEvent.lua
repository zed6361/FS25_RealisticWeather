-- FogStateEvent.lua
-- Evento di rete per la sincronizzazione dello stato corrente del FogUpdater.
-- Viene trasmesso in due occasioni:
--   1. Al join di un nuovo client (da Weather.sendInitialState)
--   2. Ogni volta che il server chiama FogUpdater.setTargetFog (hook append in FogUpdater.lua)
--
-- In readStream, i dati vengono letti direttamente nel fogUpdater globale
-- (g_currentMission.environment.weather.fogUpdater) tramite fogUpdater:readStream().
-- run() è vuoto perché l'applicazione dello stato avviene già durante readStream
-- tramite il flag isDirty del fogUpdater.

FogStateEvent = {}
local FogStateEvent_mt = Class(FogStateEvent, Event)
InitEventClass(FogStateEvent, "FogStateEvent")


-- Costruttore base usato internamente dal sistema di eventi di FS.
function FogStateEvent.emptyNew()

	return Event.new(FogStateEvent_mt)

end


-- Costruttore principale dell'evento.
-- @param fogUpdater  istanza corrente del FogUpdater da serializzare
function FogStateEvent.new(fogUpdater)

	local self = FogStateEvent.emptyNew()
	
	self.fogUpdater = fogUpdater

	return self

end


-- Deserializza lo stato del FogUpdater dallo stream di rete.
-- Delega la lettura al fogUpdater globale tramite il suo metodo readStream,
-- che imposta isDirty=true per forzare l'aggiornamento visivo nel frame successivo.
function FogStateEvent:readStream(streamId, connection)

	local fogUpdater = g_currentMission.environment.weather.fogUpdater
	fogUpdater:readStream(streamId, connection)
	self:run(connection)

end


-- Serializza lo stato del FogUpdater nello stream di rete.
-- Delega la scrittura al fogUpdater associato all'evento.
function FogStateEvent:writeStream(streamId, connection)

	self.fogUpdater:writeStream(streamId, connection)

end


-- Nessuna logica applicativa: l'aggiornamento avviene già in readStream
-- tramite il meccanismo isDirty del fogUpdater.
function FogStateEvent:run(connection)



end
