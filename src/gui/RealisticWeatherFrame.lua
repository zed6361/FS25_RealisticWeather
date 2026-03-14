-- RealisticWeatherFrame.lua
-- Frame del menu in-game dedicato a RealisticWeather.
-- Mostra una tabella paginata con i dati di umidità di tutte le celle del campo,
-- con funzionalità di ordinamento, paginazione, teleport e gestione irrigazione.
-- Estende TabbedMenuFrameElement e viene inserito nel menu in-game da FSBaseMission.lua.
--
-- Modalità di visualizzazione (controllate da moistureFrameBehaviour):
--   showAll = true  (behaviour == 1): un campo per tab nel fieldList, mostra dati a livello
--                    di singola cella (x, z, moisture, trend, retention, witherChance)
--   showAll = false (behaviour != 1): lista "Campi Posseduti" / "Tutti i Campi" nel fieldList,
--                    mostra dati aggregati per campo (media di tutte le celle del campo)
--                    con colonne aggiuntive: field, irrigationActive, irrigationCost
--
-- Struttura dati:
--   fieldData[i]    → lista di celle (dati raw) per il campo i-esimo (modalità showAll)
--   ownedFieldData  → lista di medie per i campi posseduti (modalità aggregata)
--   allFieldData    → lista di medie per tutti i campi (modalità aggregata)
--   pages[p][i]     → dati della pagina p, elemento i (max ITEMS_PER_PAGE=250 per pagina)
--
-- Pulsanti disponibili:
--   MENU_BACK         → torna al menu precedente
--   MENU_PAGE_NEXT    → pagina successiva
--   MENU_PAGE_PREV    → pagina precedente
--   MENU_EXTRA_1      → aggiorna i dati (onClickRefresh)
--   MENU_ACCEPT       → teleporta il player alla cella selezionata (onClickTeleport)
--   MENU_ACTIVATE     → attiva/disattiva irrigazione per il campo selezionato (onClickIrrigation)
--
-- Ordinamento:
--   onClickSortButton(): toggle crescente/decrescente per la colonna cliccata.
--   Per le colonne irrigationActive/irrigationCost richiede una query al moistureSystem
--   prima di ordinare (i valori non sono cached nelle celle).

RealisticWeatherFrame = {}
RealisticWeatherFrame.ITEMS_PER_PAGE = 250  -- numero massimo di celle per pagina

local realisticWeatherFrame_mt = Class(RealisticWeatherFrame, TabbedMenuFrameElement)


-- Costruttore: inizializza tutte le strutture dati con valori di default.
function RealisticWeatherFrame.new()

	local self = RealisticWeatherFrame:superClass().new(nil, realisticWeatherFrame_mt)
	
	self.name = "RealisticWeatherFrame"
	self.ownedFields = {}        -- lista di fieldId dei campi posseduti dal player
	self.fieldTexts = {}         -- testi del fieldList selettore
	self.selectedField = 1       -- indice del campo selezionato nel fieldList
	self.fieldData = {}          -- dati celle per campo (modalità showAll)
	self.allFields = {}          -- lista di tutti i fieldId
	self.mapWidth, self.mapHeight = 2048, 2048  -- dimensioni mappa per conversione coordinate
	self.buttonStates = {}       -- stato dei pulsanti di ordinamento (sorter, target, pos)
	self.hasContent = false      -- true se il contenuto è già stato caricato
	self.cachedBehaviour = 0     -- valore di moistureFrameBehaviour al momento del caricamento
	self.selectedFieldId = nil   -- fieldId del campo selezionato in modalità aggregata

	return self

end


function RealisticWeatherFrame:delete()
	RealisticWeatherFrame:superClass().delete(self)
end


-- Inizializza i buttonInfo per tutti i pulsanti del frame.
-- Chiamato dal sistema menu prima della prima apertura del frame.
function RealisticWeatherFrame:initialize()

	self.backButtonInfo = {
		["inputAction"] = InputAction.MENU_BACK
	}

	self.nextPageButtonInfo = {
		["inputAction"] = InputAction.MENU_PAGE_NEXT,
		["text"] = g_i18n:getText("ui_ingameMenuNext"),
		["callback"] = self.onPageNext
	}

	self.prevPageButtonInfo = {
		["inputAction"] = InputAction.MENU_PAGE_PREV,
		["text"] = g_i18n:getText("ui_ingameMenuPrev"),
		["callback"] = self.onPagePrevious
	}

	self.irrigationButtonInfo = {
		["inputAction"] = InputAction.MENU_ACTIVATE,
		["text"] = g_i18n:getText("rw_ui_irrigation_start"),
		["callback"] = function()
			self:onClickIrrigation()
		end,
		["profile"] = "buttonSelect"
	}

	self.refreshButtonInfo = {
		["inputAction"] = InputAction.MENU_EXTRA_1,
		["text"] = g_i18n:getText("button_refresh"),
		["callback"] = function()
			self:onClickRefresh()
		end,
		["profile"] = "buttonMenuSwitch"
	}

	self.teleportButtonInfo = {
		["inputAction"] = InputAction.MENU_ACCEPT,
		["text"] = g_i18n:getText("rw_ui_teleport"),
		["callback"] = function()
			self:onClickTeleport()
		end,
		["profile"] = "buttonOK"
	}
	
