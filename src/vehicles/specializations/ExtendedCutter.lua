-- ExtendedCutter.lua
-- Specializzazione veicolo ExtendedCutter per le testine da raccolta compatibili con RW.
-- Richiede la specializzazione Cutter come prerequisito.
--
-- Funziona come bridge tra il sistema di specializzazioni di FS25 e la logica RW:
-- registra un override di processCutterArea che chiama i callback pre/post
-- di g_realisticWeather (preProcessCutterArea e postProcessCutterArea).
-- Questi callback sono definiti in RealisticWeather.lua e gestiscono
-- la lettura/scrittura dell'umidità durante la raccolta.
--
-- La differenza rispetto a RW_Cutter (Cutter.lua):
--   - RW_Cutter: override diretto della classe Cutter (copre tutti i veicoli vanilla)
--   - ExtendedCutter: override tramite sistema specializzazioni (per veicoli con vehicleType)
--   I due sistemi coesistono: ExtendedCutter viene iniettato automaticamente da TypeManager.lua
--   nei tipi veicolo che già hanno la specializzazione "cutter".
--
-- Guard CLIENT_DM_UPDATE_RADIUS: se il client è troppo lontano dal veicolo,
-- salta la logica RW e usa la funzione vanilla per evitare aggiornamenti inutili.

ExtendedCutter = {}


-- Verifica che la specializzazione Cutter sia presente nel tipo veicolo.
function ExtendedCutter.prerequisitesPresent(specializations)
	return SpecializationUtil.hasSpecialization(Cutter, specializations)
end


-- Nessuna funzione aggiuntiva da registrare (solo override).
function ExtendedCutter.registerFunctions(vehicleType) end


-- Registra l'override di processCutterArea sul tipo veicolo.
function ExtendedCutter.registerOverwrittenFunctions(vehicleType)
	SpecializationUtil.registerOverwrittenFunction(vehicleType, "processCutterArea", ExtendedCutter.processCutterArea)
end


-- Override di processCutterArea per i veicoli con specializzazione ExtendedCutter.
-- Se il client è fuori dal raggio di aggiornamento DM, usa la funzione vanilla.
-- Altrimenti: chiama preProcessCutterArea, esegue la funzione vanilla, chiama postProcessCutterArea.
-- @param workArea  work area della testata da raccolta
-- @param dt        delta time in ms
-- @return lastChangedArea, lastTotalArea
function ExtendedCutter:processCutterArea(superFunc, workArea, dt)

	-- Su client remoti oltre il raggio di aggiornamento, salta la logica RW.
	if not self.isServer and self.currentUpdateDistance > Cutter.CLIENT_DM_UPDATE_RADIUS then return superFunc(self, workArea, dt) end

	if g_realisticWeather ~= nil then g_realisticWeather:preProcessCutterArea(self, workArea, dt) end

	local lastChangedArea, lastTotalArea = superFunc(self, workArea, dt)

	if g_realisticWeather ~= nil then g_realisticWeather:postProcessCutterArea(self, workArea, dt, lastChangedArea) end

	return lastChangedArea, lastTotalArea

end
