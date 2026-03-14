-- ExtendedMower.lua
-- Specializzazione veicolo ExtendedMower per i veicoli falciatrici compatibili con RW.
-- Richiede la specializzazione Mower come prerequisito.
--
-- Funziona come bridge tra il sistema di specializzazioni di FS25 e la logica RW:
-- registra un override di processMowerArea che chiama i callback pre/post
-- di g_realisticWeather (preProcessMowerArea e postProcessMowerArea).
-- Questi callback sono definiti in RealisticWeather.lua e gestiscono
-- la lettura/scrittura dell'umidità durante la falciatura.
--
-- Nota: l'override RW_Mower.processMowerArea (in Mower.lua) gestisce la logica
-- completa per i mower vanilla; ExtendedMower gestisce invece i veicoli
-- che usano il sistema di specializzazioni di FS25 (modType/vehicleType).
--
-- Nota sul guard: se il client è oltre CLIENT_DM_UPDATE_RADIUS dal veicolo,
-- la logica RW viene saltata e si usa la funzione vanilla per evitare
-- aggiornamenti di density map su client remoti.

ExtendedMower = {}


-- Verifica che la specializzazione Mower sia presente nel tipo veicolo.
function ExtendedMower.prerequisitesPresent(specializations)
	return SpecializationUtil.hasSpecialization(Mower, specializations)
end


-- Nessuna funzione aggiuntiva da registrare (solo override).
function ExtendedMower.registerFunctions(vehicleType) end


-- Registra l'override di processMowerArea sul tipo veicolo.
function ExtendedMower.registerOverwrittenFunctions(vehicleType)
	SpecializationUtil.registerOverwrittenFunction(vehicleType, "processMowerArea", ExtendedMower.processMowerArea)
end


-- Override di processMowerArea per i veicoli con specializzazione ExtendedMower.
-- Se il client è fuori dal raggio di aggiornamento DM (CLIENT_DM_UPDATE_RADIUS),
-- usa direttamente la funzione vanilla per evitare aggiornamenti inutili.
-- Altrimenti: chiama preProcessMowerArea, esegue la funzione vanilla, chiama postProcessMowerArea.
-- I callback pre/post gestiscono la lettura dell'umidità pre-falciatura
-- e la registrazione dell'area falciata nel GrassMoistureSystem.
-- @param workArea  work area della falciatrice
-- @param dt        delta time in ms
-- @return changedArea, totalArea
function ExtendedMower:processMowerArea(superFunc, workArea, dt)

	-- Su client remoti oltre il raggio di aggiornamento, salta la logica RW.
	if not self.isServer and self.currentUpdateDistance > Mower.CLIENT_DM_UPDATE_RADIUS then return superFunc(self, workArea, dt) end

	if g_realisticWeather ~= nil then g_realisticWeather:preProcessMowerArea(self, workArea, dt) end

	local lastChangedArea, lastTotalArea = superFunc(self, workArea, dt)

	if g_realisticWeather ~= nil then g_realisticWeather:postProcessMowerArea(self, workArea, dt, lastChangedArea) end

	return lastChangedArea, lastTotalArea

end