end


function RealisticWeatherFrame:onGuiSetupFinished()
	RealisticWeatherFrame:superClass().onGuiSetupFinished(self)
end


-- Chiamato all'apertura del frame.
-- Se il contenuto non è ancora stato caricato, o se il comportamento del frame
-- è cambiato (moistureFrameBehaviour modificato nelle impostazioni), rigenera
-- tutto il contenuto tramite updateContent().
-- Altrimenti, ricarica solo la lista e aggiorna i pulsanti (path veloce).
function RealisticWeatherFrame:onFrameOpen()
	RealisticWeatherFrame:superClass().onFrameOpen(self)
    if not self.hasContent or (g_currentMission.moistureSystem ~= nil and g_currentMission.moistureSystem.moistureFrameBehaviour ~= self.cachedBehaviour) then
		self:updateContent()
	else
		self:resetButtonStates()
		self:updateMenuButtons()
		self.moistureList:reloadData()
	end
end


function RealisticWeatherFrame:onFrameClose()
	RealisticWeatherFrame:superClass().onFrameClose(self)
end


-- Ricostruisce tutto il contenuto del frame a partire dai dati correnti del moistureSystem.
-- Determina la modalità (showAll o aggregata), popola ownedFields e allFields,
-- aggiorna il fieldList selettore e chiama updateFieldInfo() per i dati delle celle.
function RealisticWeatherFrame:updateContent()

	self.hasContent = true

	local ownedFields = {}
	local allFields = {}
	local fieldTexts = {}
	
	local moistureSystem = g_currentMission.moistureSystem
	if moistureSystem == nil then return end

	self.mapWidth, self.mapHeight, self.showAll = moistureSystem.mapWidth, moistureSystem.mapHeight, moistureSystem.moistureFrameBehaviour == 1
	self.cachedBehaviour = moistureSystem.moistureFrameBehaviour

	if g_localPlayer ~= nil and g_localPlayer.farmId ~= nil and g_localPlayer.farmId ~= FarmlandManager.NO_OWNER_FARM_ID then
		
		local farm = g_localPlayer.farmId
		local fields = g_fieldManager:getFields()

		for _, field in pairs(fields) do
			local owner = field:getOwner()
			if owner == farm then
				local id = field:getId()
				table.insert(ownedFields, id)
				-- In modalità showAll: un'etichetta per campo nel fieldList.
				if self.showAll then table.insert(fieldTexts, "Field " .. id) end
			end
			if not self.showAll then
				local id = field:getId()
				table.insert(allFields, id)
			end
		end
	end

	-- In modalità aggregata: solo due voci nel fieldList ("Campi Posseduti" / "Tutti i Campi").
	if not self.showAll then fieldTexts = { g_i18n:getText("rw_ui_ownedFields"), g_i18n:getText("rw_ui_allFields") } end

	self.fieldList:setTexts(fieldTexts)
	self.ownedFields = ownedFields
	self.allFields = allFields
	self.selectedField = 1
	self.fieldList:setState(self.selectedField)

	self.currentBalanceText:setText(g_i18n:formatMoney(g_currentMission:getMoney(), 2, true, true))
	
	self:updateFieldInfo()

end


