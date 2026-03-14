-- Puddle.lua
-- Classe che rappresenta una singola pozzanghera nel mondo di gioco.
-- Ogni pozzanghera ha:
--   - un nodo 3D clonato dalla variante grafica corrispondente
--   - due forme scalabili indipendentemente (left / right) per asimmetria visiva
--   - un anello interno e uno esterno di punti di controllo (inner / outer)
--   - 4 feeler (sensori topografici: up/down/left/right) per simulare il flusso laterale
-- L'aggiornamento adatta dimensioni e posizione all'umidità del terreno circostante
-- e alla topografia locale, eliminando la pozzanghera se troppo piccola o sotto il suolo.

Puddle = {}

local puddle_mt = Class(Puddle)


-- Costruttore. Inizializza tutti i campi della pozzanghera con valori di default.
-- @param variation     indice della variante grafica (da puddles.xml)
-- @param terrainHeight altezza del terreno nel punto di creazione (opzionale)
function Puddle.new(variation, terrainHeight)

    local self = setmetatable({}, puddle_mt)

    self.variation = variation
    self.node = 0
    self.size = { 0, 0 }           -- {larghezza, altezza} del nodo 3D
    self.widthLeft = 1             -- scala laterale della forma sinistra [0.1, 1.75]
    self.widthRight = 1            -- scala laterale della forma destra [0.1, 1.75]
    self.position = { 0, 0, 0 }
    self.rotation = { 0, 0, 0 }
    self.moisture = 0              -- umidità attuale nel centro della pozzanghera
    self.terrainHeight = terrainHeight
    self.timeSinceLastUpdate = 0   -- accumulatore di timescale tra un update e l'altro

    self.points = { ["inner"] = {}, ["outer"] = {} }  -- anelli di punti per geometria e ancoraggio
    self.shapes = { ["right"] = {}, ["left"] = {} }   -- nodi delle due forme scalabili
    self.feelers = { ["up"] = {}, ["down"] = {}, ["left"] = {}, ["right"] = {} }  -- sensori topografici

    return self

end


-- Distrugge la pozzanghera: rimuove il piano d'acqua dalla simulazione e cancella il nodo 3D.
function Puddle:delete()

    if self.node ~= nil then
        for _, shape in pairs(self.shapes) do
            g_currentMission.shallowWaterSimulation:removeWaterPlane(shape)
	        g_currentMission.shallowWaterSimulation:removeAreaGeometry(shape)
        end
        delete(self.node)
    end
    self.node = 0

end


-- Carica i dati della pozzanghera da un file XML di salvataggio.
-- @param xmlFile  handle al file XML
-- @param key      percorso XML del nodo da leggere
-- @return true se il caricamento è andato a buon fine
function Puddle:loadFromXMLFile(xmlFile, key)

    if xmlFile == nil then return false end

    self.variation = xmlFile:getInt(key .. "#variation", 1)
    self.size = xmlFile:getVector(key .. "#size", { 0, 0 })
    self.position = xmlFile:getVector(key .. "#position", { 0, 0, 0 })
    self.rotation = xmlFile:getVector(key .. "#rotation", { 0, 0, 0 })
    self.terrainHeight = xmlFile:getFloat(key .. "#terrainHeight", nil)
    self.widthLeft = math.clamp(xmlFile:getFloat(key .. "#wl", 1), 0.1, 1.75)
    self.widthRight = math.clamp(xmlFile:getFloat(key .. "#wr", 1), 0.1, 1.75)

    return true

end


-- Salva i dati della pozzanghera in un file XML di salvataggio.
-- @param xmlFile  handle al file XML
-- @param key      percorso XML del nodo da scrivere
function Puddle:saveToXMLFile(xmlFile, key)

    if xmlFile == nil then return end

    xmlFile:setInt(key .. "#variation", self.variation or 1)
    xmlFile:setFloat(key .. "#terrainHeight", self.terrainHeight or getTerrainHeightAtWorldPos(g_terrainNode, self.position[1], 0, self.position[3]))
    xmlFile:setVector(key .. "#size", self.size or { 0, 0 })
    xmlFile:setVector(key .. "#position", self.position or {0, 0, 0 })
    xmlFile:setVector(key .. "#rotation", self.rotation or {0, 0, 0 })
    xmlFile:setFloat(key .. "#wl", self.widthLeft or 1)
    xmlFile:setFloat(key .. "#wr", self.widthRight or 1)

