-- Fire.lua
-- Classe che rappresenta un singolo fuoco nel mondo di gioco.
-- Ogni fuoco ha:
--   - un nodo 3D caricato come i3d condiviso (fire.i3d)
--   - dimensioni (width, height) e carburante (fuel) che evolvono nel tempo
--   - una direzione di propagazione (direction) da cui si calcolano i fattori xF, zF
--   - un meccanismo di "spawn figli": quando il fuoco ha bruciato abbastanza terreno
--     e ha ancora carburante, crea un nuovo fuoco figlio a 1.5m in direzione ruotata di 45°
--
-- Logica di propagazione (update):
--   - Il fuoco si sposta di step = 0.000026 × timescale in direzione (xF, zF)
--   - Il carburante si consuma proporzionalmente a width × height × timescale × shrinkFactor
--   - shrinkFactor = 10 se piove, +50 se su terreno coltivato (il fuoco si spegne rapidamente)
--   - Quando burnDistance >= 0.5 tra oldPosition e posizione corrente:
--       * Campiona i raccolti sul percorso e calcola lastBurnArea (% di campo bruciabile)
--       * Chiama RWUtils.burnArea() per aggiornare le density map
--       * Aggiunge carburante proporzionale alla distanza bruciata e alla superficie
--       * Se le condizioni sono soddisfatte (timeSinceLastChild >= 350, fuel > soglia, < 25 fuochi),
--         crea un fuoco figlio con createFromExistingFire()
--   - La rotazione del nodo 3D segue la direzione della telecamera del giocatore locale
--     (solo se il fuoco è entro 250m dal giocatore)

Fire = {}


local modDirectory = g_currentModDirectory
local fire_mt = Class(Fire)
-- Offset di rotazione per allineare il billboard del fuoco alla direzione della camera.
local rotationOffset = math.pi / 2


-- Costruttore. Inizializza tutti i campi con valori di default.
function Fire.new()

	local self = setmetatable({}, fire_mt)

	self.node = nil
	self.sharedLoadRequest = nil
	self.isInRange = false               -- true se il giocatore è entro 250m
	self.position = { 0, 0, 0 }
	self.oldPosition = nil               -- posizione al momento dell'ultimo burnArea
	self.width = 1                       -- larghezza del fuoco [0.15, 1.4]
	self.height = 1                      -- altezza del fuoco [0.15, 1.6]
	self.burnTime = 0                    -- accumulatore per il trigger di burnArea
	self.fuel = 1500                     -- carburante residuo
	self.direction = 0                   -- direzione di propagazione in gradi [-180, 180]
	self.timeSinceLastUpdate = 0         -- accumulatore timescale tra un update e l'altro
	self.timeSinceLastChild = 0          -- contatore aggiornamenti dall'ultimo figlio
	self.updatesSinceLastGroundCheck = 0 -- contatore aggiornamenti dall'ultimo check terreno
	self.isOnCultivatedGround = false    -- true se il fuoco è su terreno coltivato o vuoto
	self.lastBurnArea = 1                -- proporzione di campo bruciabile nell'ultimo aggiornamento

	return self

end


-- Distrugge il fuoco: rilascia il file i3d condiviso e cancella il nodo 3D.
function Fire:delete()

	if self.sharedLoadRequest ~= nil then
		g_i3DManager:releaseSharedI3DFile(self.sharedLoadRequest)
		self.sharedLoadRequest = nil
	end

	delete(self.node)

end


-- Carica i dati del fuoco dal file XML di salvataggio.
-- @param xmlFile  handle al file XML
-- @param key      percorso XML del nodo da leggere
-- @return true se il caricamento è andato a buon fine
function Fire:loadFromXMLFile(xmlFile, key)

    if xmlFile == nil then return false end

    self.position = xmlFile:getVector(key .. "#position", { 0, 0, 0 })
    self.direction = xmlFile:getFloat(key .. "#direction", 0)
    self.width = xmlFile:getFloat(key .. "#width", 1)
    self.height = xmlFile:getFloat(key .. "#height", 1)
    self.burnTime = xmlFile:getFloat(key .. "#burnTime", 0)
    self.fuel = xmlFile:getFloat(key .. "#fuel", 1500)
	self.lastChildDirection = xmlFile:getFloat(key .. "#lastChildDirection")
	self.lastBurnArea = xmlFile:getFloat(key .. "#lastBurnArea", 1)
	self.oldPosition = xmlFile:getVector(key .. "#oldPosition")
	self.timeSinceLastChild = xmlFile:getInt(key .. "#timeSinceLastChild", 0)
	self.isOnCultivatedGround = xmlFile:getBool(key .. "#isOnCultivatedGround", false)

	self:calculateDirectionFactors()

    return true

