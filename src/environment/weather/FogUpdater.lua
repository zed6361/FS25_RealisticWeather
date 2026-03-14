-- FogUpdater.lua
-- Estensione di FogUpdater con:
--   1. Hook append su setTargetFog: ogni volta che il server aggiorna la nebbia target,
--      trasmette immediatamente lo stato corrente a tutti i client tramite FogStateEvent.
--   2. Metodi readStream/writeStream aggiunti alla classe FogUpdater esistente
--      per supportare la serializzazione via FogStateEvent.
--
-- Dati serializzati:
--   alpha           → fattore di interpolazione corrente [0, 1]
--   visibilityAlpha → fattore di visibilità corrente
--   duration        → durata totale della transizione
--   targetFog       → FogSettings di destinazione (serializzato tramite FogSettings:writeStream)
--   lastFog         → FogSettings di partenza (ultimo stato applicato)
--   currentFog      → FogSettings interpolato corrente
--
-- Dopo la deserializzazione, isDirty=true forza il ricalcolo immediato dei parametri
-- di nebbia nel motore di rendering.

-- Hook append su FogUpdater.setTargetFog.
-- Chiamato automaticamente ogni volta che il server imposta una nuova nebbia target.
-- Trasmette lo stato aggiornato del fogUpdater a tutti i client connessi.
FogUpdater.setTargetFog = Utils.appendedFunction(FogUpdater.setTargetFog, function(self, fog, duration)

	g_server:broadcastEvent(FogStateEvent.new(self))

end)


-- Deserializza lo stato del FogUpdater dallo stream di rete.
-- Legge i parametri di interpolazione e i tre FogSettings (target, last, current).
-- Imposta isDirty=true per forzare l'aggiornamento del rendering nel frame successivo.
function FogUpdater:readStream(streamId, connection)

	self.alpha = streamReadFloat32(streamId)
	self.visibilityAlpha = streamReadFloat32(streamId)
	self.duration = streamReadFloat32(streamId)

	-- Deserializza i tre snapshot di nebbia: destinazione, partenza e stato corrente.
	self.targetFog:readStream(streamId, connection)
	self.lastFog:readStream(streamId, connection)
	self.currentFog:readStream(streamId, connection)

	-- Segnala al fogUpdater che i parametri sono cambiati e vanno riapplicati.
	self.isDirty = true

end


-- Serializza lo stato del FogUpdater nello stream di rete.
-- Scrive i parametri di interpolazione e i tre FogSettings.
function FogUpdater:writeStream(streamId, connection)

	streamWriteFloat32(streamId, self.alpha)
	streamWriteFloat32(streamId, self.visibilityAlpha)
	streamWriteFloat32(streamId, self.duration)

	-- Serializza i tre snapshot di nebbia nell'ordine: target, last, current.
	self.targetFog:writeStream(streamId, connection)
	self.lastFog:writeStream(streamId, connection)
	self.currentFog:writeStream(streamId, connection)

end