-- Aggiorna la lista menuButtonInfo con i pulsanti corretti in base allo stato corrente.
-- Il pulsante irrigazione è abilitato solo se un campo di proprietà è selezionato.
-- Il testo del pulsante cambia tra "Avvia irrigazione" e "Interrompi irrigazione".
function RealisticWeatherFrame:updateMenuButtons()

	local moistureSystem = g_currentMission.moistureSystem
	if moistureSystem == nil then return end

	self.menuButtonInfo = { self.backButtonInfo, self.nextPageButtonInfo, self.prevPageButtonInfo, self.refreshButtonInfo, self.teleportButtonInfo }

	if (self.showAll and self.ownedFields ~= nil and self.ownedFields[self.selectedField] ~= nil) or (not self.showAll and self.selectedFieldId ~= nil) then
		-- Campo di proprietà selezionato: abilita irrigazione con testo dinamico.
		local isBeingIrrigated, _ = moistureSystem:getIsFieldBeingIrrigated(self.showAll and self.ownedFields[self.selectedField] or self.selectedFieldId)
		self.irrigationButtonInfo.text = g_i18n:getText(isBeingIrrigated and "rw_ui_irrigation_stop" or "rw_ui_irrigation_start")
		self.irrigationButtonInfo.disabled = false
	else
		self.irrigationButtonInfo.disabled = true
	end

	table.insert(self.menuButtonInfo, self.irrigationButtonInfo)
	self:setMenuButtonInfoDirty()

end


-- Chiamato al click su un campo nel fieldList selettore.
-- @param index  indice del campo selezionato (1-based)
function RealisticWeatherFrame:onClickFieldList(index)

	self.selectedField = index
	self:createPages()

end


-- Resetta lo stato di tutti i pulsanti di ordinamento allo stato iniziale
-- (nessuna colonna ordinata, icone di ordinamento nascoste).
function RealisticWeatherFrame:resetButtonStates()

	self.buttonStates = {
		[self.fieldButton] = { ["sorter"] = false, ["target"] = "field", ["pos"] = "-5px" },
		[self.moistureButton] = { ["sorter"] = false, ["target"] = "moisture", ["pos"] = "12px" },
		[self.trendButton] = { ["sorter"] = false, ["target"] = "trend", ["pos"] = "35px" },
		[self.retentionButton] = { ["sorter"] = false, ["target"] = "retention", ["pos"] = "12px" },
		[self.witherChanceButton] = { ["sorter"] = false, ["target"] = "witherChance", ["pos"] = "22px" },
		[self.xButton] = { ["sorter"] = false, ["target"] = "x", ["pos"] = "36px" },
		[self.zButton] = { ["sorter"] = false, ["target"] = "z", ["pos"] = "36px" },
		[self.irrigationActiveButton] = { ["sorter"] = false, ["target"] = "irrigationActive", ["pos"] = "10px" },
		[self.irrigationCostButton] = { ["sorter"] = false, ["target"] = "irrigationCost", ["pos"] = "20px" }
	}

	self.sortingIcon_true:setVisible(false)
	self.sortingIcon_false:setVisible(false)

end


-- Ricostruisce fieldData, ownedFieldData e allFieldData dal moistureSystem.
-- In modalità showAll: fieldData[i] = lista raw di celle per il campo i.
-- In modalità aggregata:
--   ownedFieldData = lista di medie per i campi posseduti
--   allFieldData   = lista di medie per tutti i campi (usa ownedFieldData se disponibile)
-- Per ogni campo, getCellsInsidePolygon() restituisce le celle con moisture,
-- trend, retention, witherChance, x, z.
-- In modalità aggregata ogni campo viene ridotto alla media aritmetica di tutte le celle.
function RealisticWeatherFrame:updateFieldInfo()

	self:resetButtonStates()

	local fieldData = {}
	local ownedFieldData = {}
	local allFieldData = {}
	local moistureSystem = g_currentMission.moistureSystem

	-- Costruisce dati per i campi posseduti.
	for _, fieldId in pairs(self.ownedFields) do

		local field = g_fieldManager:getFieldById(fieldId)
		local data = {}

		if field ~= nil and moistureSystem ~= nil then
			local polygon = field.densityMapPolygon
			data = moistureSystem:getCellsInsidePolygon(polygon:getVerticesList()) or {}
		end

		if self.showAll then
			-- Modalità showAll: salva i dati raw per campo.
			table.insert(fieldData, data)
		else
			-- Modalità aggregata: calcola la media di tutte le celle del campo.
			local averageData = {
				["moisture"] = 0, ["trend"] = 0, ["retention"] = 0,
				["witherChance"] = 0, ["x"] = 0, ["z"] = 0
			}
			for _, cell in pairs(data) do
				for key, value in pairs(averageData) do averageData[key] = value + cell[key] end
			end
			if #data ~= 0 then
				for key, value in pairs(averageData) do averageData[key] = value / #data end
			end
			averageData.field = fieldId
			table.insert(ownedFieldData, averageData)
		end

	end

	-- Costruisce allFieldData: usa ownedFieldData se il campo è posseduto, altrimenti calcola.
	if not self.showAll then

		for _, fieldId in pairs(self.allFields) do

			local data = {}
			-- Cerca prima tra i campi posseduti per evitare un doppio getCellsInsidePolygon.
			for _, ownedField in pairs(ownedFieldData) do
				if ownedField.field == fieldId then
					data = ownedField
					break
				end
			end

			local field = g_fieldManager:getFieldById(fieldId)

			if field ~= nil and moistureSystem ~= nil then
				local polygon = field.densityMapPolygon
				-- Calcola le celle solo se il campo non è già nella lista posseduti.
				data = moistureSystem:getCellsInsidePolygon(polygon:getVerticesList()) or {}
			end

			local averageData = {
				["moisture"] = 0, ["trend"] = 0, ["retention"] = 0,
				["witherChance"] = 0, ["x"] = 0, ["z"] = 0
			}
			for _, cell in pairs(data) do
				for key, value in pairs(averageData) do averageData[key] = value + cell[key] end
			end
			if #data ~= 0 then
				for key, value in pairs(averageData) do averageData[key] = value / #data end
			end
			averageData.field = fieldId
			table.insert(allFieldData, averageData)

		end

	end

	self.fieldData = fieldData
	self.ownedFieldData = ownedFieldData
	self.allFieldData = allFieldData

	-- Mostra le colonne campo/irrigazione solo in modalità aggregata.
	self.fieldButton:setVisible(not self.showAll)
	self.irrigationActiveButton:setVisible(not self.showAll)
	self.irrigationCostButton:setVisible(not self.showAll)

	self:createPages()