end


-- Salva i dati del fuoco nel file XML di salvataggio.
-- Salva in modo condizionale i campi opzionali per minimizzare le dimensioni del file.
-- @param xmlFile  handle al file XML
-- @param key      percorso XML del nodo da scrivere
function Fire:saveToXMLFile(xmlFile, key)

    if xmlFile == nil then return end

    xmlFile:setVector(key .. "#position", self.position or {0, 0, 0 })
    xmlFile:setFloat(key .. "#direction", self.direction or 0)
    xmlFile:setFloat(key .. "#width", self.width or 1)
    xmlFile:setFloat(key .. "#height", self.height or 1)
	xmlFile:setFloat(key .. "#burnTime", self.burnTime or 0)
	xmlFile:setFloat(key .. "#fuel", self.fuel or 1500)
	
	if self.lastChildDirection ~= nil then xmlFile:setFloat(key .. "#lastChildDirection", self.lastChildDirection) end
	if self.lastBurnArea < 1 then xmlFile:setFloat(key .. "#lastBurnArea", self.lastBurnArea) end
	if self.oldPosition ~= nil then xmlFile:setVector(key .. "#oldPosition", self.oldPosition) end
	if self.timeSinceLastChild ~= 0 then xmlFile:setInt(key .. "#timeSinceLastChild", self.timeSinceLastChild) end
	if self.isOnCultivatedGround then xmlFile:setBool(key .. "#isOnCultivatedGround", self.isOnCultivatedGround) end

end


-- Serializza il fuoco nello stream di rete (per FireEvent).
-- Trasmette oldPosition come posizione corrente se oldPosition è nil.
function Fire:writeStream(streamId)

    streamWriteFloat32(streamId, self.timeSinceLastUpdate)
    streamWriteUInt16(streamId, self.updatesSinceLastGroundCheck)

    streamWriteFloat32(streamId, self.width)
    streamWriteFloat32(streamId, self.height)

    streamWriteFloat32(streamId, self.position[1])
    streamWriteFloat32(streamId, self.position[2])
    streamWriteFloat32(streamId, self.position[3])

	-- Se oldPosition non è ancora definita, usa la posizione corrente come riferimento.
	if self.oldPosition == nil then

		streamWriteFloat32(streamId, self.position[1])
		streamWriteFloat32(streamId, self.position[2])
		streamWriteFloat32(streamId, self.position[3])

	else

		streamWriteFloat32(streamId, self.oldPosition[1])
		streamWriteFloat32(streamId, self.oldPosition[2])
		streamWriteFloat32(streamId, self.oldPosition[3])

	end

	streamWriteFloat32(streamId, self.fuel)
	streamWriteFloat32(streamId, self.burnTime)
	streamWriteFloat32(streamId, self.direction)
	
	streamWriteFloat32(streamId, self.lastChildDirection or self.direction)
	streamWriteFloat32(streamId, self.lastBurnArea)
	streamWriteUInt16(streamId, self.timeSinceLastChild)
	streamWriteBool(streamId, self.isOnCultivatedGround)

end


-- Deserializza il fuoco dallo stream di rete.
-- @return true se la lettura è andata a buon fine
function Fire:readStream(streamId)

    self.timeSinceLastUpdate = streamReadFloat32(streamId)
    self.updatesSinceLastGroundCheck = streamReadUInt16(streamId)

    self.width = streamReadFloat32(streamId)
    self.height = streamReadFloat32(streamId)

    self.position[1] = streamReadFloat32(streamId)
    self.position[2] = streamReadFloat32(streamId)
    self.position[3] = streamReadFloat32(streamId)

    self.oldPosition[1] = streamReadFloat32(streamId)
    self.oldPosition[2] = streamReadFloat32(streamId)
    self.oldPosition[3] = streamReadFloat32(streamId)

    self.fuel = streamReadFloat32(streamId)
    self.burnTime = streamReadFloat32(streamId)
    self.direction = streamReadFloat32(streamId)

    self.lastChildDirection = streamReadFloat32(streamId)
    self.lastBurnArea = streamReadFloat32(streamId)
    self.timeSinceLastChild = streamReadUInt16(streamId)
    self.isOnCultivatedGround = streamReadBool(streamId)

    return true

