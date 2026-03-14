-- IrrigationMission.lua
-- Tipo di contratto personalizzato: "Irrigazione del campo".
-- Estende AbstractFieldMission per creare un contratto che richiede al giocatore
-- di portare l'umidità media di un campo a un livello target tramite irrorazione con acqua.
--
-- Caratteristiche:
--   - Generazione automatica tramite g_missionManager (priorità 3)
--   - Solo su campi con coltura piantata/crescente/raccoglibile (non in inverno)
--   - Il campo viene selezionato solo se l'umidità media è sotto l'umidità minima ideale
--     per la coltura presente (averageMoistureLevel < averageMinTargetMoistureLevel)
--   - Il target di completamento è l'umidità perfetta (media tra LOW e HIGH del tipo coltura)
--   - Il progresso viene misurato ogni tick su una cella per volta (round-robin)
--     per distribuire il costo computazionale
--   - La ricompensa base è 1500 $/ha (configurabile da XML mappa)
--   - Il rimborso include l'acqua residua nei veicoli assegnati al contratto
--
-- Persistenza:
--   - targetMoistureLevel e averageMoistureLevel salvati nel savegame XML
--   - Serializzazione di rete tramite writeStream/readStream
--
-- Stato del contratto:
--   fieldPolygon  → vertici del campo per il calcolo delle celle
--   cells         → lista celle con posizione e moisture corrente
--   targetMoistureLevel   → umidità media obiettivo (media LOW+HIGH per la coltura)
--   averageMoistureLevel  → umidità media corrente (aggiornata in getFieldCompletion)
--   currentUpdateIteration → indice della cella aggiornata nel tick corrente

IrrigationMission = {}

IrrigationMission.NAME = "irrigationMission"
IrrigationMission.rewardPerHa = 1500  -- ricompensa base in $/ha (sovrascrivibile da XML mappa)

local irrigationMission_mt = Class(IrrigationMission, AbstractFieldMission)
InitObjectClass(IrrigationMission, "IrrigationMission")


-- Costruttore: crea il contratto con i parametri base.
-- Imposta workAreaTypes (solo SPRAYER) e validFertilizerTypes (solo WATER).
-- @param isServer   true se questa istanza gira sul server
-- @param isClient   true se questa istanza è visibile al client
-- @param customMt   metatable custom opzionale
function IrrigationMission.new(isServer, isClient, customMt)

	local title = g_i18n:getText("rw_contract_field_irrigation_title")
	local description = g_i18n:getText("rw_contract_field_irrigation_description")

	local self = AbstractFieldMission.new(isServer, isClient, title, description, customMt or irrigationMission_mt)

	-- Solo gli irroratori con acqua contribuiscono al completamento del contratto.
	self.workAreaTypes = {
		[WorkAreaType.SPRAYER] = true
	}

	self.validFertilizerTypes = {
		[FillType.WATER] = true
	}

	self.fillTypeTitle = g_fillTypeManager:getFillTypeTitleByIndex(FillType.WATER)
	self.targetMoistureLevel = nil    -- umidità obiettivo calcolata in initialize()
	self.averageMoistureLevel = nil   -- umidità media corrente, aggiornata in getFieldCompletion()
	self.currentUpdateIteration = 1   -- indice round-robin per l'aggiornamento celle

	return self

end


-- Salva lo stato del contratto nel savegame XML.
-- Persiste targetMoistureLevel e averageMoistureLevel oltre ai dati base.
function IrrigationMission:saveToXMLFile(xmlFile, key)

	IrrigationMission:superClass().saveToXMLFile(self, xmlFile, key)
	xmlFile:setFloat(key .. "#targetMoistureLevel", self.targetMoistureLevel or 0)
	xmlFile:setFloat(key .. "#averageMoistureLevel", self.averageMoistureLevel or 0)

end