end


-- Inizializza la pozzanghera nella scena 3D: clona il nodo dalla variante grafica,
-- configura reflection/shadow/collisione tramite PuddleSystem.onCreateWater,
-- e popola le tabelle dei punti inner/outer e dei feeler da usare nell'update.
function Puddle:initialize()

    local puddleSystem = g_currentMission.puddleSystem
    local variation = puddleSystem:getVariationById(self.variation)
    local node = clone(variation.node, false, false, true)

    if node == nil or node == 0 then
        puddleSystem:removePuddle(self)
        return
    end

    link(getRootNode(), node)
    
    setVisibility(node, true)
    setWorldTranslation(node, unpack(self.position))
    setScale(node, self.size[1], 1.75, self.size[2])
    setWorldRotation(node, unpack(self.rotation))

    self.node = node

    for i = 0, variation.shapes - 1 do

        local shape = getChildAt(node, i)

        -- Configura il piano d'acqua (reflection map, shadow, collisione) in base al profilo grafico.
        PuddleSystem.onCreateWater(shape)

        local shapeName = getName(shape)

        local innerPoints = getChild(shape, shapeName .. "Inner")
        local path = shapeName .. "Inner"

        self.points.inner[shapeName] = {}
        self.points.outer[shapeName] = {}

        self.shapes[shapeName] = shape
        
        -- Popola l'anello interno: punti usati per verificare ancoraggio al terreno.
        for j = 0, variation.groups[path] - 1 do

            local point = getChild(innerPoints, path .. (j + 1))
            local x, y, z = getWorldTranslation(point)
            local t = getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z)
            self.points.inner[shapeName][j + 1] = { ["node"] = point, ["x"] = x, ["y"] = y, ["z"] = z, ["t"] = t }

        end

        local outerPoints = getChild(shape, shapeName .. "Outer")
        path = shapeName .. "Outer"
        
        -- Popola l'anello esterno: punti usati per il ray-casting e l'ancoraggio al terreno.
        for j = 0, variation.groups[path] - 1 do

            local point = getChild(outerPoints, path .. (j + 1))
            local x, y, z = getWorldTranslation(point)
            local t = getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z)
            self.points.outer[shapeName][j + 1] = { ["node"] = point, ["x"] = x, ["y"] = y, ["z"] = z, ["t"] = t }

        end


        local feelerGroup = getChild(shape, shapeName .. "Feelers")

        -- Popola i feeler: ogni feeler ha un nodo sensore (esterno), un connettore (anello esterno)
        -- e una base (anello interno), usati per calcolare il flusso laterale della pozzanghera.
        for j = 0, variation.groups[shapeName .. "Feelers"] - 1 do

            local feelerNode = getChildAt(feelerGroup, j)
            local feelerName = getName(feelerNode)
            
            local p, _ = string.find(feelerName, "Feeler")
            local connectorId = getUserAttribute(feelerNode, "connector")
            local connectorNode = self.points.outer[shapeName][connectorId].node

            local baseId = getUserAttribute(feelerNode, "base")
            local baseNode = self.points.outer[shapeName][baseId].node
            
            self.feelers[string.sub(feelerName, 1, p - 1)] = { ["feeler"] = feelerNode, ["connector"] = connectorNode, ["base"] = baseNode }

        end


    end

    -- Applica le scale laterali iniziali alle due forme.
    setScale(self.shapes.left, self.widthLeft, 1, 1)
    setScale(self.shapes.right, self.widthRight, 1, 1)

end


-- Imposta la posizione della pozzanghera (senza applicarla al nodo 3D).
function Puddle:setPosition(x, y, z)
    
    self.position = table.pack(x, y, z)

end


-- Applica la posizione corrente al nodo 3D.
function Puddle:applyPosition()

    setWorldTranslation(self.node, unpack(self.position))

end


-- Imposta la scala (larghezza e altezza) della pozzanghera.
function Puddle:setScale(width, height)
    
    self.size = table.pack(width, height)

end


-- Applica la scala corrente al nodo 3D e alle due forme laterali.
function Puddle:applyScale()

    setScale(self.node, self.size[1], 1.75, self.size[2])
    setScale(self.shapes.left, self.widthLeft, 1, 1)
    setScale(self.shapes.right, self.widthRight, 1, 1)

end

-- Aggiorna il valore di umidità interno della pozzanghera.
function Puddle:setMoisture(moisture)

    self.moisture = moisture

