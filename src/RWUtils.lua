-- RWUtils.lua
-- Utility per operazioni massive sulle density map del terreno.
-- Espone due funzioni principali:
--   witherArea: fa appassire tutti i raccolti maturi/avanzati e taglia quelli giovani
--               in un'area parallelogramma definita da tre punti mondo.
--   burnArea:   porta tutti i raccolti allo stato di distruzione da disastro e
--               converte il terreno non coltivato in stoppie.
-- Entrambe usano un pattern di cache (functionCache) per costruire i DensityMapModifier
-- e DensityMapMultiModifier una sola volta, evitando riallocazioni ad ogni chiamata.

RWUtils = {}
RWUtils.functionCache = {}


-- Appassisce i raccolti avanzati (→ witheredState) e taglia quelli giovani (→ cutState)
-- nell'area parallelogramma definita dai punti (sx,sz), (wx,wz), (hx,hz).
-- Azzera anche tutti i layer di erba dinamica nell'area.
--
-- Calcolo della soglia minWitherableState:
--   Parte da minHarvestingGrowthState - 1 (opzionalmente ridotto al minPreparingGrowthState - 1),
--   poi viene abbassata del 50% del numero di stadi di crescita per includere anche
--   piante giovani ma non appena germogliate. Il valore minimo assoluto è 2.
--   - Stadi >= minWitherableState → witheredState (appassimento)
--   - Stadi tra 1 e minWitherableState-1 → cutState (taglio)
--
-- @param sx, sz  punto di partenza del parallelogramma (world coords)
-- @param wx, wz  vettore larghezza
-- @param hx, hz  vettore altezza
function RWUtils.witherArea(sx, sz, wx, wz, hx, hz)

	local cache = RWUtils.functionCache.witherArea

	-- Prima chiamata: crea e memorizza nella cache modifier, multiModifier e filtri.
	if cache == nil then

		local fieldGroundSystem = g_currentMission.fieldGroundSystem

		local groundTypeMapId, groundTypeFirstChannel, groundTypeNumChannels = fieldGroundSystem:getDensityMapData(FieldDensityMap.GROUND_TYPE)
		local sprayTypeMapId, sprayTypeFirstChannel, sprayTypeNumChannels = fieldGroundSystem:getDensityMapData(FieldDensityMap.SPRAY_TYPE)

		cache = {
			["modifier"] = DensityMapModifier.new(sprayTypeMapId, sprayTypeFirstChannel, sprayTypeNumChannels, g_terrainNode),
			["multiModifier"] = nil,      -- costruito in modo lazy al primo utilizzo
			["filter1"] = DensityMapFilter.new(groundTypeMapId, groundTypeFirstChannel, groundTypeNumChannels),
			["filter2"] = DensityMapFilter.new(groundTypeMapId, groundTypeFirstChannel, groundTypeNumChannels),
			["fieldFilter"] = DensityMapFilter.new(groundTypeMapId, groundTypeFirstChannel, groundTypeNumChannels)
		}

		-- fieldFilter: opera solo sulle celle che sono un campo (groundType > 0).
		cache.fieldFilter:setValueCompareParams(DensityValueCompareType.GREATER, 0)
		RWUtils.functionCache.witherArea = cache

	end

	local modifier = cache.modifier
	local multiModifier = cache.multiModifier
	local filter1 = cache.filter1
	local filter2 = cache.filter2
	local fieldFilter = cache.fieldFilter

	g_currentMission.growthSystem:setIgnoreDensityChanges(true)

	-- Prima chiamata: costruisce il DensityMapMultiModifier iterando su tutti i tipi di frutto.
	if multiModifier == nil then

		multiModifier = DensityMapMultiModifier.new()
		cache.multiModifier = multiModifier

		for _, fruitType in pairs(g_fruitTypeManager:getFruitTypes()) do

			if fruitType.terrainDataPlaneId ~= nil and fruitType.witheredState ~= nil and fruitType.cutState ~= nil then

				modifier:resetDensityMapAndChannels(fruitType.terrainDataPlaneId, fruitType.startStateChannel, fruitType.numStateChannels)
				filter1:resetDensityMapAndChannels(fruitType.terrainDataPlaneId, fruitType.startStateChannel, fruitType.numStateChannels)
				filter2:resetDensityMapAndChannels(fruitType.terrainDataPlaneId, fruitType.startStateChannel, fruitType.numStateChannels)

				-- Calcola la soglia minima oltre la quale un raccolto è considerato "appassibile".
				local minWitherableState = fruitType.minHarvestingGrowthState - 1

				if fruitType.minPreparingGrowthState >= 0 then minWitherableState = math.min(minWitherableState, fruitType.minPreparingGrowthState - 1) end

				-- Abbassa la soglia del 50% del ciclo di crescita, minimo 2.
				minWitherableState = math.max(math.ceil(minWitherableState - fruitType.numGrowthStates * 0.5), 2)

				-- filter1: stadi avanzati → appassimento
				filter1:setValueCompareParams(DensityValueCompareType.BETWEEN, minWitherableState, fruitType.maxHarvestingGrowthState)
				-- filter2: stadi giovani → taglio
				filter2:setValueCompareParams(DensityValueCompareType.BETWEEN, 1, minWitherableState - 1)
				
				multiModifier:addExecuteSet(fruitType.witheredState, modifier, filter1, fieldFilter)
				multiModifier:addExecuteSet(fruitType.cutState, modifier, filter2, fieldFilter)

			end

		end

		-- Azzera tutti i layer di erba dinamica nell'area.
		for i = 1, #g_currentMission.dynamicFoliageLayers do

			local dynamicFoliageLayer = g_currentMission.dynamicFoliageLayers[i]
			modifier:resetDensityMapAndChannels(dynamicFoliageLayer, 0, (getTerrainDetailNumChannels(dynamicFoliageLayer)))
			multiModifier:addExecuteSet(0, modifier)

		end

	end

	-- Aggiorna il parallelogramma di lavoro ed esegue tutte le operazioni in batch.
	multiModifier:updateParallelogramWorldCoords(sx, sz, wx, wz, hx, hz, DensityCoordType.POINT_POINT_POINT)
	multiModifier:execute()

	FSDensityMapUtil.removeWeedArea(sx, sz, wx, wz, hx, hz)
	g_currentMission.growthSystem:setIgnoreDensityChanges(false)

