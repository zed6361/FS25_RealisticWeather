-- PuddleSystem.lua
-- Gestore globale delle pozzanghere nel mondo di gioco.
-- Responsabilità principali:
--   - Caricamento delle varianti grafiche da puddles.xml (i3d con geometria e gruppi di punti)
--   - Creazione, aggiunta, rimozione delle pozzanghere con limite basato sul profilo grafico
--   - Aggiornamento in round-robin (una pozzanghera per tick) per distribuire il carico
--   - Salvataggio/caricamento delle pozzanghere nel savegame XML
--   - Configurazione del piano d'acqua (reflection map, shadow, collisione) per ogni forma
--   - Gestione dell'impostazione puddlesEnabled (distrugge tutte le pozzanghere se disabilitata)

PuddleSystem = {}

local puddleSystem_mt = Class(PuddleSystem)
local modDirectory = g_currentModDirectory

-- Numero massimo di pozzanghere simultanee, scalato con il profilo di performance grafica.
PuddleSystem.maxPuddles = Utils.getPerformanceClassId() * 4


-- Costruttore. Inizializza le liste interne e lo stato del sistema.
function PuddleSystem.new()

    local self = setmetatable({}, puddleSystem_mt)

    self.puddles = {}           -- lista delle pozzanghere attive
    self.variations = {}        -- varianti grafiche caricate da puddles.xml
    self.updateIteration = 1    -- indice round-robin per l'aggiornamento delle pozzanghere
    self.timeSinceLastUpdate = 0
    self.isServer = g_currentMission:getIsServer()
    self.puddlesEnabled = true

    return self

end


-- Configura un nodo forma come piano d'acqua: reflection map, shadow, collisione.
-- Viene chiamato da Puddle:initialize() per ogni shape clonata dalla variante.
-- Gestisce profili diversi: Medium/Console → no reflections, High → reflections base, VeryHigh → reflections full.
-- Emette warning se il nodo ha configurazioni errate (shadow cast, no shadow receive, collisione mancante).
-- @param node  nodo i3d della forma acqua da configurare
function PuddleSystem.onCreateWater(node)

	if getHasClassId(node, ClassIds.SHAPE) then

		if not Utils.getNoNil(getUserAttribute(node, "useShapeObjectMask"), false) then
			local mask = bitAND(getObjectMask(node), bitNOT(ObjectMask.SHAPE_VIS_MIRROR))
			setObjectMask(node, mask)
		end

		if getShapeCastShadowmap(node) then
			Logging.i3dWarning(node, "PuddleSystem:onCreateWater(): Water plane has shadow casting active")
		end

		if not getShapeReceiveShadowmap(node) then
			Logging.i3dWarning(node, "PuddleSystem:onCreateWater(): Water plane is missing shadow receive")
		end

		local performanceClass = Utils.getPerformanceClassId()

		if performanceClass <= GS_PROFILE_MEDIUM or GS_IS_CONSOLE_VERSION then
			-- Profilo basso o console: disabilita completamente le reflection.
			setReflectionMapScaling(node, 0, true)
		elseif performanceClass <= GS_PROFILE_HIGH then
			-- Profilo medio: reflection base con maschere standard per l'acqua.
			setReflectionMapObjectMasks(node, ObjectMask.SHAPE_VIS_WATER_REFL, ObjectMask.LIGHT_VIS_WATER_REFL, true)
		else
			-- Profilo alto: reflection di qualità massima.
			setReflectionMapObjectMasks(node, ObjectMask.SHAPE_VIS_WATER_REFL_VERYHIGH, ObjectMask.LIGHT_VIS_WATER_REFL_VERYHIGH, true)
		end

		if getRigidBodyType(node) ~= RigidBodyType.NONE then
			if not CollisionFlag.getHasGroupFlagSet(node, CollisionFlag.WATER) then
				Logging.i3dWarning(node, "PuddleSystem:onCreateWater(): Water plane is missing %s", CollisionFlag.getBitAndName(CollisionFlag.WATER))
			end
			if g_currentMission.shallowWaterSimulation ~= nil then
				g_currentMission.shallowWaterSimulation:addWaterPlane(node)
				g_currentMission.shallowWaterSimulation:addAreaGeometry(node)
			end
		end

	else
		Logging.i3dError(node, "PuddleSystem:onCreateWater(): Given node is not a shape, ignoring")
	end