end


-- Inizializza il fuoco nella scena 3D: carica fire.i3d come risorsa condivisa,
-- posiziona e scala il nodo, e imposta un parametro shader random per la variazione visiva.
-- Inizializza oldPosition se non già definita (necessario per il primo update).
function Fire:initialize()

	local node, sharedLoadRequest = g_i3DManager:loadSharedI3DFile(modDirectory .. "i3d/fire.i3d")

	self.node, self.sharedLoadRequest = node, sharedLoadRequest

	-- oldPosition viene usata per tracciare il percorso bruciato; inizializzata alla posizione corrente.
	self.oldPosition = self.oldPosition or { self.position[1], self.position[3] }

	link(getRootNode(), node)
	setWorldTranslation(node, unpack(self.position))
	setVisibility(node, true)
	setScale(node, 1, self.height, self.width)

	local shapeNode = getChildAt(node, 0)

	-- Offset shader casuale per evitare che tutti i fuochi abbiano la stessa animazione.
	setShaderParameter(shapeNode, "startPosition", math.random(), 0, 0, 0, false)

end


-- Calcola i fattori di direzione xF e zF dalla direzione angolare in gradi.
-- La direzione è divisa in 8 settori da 45° con interpolazione lineare ai bordi.
-- xF e zF sono i componenti del vettore di propagazione normalizzato.
-- Vengono chiamati da loadFromXMLFile, createFromExistingFire e updateGroundDetails.
function Fire:calculateDirectionFactors()

	local xF, zF

	if self.direction <= -135 then
		
		xF = 0.5 * ((-180 - self.direction) / 45)
		zF = -1 - xF

	elseif self.direction <= -90 then
		
		xF = -0.5 + 0.5 * ((-135 - self.direction) / 45)
		zF = -1 - xF

	elseif self.direction <= -45 then
		
		xF = -0.5 + 0.5 * ((-90 - self.direction) / 45)
		zF = 1 + xF

	elseif self.direction <= 0 then
		
		zF = 0.5 + 0.5 * math.abs((-45 - self.direction) / 45)
		xF = -1 + zF

	elseif self.direction <= 45 then
		
		zF = 1 - 0.5 * math.abs((0 - self.direction) / 45)
		xF = 1 - zF

	elseif self.direction <= 90 then
		
		xF = 0.5 + 0.5 * math.abs((45 - self.direction) / 45)
		zF = 1 - xF

	elseif self.direction <= 135 then
		
		xF = 1 - 0.5 * math.abs((90 - self.direction) / 45)
		zF = -1 + xF

	else
		
		xF = 0.5 - 0.5 * math.abs((135 - self.direction) / 45)
		zF = -1 + xF
		
	end

	self.xF, self.zF = xF, zF

end


-- Inizializza un fuoco figlio a partire da un fuoco esistente.
-- Il figlio eredita il 97% delle dimensioni del padre (ridotte leggermente) e metà del carburante.
-- La direzione del figlio è quella dell'ultimo figlio creato dal padre + 45°,
-- garantendo che i figli si propaghino in spirale crescente.
-- Posiziona il figlio a 1.5m dal padre nella direzione calcolata.
-- @param fire  fuoco padre da cui derivare il figlio
function Fire:createFromExistingFire(fire)

	self.width, self.height, self.fuel = math.clamp(fire.width * 0.97, 0.15, 1.4), math.clamp(fire.height * 0.97, 0.15, 1.6), fire.fuel * 0.5
	
	local lastChildDirection = fire.lastChildDirection or fire.direction

	-- Ruota di 45° rispetto alla direzione dell'ultimo figlio creato.
	self.direction = lastChildDirection + 45

	-- Mantieni la direzione nel range [-180, 180].
	if self.direction < -180 then
		self.direction = 360 + self.direction
	elseif self.direction > 180 then
		self.direction = -360 + self.direction
	end

	fire.lastChildDirection = self.direction

	self:calculateDirectionFactors()

	-- Posiziona il figlio a 1.5m dal padre nella direzione calcolata.
	self.position = { fire.position[1] + 1.5 * self.xF, fire.position[2], fire.position[3] + 1.5 * self.zF }

	self:initialize()

end


