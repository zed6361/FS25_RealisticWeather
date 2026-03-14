-- RWSettings.lua
-- Sistema di impostazioni configurabili del mod RealisticWeather.
-- Definisce 15 impostazioni (BinaryOption, MultiTextOption, Button) con indici, valori,
-- callback e dipendenze tra controlli. Si integra nel menu impostazioni di FS clonando
-- i controlli UI esistenti e iniettando i propri.
-- Le impostazioni vengono caricate/salvate in rwSettings.xml nel savegame corrente.
-- In multiplayer, le modifiche del client vengono trasmesse al server via RW_BroadcastSettingsEvent.

RWSettings = {}
local modDirectory = g_currentModDirectory

g_gui:loadProfiles(modDirectory .. "gui/guiProfiles.xml")

-- Tabella principale delle impostazioni. Ogni entry ha:
--   index:          ordine di visualizzazione nel menu
--   type:           tipo di controllo UI (BinaryOption / MultiTextOption / Button)
--   default:        indice del valore predefinito nella lista values
--   values:         lista dei valori possibili
--   callback:       funzione chiamata quando l'impostazione cambia
--   dynamicTooltip: se true, il tooltip cambia in base allo stato corrente
--   dependancy:     blocca questo controllo se l'impostazione dipendente non ha lo stato atteso
RWSettings.SETTINGS = {

	-- Abilita/disabilita l'appassimento dei raccolti dovuto a carenza di umidità.
	["witheringEnabled"] = {
		["index"] = 2,
		["type"] = "BinaryOption",
		["dynamicTooltip"] = true,
		["default"] = 2,
		["binaryType"] = "offOn",
		["values"] = { false, true },
		["callback"] = MoistureSystem.onSettingChanged
	},

	-- Moltiplicatore di probabilità di appassimento (0.5x – 1.5x).
	-- Disabilitato se witheringEnabled è spento.
	["witheringChance"] = {
		["index"] = 3,
		["type"] = "MultiTextOption",
		["default"] = 6,
		["valueType"] = "float",
		["values"] = { 0.5, 0.6, 0.7, 0.8, 0.9, 1, 1.1, 1.2, 1.3, 1.4, 1.5 },
		["callback"] = MoistureSystem.onSettingChanged,
		["dependancy"] = {
			["name"] = "witheringEnabled",
			["state"] = 2
		}
	},

	-- Pulsante per forzare la rigenerazione completa della mappa di umidità.
	["rebuildMoistureMap"] = {
		["index"] = 1,
		["type"] = "Button",
		["ignore"] = true,
		["callback"] = MoistureSystem.onClickRebuildMoistureMap
	},

	-- Indice di performance: controlla la risoluzione della griglia di umidità.
	-- Valori più alti = celle più piccole = maggiore precisione ma più carico CPU.
	["performanceIndex"] = {
		["index"] = 4,
		["type"] = "MultiTextOption",
		["default"] = MoistureSystem.getDefaultPerformanceIndex(),
		["valueType"] = "int",
		["values"] = { 2, 3, 4, 5, 6, 7, 8, 9, 10 },
		["callback"] = MoistureSystem.onSettingChanged
	},

	-- Modificatore guadagno umidità terreno (0.1x – 2.0x).
	["moistureGainModifier"] = {
		["index"] = 5,
		["type"] = "MultiTextOption",
		["default"] = 10,
		["valueType"] = "float",
		["values"] = { 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1, 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 1.9, 2.0 },
		["callback"] = MoistureSystem.onSettingChanged
	},

	-- Modificatore perdita umidità terreno (0.1x – 2.0x).
	["moistureLossModifier"] = {
		["index"] = 6,
		["type"] = "MultiTextOption",
		["default"] = 10,
		["valueType"] = "float",
		["values"] = { 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1, 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 1.9, 2.0 },
		["callback"] = MoistureSystem.onSettingChanged
	},

	-- Modificatore guadagno umidità erba (sistema GrassMoistureSystem separato).
	["grassMoistureGainModifier"] = {
		["index"] = 7,
		["type"] = "MultiTextOption",
		["default"] = 10,
		["valueType"] = "float",
		["values"] = { 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1, 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 1.9, 2.0 },
		["callback"] = GrassMoistureSystem.onSettingChanged
	},

	-- Modificatore perdita umidità erba.
	["grassMoistureLossModifier"] = {
		["index"] = 8,
		["type"] = "MultiTextOption",
		["default"] = 10,
		["valueType"] = "float",
		["values"] = { 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1, 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 1.9, 2.0 },
		["callback"] = GrassMoistureSystem.onSettingChanged
	},

	-- Comportamento dell'overlay visivo di umidità sul terreno (3 modalità).
	["moistureOverlayBehaviour"] = {
		["index"] = 9,
		["type"] = "MultiTextOption",
		["dynamicTooltip"] = true,
		["default"] = 3,
		["values"] = { 1, 2, 3 },
		["callback"] = MoistureSystem.onSettingChanged
	},

	-- Comportamento del frame dell'overlay (2 modalità).
	["moistureFrameBehaviour"] = {
		["index"] = 10,
		["type"] = "BinaryOption",
		["dynamicTooltip"] = true,
		["default"] = 2,
		["values"] = { 1, 2 },
		["callback"] = MoistureSystem.onSettingChanged
	},

	-- Abilita/disabilita le tempeste di neve (blizzard).
	["blizzardsEnabled"] = {
		["index"] = 11,
		["type"] = "BinaryOption",
		["dynamicTooltip"] = true,
		["default"] = 2,
		["binaryType"] = "offOn",
		["values"] = { false, true },
		["callback"] = RW_Weather.onSettingChanged
	},

	-- Abilita/disabilita la siccità (drought).
	["droughtsEnabled"] = {
		["index"] = 12,
		["type"] = "BinaryOption",
		["dynamicTooltip"] = true,
		["default"] = 2,
		["binaryType"] = "offOn",
		["values"] = { false, true },
		["callback"] = RW_Weather.onSettingChanged
	},

	-- Abilita/disabilita le pozzanghere.
	["puddlesEnabled"] = {
		["index"] = 13,
		["type"] = "BinaryOption",
		["dynamicTooltip"] = true,
		["default"] = 2,
		["binaryType"] = "offOn",
		["values"] = { false, true },
		["callback"] = PuddleSystem.onSettingChanged
	},

	-- Abilita/disabilita il sistema di incendi.
	["fireEnabled"] = {
		["index"] = 14,
		["type"] = "BinaryOption",
		["dynamicTooltip"] = true,
		["default"] = 2,
		["binaryType"] = "offOn",
		["values"] = { false, true },
		["callback"] = FireSystem.onSettingChanged
	},

	-- Fattore moltiplicativo dell'effetto dell'umidità sulla resa del raccolto (0 – 2.0x).
	-- 0 = l'umidità non influenza la resa; 1 = effetto standard; >1 = effetto amplificato.
	["moistureYieldFactor"] = {
		["index"] = 15,
		["type"] = "MultiTextOption",
		["default"] = 11,
		["valueType"] = "float",
		["values"] = { 0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1, 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 1.9, 2.0 },
		["callback"] = RW_FSBaseMission.onSettingChanged
	}

}

