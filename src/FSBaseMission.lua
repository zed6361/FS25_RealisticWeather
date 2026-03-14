-- FSBaseMission.lua (RW_FSBaseMission)
-- Modulo di integrazione di RealisticWeather con FSBaseMission.
-- Aggancia tramite hook (prepend/append) le funzioni principali della missione base di FS
-- per inizializzare, sincronizzare e salvare tutti i sistemi del mod.
--
-- Hook registrati:
--   FSBaseMission.onStartMission      (prepend) → RW_FSBaseMission.onStartMission
--   FSBaseMission.sendInitialClientState (prepend) → RW_FSBaseMission.sendInitialClientState
--   FSBaseMission.initTerrain         (append)  → RW_FSBaseMission.initTerrain
--
-- Contiene inoltre:
--   FRUIT_TYPES_MOISTURE: tabella con i range di umidità ottimali (LOW/HIGH) per ogni coltura.
--     Usata come fallback quando PrecisionFarming non è disponibile.
--   fixInGameMenu: utility interna per inserire una pagina custom nel menu in-game
--     nella posizione corretta (prima del tab Animali).
--   onSettingChanged: callback generica per aggiornare g_currentMission con il nuovo stato.

RW_FSBaseMission = {}
local modDirectory = g_currentModDirectory

-- Tabella dei range di umidità ottimale per ciascuna coltura (valori agronomi reali).
-- LOW = umidità minima accettabile per la raccolta senza perdita di qualità.
-- HIGH = umidità massima ottimale.
-- Il valore DEFAULT viene usato per le colture non esplicitamente elencate.
RW_FSBaseMission.FRUIT_TYPES_MOISTURE = {
    ["DEFAULT"] = { ["LOW"] = 0.15, ["HIGH"] = 0.18 },
    ["BARLEY"] = { ["LOW"] = 0.12, ["HIGH"] = 0.135 },
    ["WHEAT"] = { ["LOW"] = 0.12, ["HIGH"] = 0.145 },
    ["OAT"] = { ["LOW"] = 0.12, ["HIGH"] = 0.18 },
    ["CANOLA"] = { ["LOW"] = 0.08, ["HIGH"] = 0.1 },
    ["SOYBEAN"] = { ["LOW"] = 0.125, ["HIGH"] = 0.135 },
    ["SORGHUM"] = { ["LOW"] = 0.17, ["HIGH"] = 0.2 },
    ["RICELONGGRAIN"] = { ["LOW"] = 0.19, ["HIGH"] = 0.22 },
    ["MAIZE"] = { ["LOW"] = 0.15, ["HIGH"] = 0.2 },
    ["SUNFLOWER"] = { ["LOW"] = 0.09, ["HIGH"] = 0.1 },
    ["GRASS"] = { ["LOW"] = 0.18, ["HIGH"] = 0.22 },
    ["OILSEEDRADISH"] = { ["LOW"] = 0.2, ["HIGH"] = 0.22 },
    ["PEA"] = { ["LOW"] = 0.14, ["HIGH"] = 0.15 },
    ["SPINACH"] = { ["LOW"] = 0.2, ["HIGH"] = 0.22 },
    ["SUGARCANE"] = { ["LOW"] = 0.22, ["HIGH"] = 0.26 },
    ["SUGARBEET"] = { ["LOW"] = 0.22, ["HIGH"] = 0.26 },
    ["COTTON"] = { ["LOW"] = 0.1, ["HIGH"] = 0.12 },
    ["GREENBEAN"] = { ["LOW"] = 0.175, ["HIGH"] = 0.185 },
    ["CARROT"] = { ["LOW"] = 0.135, ["HIGH"] = 0.155 },
    ["PARSNIP"] = { ["LOW"] = 0.135, ["HIGH"] = 0.155 },
    ["BEETROOT"] = { ["LOW"] = 0.15, ["HIGH"] = 0.17 },
    ["RICE"] = { ["LOW"] = 0.22, ["HIGH"] = 0.24 },
    ["POTATO"] = { ["LOW"] = 0.18, ["HIGH"] = 0.2 }
}