end


-- Imposta la rotazione della pozzanghera.
function Puddle:setRotation(dx, dy, dz)

    self.rotation = table.pack(dx, dy, dz)

end


-- Applica la rotazione corrente al nodo 3D.
function Puddle:applyRotation()

    setWorldRotation(self.node, unpack(self.rotation))

end


-- Aggiorna la pozzanghera ogni tick (chiamato dal PuddleSystem in round-robin).
-- Logica principale:
--   1. Per ogni feeler: calcola le differenze di altezza terreno tra feeler/connettore/base
--      e adatta widthLeft/widthRight per simulare il flusso verso le zone più basse.
--   2. Calcola il delta dimensionale dall'umidità corrente del moistureSystem.
--   3. Elimina la pozzanghera se troppo piccola o sotto il terreno.
--   4. Ancora la pozzanghera al terreno tramite getHighestTerrainOffset.
-- @param moistureSystem  sistema di umidità del terreno per leggere il valore corrente
function Puddle:update(moistureSystem)

    local timescale = self.timeSinceLastUpdate
    local moisture = moistureSystem:getValuesAtCoords(self.position[1], self.position[3], { "moisture" }).moisture

    for name, feeler in pairs(self.feelers) do

        local fx, _, fz = getWorldTranslation(feeler.feeler)
        local cx, _, cz = getWorldTranslation(feeler.connector)
        local bx, _, bz = getWorldTranslation(feeler.base)

        -- Legge le altezze del terreno nei tre punti del feeler:
        --   ft = esterno (fuori dalla pozzanghera)
        --   ct = connettore (anello esterno)
        --   bt = base (anello interno)
        local ft = getTerrainHeightAtWorldPos(g_terrainNode, fx, 0, fz)
        local ct = getTerrainHeightAtWorldPos(g_terrainNode, cx, 0, cz)
        local bt = getTerrainHeightAtWorldPos(g_terrainNode, bx, 0, bz)

        -- cfd > 0: il connettore è più alto del feeler → l'acqua fluisce verso l'esterno (espansione)
        -- bcd > 0: la base è più alta del connettore → la forma si espande verso quel lato
        local cfd = ct - ft
        local bcd = bt - ct

        if bcd ~= 0 then
            if name == "left" then self.widthLeft = math.clamp(self.widthLeft + bcd * timescale * 0.00005, 0.1, 1.75) end
            if name == "right" then self.widthRight = math.clamp(self.widthRight + bcd * timescale * 0.00005, 0.1, 1.75) end
        end
        
        if bcd >= 0 and cfd > 0 then
            if name == "left" then self.widthLeft = math.clamp(self.widthLeft + cfd * timescale * 0.00005, 0.1, 1.75) end
            if name == "right" then self.widthRight = math.clamp(self.widthRight + cfd * timescale * 0.00005, 0.1, 1.75) end
        end

    end

    self.terrainHeight = self.terrainHeight or getTerrainHeightAtWorldPos(g_terrainNode, self.position[1], 0, self.position[3])

    -- Il delta dimensionale è proporzionale alla differenza tra umidità corrente e umidità memorizzata.
    local delta = (moisture - self.moisture) * timescale * 0.003
    local width, height = unpack(self.size)
    local y = self.position[2] + delta * 0.04

    width = math.clamp(width + delta, 0, 2)
    height = math.clamp(height + delta, 0, 2)

    -- Elimina la pozzanghera se è diventata troppo piccola o è finita sotto il terreno.
    if width <= 0 or height <= 0 or (self.widthLeft <= 0 and self.widthRight <= 0) or not self:getIsAboveGround() then
        self:delete()
        g_currentMission.puddleSystem:removePuddle(self)
        return
    end

    self:setScale(width, height)

    self.moisture = moisture


    -- Ancora la pozzanghera al terreno: l'anello esterno non deve mai essere sotto il suolo.
    -- Solo l'anello interno può essere leggermente sopra perché è inclinato ai bordi.
    local yOffset = self:getHighestTerrainOffset(y - self.position[2])
    if yOffset > 0 then y = self.position[2] - yOffset end

    self.position[2] = y

    self:applyPosition()
    self:applyScale()
    self:applyRotation()

    self.timeSinceLastUpdate = 0

    self:updateCachedCoords()

end