-- Template dei controlli UI clonati dal menu di FS durante initialize().
RWSettings.BinaryOption = nil
RWSettings.MultiTextOption = nil
RWSettings.Button = nil


-- Carica i valori delle impostazioni da rwSettings.xml nel savegame corrente.
-- Chiamato solo sul server durante initialize().
-- Se il file non esiste, le impostazioni mantengono il loro valore default.
function RWSettings.loadFromXMLFile()

	local savegameIndex = g_careerScreen.savegameList.selectedIndex
	local savegame = g_savegameController:getSavegame(savegameIndex)

	if savegame ~= nil and savegame.savegameDirectory ~= nil then

		local path = savegame.savegameDirectory .. "/rwSettings.xml"

		local xmlFile = XMLFile.loadIfExists("rwSettings", path)

		if xmlFile ~= nil then

			local key = "settings"
			
			for name, setting in pairs(RWSettings.SETTINGS) do

				if setting.ignore then continue end

				setting.state = xmlFile:getInt(key .. "." .. name .. "#value", setting.default)

				-- Sicurezza: se il valore salvato è fuori range, usa l'ultimo valore disponibile.
				if setting.state > #setting.values then setting.state = #setting.values end

			end

			xmlFile:delete()

		end

	end

end


-- Salva tutte le impostazioni in rwSettings.xml nel savegame corrente.
-- Viene ricreato da zero ad ogni salvataggio (non aggiornamento incrementale).
-- Chiamato solo sul server dopo ogni modifica a un'impostazione.
-- @param name   nome dell'impostazione modificata (non usato direttamente, si salvano tutte)
-- @param state  nuovo stato (non usato direttamente, si leggono tutti da setting.state)
function RWSettings.saveToXMLFile(name, state)

	if g_server ~= nil then

		local savegameIndex = g_careerScreen.savegameList.selectedIndex
		local savegame = g_savegameController:getSavegame(savegameIndex)

		if savegame ~= nil and savegame.savegameDirectory ~= nil then

			local path = savegame.savegameDirectory .. "/rwSettings.xml"
			local xmlFile = XMLFile.create("rwSettings", path, "settings")

			if xmlFile ~= nil then

				for settingName, setting in pairs(RWSettings.SETTINGS) do
					if setting.ignore then continue end
					xmlFile:setInt("settings." .. settingName .. "#value", setting.state)
				end

				local saved = xmlFile:save(false, true)

				xmlFile:delete()

			end

		end

	end