-- Inserisce una pagina custom (frame) nel menu in-game di FS nella posizione corretta.
-- La funzione cerca il tab pageAnimals come punto di riferimento e inserisce prima di esso.
-- Dopo l'inserimento, aggiorna il mapping del pager e registra il tab con l'icona custom.
-- @param frame         istanza del frame GUI da inserire
-- @param pageName      nome della proprietà in inGameMenu (es. "realisticWeatherFrame")
-- @param uvs           coordinate UV per l'icona del tab (da icons.dds)
-- @param position      posizione di inserimento (default: ultimo + 1, poi sovrascritta)
-- @param predicateFunc funzione che determina se il tab è visibile (es. function() return true end)
local function fixInGameMenu(frame, pageName, uvs, position, predicateFunc)

	local inGameMenu = g_gui.screenControllers[InGameMenu]
	position = position or #inGameMenu.pagingElement.pages + 1

	-- Rimuove l'eventuale mapping precedente del controlID per evitare duplicati.
	for k, v in pairs({pageName}) do
		inGameMenu.controlIDs[v] = nil
	end

	-- Trova la posizione del tab pageAnimals per inserire prima di esso.
	for i = 1, #inGameMenu.pagingElement.elements do
		local child = inGameMenu.pagingElement.elements[i]
		if child == inGameMenu.pageAnimals then
			position = i
            break
		end
	end
	
	inGameMenu[pageName] = frame
	inGameMenu.pagingElement:addElement(inGameMenu[pageName])

	inGameMenu:exposeControlsAsFields(pageName)

	-- Riposiziona l'elemento nel pagingElement alla posizione corretta.
	for i = 1, #inGameMenu.pagingElement.elements do
		local child = inGameMenu.pagingElement.elements[i]
		if child == inGameMenu[pageName] then
			table.remove(inGameMenu.pagingElement.elements, i)
			table.insert(inGameMenu.pagingElement.elements, position, child)
			break
		end
	end

	-- Riposiziona anche nella lista delle pages (metadati di navigazione).
	for i = 1, #inGameMenu.pagingElement.pages do
		local child = inGameMenu.pagingElement.pages[i]
		if child.element == inGameMenu[pageName] then
			table.remove(inGameMenu.pagingElement.pages, i)
			table.insert(inGameMenu.pagingElement.pages, position, child)
			break
		end
	end

	inGameMenu.pagingElement:updateAbsolutePosition()
	inGameMenu.pagingElement:updatePageMapping()
	
	inGameMenu:registerPage(inGameMenu[pageName], position, predicateFunc)
	inGameMenu:addPageTab(inGameMenu[pageName], modDirectory .. "gui/icons.dds", GuiUtils.getUVs(uvs))

	-- Riposiziona il frame nella lista pageFrames.
	for i = 1, #inGameMenu.pageFrames do
		local child = inGameMenu.pageFrames[i]
		if child == inGameMenu[pageName] then
			table.remove(inGameMenu.pageFrames, i)
			table.insert(inGameMenu.pageFrames, position, child)
			break
		end
	end

	inGameMenu:rebuildTabList()

end