-- Aggiorna la cache della distanza dal giocatore locale.
-- isInRange viene usato in update() per decidere se ruotare il nodo 3D.
-- @param px, pz  coordinate del giocatore locale (nil se non disponibile)
function Fire:updateDistanceToPlayer(px, pz)

	if px == nil or pz == nil then
		self.isInRange = false
		return
	end

	local x, z = self.position[1], self.position[3]

	local distance = MathUtil.vector2Length(x - px, z - pz)
	
	self.isInRange = distance < 250

end


-- Aggiorna il fuoco per un tick. Chiamato dal FireSystem in round-robin.
--
-- Pipeline di aggiornamento:
--   1. Se il giocatore è in range, ruota il billboard verso la camera.
--   2. Calcola step di propagazione e sposta il fuoco in direzione (xF, zF).
--   3. Aggiorna burnTime e consuma carburante (amplificato da shrinkFactor).
--      shrinkFactor: 10 se piove, +50 se su terreno coltivato.
--   4. Se fuel/width/height scendono sotto soglia → elimina il fuoco (return true).
--   5. Se burnTime >= soglia e distanza da oldPosition >= 0.5m:
--      a. Campiona i raccolti lungo il percorso per calcolare lastBurnArea
--      b. Chiama RWUtils.burnArea() per aggiornare le density map
--      c. Aggiunge carburante proporzionale al campo bruciato
--      d. Se timeSinceLastChild >= 350 e fuel > soglia e < 25 fuochi: crea un figlio
--   6. Aggiorna timeSinceLastChild e updatesSinceLastGroundCheck (scaling per numFires).
--   7. Ogni 100 aggiornamenti: chiama updateGroundDetails().
-- @param fireSystem  riferimento al FireSystem per accedere alla lista dei fuochi
-- @param isRaining   true se sta piovendo (aumenta shrinkFactor)
-- @return true se il fuoco deve essere eliminato, false altrimenti
function Fire:update(fireSystem, isRaining)

	local timescale = math.min(self.timeSinceLastUpdate, 3500)

	-- Rotazione billboard verso la camera del giocatore (solo se in range).
	if self.isInRange then

		local dx, _, dz = localDirectionToWorld(g_localPlayer.camera.cameraRootNode, 0, 0, -1)
		local dir = MathUtil.getYRotationFromDirection(dx, dz)

		dir = dir + (dir >= 0 and -rotationOffset or rotationOffset)

		setWorldRotation(self.node, 0, dir, 0)

	end

	local x, z = self.position[1], self.position[3]
	
	local step = 0.000026 * timescale

	local isOnCultivatedGround, shrinkFactor = self.isOnCultivatedGround, isRaining and 10 or 1

	-- Su terreno coltivato: propagazione ridotta al 30% e shrinkFactor aumentato di 50 (spegnimento rapido).
	if isOnCultivatedGround then
		step = step * 0.3
		shrinkFactor = shrinkFactor + 50
	end
		
	x, z = x + step * self.xF, z + step * self.zF

	self.position[1], self.position[3] = x, z

	setWorldTranslation(self.node, x, self.position[2], z)

	local burnTime = self.burnTime + math.min(0.0028 * timescale, 1.5)
	local fuel = math.clamp(self.fuel - self.width * self.height * timescale * 0.0006 * shrinkFactor, 0, 2500)

	local width, height = self.width, self.height

	-- Le dimensioni si riducono proporzionalmente al carburante consumato.
	width = math.max(width - 0.0002 * (self.fuel - fuel) * shrinkFactor, 0.15)
	height = math.max(height - 0.000175 * (self.fuel - fuel) * shrinkFactor, 0.15)

	-- Eliminazione del fuoco se esaurito.
	if fuel <= 0 or width <= 0.15 or height <= 0.15 then

		self:delete()
		return true

	end

	local numFires = #fireSystem.fires

	-- Logica di burnArea: si attiva su terreno non coltivato quando burnTime supera la soglia.
	if not isOnCultivatedGround and burnTime >= 3 - width * height then
	
		local ox, oz = self.oldPosition[1], self.oldPosition[2]
		
		local burnDistance = MathUtil.vector2Length(ox - x, oz - z)

		-- Aggiorna le density map solo se il fuoco si è spostato di almeno 0.5m.
		if burnDistance >= 0.5 then

			local burnWidth = x - ox
			local burnHeight = z - oz
			local dataPlaneId = g_fruitTypeManager:getDefaultDataPlaneId()
			local totalBurnArea = 0
			local burnArea = 0

			-- Campiona ogni 0.25m lungo il percorso per stimare la percentuale di campo bruciabile.
			for i = 0, burnDistance, 0.25 do

				local burnX = ox + 0.25 + burnWidth * (i / burnDistance)
				local burnZ = oz + 0.25 + burnHeight * (i / burnDistance)
				
				local fruitTypeIndex = getDensityTypeIndexAtWorldPos(dataPlaneId, burnX, 0, burnZ)
				local fruitType = g_fruitTypeManager:getFruitTypeByDensityTypeIndex(fruitTypeIndex)

				if fruitType ~= nil then

					local growthState = getDensityStatesAtWorldPos(dataPlaneId, burnX, 0, burnZ)

					-- Conta come bruciabile solo se il raccolto è in uno stadio harvestable.
					if growthState > 0 and growthState <= fruitType.maxHarvestingGrowthState then burnArea = burnArea + 1 end

				end

				totalBurnArea = totalBurnArea + 1

			end

			-- Applica la bruciatura alle density map nell'area percorsa.
			RWUtils.burnArea(ox + 0.2, oz + 0.2, ox - 0.2, oz - 0.2, x, z)

			self.lastBurnArea = (burnArea / totalBurnArea)

			-- burnDistance effettiva ridotta dalla proporzione di campo effettivamente bruciabile.
			burnDistance = burnDistance * (burnArea / totalBurnArea)

			burnTime = 0
			-- Aggiunge carburante proporzionale alla distanza bruciata e alla superficie del fuoco.
			fuel = fuel + burnDistance * 80 * width * height
			self.oldPosition = { x, z }

			width = math.min(width + burnDistance * 0.0006, 1.4)
			height = math.min(width + burnDistance * 0.00075, 1.6)

			-- Crea un fuoco figlio se: intervallo sufficiente, carburante abbondante, < 25 fuochi totali.
			if self.timeSinceLastChild >= 350 and fuel > width * height * 100 and numFires < 25 then
			
				self.width, self.height = width, height
				self.timeSinceLastChild = 0

				local fire = Fire.new()
				fire:createFromExistingFire(self)
				table.insert(fireSystem.fires, fire)

				-- Il carburante viene dimezzato alla nascita del figlio.
				fuel = fuel * 0.5
		
			end

		end

	end


	self.width, self.height = width, height
	self.burnTime, self.fuel = burnTime, fuel

	setScale(self.node, 1, height, width)

	self.timeSinceLastUpdate = 0
	-- timeSinceLastChild e updatesSinceLastGroundCheck scalano con numFires per rallentare
	-- la propagazione quando ci sono molti fuochi contemporaneamente.
	self.timeSinceLastChild = math.min(self.timeSinceLastChild + 1 * numFires, 1000)
	self.updatesSinceLastGroundCheck = self.updatesSinceLastGroundCheck + 1 * numFires

	-- Verifica periodica del tipo di terreno (ogni 100 aggiornamenti scalati per numFires).
	if self.updatesSinceLastGroundCheck >= 100 then
		self.updatesSinceLastGroundCheck = 0
		self:updateGroundDetails()
	end

	return false

