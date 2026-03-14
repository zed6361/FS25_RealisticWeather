-- InGameMenuSettingsFrame.lua (RW_InGameMenuSettingsFrame)
-- Estensione del menu impostazioni in-game per integrare i controlli di RW.
--
-- Hook registrati:
--   InGameMenuSettingsFrame.onFrameOpen (append) → RW_InGameMenuSettingsFrame.onFrameOpen
--
-- updateButtons (attualmente commentato/disabilitato):
--   Aggiungeva un pulsante "Rigenera mappa umidità" (MENU_EXTRA_1) al menu impostazioni.
--   Il pulsante chiamava moistureSystem:onClickRebuildMoistureMap() al click.
--   È disabilitato perché la funzionalità è stata spostata nel pulsante
--   dedicato nella pagina RW del menu in-game (RWSettings).
--
-- onFrameOpen (append):
--   Chiamato ogni volta che il menu impostazioni viene aperto.
--   Ripristina lo stato disabled/enabled dei controlli UI di RW che hanno
--   dipendenze da altri controlli (campo `dependancy` in RWSettings.SETTINGS).
--   Esempio: witheringChance deve essere disabilitato se witheringEnabled == false.
--   Questo garantisce che lo stato visivo sia corretto anche dopo che
--   il menu è stato chiuso e riaperto senza modifiche intermedie.

RW_InGameMenuSettingsFrame = {}


-- (DISABILITATO) Aggiunta del pulsante "Rigenera mappa umidità" al menu impostazioni.
-- L'hook su updateButtons è commentato: il pulsante è stato rimosso da questo menu
-- e spostato in RWSettings (tab dedicato nel menu in-game).
function RW_InGameMenuSettingsFrame:updateButtons()
	
    local moistureSystem = g_currentMission.moistureSystem

	if moistureSystem == nil then return end

	-- Crea il buttonInfo solo al primo utilizzo (lazy init).
	self.regenerateMoistureMapButton = self.regenerateMoistureMapButton or {
		["inputAction"] = InputAction.MENU_EXTRA_1,
		["text"] = g_i18n:getText("rw_ui_rebuildMoistureMap"),
		["callback"] = function()
			moistureSystem:onClickRebuildMoistureMap()
		end,
		["showWhenPaused"] = true }

	table.insert(self.menuButtonInfo, self.regenerateMoistureMapButton)

	self:setMenuButtonInfoDirty()

end

-- L'hook su updateButtons è disabilitato: il pulsante non viene più aggiunto al menu impostazioni.
--InGameMenuSettingsFrame.updateButtons = Utils.appendedFunction(InGameMenuSettingsFrame.updateButtons, RW_InGameMenuSettingsFrame.updateButtons)


-- Hook append su InGameMenuSettingsFrame.onFrameOpen.
-- All'apertura del menu impostazioni, aggiorna lo stato abilitato/disabilitato
-- di tutti i controlli RW che hanno dipendenze dichiarate in RWSettings.SETTINGS.
-- Un controllo viene disabilitato se la sua dipendenza non è nello stato richiesto.
-- @param _  parametro non usato (supFunc già chiamata dal sistema append)
function RW_InGameMenuSettingsFrame:onFrameOpen(_)

	for name, setting in pairs(RWSettings.SETTINGS) do

		if setting.dependancy then
			local dependancy = RWSettings.SETTINGS[setting.dependancy.name]
			-- Disabilita il controllo se la dipendenza non è nello stato richiesto.
			if dependancy ~= nil and setting.element ~= nil then setting.element:setDisabled(dependancy.state ~= setting.dependancy.state) end
		end

	end

end

InGameMenuSettingsFrame.onFrameOpen = Utils.appendedFunction(InGameMenuSettingsFrame.onFrameOpen, RW_InGameMenuSettingsFrame.onFrameOpen)