end


-- Divide i dati correnti in pagine da ITEMS_PER_PAGE elementi.
-- Seleziona il dataset corretto in base a showAll e selectedField:
--   showAll=true  → fieldData[selectedField] (celle raw del campo selezionato)
--   showAll=false, selectedField==1 → ownedFieldData
--   showAll=false, selectedField==2 → allFieldData
-- Resetta la paginazione e chiama onChangePage() per aggiornare la UI.
function RealisticWeatherFrame:createPages()

	local data = self.showAll and self.fieldData[self.selectedField] or (self.selectedField == 1 and self.ownedFieldData or self.allFieldData)
	self.pages = { {} }
	local page = self.pages[1]

	for _, item in pairs(data) do
		if #page >= RealisticWeatherFrame.ITEMS_PER_PAGE then
			table.insert(self.pages, {})
			page = self.pages[#self.pages]
		end
		table.insert(page, item)
	end

	self.currentPage = 1
	self.lastPage = 0
	self:onChangePage()

end


-- @return numero di sezioni nella lista (0 se la pagina corrente è vuota, 1 altrimenti)
function RealisticWeatherFrame:getNumberOfSections()

	if #self.pages == 0 or #self.pages[self.currentPage] == 0 then return 0 end
	return 1

end


-- @return numero di elementi nella sezione (= lunghezza della pagina corrente)
function RealisticWeatherFrame:getNumberOfItemsInSection(list, section)

	if #self.pages == 0 or #self.pages[self.currentPage] == 0 then return 0 end
	return #self.pages[self.currentPage]

end


-- @return stringa vuota (nessun titolo di sezione visibile)
function RealisticWeatherFrame:getTitleForSectionHeader(list, section)

    return ""

end


-- Popola una cella della lista con i dati dell'elemento corrispondente.
-- Per la colonna trend: calcola (moisture - trend) * 100 e applica colore:
--   verde (trend positivo → umidità in aumento), rosso (trend negativo → in diminuzione)
-- Per irrigationActive/irrigationCost: legge dal moistureSystem se non in cache.
-- Aggiunge una callback setSelected su ogni cella per tracciare la selezione in modalità aggregata.
-- Le coordinate x/z vengono convertite: x + mapWidth/2 per coordinate mappa positive.
function RealisticWeatherFrame:populateCellForItemInSection(list, section, index, cell)

	local data = self.pages[self.currentPage]
	local item = data[index]

	-- trend = differenza tra umidità attuale e umidità del tick precedente (×100 per %).
	local trend = (item.moisture - item.trend) * 100
	local colour = { 0, 0, 0, 0}

	if trend > 0 then
		-- Trend positivo: verde (verde diminuisce all'aumentare dell'intensità).
		colour = { math.max(1 - trend * 0.75, 0), 1, 0, 1}
	elseif trend < 0 then
		-- Trend negativo: rosso (verde diminuisce all'aumentare dell'entità del calo).
		colour = { 1, math.max(1 - math.abs(trend) * 0.75, 0), 0, 1 }
		cell:getAttribute("trendArrow"):applyProfile("rw_trendArrowDown")
	end

	cell:getAttribute("field"):setText(self.showAll and "" or item.field)
	cell:getAttribute("trendArrow"):setImageColor(nil, unpack(colour))
	cell:getAttribute("moisture"):setText(string.format("%.3f%%", item.moisture * 100))
	cell:getAttribute("trend"):setText(string.format("%.3f%%", trend))
	cell:getAttribute("retention"):setText(string.format("%.2f%%", item.retention * 100))
	cell:getAttribute("witherChance"):setText(string.format("%.2f%%", item.witherChance * 100))
	-- Conversione coordinate: da coordinate mondo centrate (0,0) a coordinate mappa (0, mapWidth).
	cell:getAttribute("x"):setText(math.round(item.x + self.mapWidth / 2))
	cell:getAttribute("z"):setText(math.round(item.z + self.mapHeight / 2))
	
	if not self.showAll then
		-- In modalità aggregata: registra callback per tracciare la riga selezionata.
		cell.setSelected = Utils.appendedFunction(cell.setSelected, function(cell, selected)
			if selected then self:onClickListItem(cell) end
		end)

		local irrigationActiveCell = cell:getAttribute("irrigationActive")
		local irrigationCostCell = cell:getAttribute("irrigationCost")
		
		irrigationActiveCell:setVisible(true)
		irrigationCostCell:setVisible(true)

		local moistureSystem = g_currentMission.moistureSystem
		local active, cost = item.irrigationActive, item.irrigationCost
		
		-- Se non in cache, legge dal moistureSystem (active: 2=attivo, 1=inattivo per ordinamento).
		if active == nil or cost == nil then
			active, cost = moistureSystem:getIsFieldBeingIrrigated(item.field)
			active = active and 2 or 1
		end

		irrigationActiveCell:setText(g_i18n:getText(active == 2 and "rw_ui_active" or "rw_ui_inactive"))
		irrigationCostCell:setText(g_i18n:formatMoney(cost, 2, true, true))

		-- Resetta la cache dopo il rendering (i valori verranno riletti al prossimo ordinamento).
		item.irrigationActive = nil
		item.irrigationCost = nil
	else
		cell:getAttribute("irrigationActive"):setText("")
		cell:getAttribute("irrigationCost"):setText("")
	end

end


-- Gestisce il click su un pulsante di ordinamento colonna.
-- Toggle crescente/decrescente per la colonna target.
-- Per irrigationActive/irrigationCost: pre-carica i valori dal moistureSystem
-- prima di ordinare (necessario perché non sono cached nelle celle).
-- Aggiorna l'icona di ordinamento (▲/▼) e ricarica la lista.
-- @param button  pulsante cliccato (usato come chiave in self.buttonStates)
function RealisticWeatherFrame:onClickSortButton(button)
	
	local buttonState = self.buttonStates[button]

	-- Nasconde l'icona corrente e mostra quella inversa nella nuova posizione.
	self["sortingIcon_" .. tostring(buttonState.sorter)]:setVisible(false)
	self["sortingIcon_" .. tostring(not buttonState.sorter)]:setVisible(true)
	self["sortingIcon_" .. tostring(not buttonState.sorter)]:setPosition(button.position[1] + GuiUtils.getNormalizedXValue(buttonState.pos), 0)

	buttonState.sorter = not buttonState.sorter
	
	local sorter = buttonState.sorter
	local target = buttonState.target

	-- Pre-carica i valori di irrigazione se si ordina per quelle colonne.
	if not self.showAll and (target == "irrigationActive" or target == "irrigationCost") then
		local data = self.pages[self.currentPage]
		local moistureSystem = g_currentMission.moistureSystem
		for _, item in pairs(data) do
			local active, cost = moistureSystem:getIsFieldBeingIrrigated(item.field)
			item.irrigationActive = active and 2 or 1  -- 2=attivo per ordinamento corretto
			item.irrigationCost = cost
		end
	end

	-- Ordina la pagina corrente per il campo target in ordine crescente o decrescente.
	table.sort(self.pages[self.currentPage], function(a, b)
		if sorter then return a[target] > b[target] end
		return a[target] < b[target]
	end)

	self.moistureList:reloadData()

end


-- Attiva/disattiva l'irrigazione per il campo correntemente selezionato.
-- In modalità showAll: usa ownedFields[selectedField].
-- In modalità aggregata: usa selectedFieldId (impostato da onClickListItem).
-- Aggiorna i pulsanti e ricarica la lista dopo il cambio.
function RealisticWeatherFrame:onClickIrrigation()

	local moistureSystem = g_currentMission.moistureSystem

	if moistureSystem == nil or (self.showAll and (#self.ownedFields == 0 or self.ownedFields[self.selectedField] == nil)) or (not self.showAll and self.selectedFieldId == nil) then return end

	moistureSystem:setFieldIrrigationState(self.showAll and self.ownedFields[self.selectedField] or self.selectedFieldId)
	self:updateMenuButtons()

	if not self.showAll then self.moistureList:reloadData() end

end


-- Aggiorna tutto il contenuto del frame con i dati correnti.
function RealisticWeatherFrame:onClickRefresh()
	self:updateContent()
end


-- Teleporta il player locale alla posizione della cella selezionata nella lista.
-- Usa getTerrainHeightAtWorldPos per la quota corretta.
function RealisticWeatherFrame:onClickTeleport()

	if g_localPlayer == nil then return end

	local item = self.pages[self.currentPage][self.moistureList.selectedIndex]

	if item == nil then return end

	g_localPlayer:teleportTo(item.x, getTerrainHeightAtWorldPos(g_terrainNode, item.x, 0, item.z), item.z, false, true)

end


-- Chiamato quando il player seleziona una riga nella lista (modalità aggregata).
-- Imposta selectedFieldId se il campo selezionato è di proprietà del player locale.
-- Se il campo non è di proprietà, selectedFieldId rimane nil (irrigazione disabilitata).
-- @param item  elemento cella della lista con indexInSection
function RealisticWeatherFrame:onClickListItem(item)

	if self.showAll then return end

	self.selectedFieldId = nil

	local data = self.pages[self.currentPage]
	local index = item.indexInSection

	if data == nil or data[index] == nil or g_localPlayer == nil then
		self:updateMenuButtons()
		return
	end

	local fieldId = data[index].field
	local field = g_fieldManager:getFieldById(fieldId)
	local playerFarm = g_localPlayer.farmId

	if field ~= nil and playerFarm ~= FarmManager.SPECTATOR_FARM_ID then
		local owner = field:getOwner()
		if owner == playerFarm then self.selectedFieldId = fieldId end
	end

	self:updateMenuButtons()

end


-- Aggiorna la UI quando cambia pagina.
-- Calcola il totale celle, aggiorna i label pagina/celle e ricarica la lista.
-- Guard: non aggiorna se la pagina non è cambiata.
function RealisticWeatherFrame:onChangePage()

	if self.lastPage == self.currentPage then return end

	self.lastPage = self.currentPage

	-- Calcola il numero totale di celle: (pagine-1) * max + celle ultima pagina.
	local totalNumCells = (#self.pages - 1) * RealisticWeatherFrame.ITEMS_PER_PAGE + #self.pages[#self.pages]

	self.pageNumber:setText(string.format("%s/%s", self.currentPage, #self.pages))
	-- Formato: "Celle X-Y di Z" (usa rw_ui_messageNumber per la stringa di formato).
	self.cellNumber:setText(string.format(g_i18n:getText("rw_ui_messageNumber"), (#self.pages[self.currentPage] == 0 and 0 or 1) + RealisticWeatherFrame.ITEMS_PER_PAGE * (self.currentPage - 1), (self.currentPage - 1) * RealisticWeatherFrame.ITEMS_PER_PAGE + #self.pages[self.currentPage], totalNumCells))

	self.moistureList:reloadData()
	self:resetButtonStates()
	self:updateMenuButtons()

end


-- Naviga alla prima pagina.
function RealisticWeatherFrame:onClickPageFirst()
    self.currentPage = 1
    self:onChangePage()
end


-- Naviga alla pagina precedente (minimo 1).
function RealisticWeatherFrame:onClickPagePrevious()
    self.currentPage = math.max(self.currentPage - 1, 1)
    self:onChangePage()
end


-- Naviga alla pagina successiva (massimo #pages).
function RealisticWeatherFrame:onClickPageNext()
    self.currentPage = math.min(self.currentPage + 1, #self.pages)
    self:onChangePage()
end


-- Naviga all'ultima pagina.
function RealisticWeatherFrame:onClickPageLast()
    self.currentPage = #self.pages
    self:onChangePage()
end