end


-- Brucia tutti i raccolti nell'area portandoli allo stato disasterDestructionState,
-- azzera l'erba dinamica e converte il terreno non coltivato in stoppie.
--
-- Logica del filtro per il tipo di distruzione:
--   - Se witheredState > cutState: distrugge gli stadi da 1 fino a witheredState (include appassiti)
--   - Altrimenti: distrugge gli stadi da 1 fino a cutState
--   Il filtro notCultivatedFilter esclude il terreno già coltivato dalla conversione in stoppie.
--
-- @param sx, sz  punto di partenza del parallelogramma (world coords)
-- @param wx, wz  vettore larghezza
-- @param hx, hz  vettore altezza
function RWUtils.burnArea(sx, sz, wx, wz, hx, hz)

	local cache = RWUtils.functionCache.burnArea

	-- Prima chiamata: crea e memorizza nella cache modifier, filtri e tipo stoppie.
	if cache == nil then

		local fieldGroundSystem = g_currentMission.fieldGroundSystem

		local groundTypeMapId, groundTypeFirstChannel, groundTypeNumChannels = fieldGroundSystem:getDensityMapData(FieldDensityMap.GROUND_TYPE)
		local sprayTypeMapId, sprayTypeFirstChannel, sprayTypeNumChannels = fieldGroundSystem:getDensityMapData(FieldDensityMap.SPRAY_TYPE)

		cache = {
			["modifier"] = DensityMapModifier.new(sprayTypeMapId, sprayTypeFirstChannel, sprayTypeNumChannels, g_terrainNode),
			["groundModifier"] = DensityMapModifier.new(groundTypeMapId, groundTypeFirstChannel, groundTypeNumChannels, g_terrainNode),
			["multiModifier"] = nil,
			["filter1"] = DensityMapFilter.new(groundTypeMapId, groundTypeFirstChannel, groundTypeNumChannels),
			["fieldFilter"] = DensityMapFilter.new(groundTypeMapId, groundTypeFirstChannel, groundTypeNumChannels),
			-- notCultivatedFilter: seleziona solo le celle NON ancora coltivate (per la conversione in stoppie).
			["notCultivatedFilter"] = DensityMapFilter.new(groundTypeMapId, groundTypeFirstChannel, groundTypeNumChannels),
			["stubbleType"] = FieldGroundType.getValueByType(FieldGroundType.STUBBLE_TILLAGE)
		}

		cache.fieldFilter:setValueCompareParams(DensityValueCompareType.GREATER, 0)
		cache.notCultivatedFilter:setValueCompareParams(DensityValueCompareType.NOTEQUAL, FieldGroundType.getValueByType(FieldGroundType.CULTIVATED))
		RWUtils.functionCache.burnArea = cache

	end

	local modifier = cache.modifier
	local multiModifier = cache.multiModifier
	local filter1 = cache.filter1
	local fieldFilter = cache.fieldFilter
	local notCultivatedFilter = cache.notCultivatedFilter

	g_currentMission.growthSystem:setIgnoreDensityChanges(true)

	-- Prima chiamata: costruisce il DensityMapMultiModifier per tutti i tipi di frutto.
	if multiModifier == nil then

		multiModifier = DensityMapMultiModifier.new()
		cache.multiModifier = multiModifier

		for _, fruitType in pairs(g_fruitTypeManager:getFruitTypes()) do

			if fruitType.terrainDataPlaneId ~= nil then

				modifier:resetDensityMapAndChannels(fruitType.terrainDataPlaneId, fruitType.startStateChannel, fruitType.numStateChannels)
				filter1:resetDensityMapAndChannels(fruitType.terrainDataPlaneId, fruitType.startStateChannel, fruitType.numStateChannels)

				-- Determina il range di stadi da distruggere in base alla presenza e posizione di witheredState.
				if fruitType.witheredState ~= nil and fruitType.witheredState > fruitType.cutState then
					filter1:setValueCompareParams(DensityValueCompareType.BETWEEN, 1, fruitType.witheredState)
				else
					filter1:setValueCompareParams(DensityValueCompareType.BETWEEN, 1, fruitType.cutState)
				end

				multiModifier:addExecuteSet(fruitType.disasterDestructionState, modifier, filter1, fieldFilter, notCultivatedFilter)

			end

		end

		-- Azzera tutti i layer di erba dinamica nell'area bruciata.
		for i = 1, #g_currentMission.dynamicFoliageLayers do

			local dynamicFoliageLayer = g_currentMission.dynamicFoliageLayers[i]
			modifier:resetDensityMapAndChannels(dynamicFoliageLayer, 0, (getTerrainDetailNumChannels(dynamicFoliageLayer)))
			multiModifier:addExecuteSet(0, modifier)

		end

		-- Converte il terreno non coltivato in stoppie dopo l'incendio.
		multiModifier:addExecuteSet(cache.stubbleType, cache.groundModifier, fieldFilter)

	end

	-- Aggiorna il parallelogramma di lavoro ed esegue tutte le operazioni in batch.
	multiModifier:updateParallelogramWorldCoords(sx, sz, wx, wz, hx, hz, DensityCoordType.POINT_POINT_POINT)
	multiModifier:execute()

	FSDensityMapUtil.removeWeedArea(sx, sz, wx, wz, hx, hz)
	g_currentMission.growthSystem:setIgnoreDensityChanges(false)

end