-- Verifica se un punto (x, z) è all'interno della pozzanghera.
-- Usa un algoritmo di ray-casting su tutti i poligoni dell'anello esterno.
-- @return true se il punto è dentro almeno uno dei poligoni
function Puddle:getIsPointInsidePuddle(x, z)

    local inside = false
    local shapes = self.points.outer

    for _, polygon in pairs(shapes) do

        local p1 = polygon[1]
        local p2

        for i = 1, #polygon do

            p2 = polygon[(i % #polygon) + 1]

            if z > math.min(p1.z, p2.z) and z <= math.max(p1.z, p2.z) and x <= math.max(p1.x, p2.x) then

                local intersection = (z - p1.z) * (p2.x - p1.x) / (p2.z - p1.z) + p1.x

                if p1.x == p2.x or x <= intersection then inside = not inside end

            end

            p1 = p2

        end

        if inside then return true end

    end

    return inside

end


-- Aggiorna le coordinate mondo memorizzate in cache per tutti i punti inner/outer.
-- Chiamato dopo ogni update per mantenere sincronizzati i dati topografici.
function Puddle:updateCachedCoords()

    for i, pointType in pairs(self.points) do
        for j, shape in pairs(pointType) do
            for k, point in pairs(shape) do
              
                local x, y, z = getWorldTranslation(point.node)
                point.x, point.y, point.z = x, y, z
                point.t = getTerrainHeightAtWorldPos(g_terrainNode, x, y, z)

            end
        end
    end

end


-- Calcola il massimo offset verticale tra i punti dell'anello esterno e il terreno sottostante.
-- Usato per capire di quanto abbassare la pozzanghera per non bucare il terreno.
-- @param delta  spostamento verticale proposto
-- @return offset positivo da sottrarre alla posizione Y se l'anello esterno è sotto il suolo
function Puddle:getHighestTerrainOffset(delta)

    local maxOffset = 0
    
    for _, shape in pairs(self.points.outer) do

        for _, point in pairs(shape) do

            local offset = point.y + delta - point.t
            if offset > maxOffset then maxOffset = offset end

        end

    end

    return maxOffset

end


-- Verifica se almeno un punto (inner o outer) è sopra il terreno.
-- Se tutti i punti sono sotto il suolo, la pozzanghera viene eliminata.
function Puddle:getIsAboveGround()

    for _, pointType in pairs(self.points) do
        for _, shape in pairs(pointType) do
            for _, point in pairs(shape) do
                if point.y >= point.t then return true end
            end
        end
    end

    return false

end


-- Serializza la pozzanghera nello stream di rete (per NewPuddleEvent e PuddleSystemStateEvent).
function Puddle:writeStream(streamId)

    streamWriteUInt8(streamId, self.variation)
    streamWriteFloat32(streamId, self.size[1])
    streamWriteFloat32(streamId, self.size[2])
    streamWriteFloat32(streamId, self.position[1])
    streamWriteFloat32(streamId, self.position[2])
    streamWriteFloat32(streamId, self.position[3])
    streamWriteFloat32(streamId, self.rotation[1])
    streamWriteFloat32(streamId, self.rotation[2])
    streamWriteFloat32(streamId, self.rotation[3])
    streamWriteFloat32(streamId, self.moisture)
    streamWriteFloat32(streamId, self.terrainHeight)
    streamWriteFloat32(streamId, self.timeSinceLastUpdate)
    streamWriteFloat32(streamId, self.widthLeft)
    streamWriteFloat32(streamId, self.widthRight)

end


-- Deserializza la pozzanghera dallo stream di rete.
-- @return true se la lettura è andata a buon fine
function Puddle:readStream(streamId)

    self.variation = streamReadUInt8(streamId)
    self.size[1] = streamReadFloat32(streamId)
    self.size[2] = streamReadFloat32(streamId)
    self.position[1] = streamReadFloat32(streamId)
    self.position[2] = streamReadFloat32(streamId)
    self.position[3] = streamReadFloat32(streamId)
    self.rotation[1] = streamReadFloat32(streamId)
    self.rotation[2] = streamReadFloat32(streamId)
    self.rotation[3] = streamReadFloat32(streamId)
    self.moisture = streamReadFloat32(streamId)
    self.terrainHeight = streamReadFloat32(streamId)
    self.timeSinceLastUpdate = streamReadFloat32(streamId)
    self.widthLeft = streamReadFloat32(streamId)
    self.widthRight = streamReadFloat32(streamId)

    return true

end
