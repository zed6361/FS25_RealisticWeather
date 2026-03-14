-- FillTypeManager.lua (RW_FillTypeManager)
-- Override di FillTypeManager.loadFillTypes per aggiungere le categorie
-- di fillType personalizzate di RealisticWeather al gestore vanilla di FS25.
--
-- Il file XML del mod (xml/fillTypes.xml) definisce nuove fillTypeCategory
-- che associano fillType vanilla a categorie custom necessarie per la logica RW
-- (es. categorie usate da Sprayer.lua per distinguere acqua da fertilizzanti,
-- o da Weather.lua per identificare le balle degradabili sotto la pioggia).
--
-- Meccanismo:
--   1. Chiama prima la superFunc vanilla per caricare i fillType standard.
--   2. Verifica il flag isLoaded per garantire che il caricamento RW avvenga
--      una sola volta (il vanilla può chiamare loadFillTypes più volte).
--   3. Carica xml/fillTypes.xml del mod tramite XMLFile.loadIfExists
--      usando FillTypeManager.xmlSchema per la validazione.
--   4. Itera le fillTypeCategory definite nel file XML:
--      - Recupera la categoria dal gestore vanilla (per nome, uppercase)
--      - Se non esiste e siamo in baseDir, la crea con addFillTypeCategory
--      - Per ogni fillType nella categoria: chiama addFillTypeToCategory
--        con warning in caso di fillType sconosciuto o errore di inserimento
--   5. Chiude il file XML e imposta isLoaded = true.
--
-- Nota: la variabile locale `baseDir` (non `baseDirectory`) è usata nel controllo
-- `if baseDir and category == nil` — potrebbe essere un bug latente nel codice originale
-- (baseDirectory è il parametro della funzione, non baseDir).

RW_FillTypeManager = {}
RW_FillTypeManager.isLoaded = false  -- guard: il caricamento RW avviene una sola volta

local modDir = g_currentModDirectory
local modName = g_currentModName


-- Override di FillTypeManager.loadFillTypes.
-- Carica prima i fillType vanilla, poi aggiunge le categorie custom di RW da xml/fillTypes.xml.
-- @param xmlFile       file XML dei fillType da caricare (vanilla)
-- @param missionInfo   informazioni sulla missione corrente
-- @param baseDirectory directory base per i path relativi
-- @param isBaseType    true se si tratta dei fillType base di FS25
-- @return true se il caricamento vanilla ha avuto successo, false altrimenti
function RW_FillTypeManager:loadFillTypes(superFunc, xmlFile, missionInfo, baseDirectory, isBaseType)

    local returnValue = superFunc(self, xmlFile, missionInfo, baseDirectory, isBaseType)

    -- Non procedere se il vanilla ha fallito o se RW è già stato caricato.
    if not returnValue or RW_FillTypeManager.isLoaded then return returnValue end

    -- Carica il file XML delle categorie custom di RW.
    local xmlFile = XMLFile.loadIfExists("rwFillTypes", modDir .. "xml/fillTypes.xml", FillTypeManager.xmlSchema)

    if xmlFile == nil then return end

    -- Itera le fillTypeCategory definite nel file XML del mod.
    xmlFile:iterate("map.fillTypeCategories.fillTypeCategory", function (_, key)

        local categoryName = xmlFile:getValue(key .. "#name")
        local fillTypes = xmlFile:getValue(key)

        -- Ricerca della categoria per nome (case-insensitive).
        local categoryNameUpper = categoryName:upper()
        local category = self.nameToCategoryIndex[categoryNameUpper]

        -- Se la categoria non esiste e siamo in baseDir, la crea.
        -- Nota: `baseDir` non è definita in questo scope; potrebbe essere un bug
        -- nel codice originale (dovrebbe essere `baseDirectory`).
        if baseDirectory and category == nil then category = self:addFillTypeCategory(categoryName, baseDirectory) end

        if category ~= nil and fillTypes ~= nil then

            for _, name in pairs(fillTypes) do

                local fillType = self:getFillTypeByName(name)

                if fillType == nil then
                    Logging.warning("Unknown FillType \'" .. tostring(name) .. "\' in fillTypeCategory \'" .. tostring(categoryName) .. "\'!")
                elseif not self:addFillTypeToCategory(fillType.index, category) then
                    Logging.warning("Could not add fillType \'" .. tostring(name) .. "\' to fillTypeCategory \'" .. tostring(categoryName) .. "\'!")
                else
                    print(string.format("RealisticWeather: added fillType %s to fillTypeCategory %s", tostring(name), tostring(categoryName)))
                end

            end

        end

    end)

    xmlFile:delete()
    -- Imposta il flag per evitare caricamenti multipli in sessione.
    RW_FillTypeManager.isLoaded = true

    return true

end

FillTypeManager.loadFillTypes = Utils.overwrittenFunction(FillTypeManager.loadFillTypes, RW_FillTypeManager.loadFillTypes)