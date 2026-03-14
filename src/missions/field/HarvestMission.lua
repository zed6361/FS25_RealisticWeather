-- HarvestMission.lua (RW_HarvestMission)
-- Override di HarvestMission.getMaxCutLiters per scalare la resa massima del contratto
-- di raccolta in base all'umidità e alle condizioni reali del campo (via RW).
--
-- Il vanilla calcola la resa massima del contratto solo dalla densità della coltura
-- senza tener conto dell'umidità del terreno. Questo override campiona la resa
-- effettiva in una griglia di punti distribuiti sul perimetro del campo e usa
-- la media come fattore di scala per la resa vanilla.
--
-- Algoritmo di campionamento:
--   1. Calcola il centroide del poligono del campo (cx, cz) come media dei vertici.
--   2. Itera le coppie di vertici consecutivi del poligono:
--      Per ogni coppia (x,z) → (nextX,nextZ):
--        a. Determina il bounding box del triangolo (x,z)-(nextX,nextZ)-(cx,cz).
--        b. Sceglie norZ: una coordinata Z di riferimento per dividere il triangolo
--           in due sub-range [minZ, norZ] e [norZ, maxZ].
--        c. Campiona ogni punto intero (px, pz) nel bounding box, chiamando
--           getHarvestScaleAtPoint(px, pz) per ogni punto.
--   3. Calcola la scala media: scale / points.
--   4. Applica: scaledLitres = (originalLitres / points) * scale.
--   5. Restituisce min(originalLitres, scaledLitres) per non superare il massimo vanilla.
--
-- getHarvestScaleAtPoint(x, z):
--   Funzione locale che crea un FieldState temporaneo, lo aggiorna per le coordinate
--   date e chiama getHarvestScaleMultiplier() se la coltura non è appassita.
--   FieldState.update (hook RW in FieldState.lua) popola self.moisture,
--   che viene poi usato da getHarvestScaleMultiplier via g_realisticWeather.fieldMoisture.
--
-- Limitazione: il campionamento per triangolazione del perimetro può essere
-- costoso computazionalmente su campi grandi (O(area)). Non è ottimizzato
-- per mappe molto grandi o campi irregolari con molti vertici.

RW_HarvestMission = {}


-- Helper locale: calcola il moltiplicatore di resa in un singolo punto del campo.
-- Crea un FieldState temporaneo, lo aggiorna (popola moisture via RW_FieldState.update)
-- e chiama getHarvestScaleMultiplier() se la coltura è raccoglibile e non appassita.
-- @param x  coordinata X mondo
-- @param z  coordinata Z mondo
-- @return moltiplicatore di resa [0, ∞), 0 se la coltura è sconosciuta o appassita
local function getHarvestScaleAtPoint(x, z)

	local state = FieldState.new()
	local scale = 0
	-- update() popola fruitTypeIndex, growthState, moisture (via RW_FieldState.update)
	state:update(x, z)

	if state.fruitTypeIndex ~= FruitType.UNKNOWN then
		local fruit = g_fruitTypeManager:getFruitTypeByIndex(state.fruitTypeIndex)
		-- Le colture appassite non contribuiscono alla resa del contratto.
		if not fruit:getIsWithered(state.growthState) then scale = state:getHarvestScaleMultiplier() end
	end

	state = nil
	return scale

end


-- Override di HarvestMission.getMaxCutLiters.
-- Campiona la resa effettiva su una griglia di punti del campo e scala la resa vanilla.
-- @return litri massimi scalati per umidità [0, originalLitres]
function RW_HarvestMission:getMaxCutLiters(superFunc)

	local field = self.field
	local polygon = field.densityMapPolygon
	local vertices = polygon:getVerticesList()
	local scale, points = 0, 0
	local cx, cz = 0, 0

	-- Calcola il centroide del poligono come media aritmetica dei vertici.
	for i = 1, #vertices, 2 do
		local x, z = vertices[i], vertices[i + 1]
		if x == nil or z == nil then break end
		cx = cx + x
		cz = cz + z
	end
	cx = cx / (#vertices / 2)
	cz = cz / (#vertices / 2)

	-- Campionamento per triangolazione del perimetro:
	-- per ogni spigolo del poligono forma un triangolo con il centroide
	-- e campiona tutti i punti interi nel suo bounding box.
	for i = 1, #vertices, 2 do

		local x, z = vertices[i], vertices[i + 1]
		if x == nil or z == nil then break end

		-- Vertice successivo (wrap-around all'ultimo → primo vertice).
		local nextX = vertices[i + 2] or vertices[1]
		local nextZ = vertices[i + 3] or vertices[2]
		
		-- Bounding box del triangolo (x,z)-(nextX,nextZ)-(cx,cz).
		local minX, maxX = math.min(x, nextX, cx), math.max(x, nextX, cx)
		local minZ, maxZ = math.min(z, nextZ, cz), math.max(z, nextZ, cz)

		-- norZ: coordinata Z di riferimento per dividere il triangolo in due sub-range.
		-- Sceglie il valore che non è né il minimo né il massimo tra i tre Z del triangolo.
		local norZ
		if cz ~= minZ and cz ~= maxZ then 
			norZ = cz
		elseif nextZ ~= minZ and nextZ ~= maxZ then 
			norZ = nextZ
		else
			norZ = z
	    end

		-- Campiona tutti i punti interi (px, pz) nel bounding box del triangolo.
		for px = minX, maxX do
		
			for pz = minZ, norZ do
				points = points + 1
				scale = scale + getHarvestScaleAtPoint(px, pz)
			end

			for pz = norZ, maxZ do
				points = points + 1
				scale = scale + getHarvestScaleAtPoint(px, pz)
			end

		end

	end

	local originalLitres = superFunc(self)

	-- Evita divisione per zero se il campo non ha punti campionabili.
	if originalLitres == 0 then return 0 end

	-- Scala i litri: usa la resa media come fattore moltiplicativo sulla resa vanilla.
	-- Non può superare il valore vanilla originale (il campo non può rendere "di più").
	local scaledLitres = (originalLitres / points) * scale

	return math.min(originalLitres, scaledLitres)

end

HarvestMission.getMaxCutLiters = Utils.overwrittenFunction(HarvestMission.getMaxCutLiters, RW_HarvestMission.getMaxCutLiters)