end


-- Aggiorna le informazioni sul terreno sotto il fuoco:
--   - isOnCultivatedGround: true se il terreno è CULTIVATED o NONE (campo libero)
--   - Aggiorna la quota Y alla quota del terreno - 0.1m
--   - Se su terreno coltivato o lastBurnArea < 0.33 (poco campo bruciabile),
--     ruota la direzione di 25° per cercare un percorso più produttivo.
-- Chiamato ogni 100 aggiornamenti scalati.
function Fire:updateGroundDetails()

	local groundTypeValue = g_currentMission.fieldGroundSystem:getValueAtWorldPos(FieldDensityMap.GROUND_TYPE, self.position[1], 0, self.position[3])
    local groundType = FieldGroundType.getTypeByValue(groundTypeValue)

	self.isOnCultivatedGround = groundType == FieldGroundType.CULTIVATED or groundType == FieldGroundType.NONE

	-- Aggancia il fuoco alla quota corrente del terreno (con leggero offset sotto la superficie).
	self.position[2] = getTerrainHeightAtWorldPos(g_terrainNode, self.position[1], 0, self.position[3]) - 0.1
	
	-- Se il fuoco è su terreno non bruciabile o l'area bruciata è troppo bassa, cambia direzione.
	if self.isOnCultivatedGround or self.lastBurnArea < 0.33 then

		self.direction = self.direction + 25

		if self.direction > 180 then self.direction = -360 + self.direction end

		self:calculateDirectionFactors()

	end

end