-- Carica lo stato del contratto dal savegame XML.
-- @return false se il caricamento base fallisce
function IrrigationMission:loadFromXMLFile(xmlFile, key)
	
	if not IrrigationMission:superClass().loadFromXMLFile(self, xmlFile, key) then return false end

	self.targetMoistureLevel = xmlFile:getFloat(key .. "#targetMoistureLevel")
	self.averageMoistureLevel = xmlFile:getFloat(key .. "#averageMoistureLevel")

	return true

end


-- Serializza il contratto per la rete (server → client).
-- Invia targetMoistureLevel e averageMoistureLevel al client.
function IrrigationMission:writeStream(streamId, connection)

	IrrigationMission:superClass().writeStream(self, streamId, connection)

	streamWriteFloat32(streamId, self.targetMoistureLevel)
	streamWriteFloat32(streamId, self.averageMoistureLevel)

end


-- Deserializza il contratto dalla rete (ricezione client).
function IrrigationMission:readStream(streamId, connection)

	IrrigationMission:superClass().readStream(self, streamId, connection)

	self.targetMoistureLevel = streamReadFloat32(streamId) or 0
	self.averageMoistureLevel = streamReadFloat32(streamId) or 0

end


-- Callback di caricamento dati mappa: legge rewardPerHa dall'XML della mappa.
-- Permette ai modmaker di personalizzare la ricompensa per mappa.
function IrrigationMission.loadMapData(xmlFile, key, _)

	g_missionManager:getMissionTypeDataByName(IrrigationMission.NAME).rewardPerHa = xmlFile:getFloat(key .. "#rewardPerHa", 1500)
	return true

end


-- Controlla se il contratto può essere generato ora.
-- Condizioni: numero istanze sotto il massimo E crescita non in corso.
function IrrigationMission.canRun()

	local data = g_missionManager:getMissionTypeDataByName(IrrigationMission.NAME)
	
	if data.numInstances >= data.maxNumInstances then return false end
	
	return not g_currentMission.growthSystem:getIsGrowingInProgress()

end