end


-- Inizializza il sistema: carica le impostazioni dal savegame (solo server),
-- poi inietta i controlli UI nel menu impostazioni di FS clonando i template esistenti.
-- I controlli vengono inseriti in ordine di index, con label, testi e tooltip localizzati.
-- Le dipendenze tra controlli vengono applicate subito dopo la creazione.
-- Eseguita automaticamente al caricamento del file (ultima riga del modulo).
function RWSettings.initialize()

	if g_server ~= nil then RWSettings.loadFromXMLFile() end

	local settingsPage = g_inGameMenu.pageSettings
	local scrollPanel = settingsPage.gameSettingsLayout

	local sectionHeader, binaryOptionElement, multiOptionElement, buttonElement

	-- Cerca i template dei controlli UI nel pannello impostazioni di FS.
	for _, element in pairs(scrollPanel.elements) do

		if element.name == "sectionHeader" and sectionHeader == nil then sectionHeader = element:clone(scrollPanel) end

		if element.typeName == "Bitmap" then

			if element.elements[1].typeName == "BinaryOption" and binaryOptionElement == nil then binaryOptionElement = element end

			if element.elements[1].typeName == "MultiTextOption" and multiOptionElement == nil then multiOptionElement = element end

			if element.elements[1].typeName == "Button" and buttonElement == nil then buttonElement = element end

		end

		if multiOptionElement and binaryOptionElement and sectionHeader and buttonElement then break end	

	end

	if multiOptionElement == nil or binaryOptionElement == nil or sectionHeader == nil or buttonElement == nil then return end

	RWSettings.BinaryOption = binaryOptionElement
	RWSettings.MultiTextOption  = multiOptionElement
	RWSettings.Button = buttonElement

	local prefix = "rw_settings_"

	sectionHeader:setText(g_i18n:getText("rw_settings"))

	local maxIndex = 0

	for _, setting in pairs(RWSettings.SETTINGS) do maxIndex = maxIndex < setting.index and setting.index or maxIndex end

	-- Crea i controlli UI in ordine di index, clonando il template corretto per ogni tipo.
	for i = 1, maxIndex do

		for name, setting in pairs(RWSettings.SETTINGS) do

			if setting.index ~= i then continue end
	
			setting.state = setting.state or setting.default
			local template = RWSettings[setting.type]:clone(scrollPanel)
			local settingsPrefix = "rw_settings_" .. name .. "_"
			template.id = nil
		
			for _, element in pairs(template.elements) do

				if element.typeName == "Text" then
					element:setText(g_i18n:getText(settingsPrefix .. "label"))
					element.id = nil
				end

				if element.typeName == setting.type then

					if setting.type == "Button" then
						element:setText(g_i18n:getText(settingsPrefix .. "text"))
						element:applyProfile("rw_settingsButton")
						element.isAlwaysFocusedOnOpen = false
						element.focused = false
					else

						local texts = {}

						-- Genera i testi visualizzati nel controllo in base al tipo di valore:
						-- offOn → testi localizzati "Off"/"On"
						-- int   → numero intero come stringa
						-- float → percentuale formattata
						-- altro → testo localizzato da file i18n
						if setting.binaryType == "offOn" then
							texts[1] = g_i18n:getText("rw_settings_off")
							texts[2] = g_i18n:getText("rw_settings_on")
						else

							for i, value in pairs(setting.values) do

								if setting.valueType == "int" then
									texts[i] = tostring(value)
								elseif setting.valueType == "float" then
									texts[i] = string.format("%.0f%%", value * 100)
								else
									texts[i] = g_i18n:getText(settingsPrefix .. "texts_" .. i)
								end
							end

						end

						element:setTexts(texts)
						element:setState(setting.state)

						-- Tooltip dinamico: cambia in base allo stato corrente dell'impostazione.
						if setting.dynamicTooltip then
							element.elements[1]:setText(g_i18n:getText(settingsPrefix .. "tooltip_" .. setting.state))
						else
							element.elements[1]:setText(g_i18n:getText(settingsPrefix .. "tooltip"))
						end

					end

					-- L'id del controllo ha il prefisso "rws_" per essere identificato in onSettingChanged.
					element.id = "rws_" .. name
					element.onClickCallback = RWSettings.onSettingChanged

					setting.element = element

					-- Applica subito la dipendenza se il controllo da cui dipende è già stato creato.
					if setting.dependancy then
						local dependancy = RWSettings.SETTINGS[setting.dependancy.name]
						if dependancy ~= nil and dependancy.element ~= nil then element:setDisabled(dependancy.state ~= setting.dependancy.state) end
					end

				end
			
			end

		end

	end

