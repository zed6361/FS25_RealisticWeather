-- DensityMapHeightManager.lua (RW_DensityMapHeightManager)
-- Modulo di integrazione di RealisticWeather con DensityMapHeightManager.
-- Aggancia tramite override la funzione loadMapData per inizializzare tutti i sistemi RW
-- nel momento in cui la mappa di gioco viene caricata (dopo che il terreno base è pronto).
--
-- Sistemi creati e registrati su g_currentMission:
--   moistureSystem      → griglia umidità terreno (MoistureSystem)
--   grassMoistureSystem → tracciamento umidità erba sfalciata (GrassMoistureSystem)
--   puddleSystem        → gestione pozzanghere (PuddleSystem)
--   fireSystem          → gestione incendi (FireSystem)
--
-- Solo sul server:
--   - Carica moisture.xml, grassMoisture.xml e fires.xml dal savegame corrente
--   - Aggancia gli hook su PlayerInputComponent.update e PlayerHUDUpdater.update
--     per rilevare la falciatura e aggiornare l'overlay HUD
--
-- Su tutti i peer (server e client):
--   - Carica le varianti grafiche delle pozzanghere (puddles.xml + file i3d)
--     necessario per la creazione dei nodi 3D alla ricezione di PuddleSystemStateEvent

RW_DensityMapHeightManager = {}


-- Override di DensityMapHeightManager.loadMapData.
-- Chiama prima la funzione originale (carica la mappa terreno di FS),
-- poi crea e inizializza tutti i sistemi RW nell'ordine corretto.
-- @param superFunc     funzione originale DensityMapHeightManager.loadMapData
-- @param xmlFile       file XML della mappa
-- @param missionInfo   informazioni sulla missione corrente
-- @param baseDirectory directory base della mappa
-- @return valore di ritorno della funzione originale
function RW_DensityMapHeightManager:loadMapData(superFunc, xmlFile, missionInfo, baseDirectory)

    local returnValue = superFunc(self, xmlFile, missionInfo, baseDirectory)

    -- Crea le istanze di tutti i sistemi RW e le registra su g_currentMission.
    g_currentMission.moistureSystem = MoistureSystem.new()
    g_currentMission.grassMoistureSystem = GrassMoistureSystem.new()
    g_currentMission.puddleSystem = PuddleSystem.new()
    g_currentMission.fireSystem = FireSystem.new()

    if g_currentMission:getIsServer() then
        -- Sul server: carica i dati salvati dal savegame per i sistemi che li supportano.
        -- moistureSystem riceve anche xmlFile per leggere parametri della mappa (dimensioni griglia).
        g_currentMission.moistureSystem:loadFromXMLFile(xmlFile)
        g_currentMission.grassMoistureSystem:loadFromXMLFile()
        g_currentMission.fireSystem:loadFromXMLFile()
        -- Aggancia gli hook per il rilevamento della falciatura e l'aggiornamento dell'overlay HUD.
        PlayerInputComponent.update = Utils.appendedFunction(PlayerInputComponent.update, RW_PlayerInputComponent.update)
        PlayerHUDUpdater.update = Utils.appendedFunction(PlayerHUDUpdater.update, RW_PlayerHUDUpdater.update)
    end

    -- Carica le varianti grafiche delle pozzanghere su tutti i peer
    -- (necessario per inizializzare i nodi 3D al join MP e al caricamento single player).
    g_currentMission.puddleSystem:loadVariations()

    return returnValue

end

DensityMapHeightManager.loadMapData = Utils.overwrittenFunction(DensityMapHeightManager.loadMapData, RW_DensityMapHeightManager.loadMapData)