-- Hook prepend su FSBaseMission.onStartMission.
-- Eseguito all'avvio della missione (dopo che i sistemi base di FS sono pronti).
-- Responsabilità:
--   1. Applica tutte le impostazioni RW con i valori caricati dal savegame (RWSettings.applyDefaultSettings)
--   2. Registra le texture degli overlay (icone UI e icone pagina)
--   3. Rileva i mod compatibili (RealisticLivestock, ExtendedGameInfoDisplay, PrecisionFarming)
--      e imposta i flag di compatibilità corrispondenti
--   4. Carica e inserisce il frame RealisticWeatherFrame nel menu in-game
--   5. Registra la MoistureArgumentsDialog
function RW_FSBaseMission:onStartMission()

    RWSettings.applyDefaultSettings()

    g_overlayManager:addTextureConfigFile(modDirectory .. "gui/icons.xml", "realistic_weather")
    g_overlayManager:addTextureConfigFile(modDirectory .. "gui/page_icons.xml", "realistic_weather_pages")

    -- Rilevamento mod compatibili: imposta i flag usati da altri sistemi RW.
    if g_modIsLoaded["FS25_RealisticLivestock"] then RW_Weather.isRealisticLivestockLoaded = true end
    if g_modIsLoaded["FS25_ExtendedGameInfoDisplay"] then RW_GameInfoDisplay.isExtendedGameInfoDisplayLoaded = true end
    -- RW_COMPAT_FIX: keep yield logic deterministic with Precision Farming
    RW_FSBaseMission.isPrecisionFarmingLoaded = g_modIsLoaded["FS25_precisionFarming"] or g_modIsLoaded["FS25_PrecisionFarming"] or g_modIsLoaded["precisionFarming"]

    -- Carica e inietta la pagina RealisticWeather nel menu in-game.
    local realisticWeatherFrame = RealisticWeatherFrame.new() 
	g_gui:loadGui(modDirectory .. "gui/RealisticWeatherFrame.xml", "RealisticWeatherFrame", realisticWeatherFrame, true)

    fixInGameMenu(realisticWeatherFrame, "realisticWeatherFrame", {260,0,256,256}, 4, function() return true end)

    realisticWeatherFrame:initialize()

    MoistureArgumentsDialog.register()

end

FSBaseMission.onStartMission = Utils.prependedFunction(FSBaseMission.onStartMission, RW_FSBaseMission.onStartMission)


-- Hook prepend su FSBaseMission.sendInitialClientState.
-- Chiamato dal server quando un nuovo client si connette.
-- Invia in sequenza:
--   1. RW_BroadcastSettingsEvent (tutte le impostazioni RW correnti)
--   2. PuddleSystemStateEvent (stato completo delle pozzanghere)
--   3. FireEvent (stato completo degli incendi, con snapshot della lista per evitare race condition)
-- RW_MP_FIX: la lista fires viene clonata prima della serializzazione per evitare
-- mutazioni concorrenti durante il broadcast.
function RW_FSBaseMission:sendInitialClientState(connection, _, _)

    local puddleSystem = g_currentMission.puddleSystem
    local fireSystem = g_currentMission.fireSystem
    local fireSnapshot = {}

    -- RW_MP_FIX: clone fire list to avoid mutation races during serialization
    for i = 1, #fireSystem.fires do
        fireSnapshot[i] = fireSystem.fires[i]
    end

    connection:sendEvent(RW_BroadcastSettingsEvent.new())
    connection:sendEvent(PuddleSystemStateEvent.new(puddleSystem.updateIteration, puddleSystem.timeSinceLastUpdate, puddleSystem.puddles))
    connection:sendEvent(FireEvent.new(fireSystem.updateIteration, fireSystem.timeSinceLastUpdate, fireSystem.fieldId, fireSnapshot))

end

FSBaseMission.sendInitialClientState = Utils.prependedFunction(FSBaseMission.sendInitialClientState, RW_FSBaseMission.sendInitialClientState)


-- Hook append su FSBaseMission.initTerrain.
-- Chiamato dopo che il terreno è stato inizializzato dalla missione base.
-- Inizializza nella scena 3D le pozzanghere e i fuochi caricati dal savegame.
function RW_FSBaseMission:initTerrain(_, _)

    g_currentMission.puddleSystem:initialize()
    g_currentMission.fireSystem:initialize()

end

FSBaseMission.initTerrain = Utils.appendedFunction(FSBaseMission.initTerrain, RW_FSBaseMission.initTerrain)


-- Callback generica per il cambio di impostazioni che aggiornano direttamente g_currentMission.
-- Usata da RWSettings per impostazioni che si mappano su proprietà della missione.
-- @param name   nome del campo da aggiornare in g_currentMission
-- @param state  nuovo valore
function RW_FSBaseMission.onSettingChanged(name, state)
    g_currentMission[name] = state
end