end


-- Carica le varianti grafiche da xml/puddles.xml e, se siamo sul server,
-- carica anche le pozzanghere salvate nel savegame.
-- Per ogni variante: carica il file i3d, analizza la gerarchia dei nodi figli
-- e memorizza il numero di punti per ogni gruppo (inner, outer, feelers).
function PuddleSystem:loadVariations()

    local xmlFile = XMLFile.loadIfExists("PuddleSystem", modDirectory .. "xml/puddles.xml")

    if xmlFile == nil then return end

    local rootNode = getRootNode()

    xmlFile:iterate("variations.variation", function (_, key)

        local path = xmlFile:getString(key .. "#file")
        local id = xmlFile:getInt(key .. "#id")
        local node = g_i3DManager:loadI3DFile(modDirectory .. path, false, false)

        if node ~= 0 then
            
            link(rootNode, node)
            
            setVisibility(node, false)
            setWorldTranslation(node, 0, 0, 0)
            local numShapes = getNumOfChildren(node)
            local groups = {}

            -- Analizza la gerarchia del nodo per contare i punti di ogni gruppo (inner/outer/feelers).
            for i = 0, numShapes - 1 do

                local shapeNode = getChildAt(node, i)
                local shapeChildren = getNumOfChildren(shapeNode)

                for j = 0, shapeChildren - 1 do

                    local group = getChildAt(shapeNode, j)
                    local groupName = getName(group)
                    local groupChildren = getNumOfChildren(group)

                    groups[groupName] = groupChildren

                end

            end

            table.insert(self.variations, { ["node"] = node, ["path"] = path, ["id"] = id, ["groups"] = groups, ["shapes"] = numShapes })

        end

    end)

    xmlFile:delete()

    if self.isServer then self:loadFromXMLFile() end

end


-- Carica le pozzanghere salvate dal file puddles.xml nel savegame corrente.
-- Chiamato solo sul server durante loadVariations().
function PuddleSystem:loadFromXMLFile()

    local savegameIndex = g_careerScreen.savegameList.selectedIndex
    local savegame = g_savegameController:getSavegame(savegameIndex)

    if savegame == nil or savegame.savegameDirectory == nil then return end

    local xmlFile = XMLFile.loadIfExists("puddlesXML", savegame.savegameDirectory .. "/puddles.xml")

    if xmlFile == nil then return end

    xmlFile:iterate("puddles.puddle", function(_, key)

        local puddle = Puddle.new()
        local success = puddle:loadFromXMLFile(xmlFile, key)

        if success then table.insert(self.puddles, puddle) end

    end)

    xmlFile:delete()

end


-- Salva tutte le pozzanghere attive nel file puddles.xml del savegame.
-- @param path  percorso completo del file di destinazione
function PuddleSystem:saveToXMLFile(path)

    if path == nil then return end

    local xmlFile = XMLFile.create("puddlesXML", path, "puddles")
    if xmlFile == nil then return end

    for i = 1, #self.puddles do

        local puddle = self.puddles[i]
        puddle:saveToXMLFile(xmlFile, string.format("puddles.puddle(%d)", i - 1))

    end

    xmlFile:save(false, true)

    xmlFile:delete()

end


-- Inizializza nella scena 3D tutte le pozzanghere già presenti nella lista
-- (caricate dal savegame o ricevute via PuddleSystemStateEvent).
function PuddleSystem:initialize()

    for _, puddle in pairs(self.puddles) do puddle:initialize() end

end


-- Restituisce la variante grafica con l'id specificato, o nil se non trovata.
function PuddleSystem:getVariationById(id)

    for _, variation in pairs(self.variations) do

        if variation.id == id then return variation end

    end

    return nil

end


