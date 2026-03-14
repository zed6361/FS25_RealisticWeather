-- =============================================================================
-- RealisticWeather.lua
-- Mod per Farming Simulator che modifica la resa del raccolto in base
-- all'umidità del terreno rilevata nell'area di lavoro degli attrezzi.
-- =============================================================================

RealisticWeather = {}
local RealisticWeather_mt = Class(RealisticWeather)
local modDirectory = g_currentModDirectory

-- Carica l'estensione GUI per la mappa in-game (al momento disabilitata)
-- source(modDirectory .. "src/gui/InGameMenuMapFrameExtension.lua")

-- Carica il file di test per l'ottimizzazione delle prestazioni
source(modDirectory .. "src/test/OptimisationTest.lua")


-- -----------------------------------------------------------------------------
-- RealisticWeather.new()
-- Costruttore della classe. Crea una nuova istanza di RealisticWeather e
-- inizializza la lista delle funzioni di gioco da sovrascrivere/estendere.
-- -----------------------------------------------------------------------------
function RealisticWeather.new()

	local self = setmetatable({}, RealisticWeather_mt)

    -- Tabella che raccoglie tutte le funzioni vanilla da patchare al caricamento della mappa
    self.changedFunctions = {}

	return self

end


-- -----------------------------------------------------------------------------
-- RealisticWeather:initialise()
-- Metodo di inizializzazione del mod. Predisposto per abilitare estensioni GUI
-- (attualmente commentate). Viene chiamato subito dopo la creazione dell'istanza.
-- -----------------------------------------------------------------------------
function RealisticWeather:initialise()

    -- Inizializzazione dell'estensione della mappa in-game (al momento disabilitata)
    -- self.inGameMenuMapFrameExtension = InGameMenuMapFrameExtension.new()
    -- self.inGameMenuMapFrameExtension:overwriteGameFunctions()

end


-- -----------------------------------------------------------------------------
-- RealisticWeather.loadMap()
-- Callback chiamata da Farming Simulator al caricamento della mappa.
-- Applica tutte le modifiche alle funzioni vanilla registrate in precedenza.
-- -----------------------------------------------------------------------------
function RealisticWeather.loadMap()

    g_realisticWeather:executeFunctionChanges()

end


-- -----------------------------------------------------------------------------
-- RealisticWeather:registerFunction(object, oldFunc, newFunc, changeFunc)
-- Registra una funzione di gioco da modificare. Le modifiche vengono accumulate
-- nella tabella changedFunctions e applicate poi tutte insieme in executeFunctionChanges().
--
-- Parametri:
--   object     : oggetto/classe che contiene la funzione da modificare (es. FSBaseMission)
--   oldFunc    : nome (stringa) della funzione originale da sovrascrivere
--   newFunc    : nuova funzione che sostituirà o avvolgerà quella originale
--   changeFunc : tipo di modifica da applicare (default: "overwritten").
--                Corrisponde al prefisso del metodo Utils usato (es. "overwritten" → Utils.overwrittenFunction)
-- -----------------------------------------------------------------------------
function RealisticWeather:registerFunction(object, oldFunc, newFunc, changeFunc)

	table.insert(self.changedFunctions, {
		["object"] = object,
		["oldFunc"] = oldFunc,
		["newFunc"] = newFunc,
		["changeFunc"] = changeFunc or "overwritten"  -- default: sovrascrittura totale
	})

end


-- -----------------------------------------------------------------------------
-- RealisticWeather:executeFunctionChanges()
-- Itera su tutte le funzioni registrate e applica il patching usando
-- il meccanismo Utils di Farming Simulator (es. Utils.overwrittenFunction),
-- che permette di sostituire o wrappare funzioni vanilla in modo compatibile
-- con altri mod attivi.
-- -----------------------------------------------------------------------------
function RealisticWeather:executeFunctionChanges()

	for _, func in pairs(self.changedFunctions) do

        -- Usa Utils.[changeFunc]Function per applicare il patching in modo sicuro
		func.object[func.oldFunc] = Utils[func.changeFunc .. "Function"](func.object[func.oldFunc], func.newFunc)

	end

end


