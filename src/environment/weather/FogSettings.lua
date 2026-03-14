-- FogSettings.lua
-- Estensione di FogSettings con metodi di serializzazione/deserializzazione di rete.
-- Aggiunge readStream e writeStream alla classe FogSettings esistente di FS25
-- per permettere la trasmissione completa dei parametri di nebbia via FogStateEvent.
--
-- Parametri serializzati:
--   groundFogCoverageEdge0/1     → soglie di copertura della nebbia a terra [0,1]
--   groundFogExtraHeight         → altezza extra della nebbia al suolo (metri)
--   groundFogGroundLevelDensity  → densità della nebbia a livello del terreno
--   groundFogMinValleyDepth      → profondità minima delle valli per la nebbia
--   heightFogMaxHeight           → altezza massima della nebbia volumetrica (metri)
--   heightFogGroundLevelDensity  → densità della nebbia volumetrica a livello terreno
--   groundFogStartDayTimeMinutes → minuto del giorno in cui inizia la nebbia (UInt16)
--   groundFogEndDayTimeMinutes   → minuto del giorno in cui finisce la nebbia (UInt16)
--   groundFogWeatherTypes        → set di WeatherType per cui la nebbia è attiva (per nome)


-- Deserializza i parametri di un FogSettings dallo stream di rete.
-- Legge prima i valori scalari, poi la lista dei tipi di tempo compatibili.
function FogSettings:readStream(streamId, connection)

	self.groundFogCoverageEdge0 = streamReadFloat32(streamId)
	self.groundFogCoverageEdge1 = streamReadFloat32(streamId)
	self.groundFogExtraHeight = streamReadFloat32(streamId)
	self.groundFogGroundLevelDensity = streamReadFloat32(streamId)
	self.groundFogMinValleyDepth = streamReadFloat32(streamId)
	self.heightFogMaxHeight = streamReadFloat32(streamId)
	self.heightFogGroundLevelDensity = streamReadFloat32(streamId)
	self.groundFogStartDayTimeMinutes = streamReadUInt16(streamId)
	self.groundFogEndDayTimeMinutes = streamReadUInt16(streamId)

	local numWeatherTypes = streamReadUInt8(streamId)

	self.groundFogWeatherTypes = {}

	-- Legge i tipi di tempo come stringhe e li converte in enum WeatherType.
	for i = 1, numWeatherTypes do

		local weatherTypeName = streamReadString(streamId)
		local weatherType = WeatherType.getByName(weatherTypeName)
			
		if weatherType ~= nil then self.groundFogWeatherTypes[weatherType] = true end

	end

end


-- Serializza i parametri di un FogSettings nello stream di rete.
-- Scrive prima i valori scalari, poi il conteggio dei tipi di tempo e i loro nomi.
function FogSettings:writeStream(streamId, connection)

	streamWriteFloat32(streamId, self.groundFogCoverageEdge0)
	streamWriteFloat32(streamId, self.groundFogCoverageEdge1)
	streamWriteFloat32(streamId, self.groundFogExtraHeight)
	streamWriteFloat32(streamId, self.groundFogGroundLevelDensity)
	streamWriteFloat32(streamId, self.groundFogMinValleyDepth)
	streamWriteFloat32(streamId, self.heightFogMaxHeight)
	streamWriteFloat32(streamId, self.heightFogGroundLevelDensity)
	streamWriteUInt16(streamId, self.groundFogStartDayTimeMinutes)
	streamWriteUInt16(streamId, self.groundFogEndDayTimeMinutes)

	-- Conta i tipi di tempo attivi prima di scriverli.
	local numWeatherTypes = 0
	for weatherType, _ in pairs(self.groundFogWeatherTypes) do numWeatherTypes = numWeatherTypes + 1 end

	streamWriteUInt8(streamId, numWeatherTypes)

	-- Trasmette ogni tipo come stringa (nome enum) per compatibilità cross-versione.
	for weatherType, _ in pairs(self.groundFogWeatherTypes) do streamWriteString(streamId, WeatherType.getName(weatherType)) end

end