-- Restituisce una variante grafica casuale tra quelle disponibili.
function PuddleSystem:getRandomVariation()
    return self.variations[math.random(1, #self.variations)]
end


-- Aggiunge una pozzanghera alla lista delle pozzanghere attive.
function PuddleSystem:addPuddle(puddle)

    table.insert(self.puddles, puddle)

end


-- Rimuove una pozzanghera specifica dalla lista.
function PuddleSystem:removePuddle(puddle)

    for i, p in pairs(self.puddles) do
        if p == puddle then
            table.remove(self.puddles, i)
            puddle = nil
            break
        end
    end

end


-- Restituisce la pozzanghera più vicina al punto (x, z) nel mondo.
-- @return tabella { distance, puddle } con la pozzanghera più vicina trovata
function PuddleSystem:getClosestPuddleToPoint(x, z)

    local closestPoint = { ["distance"] = 10000, ["puddle"] = nil }

    for _, puddle in pairs(self.puddles) do

        local distance = MathUtil.vector2Length(x - puddle.position[1], z - puddle.position[3])
        
        if closestPoint.puddle == nil or closestPoint.distance > distance then closestPoint = { ["distance"] = distance, ["puddle"] = puddle } end 

    end

    return closestPoint

end


-- Aggiorna il sistema di pozzanghere ogni tick del gioco.
-- Strategia round-robin: si aggiorna una sola pozzanghera per chiamata,
-- accumulando il timescale per le altre tramite timeSinceLastUpdate.
-- Le pozzanghere con nodo non valido vengono rimosse automaticamente.
-- @param timescale      tempo trascorso dall'ultimo tick
-- @param moistureSystem sistema di umidità per la lettura del terreno
function PuddleSystem:update(timescale, moistureSystem)

    if moistureSystem == nil or moistureSystem.isSaving or not self.puddlesEnabled then return end

    -- Accumula il timescale su tutte le pozzanghere non ancora aggiornate questo tick.
    for _, puddle in pairs(self.puddles) do

        puddle.timeSinceLastUpdate = puddle.timeSinceLastUpdate + timescale + self.timeSinceLastUpdate

    end

    self.timeSinceLastUpdate = 0

    local puddle = self.puddles[self.updateIteration] or self.puddles[1]

    if puddle == nil then return end

    self.updateIteration = self.updateIteration + 1
    if self.updateIteration > #self.puddles then self.updateIteration = 1 end

    if puddle.node ~= nil and puddle.node ~= 0 then
        puddle:update(moistureSystem)
    elseif puddle ~= nil then
        if puddle.node ~= 0 and puddle.node ~= nil then puddle:delete() end
        self:removePuddle(puddle)
        self.updateIteration = self.updateIteration - 1
    end

end


-- Verifica se è possibile creare una nuova pozzanghera.
-- Solo il server può creare pozzanghere, il sistema deve essere abilitato
-- e non deve essere stato raggiunto il limite massimo.
function PuddleSystem:getCanCreatePuddle()
    return self.isServer and #self.puddles < PuddleSystem.maxPuddles and self.puddlesEnabled
end


-- Restituisce la pozzanghera che contiene il punto (x, z), o nil se nessuna la contiene.
function PuddleSystem:getPuddleAtCoords(x, z)

    for _, puddle in pairs(self.puddles) do

        if puddle:getIsPointInsidePuddle(x, z) then return puddle end

    end

    return nil

end


-- Aggiorna le coordinate mondo in cache per tutte le pozzanghere con nodo valido.
function PuddleSystem:updateCachedCoords()

    for _, puddle in pairs(self.puddles) do
        if puddle.node ~= 0 then puddle:updateCachedCoords() end
    end

end


-- Callback per il cambio delle impostazioni (chiamato da RWSettings).
-- Se puddlesEnabled viene impostato a false, distrugge e rimuove tutte le pozzanghere attive.
-- @param name   nome dell'impostazione modificata (es. "puddlesEnabled")
-- @param state  nuovo valore dell'impostazione
function PuddleSystem.onSettingChanged(name, state)

    local puddleSystem = g_currentMission.puddleSystem

    if puddleSystem == nil then return end

    puddleSystem[name] = state

    if name == "puddlesEnabled" and not state and puddleSystem.puddles ~= nil then

        for i = #puddleSystem.puddles, 1, -1 do

            local puddle = puddleSystem.puddles[i]
            puddle:delete()
            table.remove(puddleSystem.puddles, i)

        end

    end

end