-- -----------------------------------------------------------------------------
-- RealisticWeather:getMoistureFromWorkArea(workArea)
-- Calcola il valore medio di umidità del terreno nell'area di lavoro fornita.
-- Legge l'umidità in 3 punti (start, width, height) dell'area tramite
-- il sistema moistureSystem della missione corrente, e restituisce la media.
--
-- Parametri:
--   workArea : tabella con i nodi 3D start/width/height dell'area di lavoro
--
-- Ritorna:
--   valore medio di umidità (float), oppure nil se workArea è nil
-- -----------------------------------------------------------------------------
function RealisticWeather:getMoistureFromWorkArea(workArea)

    if workArea == nil then return nil end

    -- Ottiene le coordinate mondo dei tre punti che definiscono l'area di lavoro
    local xs, _ ,zs = getWorldTranslation(workArea.start)
    local xw, _, zw = getWorldTranslation(workArea.width)
    local xh, _, zh = getWorldTranslation(workArea.height)

    -- Definisce il campo da leggere dal sistema di umidità
    local target = { "moisture" }

    -- Legge l'umidità nei tre punti dell'area
    local startMoistureValues = g_currentMission.moistureSystem:getValuesAtCoords(xs, zs, target)
    local widthMoistureValues = g_currentMission.moistureSystem:getValuesAtCoords(xw, zw, target)
    local heightMoistureValues = g_currentMission.moistureSystem:getValuesAtCoords(xh, zh, target)

    -- Estrae il valore numerico, usando 0 come fallback se il dato non è disponibile
    local startMoisture = startMoistureValues ~= nil and startMoistureValues.moisture ~= nil and startMoistureValues.moisture or 0
    local widthMoisture = widthMoistureValues ~= nil and widthMoistureValues.moisture ~= nil and widthMoistureValues.moisture or 0
    local heightMoisture = heightMoistureValues ~= nil and heightMoistureValues.moisture ~= nil and heightMoistureValues.moisture or 0

    -- Restituisce la media dei tre valori rilevati
    return (startMoisture + widthMoisture + heightMoisture) / 3

end


-- -----------------------------------------------------------------------------
-- RealisticWeather:preProcessMowerArea(mower, workArea, dt)
-- Hook chiamato PRIMA che la falciatrice elabori la propria area di lavoro.
-- Campiona e salva l'umidità locale dell'area, rendendola disponibile
-- al calcolo della resa durante l'operazione.
--
-- Parametri:
--   mower    : oggetto falciatrice
--   workArea : area di lavoro corrente
--   dt       : delta time
-- -----------------------------------------------------------------------------
function RealisticWeather:preProcessMowerArea(mower, workArea, dt)

    -- Salva l'umidità dell'area prima che inizi la falciatura
    self.mowerMoisture = self:getMoistureFromWorkArea(workArea)

end


-- -----------------------------------------------------------------------------
-- RealisticWeather:postProcessMowerArea(mower, workArea, dt, lastChangedArea)
-- Hook chiamato DOPO che la falciatrice ha elaborato la propria area di lavoro.
-- Resetta il valore di umidità temporaneo salvato nel pre-process.
--
-- Parametri:
--   mower           : oggetto falciatrice
--   workArea        : area di lavoro corrente
--   dt              : delta time
--   lastChangedArea : area effettivamente modificata nell'ultimo frame
-- -----------------------------------------------------------------------------
function RealisticWeather:postProcessMowerArea(mower, workArea, dt, lastChangedArea)

    -- Pulisce il valore di umidità dopo la fine dell'operazione
    self.mowerMoisture = nil

end


-- -----------------------------------------------------------------------------
-- RealisticWeather:preProcessCutterArea(cutter, workArea, dt)
-- Hook chiamato PRIMA che la tagliatrice/mietitrebbia elabori la propria area.
-- Campiona e salva l'umidità locale dell'area per il calcolo della resa.
--
-- Parametri:
--   cutter   : oggetto tagliatrice/mietitrebbia
--   workArea : area di lavoro corrente
--   dt       : delta time
-- -----------------------------------------------------------------------------
function RealisticWeather:preProcessCutterArea(cutter, workArea, dt)

    -- Salva l'umidità dell'area prima che inizi il taglio/raccolta
    self.cutterMoisture = self:getMoistureFromWorkArea(workArea)

end


-- -----------------------------------------------------------------------------
-- RealisticWeather:postProcessCutterArea(cutter, workArea, dt, lastChangedArea)
-- Hook chiamato DOPO che la tagliatrice/mietitrebbia ha elaborato la propria area.
-- Resetta il valore di umidità temporaneo salvato nel pre-process.
--
-- Parametri:
--   cutter          : oggetto tagliatrice/mietitrebbia
--   workArea        : area di lavoro corrente
--   dt              : delta time
--   lastChangedArea : area effettivamente modificata nell'ultimo frame
-- -----------------------------------------------------------------------------
function RealisticWeather:postProcessCutterArea(cutter, workArea, dt, lastChangedArea)

    -- Pulisce il valore di umidità dopo la fine dell'operazione
    self.cutterMoisture = nil

end


-- =============================================================================
-- Istanziazione globale del mod e registrazione come listener degli eventi FS
-- =============================================================================
g_realisticWeather = RealisticWeather.new()
g_realisticWeather:initialise()
addModEventListener(RealisticWeather)


