-- WeatherInstance.lua (RW_WeatherInstance)
-- Estensione di WeatherInstance per aggiungere i campi custom di RealisticWeather:
--   isBlizzard   → true se questo slot meteo è un evento blizzard
--   isDraught    → true se questo slot meteo è un evento di siccità
--   snowForecast → previsione neve in cm (float opzionale, nil se non rilevante)
--
-- Hook registrati:
--   WeatherInstance.saveToXMLFile   (append)    → RW_WeatherInstance.saveToXMLFile
--   WeatherInstance.loadFromXMLFile (overwrite) → RW_WeatherInstance.loadFromXMLFile
--   WeatherInstance.readStream      (append)    → RW_WeatherInstance.readStream
--   WeatherInstance.writeStream     (append)    → RW_WeatherInstance.writeStream
--
-- Tutti i campi aggiuntivi sono opzionali con valori di default sicuri (false / -1.0)
-- per garantire compatibilità con savegame creati senza il mod.


-- Hook append su WeatherInstance.saveToXMLFile.
-- Salva i campi RW solo se hanno valori significativi (risparmio spazio XML).
-- snowForecast viene salvato solo se non nil; isBlizzard/isDraught solo se true.
function RW_WeatherInstance:saveToXMLFile(xmlFile, key, _)
    -- AGGIUNTA: Se xmlFile è nil, esci dalla funzione senza crashare
    if xmlFile == nil then
        return 
    end

    if self.isBlizzard then xmlFile:setBool(key .. "#isBlizzard", true) end
    if self.isDraught then xmlFile:setBool(key .. "#isDraught", true) end
    if self.snowForecast ~= nil then 
        xmlFile:setFloat(key .. "#snowForecast", self.snowForecast) 
    end
end

WeatherInstance.saveToXMLFile = Utils.appendedFunction(WeatherInstance.saveToXMLFile, RW_WeatherInstance.saveToXMLFile)


-- Override di WeatherInstance.loadFromXMLFile.
-- Chiama prima la funzione base di FS (carica i campi vanilla),
-- poi legge i campi RW con valori di default compatibili.
-- snowForecast viene letto come float: se il valore letto è -1.0 (non salvato),
-- rimane nil (non impostato).
-- @param superFunc  funzione originale WeatherInstance.loadFromXMLFile
-- @param xmlFile    file XML del savegame
-- @param key        percorso XML del nodo WeatherInstance
-- @return valore di ritorno della funzione base
function RW_WeatherInstance:loadFromXMLFile(superFunc, xmlFile, key)
    -- AGGIUNTA SICUREZZA: se xmlFile è nil, non possiamo leggere nulla
    if xmlFile == nil then
        return superFunc(self, xmlFile, key)
    end

    local r = superFunc(self, xmlFile, key)

    self.isBlizzard = xmlFile:getBool(key .. "#isBlizzard", false)
    self.isDraught = xmlFile:getBool(key .. "#isDraught", false)

    -- -1.0 è il valore sentinella che indica "non salvato" → rimane nil.
    local snowForecast = xmlFile:getFloat(key .. "#snowForecast", -1.0)
    if snowForecast >= 0 then self.snowForecast = snowForecast end

    return r
end

WeatherInstance.loadFromXMLFile = Utils.overwrittenFunction(WeatherInstance.loadFromXMLFile, RW_WeatherInstance.loadFromXMLFile)


-- Hook append su WeatherInstance.readStream.
-- Legge i campi RW aggiunti dopo i dati vanilla nello stream di rete.
-- snowForecast: −1.0 come sentinella per "non presente".
function RW_WeatherInstance:readStream(streamId, _)

    self.isBlizzard = streamReadBool(streamId)
    self.isDraught = streamReadBool(streamId)
    local snowForecast = streamReadFloat32(streamId)
    if snowForecast >= 0 then self.snowForecast = snowForecast end

end

WeatherInstance.readStream = Utils.appendedFunction(WeatherInstance.readStream, RW_WeatherInstance.readStream)


-- Hook append su WeatherInstance.writeStream.
-- Scrive i campi RW dopo i dati vanilla nello stream di rete.
-- isBlizzard/isDraught: false come default; snowForecast: -1.0 se nil.
function RW_WeatherInstance:writeStream(streamId, _)

    streamWriteBool(streamId, self.isBlizzard or false)
    streamWriteBool(streamId, self.isDraught or false)
    streamWriteFloat32(streamId, self.snowForecast or -1.0)

end

WeatherInstance.writeStream = Utils.appendedFunction(WeatherInstance.writeStream, RW_WeatherInstance.writeStream)
