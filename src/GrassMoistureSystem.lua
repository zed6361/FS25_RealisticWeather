-- GrassMoistureSystem.lua
-- Sistema di umidità per l'erba falciata (windrow).
-- Traccia le aree di erba sfalciata sulla mappa e simula l'essiccazione nel tempo.
-- Quando l'umidità di un'area scende sotto HAY_MOISTURE (0.125 = 12.5%), l'erba
-- viene convertita in fieno (GRASS_WINDROW → DRYGRASS_WINDROW) usando DensityMapHeightUtil.
--
-- Architettura:
--   - areaToGrass: lista di aree {sx, sz, wx, wz, hx, hz, moisture}
--   - moistureDelta: variazione cumulata di umidità nell'intervallo corrente
--   - L'aggiornamento avviene ogni TICKS_PER_UPDATE (250) tick di gioco
--   - delta > 0 (pioggia) → guadagno amplificato da grassMoistureGainModifier × 0.5
--   - delta < 0 (asciutto) → perdita amplificata da grassMoistureLossModifier × 1.5
--
-- Hook registrati (solo server):
--   PlayerInputComponent.update → RW_PlayerInputComponent.update (rileva la falciatura)
--   PlayerHUDUpdater.update     → RW_PlayerHUDUpdater.update (aggiornamento overlay)

GrassMoistureSystem = {}

-- Umidità soglia sotto la quale l'erba diventa fieno (valore agronomi: 12.5%).
GrassMoistureSystem.HAY_MOISTURE = 0.125
-- Numero di tick tra un aggiornamento e il successivo.
GrassMoistureSystem.TICKS_PER_UPDATE = 250

local grassMoistureSystem_mt = Class(GrassMoistureSystem)


-- Crea il GrassMoistureSystem e lo registra in g_currentMission.
-- Solo sul server: carica lo stato dal savegame e aggancia gli hook su PlayerInputComponent
-- e PlayerHUDUpdater per rilevare la falciatura dell'erba.
function GrassMoistureSystem.loadMap()
    g_currentMission.grassMoistureSystem = GrassMoistureSystem.new()

    if g_currentMission:getIsServer() then
        g_currentMission.grassMoistureSystem:loadFromXMLFile()
        PlayerInputComponent.update = Utils.appendedFunction(PlayerInputComponent.update, RW_PlayerInputComponent.update)
        PlayerHUDUpdater.update = Utils.appendedFunction(PlayerHUDUpdater.update, RW_PlayerHUDUpdater.update)
    end
end


-- Costruttore. Inizializza le strutture dati e i modificatori di default.
function GrassMoistureSystem.new()

    local self = setmetatable({}, grassMoistureSystem_mt)

    self.mission = g_currentMission
    self.areaToGrass = {}             -- lista delle aree di erba tracciate
    self.moistureDelta = 0            -- variazione umidità accumulata nell'intervallo corrente
    self.ticksSinceLastUpdate = GrassMoistureSystem.TICKS_PER_UPDATE + 1  -- forza aggiornamento al primo tick
    self.isServer = self.mission:getIsServer()
    self.grassMoistureGainModifier = 1  -- moltiplicatore configurabile per il guadagno di umidità
    self.grassMoistureLossModifier = 1  -- moltiplicatore configurabile per la perdita di umidità

    return self

end


-- Distrugge il sistema (rilascia il riferimento).
function GrassMoistureSystem:delete()
    self = nil
end


-- Aggiorna il sistema ogni tick del gioco.
-- Se non ci sono aree da tracciare, azzera moistureDelta e torna.
-- Ogni TICKS_PER_UPDATE tick:
--   1. Applica moistureDelta accumulato all'umidità di ogni area.
--   2. Se moisture <= HAY_MOISTURE: converte l'area da erba a fieno (solo server)
--      e la aggiunge alla lista di rimozione.
--   3. Rimuove le aree convertite dalla lista.
--   4. Azzera moistureDelta.
-- @param delta  variazione di umidità da applicare (positivo = pioggia, negativo = asciutto)
function GrassMoistureSystem:update(delta)

    if #self.areaToGrass == 0 then
        self.moistureDelta = 0
        return
    end

    local linesToRemove = {}

    -- Amplifica il delta in base alla direzione: guadagno ridotto (× 0.5), perdita aumentata (× 1.5).
    delta = delta * (delta > 0 and (0.5 * self.grassMoistureGainModifier) or (1.5 * self.grassMoistureLossModifier))
    self.moistureDelta = self.moistureDelta + delta

    if self.ticksSinceLastUpdate >= GrassMoistureSystem.TICKS_PER_UPDATE then

        self.ticksSinceLastUpdate = 0
        local grassFillType = g_fillTypeManager:getFillTypeIndexByName("GRASS_WINDROW")
        local hayFillType = g_fillTypeManager:getFillTypeIndexByName("DRYGRASS_WINDROW")

        for i, line in pairs(self.areaToGrass) do

            line.moisture = line.moisture + self.moistureDelta

            -- Conversione erba → fieno: solo sul server, solo se i fillType sono disponibili.
            if line.moisture <= GrassMoistureSystem.HAY_MOISTURE then

                if self.isServer and grassFillType ~= nil and hayFillType ~= nil then DensityMapHeightUtil.changeFillTypeAtArea(line.sx, line.sz, line.wx, line.wz, line.hx, line.hz, grassFillType, hayFillType) end
                table.insert(linesToRemove, i)

            end

        end

        self.moistureDelta = 0

        -- Rimozione in ordine inverso per non invalidare gli indici.
        for i = #linesToRemove, 1, -1 do table.remove(self.areaToGrass, linesToRemove[i]) end

    end

    self.ticksSinceLastUpdate = self.ticksSinceLastUpdate + 1

end