-- =============================================================================
-- Patch di FSBaseMission:getHarvestScaleMultiplier
--
-- Sovrascrive la funzione vanilla che calcola il moltiplicatore di resa del
-- raccolto, introducendo una correzione basata sull'umidità del terreno.
--
-- Logica:
--   1. Chiama la funzione originale con pcall per protezione dagli errori.
--   2. Se Precision Farming è attivo, restituisce la resa base senza modifiche.
--   3. Legge l'umidità corrente (da falciatrice, tagliatrice o campo).
--   4. Recupera i parametri di umidità ottimale per il tipo di coltura.
--   5. Calcola un moistureFactor:
--      - Massimo (1.0) in prossimità del valore di umidità perfetto.
--      - Ridotto progressivamente allontanandosi dal range ottimale [LOW, HIGH].
--      - Clampato tra 0.1 e 1.0 per evitare valori estremi.
--      - Bonus aggiuntivo se l'umidità è nel range ottimale.
--   6. Resa finale = baseYield + (-0.65 + moistureFactor) * moistureYieldFactor
--      (mai negativa grazie a math.max(..., 0))
-- =============================================================================
g_realisticWeather:registerFunction(FSBaseMission, "getHarvestScaleMultiplier", function(self, superFunc, fruitTypeIndex, sprayLevel, plowLevel, limeLevel, weedsLevel, stubbleLevel, rollerLevel, beeYieldBonusPercentage)

    -- RW_CRITICAL_FIX: chiama la funzione GIANTS originale in modo protetto per evitare crash
    local okBase, baseYield = pcall(superFunc, self, fruitTypeIndex, sprayLevel, plowLevel, limeLevel, weedsLevel, stubbleLevel, rollerLevel, beeYieldBonusPercentage)
    if not okBase then
        -- Se la funzione base fallisce, logga l'errore e restituisce 1 (nessuna modifica)
        print(string.format("RealisticWeather: getHarvestScaleMultiplier base call failed (%s)", tostring(baseYield)))
        return 1
    end

    -- RW_COMPAT_FIX: se Precision Farming è caricato, non interferire con il suo calcolo della resa
    if RW_FSBaseMission ~= nil and RW_FSBaseMission.isPrecisionFarmingLoaded then
        return baseYield
    end

    -- Verifica che il sistema di umidità sia disponibile nella missione corrente
    if g_currentMission == nil or g_currentMission.moistureSystem == nil then
        return baseYield
    end

    -- Legge l'umidità rilevante: priorità a falciatrice > tagliatrice > campo generico
    local moisture = g_realisticWeather.mowerMoisture or g_realisticWeather.cutterMoisture or g_realisticWeather.fieldMoisture

    -- Se non è disponibile alcun dato di umidità, restituisce la resa base invariata
    if moisture == nil then return baseYield end

    local moistureFactor = 1  -- valore di default (nessuna penalità)

    -- Recupera il nome della coltura dall'indice e i suoi parametri di umidità ottimale
    local fruitType = g_fruitTypeManager:getFruitTypeNameByIndex(fruitTypeIndex)
    local fruitTypeMoistureFactor = RW_FSBaseMission.FRUIT_TYPES_MOISTURE[fruitType] or RW_FSBaseMission.FRUIT_TYPES_MOISTURE.DEFAULT

    if fruitTypeMoistureFactor ~= nil then

        local lowMoisture = fruitTypeMoistureFactor.LOW        -- soglia minima ottimale
        local highMoisture = fruitTypeMoistureFactor.HIGH      -- soglia massima ottimale
        local perfectMoisture = (highMoisture + lowMoisture) / 2  -- valore ideale (punto di massima resa)

        -- Calcola il fattore come rapporto tra umidità attuale e umidità perfetta
        moistureFactor = moisture / perfectMoisture

        -- Specchia il fattore se l'umidità supera il valore perfetto (simmetria della curva)
        if moisture > perfectMoisture then moistureFactor = 2 - moistureFactor end

        -- Clamp: il fattore non può scendere sotto 0.1 né superare 1.0
        moistureFactor = math.clamp(moistureFactor, 0.1, 1)

        -- Bonus extra se l'umidità è nel range ottimale [LOW, HIGH]
        -- Il bonus scala in base a quanto ci si avvicina al valore perfetto
        if moisture >= lowMoisture and moisture <= highMoisture then moistureFactor = moistureFactor + math.max(1.5 - 2 * (1 - moistureFactor), 0.5) end

    end

    -- Resa finale: somma la resa base con la correzione per umidità, mai sotto zero
    return math.max(baseYield + (-0.65 + moistureFactor) * self.moistureYieldFactor, 0)

end)