end


-- Callback unificato per tutti i controlli UI di RealisticWeather.
-- Identifica l'impostazione dall'id del controllo (prefisso "rws_"),
-- chiama la callback specifica del sistema interessato,
-- aggiorna le dipendenze tra controlli,
-- aggiorna il tooltip dinamico se previsto,
-- salva (server) o trasmette al server (client) la modifica.
-- @param _      parametro ignorato (contesto UI)
-- @param state  nuovo indice dello stato selezionato
-- @param button elemento UI che ha generato l'evento
function RWSettings.onSettingChanged(_, state, button)

	if button == nil then button = state end

	if button == nil or button.id == nil then return end

	-- Verifica che il controllo appartenga a RealisticWeather (prefisso "rws_").
	if not string.contains(button.id, "rws_") then return end

	local name = string.sub(button.id, 5)
	local setting = RWSettings.SETTINGS[name]

	if setting == nil then return end

	-- Impostazioni con ignore=true (es. Button) chiamano solo la callback senza aggiornare lo stato.
	if setting.ignore then
		if setting.callback then setting.callback() end
		return
	end

	if setting.callback then setting.callback(name, setting.values[state]) end

	setting.state = state

	-- Aggiorna lo stato disabilitato di tutti i controlli che dipendono da questa impostazione.
	for _, s in pairs(RWSettings.SETTINGS) do
		if s.dependancy and s.dependancy.name == name then
			s.element:setDisabled(s.dependancy.state ~= state)
		end
	end

	if setting.dynamicTooltip and setting.element ~= nil then setting.element.elements[1]:setText(g_i18n:getText("rw_settings_" .. name .. "_tooltip_" .. setting.state)) end

	if g_server ~= nil then

		RWSettings.saveToXMLFile(name, state)

	else

		-- In multiplayer, il client trasmette la modifica al server.
		RW_BroadcastSettingsEvent.sendEvent(name)

	end

end


-- Applica tutte le impostazioni con il loro stato corrente, chiamando le rispettive callback.
-- Usata all'avvio per inizializzare i sistemi con i valori caricati dal savegame.
-- Sul client, la logica di broadcast è commentata (le impostazioni vengono ricevute dal server).
function RWSettings.applyDefaultSettings()

	if g_server == nil then

		--RW_BroadcastSettingsEvent.sendEvent()

	else

		for name, setting in pairs(RWSettings.SETTINGS) do
		
			if setting.ignore then continue end

			if setting.callback ~= nil then setting.callback(name, setting.values[setting.state]) end

			if setting.dynamicTooltip and setting.element ~= nil then setting.element.elements[1]:setText(g_i18n:getText("rw_settings_" .. name .. "_tooltip_" .. setting.state)) end

			for _, s in pairs(RWSettings.SETTINGS) do
				if s.dependancy and s.dependancy.name == name and s.element ~= nil then
					s.element:setDisabled(s.dependancy.state ~= state)
				end
			end
		end

	end
end


-- Eseguito al caricamento del file: inizializza il sistema UI e carica le impostazioni.
RWSettings.initialize()
