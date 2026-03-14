-- FSCareerMissionInfo.lua (RW_FSCareerMissionInfo)
-- Modulo di integrazione di RealisticWeather con FSCareerMissionInfo.
-- Aggancia tramite append la funzione saveToXMLFile della missione career
-- per salvare i dati di tutti i sistemi RW insieme al savegame di FS.
--
-- File salvati nella directory del savegame corrente:
--   grassMoisture.xml  → stato del GrassMoistureSystem (aree di erba con umidità tracciata)
--   moisture.xml       → stato del MoistureSystem (griglia umidità terreno)
--   puddles.xml        → stato del PuddleSystem (pozzanghere attive)
--   fires.xml          → stato del FireSystem (fuochi attivi e campo in fiamme)
--   rwSettings.xml     → impostazioni RW (salvataggio senza parametri = tutte le impostazioni)
--
-- Il salvataggio avviene solo se xmlFile è valido (missione già inizializzata)
-- e se grassMoistureSystem è presente (guard contro chiamate anticipate).

RW_FSCareerMissionInfo = {}

-- Hook append su FSCareerMissionInfo.saveToXMLFile.
-- Viene chiamato automaticamente da FS al salvataggio della partita.
-- Delega il salvataggio di ogni sistema al rispettivo metodo saveToXMLFile.
function RW_FSCareerMissionInfo:saveToXMLFile()
    if self.xmlFile ~= nil and g_currentMission ~= nil and g_currentMission.grassMoistureSystem ~= nil then
        g_currentMission.grassMoistureSystem:saveToXMLFile(self.savegameDirectory .. "/grassMoisture.xml")
        g_currentMission.moistureSystem:saveToXMLFile(self.savegameDirectory .. "/moisture.xml")
        g_currentMission.puddleSystem:saveToXMLFile(self.savegameDirectory .. "/puddles.xml")
        g_currentMission.fireSystem:saveToXMLFile(self.savegameDirectory .. "/fires.xml")
        RWSettings.saveToXMLFile()
    end
end

FSCareerMissionInfo.saveToXMLFile = Utils.appendedFunction(FSCareerMissionInfo.saveToXMLFile, RW_FSCareerMissionInfo.saveToXMLFile)
