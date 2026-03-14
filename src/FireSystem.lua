-- FireSystem.lua
-- Gestore globale del sistema di incendi per il mod RealisticWeather.
-- Responsabilità principali:
--   - Avvio e spegnimento degli incendi su un campo alla volta (fieldId identifica il campo attivo)
--   - Aggiornamento in round-robin dei singoli fuochi (un fuoco per tick)
--   - Probabilità di innesco oraria basata su stagione, temperatura, siccità e umidità del terreno
--   - Verifica giornaliera se il giorno è "viable" per un incendio (probabilità stagionale)
--   - Salvataggio/caricamento dello stato in fires.xml nel savegame
--   - Sincronizzazione MP tramite FireEvent (broadcast al join e all'avvio incendio)
--   - Comandi console rwSpawnFire e rwEndFire (solo single player, solo server)
--
-- Probabilità stagionale (SEASON_TO_PROBABILITY):
--   Primavera: 0.35, Estate: 1.0, Autunno: 0.05, Inverno: 0

FireSystem = {}

-- Moltiplicatore base di probabilità incendio per stagione.
FireSystem.SEASON_TO_PROBABILITY = {
    [Season.SPRING] = 0.35,
    [Season.SUMMER] = 1,
    [Season.AUTUMN] = 0.05,
    [Season.WINTER] = 0
}

local fireSystem_mt = Class(FireSystem)
local modDirectory = g_currentModDirectory


-- Costruttore del FireSystem.
-- Sul server: sottoscrive gli eventi HOUR_CHANGED e DAY_CHANGED e registra i comandi console.
function FireSystem.new()

	local self = setmetatable({}, fireSystem_mt)

	self.fieldId = nil           -- ID del campo attualmente in fiamme (nil = nessun incendio)
	self.fires = {}              -- lista dei fuochi attivi
	self.isServer = g_currentMission:getIsServer()
	self.fireEnabled = true
    self.isSaving = false
    self.timeSinceLastUpdate = 0
    self.updateIteration = 1    -- indice round-robin per l'aggiornamento dei fuochi
    self.isRaining = false

    if self.isServer then
        
        g_messageCenter:subscribe(MessageType.HOUR_CHANGED, self.onHourChanged, self)
        g_messageCenter:subscribe(MessageType.DAY_CHANGED, self.onDayChanged, self)

        self.isViableForFire = false  -- diventa true solo se la probabilità giornaliera viene estratta

        -- Comandi console disponibili solo in single player.
        if not g_currentMission.missionDynamicInfo.isMultiplayer then
            addConsoleCommand("rwSpawnFire", "Spawns a fire at the player's coordinates", "consoleCommandSpawnFire", self)
            addConsoleCommand("rwEndFire", "Ends the current fire", "consoleCommandEndFire", self)
        end

    end

	return self

end


-- Carica lo stato degli incendi dal file fires.xml nel savegame corrente.
-- Legge fieldId, isViableForFire e la lista dei fuochi serializzati.
function FireSystem:loadFromXMLFile()

	local savegameIndex = g_careerScreen.savegameList.selectedIndex
    local savegame = g_savegameController:getSavegame(savegameIndex)

    if savegame == nil or savegame.savegameDirectory == nil then return end

    local xmlFile = XMLFile.loadIfExists("firesXML", savegame.savegameDirectory .. "/fires.xml")

    if xmlFile == nil then return end

    self.fieldId = xmlFile:getInt("fires#fieldId")
    self.isViableForFire = xmlFile:getBool("fires#isViableForFire", false)

    xmlFile:iterate("fires.fire", function(_, key)

        local fire = Fire.new()
        local success = fire:loadFromXMLFile(xmlFile, key)

        if success then table.insert(self.fires, fire) end

    end)

    xmlFile:delete()

end


-- Salva lo stato degli incendi nel file fires.xml.
-- @param path  percorso completo del file di destinazione
function FireSystem:saveToXMLFile(path)

	if path == nil then return end

    local xmlFile = XMLFile.create("firesXML", path, "fires")
    if xmlFile == nil then return end

    self.isSaving = true

    if self.fieldId ~= nil then xmlFile:setInt("fires#fieldId", self.fieldId) end
    xmlFile:setBool("fires#isViableForFire", self.isViableForFire)

    for i = 1, #self.fires do

        local fire = self.fires[i]
        fire:saveToXMLFile(xmlFile, string.format("fires.fire(%d)", i - 1))

    end

    xmlFile:save(false, true)

    xmlFile:delete()

    self.isSaving = false

end


-- Inizializza nella scena 3D tutti i fuochi già presenti nella lista
-- (caricati dal savegame o ricevuti via FireEvent al join).
function FireSystem:initialize()

	for _, fire in pairs(self.fires) do fire:initialize() end

end


-- Aggiorna il sistema di incendi ogni tick del gioco.
-- Strategia round-robin: aggiorna un solo fuoco per chiamata.
-- Se non ci sono incendi o il sistema è disabilitato, chiama endFire() se necessario e torna.
-- Contiene due fix critici MP:
--   RW_CRITICAL_FIX: corregge l'iteratore fuori range durante mutazioni concorrenti
--   RW_CRITICAL_FIX: controlla weather con guard per shutdown deterministico in caso di pioggia
-- @param timescale    tempo trascorso dall'ultimo tick
-- @param updateCache  se true, aggiorna isRaining e le distanze dal giocatore
function FireSystem:update(timescale, updateCache)

    if self.isSaving then return end

    if self.fieldId == nil or #self.fires == 0 or not self.fireEnabled then
        
        if self.fieldId ~= nil then self:endFire() end

        -- RW_CRITICAL_FIX: stop iteration loop when fire table is empty
        self.updateIteration = 1
        return

    end

    local timeSinceLastUpdate = self.timeSinceLastUpdate + timescale

    -- Distribuisce il timescale accumulato su tutti i fuochi.
    for _, fire in pairs(self.fires) do fire.timeSinceLastUpdate = fire.timeSinceLastUpdate + timeSinceLastUpdate end

    -- RW_CRITICAL_FIX: prevent index-out-of-bounds and nil fire access during MP mutations
    if self.updateIteration == nil or self.updateIteration < 1 or self.updateIteration > #self.fires then
        print(string.format("RealisticWeather: fire iteration corrected (%s -> 1, fireCount=%s)", tostring(self.updateIteration), tostring(#self.fires)))
        self.updateIteration = 1
    end

    local currentFire = self.fires[self.updateIteration]
    if currentFire == nil then
        self.updateIteration = 1
        return
    end

    local needsDeletion = currentFire:update(self, self.isRaining)

    -- Se il fuoco si è esaurito, rimuovilo e correggi l'indice.
    if needsDeletion then

        table.remove(self.fires, self.updateIteration)
        self.updateIteration = self.updateIteration - 1

    end

    if updateCache then

        -- RW_CRITICAL_FIX: guard weather access for deterministic fire shutdown in rain
        local weather = g_currentMission.environment ~= nil and g_currentMission.environment.weather or nil
        self.isRaining = weather ~= nil and weather.timeSinceLastRain ~= nil and weather.timeSinceLastRain == 0
        
        local px, pz
        
        if g_localPlayer ~= nil then px, _, pz = g_localPlayer:getPosition() end

        for _, fire in pairs(self.fires) do fire:updateDistanceToPlayer(px, pz) end

    end


    self.timeSinceLastUpdate = 0
    self.updateIteration = self.updateIteration + 1

    if self.updateIteration > #self.fires then self.updateIteration = 1 end

end


-- Avvia un incendio nel punto (x, z) sul campo fieldId.
-- Crea un fuoco iniziale con dimensioni e direzione casuali, lo inizializza nella scena
-- e trasmette lo stato a tutti i client tramite FireEvent.
-- La clonazione della lista prima del broadcast evita race condition con update/remove.
-- Non fa nulla se un incendio è già attivo, se non siamo il server, o se gli incendi sono disabilitati.
-- @param x, z    coordinate mondo del punto di innesco
-- @param fieldId ID del campo interessato
function FireSystem:startFire(x, z, fieldId)

    if self.fieldId ~= nil or not self.isServer or not self.fireEnabled then return end

    self.fieldId = fieldId
    self.updateIteration = 1
    self.timeSinceLastUpdate = 0

    local fire = Fire.new()

    fire.position = { x, 0, z }
    local y = getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z) - 0.1
    fire.position[2] = y
    fire.direction = math.random(-1800, 1800) / 10
    fire.width = math.random(800, 1200) / 1000
    fire.height = math.random(900, 1500) / 1000
    
    fire:calculateDirectionFactors()
    fire:initialize()

    table.insert(self.fires, fire)

    g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL, string.format("Fire started on field %d", fieldId))

    -- RW_MP_FIX: clone array before broadcast to avoid race with update/remove
    local fireSnapshot = {}
    for i = 1, #self.fires do
        fireSnapshot[i] = self.fires[i]
    end
    g_server:broadcastEvent(FireEvent.new(1, 0, fieldId, fireSnapshot))

end


-- Termina l'incendio corrente: rimuove tutti i fuochi dalla scena e azzera fieldId.
-- Notifica i giocatori con un messaggio critico in-game (solo sul server).
function FireSystem:endFire()

    if self.isServer then g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL, "Fire ended on field " .. self.fieldId) end

    self.fieldId = nil

    for i = #self.fires, 1, -1 do

        local fire = self.fires[i]
        fire:delete()
        table.remove(self.fires, i)

    end

end


-- Calcola la direzione del prossimo fuoco figlio in base alla direzione dell'ultimo fuoco attivo.
-- La direzione ruota di 180/numFires gradi rispetto all'ultima direzione registrata.
-- Garantisce che il valore rimanga nel range [-180, 180].
function FireSystem:getNextFireDirection()

    local direction = 0

    for i = #self.fires, 1, -1 do

        direction = self.fires[i].direction

    end

    direction = direction + 180 / #self.fires

    if direction > 180 then direction = -360 + direction end

    return direction

end


-- Callback per il cambio delle impostazioni (chiamato da RWSettings).
-- Se fireEnabled viene impostato a false mentre un incendio è attivo, lo termina.
-- @param name   nome dell'impostazione modificata (es. "fireEnabled")
-- @param state  nuovo valore booleano
function FireSystem.onSettingChanged(name, state)

    local fireSystem = g_currentMission.fireSystem

    if fireSystem == nil then return end

    fireSystem[name] = state

    if name == "fireEnabled" and not state and fireSystem.fieldId ~= nil then fireSystem:endFire() end

end


-- Callback HOUR_CHANGED: verifica se le condizioni ambientali permettono l'innesco di un incendio.
-- Viene chiamata ogni ora di gioco solo sul server.
--
-- Formula probabilità:
--   probability = SEASON_TO_PROBABILITY[season]
--                 × (siccità? 0.45 : 0.05)
--                 × (temperature / 35)
--   - Ridotta del 92% fuori dall'orario 6-18
--   - Azzerata se temperatura < 25°C o se sta piovendo
--
-- Se la probabilità viene estratta (math.random() < probability):
--   Cerca fino a 25 celle casuali con umidità < 0.075, terreno non coltivato e fieldId valido.
--   Alla prima cella valida, avvia l'incendio.
function FireSystem:onHourChanged()

    if not self.isViableForFire or self.fieldId ~= nil then return end

    environment = g_currentMission.environment

    local _, currentWeather = environment.weather.forecast:dataForTime(environment.currentMonotonicDay, environment.dayTime)
    
    local season, hour = environment.currentSeason, math.floor(environment:getMinuteOfDay() / 60)
    local temperature = environment.weather.temperatureUpdater:getTemperatureAtTime(environment.dayTime)

    -- Probabilità base: stagione × (siccità o fattore standard) × temperatura normalizzata a 35°C.
    local probability = FireSystem.SEASON_TO_PROBABILITY[season] * (currentWeather ~= nil and currentWeather.isDraught and 0.45 or 0.05)

    -- Riduzione notturna: fuori dall'orario 6-18, probabilità ridotta all'8%.
    if hour < 6 or hour > 18 then probability = probability * 0.08 end

    probability = probability * (temperature / 35)

    -- Nessun incendio se troppo freddo o se sta piovendo.
    if temperature < 25 or environment.weather.timeSinceLastRain == 0 then probability = 0 end

    if math.random() >= probability then return end

    local moistureSystem = g_currentMission.moistureSystem

    -- Cerca una cella valida per l'innesco: umidità bassa, terreno non coltivato, campo esistente.
    for i = 1, 25 do

        local cell = moistureSystem:getRandomCell()

        if cell == nil or cell.moisture > 0.075 then continue end

        local groundTypeValue = g_currentMission.fieldGroundSystem:getValueAtWorldPos(FieldDensityMap.GROUND_TYPE, cell.x, 0, cell.z)
        local groundType = FieldGroundType.getTypeByValue(groundTypeValue)

	    if groundType == FieldGroundType.CULTIVATED or groundType == FieldGroundType.NONE then continue end

        local fieldId = g_farmlandManager:getFarmlandIdAtWorldPosition(cell.x, cell.z)

        if fieldId == nil or fieldId == 0 then continue end

        self:startFire(cell.x, cell.z, fieldId)
        break

    end

end


-- Callback DAY_CHANGED: determina se il nuovo giorno è "viable" per un incendio.
-- Estrae un numero casuale e lo confronta con la probabilità stagionale.
-- isViableForFire viene usato in onHourChanged per evitare calcoli ogni ora in stagioni sicure.
function FireSystem:onDayChanged()

    local environment = g_currentMission.environment

    local season = environment.currentSeason

    local probability = FireSystem.SEASON_TO_PROBABILITY[season]

    self.isViableForFire = math.random() < probability

end


-- Comando console per avviare manualmente un incendio alla posizione del giocatore.
-- Verifica: server, incendi abilitati, nessun incendio già attivo, giocatore su campo non coltivato.
-- Restituisce un messaggio di successo con le coordinate mondo e l'ID del campo.
function FireSystem:consoleCommandSpawnFire()

    if not self.isServer then return "Failed to spawn fire: fire can only be spawned server-side" end

    if not self.fireEnabled then return "Failed to spawn fire: fires are disabled" end

    if self.fieldId ~= nil then return "Failed to spawn fire: a fire already exists" end

    local player = g_localPlayer

    if player == nil then return "Failed to spawn fire: local player does not exist" end

    local fieldId = FieldManager.getFieldIdAtPlayerPosition()
    local x, _, z = player:getPosition()

    local groundTypeValue = g_currentMission.fieldGroundSystem:getValueAtWorldPos(FieldDensityMap.GROUND_TYPE, x, 0, z)
    local groundType = FieldGroundType.getTypeByValue(groundTypeValue)

	if groundType == FieldGroundType.CULTIVATED then return "Failed to spawn fire: player is on a cultivated field" end
    
    if groundType == FieldGroundType.NONE then return "Failed to spawn fire: player must be on a field" end

    self:startFire(x, z, fieldId)

    local moistureSystem = g_currentMission.moistureSystem

    return string.format("Successfully spawned fire: %.2fx (%.0fx), %.2fz (%.2fz), field #%s", x, moistureSystem.mapWidth / 2 + x, z, moistureSystem.mapHeight / 2 + z, fieldId)

end


-- Comando console per terminare manualmente l'incendio corrente.
function FireSystem:consoleCommandEndFire()

    if self.fieldId == nil then return "Failed to end fire: no fire exists" end

    self:endFire()

    return "Successfully ended fire"

end