-- Carica le aree di erba salvate da grassMoisture.xml nel savegame corrente.
-- Ogni area contiene: moisture, sx, sz, wx, wz, hx, hz (parallelogramma in coordinate mondo).
function GrassMoistureSystem:loadFromXMLFile()

    local savegameIndex = g_careerScreen.savegameList.selectedIndex
    local savegame = g_savegameController:getSavegame(savegameIndex)

    if savegame == nil or savegame.savegameDirectory == nil then return end

    local path = savegame.savegameDirectory .. "/grassMoisture.xml"

    local xmlFile = XMLFile.loadIfExists("grassMoistureXML", path)
    if xmlFile == nil then return end

    local key = "grassMoisture"

    xmlFile:iterate(key .. ".areas.area", function (_, areaKey)

        local newArea = {
            moisture = xmlFile:getFloat(areaKey .. "#moisture", 0),
            sx = xmlFile:getFloat(areaKey .. "#sx", 0),
            sz = xmlFile:getFloat(areaKey .. "#sz", 0),
            wx = xmlFile:getFloat(areaKey .. "#wx", 0),
            wz = xmlFile:getFloat(areaKey .. "#wz", 0),
            hx = xmlFile:getFloat(areaKey .. "#hx", 0),
            hz = xmlFile:getFloat(areaKey .. "#hz", 0)
        }

        table.insert(self.areaToGrass, newArea)

    end)

end


-- Salva tutte le aree di erba tracciate in grassMoisture.xml.
-- @param path  percorso completo del file di destinazione
function GrassMoistureSystem:saveToXMLFile(path)

    if path == nil then return end

    local xmlFile = XMLFile.create("grassMoistureXML", path, "grassMoisture")
    if xmlFile == nil then return end

    local key = "grassMoisture"

    xmlFile:setTable(key .. ".areas.area", self.areaToGrass, function (areaKey, area)

        xmlFile:setFloat(areaKey .. "#moisture", area.moisture)
        xmlFile:setFloat(areaKey .. "#sx", area.sx)
        xmlFile:setFloat(areaKey .. "#sz", area.sz)
        xmlFile:setFloat(areaKey .. "#wx", area.wx)
        xmlFile:setFloat(areaKey .. "#wz", area.wz)
        xmlFile:setFloat(areaKey .. "#hx", area.hx)
        xmlFile:setFloat(areaKey .. "#hz", area.hz)

    end)

    xmlFile:save(false, true)

    xmlFile:delete()

end


-- Restituisce l'umidità corrente di un'area di erba che contiene il punto (x, z).
-- Usa un test AABB (bounding box allineato agli assi) sul segmento sx→wx e sz→wz.
-- @return found (bool), moisture (float|nil)
function GrassMoistureSystem:getMoistureAtArea(x, z)

    for _, line in pairs(self.areaToGrass) do

        -- Verifica se x è nel range [min(sx,wx), max(sx,wx)] e z nel range [min(sz,wz), max(sz,wz)].
        if ((line.sx >= line.wx and line.sx >= x and line.wx <= x) or (line.sx <= line.wx and line.sx <= x and line.wx >= x)) and ((line.sz >= line.wz and line.sz >= z and line.wz <= z) or (line.sz <= line.wz and line.sz <= z and line.wz >= z)) then
            return true, line.moisture + self.moistureDelta
        end

    end

    return false, nil

end


-- Aggiunge un'area di erba appena sfalciata alla lista di tracciamento.
-- L'umidità iniziale è la media delle umidità del terreno nei tre punti del parallelogramma,
-- ridotta all'85% (l'erba sfalciata perde subito parte dell'umidità al taglio).
-- @param sx, sz  punto di partenza del parallelogramma
-- @param wx, wz  vettore larghezza
-- @param hx, hz  vettore altezza
function GrassMoistureSystem:addArea(sx, sz, wx, wz, hx, hz)

    local moistureSystem = g_currentMission.moistureSystem

    if moistureSystem == nil then return end

    local target = { "moisture" }

    -- Legge l'umidità del terreno nei tre punti del parallelogramma.
    local startMoistureValues = moistureSystem:getValuesAtCoords(sx, sz, target)
    local widthMoistureValues = moistureSystem:getValuesAtCoords(wx, wz, target)
    local heightMoistureValues = moistureSystem:getValuesAtCoords(hx, hz, target)

    local startMoisture, widthMoisture, heightMoisture = 0, 0, 0

    if startMoistureValues ~= nil and startMoistureValues.moisture ~= nil then startMoisture = startMoistureValues.moisture end
    if widthMoistureValues ~= nil and widthMoistureValues.moisture ~= nil then widthMoisture = widthMoistureValues.moisture end
    if heightMoistureValues ~= nil and heightMoistureValues.moisture ~= nil then heightMoisture = heightMoistureValues.moisture end

    -- Media dei tre punti, ridotta all'85% per simulare la perdita iniziale al taglio.
    local averageMoisture = (startMoisture + widthMoisture + heightMoisture) / 3

    local newAreaToGrass = {
        moisture = averageMoisture * 0.85,
        sx = sx,
        sz = sz,
        wx = wx,
        wz = wz,
        hx = hx,
        hz = hz
    }

    table.insert(self.areaToGrass, newAreaToGrass)

end


-- Callback per il cambio delle impostazioni (chiamato da RWSettings).
-- Aggiorna grassMoistureGainModifier o grassMoistureLossModifier sul sistema.
-- @param name   nome dell'impostazione (es. "grassMoistureGainModifier")
-- @param state  nuovo valore numerico
function GrassMoistureSystem.onSettingChanged(name, state)

    local grassMoistureSystem = g_currentMission.grassMoistureSystem

    if grassMoistureSystem == nil then return end

    grassMoistureSystem[name] = state

end