-- Controlla se il contratto è disponibile per un campo specifico.
-- Se mission == nil (check di generazione): verifica che il campo abbia una coltura
-- piantata/crescente/raccoglibile con uno stato di crescita valido.
-- In tutti i casi: non disponibile in inverno.
-- @param field    campo da verificare
-- @param mission  istanza contratto esistente (nil = check di generazione)
function IrrigationMission.isAvailableForField(field, mission)

	if mission == nil then

		local fieldState = field:getFieldState()

		if not fieldState.isValid then return false end

		local fruitTypeIndex = fieldState.fruitTypeIndex

		if fruitTypeIndex == FruitType.UNKNOWN then return false end

		local growthState = fieldState.growthState

		if growthState ~= nil and growthState <= 0 then return false end

		local fruitType = g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)

		-- Solo colture in crescita o raccoglibili (non appena seminate, non allo stato 0).
		if not fruitType:getIsGrowing(growthState) and not fruitType:getIsHarvestable(growthState) then return false end

	end

	-- Non disponibile in inverno (la crescita è ferma e l'irrigazione non è efficace).
	return g_currentMission.environment == nil or g_currentMission.environment.currentSeason ~= Season.WINTER

end


-- Tenta di generare un nuovo contratto di irrigazione.
-- Seleziona un campo casuale, verifica le condizioni e crea l'istanza.
-- @return IrrigationMission se generato con successo, nil altrimenti
function IrrigationMission.tryGenerateMission()

	if IrrigationMission.canRun() then

		local field = g_fieldManager:getFieldForMission()

		if field == nil or field.currentMission ~= nil or not IrrigationMission.isAvailableForField(field, nil) then return nil end

		local mission = IrrigationMission.new(true, g_client ~= nil)

		if mission:initialize(field) then
			mission:setDefaultEndDate()
			return mission
		end

		mission:delete()

	end

	return nil

end


-- Inizializza il contratto per il campo dato.
-- Ottiene le celle del campo tramite getCellsInsidePolygon e calcola:
--   averageMoistureLevel  → media umidità attuale su tutte le celle
--   targetMoistureLevel   → media delle umidità perfette per la coltura presente
--   averageMinTargetMoistureLevel → media delle umidità minime accettabili
-- Il contratto viene generato SOLO se averageMoistureLevel < averageMinTargetMoistureLevel
-- (il campo ha realmente bisogno di irrigazione).
-- @param field  campo per cui inizializzare il contratto
-- @return false se il campo è già abbastanza bagnato o se superClass().init fallisce
function IrrigationMission:initialize(field)

	self.fieldPolygon = field.densityMapPolygon:getVerticesList()

	local cells = g_currentMission.moistureSystem:getCellsInsidePolygon(self.fieldPolygon, { "moisture" })

	local totalMoistureLevel = 0
	local totalTargetMoistureLevel = 0
	local minTargetMoistureLevel = 0

	for _, cell in pairs(cells) do

		totalMoistureLevel = totalMoistureLevel + cell.moisture

		-- Recupera il tipo di coltura in questa cella e il suo range di umidità ideale.
		local fruitTypeIndex = FSDensityMapUtil.getFruitTypeIndexAtWorldPos(cell.x, cell.z)
		local cropToMoisture = RW_FSBaseMission.FRUIT_TYPES_MOISTURE[fruitTypeIndex] or RW_FSBaseMission.FRUIT_TYPES_MOISTURE.DEFAULT
		local perfectMoisture = (cropToMoisture.LOW + cropToMoisture.HIGH) / 2

		totalTargetMoistureLevel = totalTargetMoistureLevel + perfectMoisture
		minTargetMoistureLevel = minTargetMoistureLevel + cropToMoisture.LOW

	end

	local averageMoistureLevel = totalMoistureLevel / #cells
	local targetMoistureLevel = totalTargetMoistureLevel / #cells
	local averageMinTargetMoistureLevel = minTargetMoistureLevel / #cells

	-- Il contratto è valido solo se l'umidità attuale è sotto la soglia minima ideale.
	if averageMoistureLevel >= averageMinTargetMoistureLevel then return false end

	self.cells = cells
	self.averageMoistureLevel = averageMoistureLevel
	self.targetMoistureLevel = targetMoistureLevel

	return IrrigationMission:superClass().init(self, field)

end


-- Nessun modificatore density map aggiuntivo per questo tipo di contratto.
function IrrigationMission:createModifier()

end


-- Restituisce il nome identificativo del tipo di contratto.
function IrrigationMission:getMissionTypeName()

	return IrrigationMission.NAME

end


-- Restituisce la ricompensa per ettaro (configurabile da XML mappa).
function IrrigationMission:getRewardPerHa()

	return g_missionManager:getMissionTypeDataByName(IrrigationMission.NAME).rewardPerHa

end


-- Valida se il contratto è ancora attivo e completabile.
-- Il contratto è valido se: la superClass lo valida E (il contratto è finito
-- OPPURE il campo è ancora disponibile per questo tipo di contratto).
function IrrigationMission:validate(event)
	
	if IrrigationMission:superClass().validate(self, event) then return (self:getIsFinished() or IrrigationMission.isAvailableForField(self.field, self)) and true or false end
	
	return false

end


-- Calcola il rimborso per l'acqua residua nei veicoli assegnati al contratto.
-- Aggiunge al rimborso base il valore dell'acqua rimasta (fillLevel × pricePerLiter × REIMBURSEMENT_FACTOR).
function IrrigationMission:calculateReimbursement()

	IrrigationMission:superClass().calculateReimbursement(self)
	local reimbursement = 0

	for _, vehicle in pairs(self.vehicles) do

		if vehicle.spec_fillUnit ~= nil then

			for fillUnit, _ in pairs(vehicle:getFillUnits()) do

				local fillType = vehicle:getFillUnitFillType(fillUnit)
				if self.validFertilizerTypes[fillType] ~= nil then reimbursement = reimbursement + vehicle:getFillUnitFillLevel(fillUnit) * g_fillTypeManager:getFillTypeByIndex(fillType).pricePerLiter end

			end

		end

	end

	self.reimbursement = self.reimbursement + reimbursement * AbstractMission.REIMBURSEMENT_FACTOR

end


-- Nessun task di finitura campo (a differenza dei contratti di raccolta/fertilizzazione).
function IrrigationMission:getFieldFinishTask()
	
	return nil

end


-- Restituisce la lista delle celle del campo, calcolandola se non ancora disponibile.
-- Lazy init: le celle vengono calcolate solo quando necessario dopo un reload.
function IrrigationMission:getCells()

	if self.cells ~= nil then return self.cells end
	
	if self.fieldPolygon == nil then self.fieldPolygon = self.field.densityMapPolygon:getVerticesList() end

	self.cells = g_currentMission.moistureSystem:getCellsInsidePolygon(self.fieldPolygon, { "moisture" })

	return self.cells

end


-- Calcola il progresso del contratto e aggiorna averageMoistureLevel.
-- Ottimizzazione round-robin: aggiorna l'umidità di UNA sola cella per tick
-- (la cella all'indice currentUpdateIteration), poi usa i valori cached
-- di tutte le altre celle per calcolare la media.
-- fieldPercentageDone = averageMoistureLevel / targetMoistureLevel
-- @return percentuale di completamento [0, ∞) (può superare 1 se supera il target)
function IrrigationMission:getFieldCompletion()

	local cells = self:getCells()

	local completedCells = 0
	local averageMoistureLevel = 0
	local moistureSystem = g_currentMission.moistureSystem

	-- Aggiorna solo la cella corrente nell'iterazione round-robin.
	local currentUpdateIteration = self.currentUpdateIteration
	local cellToUpdate = self.cells[currentUpdateIteration]

	if cellToUpdate ~= nil then

		local values = moistureSystem:getValuesAtCoords(cellToUpdate.x, cellToUpdate.z, { "moisture" })

		if values.moisture ~= nil then self.cells[currentUpdateIteration].moisture = values.moisture end

	end

	self.currentUpdateIteration = currentUpdateIteration + 1

	if self.currentUpdateIteration > #cells then self.currentUpdateIteration = 1 end

	-- Calcola la media usando i valori cached (aggiornati ciclicamente).
	for _, cell in pairs(cells) do
		averageMoistureLevel = averageMoistureLevel + cell.moisture
	end

	self.averageMoistureLevel = averageMoistureLevel / #cells
	self.fieldPercentageDone = self.averageMoistureLevel / self.targetMoistureLevel

	return self.fieldPercentageDone

end


-- Aggiunge i dettagli del contratto per il pannello UI contratti.
-- Mostra umidità media corrente e umidità target in formato percentuale.
-- @return tabella dettagli estesa con le due righe aggiuntive RW
function IrrigationMission:getDetails()

	local details = IrrigationMission:superClass().getDetails(self)

	local currentAverageMoistureInfo = {
		["title"] = g_i18n:getText("rw_contract_field_irrigation_currentAverage"),
		["value"] = string.format("%.3f%%", self.averageMoistureLevel * 100)
	}
	
	local targetAverageMoistureInfo = {
		["title"] = g_i18n:getText("rw_contract_field_irrigation_targetAverage"),
		["value"] = string.format("%.3f%%", self.targetMoistureLevel * 100)
	}

	table.insert(details, currentAverageMoistureInfo)
	table.insert(details, targetAverageMoistureInfo)

	return details

end


-- Registra il tipo di contratto nel MissionManager con priorità 3.
g_missionManager:registerMissionType(IrrigationMission, IrrigationMission.NAME, 3)
