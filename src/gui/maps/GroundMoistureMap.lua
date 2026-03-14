-- GroundMoistureMap.lua
-- Controller per l'overlay della mappa di umidità del terreno nella pagina
-- "Realistic Weather" del menu mappa in-game (InGameMenuMapFrameExtension).
--
-- Gestisce la creazione e il filtraggio dell'overlay visivo che colora
-- le celle della mappa in base al livello di umidità (bassa = rosso, alta = blu).
-- Attualmente in sviluppo: buildOverlay() è uno stub (stampa log ma non
-- applica ancora i colori delle celle alla density map visualization).
--
-- Integrazione con InGameMenuMapFrameExtension:
--   - onLoadMapFinished() crea un'istanza di GroundMoistureMap come controller
--     per l'overlay "groundMoisture" (1024×1024 px)
--   - onSelectorChanged() chiama getDisplayValues() e getValueFilter()
--     per aggiornare la lista filtri nel pannello laterale del menu
--   - updateMapOverlay() chiama buildOverlay() e generateDensityMapVisualizationOverlay()
--
-- Palette colori:
--   LOW  (umidità bassa): tre sfumature di rosso [1,0,0,1] → [0.33,0,0,1]
--   HIGH (umidità alta):  tre sfumature di blu   [0,0,1,1] → [0,0,0.33,1]
--
-- NUM_VALUES = 2 (LOW e HIGH): due categorie selezionabili come filtro.
--
-- NOTA: il commento originale "Might use this for something else in the future /
-- Placeholder for now" indica che buildOverlay è ancora da implementare.

GroundMoistureMap = {}

GroundMoistureMap.COLOURS = {
	["LOW"] = {
		{ 1, 0, 0, 1 },
		{ 0.67, 0, 0, 1 },
		{ 0.33, 0, 0, 1 }
	},
	["HIGH"] = {
		{ 0, 0, 1, 1 },
		{ 0, 0, 0.67, 1 },
		{ 0, 0, 0.33, 1 }
	}
}


GroundMoistureMap.NUM_VALUES = 2
GroundMoistureMap.DRY_THRESHOLD = 0.3


local GroundMoistureMap_mt = Class(GroundMoistureMap)


function GroundMoistureMap.new(parent)

	local self = setmetatable({}, GroundMoistureMap_mt)

	self.parent = parent

	return self

end


function GroundMoistureMap:buildOverlay(overlayId, valueFilter, isColourBlindMode)

	print("--- RealisticWeather: Building Moisture Overlay ---")

	local moistureSystem = g_currentMission.moistureSystem

	if moistureSystem == nil or moistureSystem.rows == nil then
		return
	end

	resetDensityMapVisualizationOverlay(overlayId)
	setOverlayColor(overlayId, 1, 1, 1, 1)

	if setDensityMapVisualizationOverlayState == nil then
		print("--- RealisticWeather: setDensityMapVisualizationOverlayState API unavailable ---")
		return
	end

	local stepsPerBand = 8
	local lowBaseState = 1
	local highBaseState = lowBaseState + stepsPerBand

	for i = 0, stepsPerBand - 1 do

		local t = i / (stepsPerBand - 1)
		local dryState = lowBaseState + i
		local wetState = highBaseState + i

		if isColourBlindMode then
			setDensityMapVisualizationOverlayStateColor(overlayId, dryState, 1, 0.55 * t, 0, 0.75)
			setDensityMapVisualizationOverlayStateColor(overlayId, wetState, 0.1 * t, 0.85 * t, 0.85, 0.75)
		else
			setDensityMapVisualizationOverlayStateColor(overlayId, dryState, 1, 0.25 * t, 0, 0.75)
			setDensityMapVisualizationOverlayStateColor(overlayId, wetState, 0, 0.25 * t, 0.35 + 0.65 * t, 0.75)
		end

	end

	for _, row in pairs(moistureSystem.rows) do
		for _, cell in pairs(row.columns) do

			local moisture = math.clamp(cell.moisture or 0, 0, 1)
			local isLow = moisture < GroundMoistureMap.DRY_THRESHOLD
			local shouldDraw = (valueFilter[1] and isLow) or (valueFilter[2] and not isLow)

			if shouldDraw then
				local state

				if isLow then
					local t = math.clamp(moisture / GroundMoistureMap.DRY_THRESHOLD, 0, 1)
					state = lowBaseState + math.floor(t * (stepsPerBand - 1) + 0.5)
				else
					local t = math.clamp((moisture - GroundMoistureMap.DRY_THRESHOLD) / (1 - GroundMoistureMap.DRY_THRESHOLD), 0, 1)
					state = highBaseState + math.floor(t * (stepsPerBand - 1) + 0.5)
				end

				setDensityMapVisualizationOverlayState(overlayId, row.x, cell.z, state)
			end

		end
	end

	print("--- RealisticWeather: Moisture Overlay Finished ---")

end


function GroundMoistureMap:getOverviewLabel()

	return "Ground Moisture"

end


function GroundMoistureMap:getShowInMenu()

	return true

end


function GroundMoistureMap:getDisplayValues()

	if self.valuesToDisplay == nil then

		self.valuesToDisplay = {}

		for displayType, colours in pairs(GroundMoistureMap.COLOURS) do

			local displayValue = {
				["colors"] = {
					[true] = colours,
					[false] = colours
				},
				["description"] = displayType
			}

			table.insert(self.valuesToDisplay, displayValue)

		end

	end

	return self.valuesToDisplay

end


function GroundMoistureMap:getValueFilter()

	if self.valueFilter == nil or self.valueFilterEnabled == nil then

		self.valueFilter = {}
		self.valueFilterEnabled = {}
		
		for i = 1, GroundMoistureMap.NUM_VALUES do
			table.insert(self.valueFilter, true)
			table.insert(self.valueFilterEnabled, true)
		end

	end

	return self.valueFilter, self.valueFilterEnabled

end