-- AmbientSoundSystem.lua (RW_AmbientSoundSystem)
-- Estensione del sistema audio ambientale di FS25 per integrare i suoni
-- personalizzati di RealisticWeather (blizzard, intensità pioggia, ecc.).
--
-- Hook registrati:
--   AmbientSoundSystem.updateMask        (append)    → RW_AmbientSoundSystem.updateMask
--   AmbientSoundSystem.loadFromConfigFile (overwrite) → RW_AmbientSoundSystem.loadFromConfigFile
--
-- updateMask:
--   Aggiunge 5 flag condizionali al sistema di maschere audio in base
--   alle condizioni meteo correnti (pioggia e blizzard):
--     blizzard   → attivo se weather.isBlizzard == true
--     rain       → pioggia media (0.33 ≤ rainfall < 0.67)
--     heavyRain  → pioggia forte (rainfall ≥ 0.67)
--     lightRain  → pioggia leggera (0 < rainfall < 0.33)
--     anyRain    → qualsiasi pioggia (rainfall > 0)
--   Questi flag vengono usati come requiredFlags/preventFlags nei campioni
--   audio definiti in xml/sounds.xml per condizionare la riproduzione.
--
-- loadFromConfigFile:
--   Chiama prima la funzione base (carica sounds.xml vanilla di FS25),
--   poi carica il file xml/sounds.xml del mod RW.
--   Registra i modifier aggiuntivi (blizzard, heavyRain, lightRain, anyRain)
--   nel conditionFlags del sistema.
--   Per ogni campione audio nel file XML del mod:
--     - Legge tutti i parametri (volume, pitch, delay, loop, fade, position, ecc.)
--     - Aggiunge il campione tramite ambientSoundsAddSample
--     - Aggiunge le variazioni audio tramite ambientSoundsAddSampleVariation
--     - Configura volume indoor, fade, loop, pitch, delay, length per ogni variazione
--   Il file XML è validato tramite AmbientSoundSystem.xmlSchema (schema vanilla).

RW_AmbientSoundSystem = {}
local modDirectory = g_currentModDirectory  -- directory base del mod per risolvere i path audio


-- Hook append su AmbientSoundSystem.updateMask.
-- Aggiorna i flag condizionali RW in base alle condizioni meteo correnti.
-- Chiamato ogni volta che FS aggiorna la maschera audio (cambio meteo, ora del giorno, ecc.).
function RW_AmbientSoundSystem:updateMask()

    local weather = g_currentMission.environment.weather
    local rainfall = weather:getRainFallScale()

    -- Imposta i flag meteo RW nel sistema di condizioni audio.
    self.conditionFlags:setModifierValue("blizzard", weather.isBlizzard or false)
    self.conditionFlags:setModifierValue("rain", rainfall >= 0.33 and rainfall < 0.67)
    self.conditionFlags:setModifierValue("heavyRain", rainfall >= 0.67)
    self.conditionFlags:setModifierValue("lightRain", rainfall < 0.33 and rainfall > 0)
    self.conditionFlags:setModifierValue("anyRain", rainfall > 0)

end

AmbientSoundSystem.updateMask = Utils.appendedFunction(AmbientSoundSystem.updateMask, RW_AmbientSoundSystem.updateMask)


-- Override di AmbientSoundSystem.loadFromConfigFile.
-- Carica prima i suoni vanilla tramite la funzione base, poi aggiunge
-- i suoni personalizzati del mod da xml/sounds.xml.
-- Registra i modifier aggiuntivi prima di caricare i campioni per garantire
-- che i flag siano disponibili per loadFlagsFromXMLFile.
-- @return false se la funzione base fallisce, altrimenti il valore di ritorno base
function RW_AmbientSoundSystem:loadFromConfigFile(superFunc)

    local returnValue = superFunc(self)

    if not returnValue then return false end

    -- Carica il file XML dei suoni RW usando lo schema vanilla di FS25.
    local xmlFile = XMLFile.loadIfExists("rwAmbientSounds", modDirectory .. "xml/sounds.xml", AmbientSoundSystem.xmlSchema)

    if xmlFile == nil then return returnValue end

    -- Registra i modifier aggiuntivi prima di processare i campioni.
    -- "rain" è già registrato dal vanilla; blizzard, heavyRain, lightRain, anyRain sono nuovi.
    self.conditionFlags:registerModifier("blizzard", nil)
    self.conditionFlags:registerModifier("heavyRain", nil)
    self.conditionFlags:registerModifier("lightRain", nil)
    self.conditionFlags:registerModifier("anyRain", nil)

    -- Processa ogni campione audio definito in xml/sounds.xml.
    for _, key in xmlFile:iterator("sound.ambient.sample") do

        -- Parametri del campione audio principale.
        local filename = xmlFile:getValue(key .. "#filename")
        local probability = xmlFile:getValue(key .. "#probability", 1)
        local positionTag = xmlFile:getValue(key .. "#positionTag", "")
        local radius = xmlFile:getValue(key .. "#radius", 0)
        local innerRadius = xmlFile:getValue(key .. "#innerRadius", 0)
        local audioGroupName = xmlFile:getValue(key .. ".settings#audioGroup", "ENVIRONMENT")
        local fadeInTime = xmlFile:getValue(key .. ".settings#fadeInTime", 0)
        local fadeOutTime = xmlFile:getValue(key .. ".settings#fadeOutTime", 0)
        local minVolume = xmlFile:getValue(key .. ".settings#minVolume", 1)
        local maxVolume = xmlFile:getValue(key .. ".settings#maxVolume", 1)
        local indoorVolume = xmlFile:getValue(key .. ".settings#indoorVolume", 0.8)
        local minLoops = xmlFile:getValue(key .. ".settings#minLoops", 1)
        local maxLoops = xmlFile:getValue(key .. ".settings#maxLoops", 1)
        local minRetriggerDelaySeconds = xmlFile:getValue(key .. ".settings#minRetriggerDelaySeconds", 0)
        local maxRetriggerDelaySeconds = xmlFile:getValue(key .. ".settings#maxRetriggerDelaySeconds", 0)
        local minPitch = xmlFile:getValue(key .. ".settings#minPitch", 1)
        local maxPitch = xmlFile:getValue(key .. ".settings#maxPitch", 1)
        local minDelay = xmlFile:getValue(key .. ".settings#minDelay", 0)
        local maxDelay = xmlFile:getValue(key .. ".settings#maxDelay", 0)
        local minLength = xmlFile:getValue(key .. ".settings#minLength", 0)
        local maxLength = xmlFile:getValue(key .. ".settings#maxLength", 0)
        local minTimeOfDay = xmlFile:getValue(key .. ".settings#minTimeOfDay", 0)
        local maxTimeOfDay = xmlFile:getValue(key .. ".settings#maxTimeOfDay", 1440)
        local minDayOfYear = xmlFile:getValue(key .. ".settings#minDayOfYear", 0)
        local maxDayOfYear = xmlFile:getValue(key .. ".settings#maxDayOfYear", 365)
        local audioGroup = AudioGroup.getAudioGroupIndexByName(audioGroupName)

        if audioGroup == nil then audioGroup = AudioGroup.ENVIRONMENT end

        local path = Utils.getFilename(filename, modDirectory)
        -- Carica i flag richiesti e preventivi per questo campione dai tag XML.
        local requiredFlags, preventFlags = self.conditionFlags:loadFlagsFromXMLFile(xmlFile, key)
        -- Registra il campione nel soundPlayer con tutti i parametri di trigger.
        local sampleId = ambientSoundsAddSample(self.soundPlayerId, audioGroup, minRetriggerDelaySeconds, maxRetriggerDelaySeconds, requiredFlags, preventFlags, minTimeOfDay, maxTimeOfDay, minDayOfYear, maxDayOfYear, positionTag or "", radius or 0, innerRadius or 0)
        -- Registra la variazione principale (file audio + probabilità di selezione).
        local sampleVariationId = ambientSoundsAddSampleVariation(self.soundPlayerId, sampleId, path, probability)
        -- Configura i parametri audio della variazione principale.
        ambientSoundsSampleSetIndoorVolumeFactor(self.soundPlayerId, sampleId, sampleVariationId, indoorVolume)
        ambientSoundsSampleSetFadeInOutTime(self.soundPlayerId, sampleId, sampleVariationId, fadeInTime, fadeOutTime)
        ambientSoundsSampleSetMinMaxVolume(self.soundPlayerId, sampleId, sampleVariationId, minVolume, maxVolume)
        ambientSoundsSampleSetMinMaxLoops(self.soundPlayerId, sampleId, sampleVariationId, minLoops, maxLoops)
        ambientSoundsSampleSetMinMaxPitch(self.soundPlayerId, sampleId, sampleVariationId, minPitch, maxPitch)
        ambientSoundsSampleSetMinMaxDelay(self.soundPlayerId, sampleId, sampleVariationId, minDelay, maxDelay)
        ambientSoundsSampleSetMinMaxLength(self.soundPlayerId, sampleId, sampleVariationId, minLength, maxLength)

        -- Processa le variazioni aggiuntive del campione (stesso sampleId, file diversi).
        -- Le variazioni ereditano i parametri del campione base se non specificati.
        for _, variationKey in xmlFile:iterator(key .. ".variation") do

            local variationFilename = xmlFile:getValue(variationKey .. "#filename")
            local variationProbability = xmlFile:getValue(variationKey .. "#probability", 1)
            local variationFadeInTime = xmlFile:getValue(variationKey .. "#fadeInTime", fadeInTime)
            local variationFadeOutTime = xmlFile:getValue(variationKey .. "#fadeOutTime", fadeOutTime)
            local variationMinVolume = xmlFile:getValue(variationKey .. "#minVolume", minVolume)
            local variationMaxVolume = xmlFile:getValue(variationKey .. "#maxVolume", maxVolume)
            local variationIndoorVolume = xmlFile:getValue(variationKey .. "#indoorVolume", indoorVolume)
            local variationMinLoops = xmlFile:getValue(variationKey .. "#minLoops", minLoops)
            local variationMaxLoops = xmlFile:getValue(variationKey .. "#maxLoops", maxLoops)
            local variationMinPitch = xmlFile:getValue(variationKey .. "#minPitch", minPitch)
            local variationMaxPitch = xmlFile:getValue(variationKey .. "#maxPitch", maxPitch)
            local variationMinDelay = xmlFile:getValue(variationKey .. "#minDelay", minDelay)
            local variationMaxDelay = xmlFile:getValue(variationKey .. "#maxDelay", maxDelay)
            local variationMinLength = xmlFile:getValue(variationKey .. "#minLength", minLength)
            local variationMaxLength = xmlFile:getValue(variationKey .. "#maxLength", maxLength)
            local variationPath = Utils.getFilename(variationFilename, modDirectory)
            local variationSampleVariationId = ambientSoundsAddSampleVariation(self.soundPlayerId, sampleId, variationPath, variationProbability)

            ambientSoundsSampleSetIndoorVolumeFactor(self.soundPlayerId, sampleId, variationSampleVariationId, variationIndoorVolume)
            ambientSoundsSampleSetFadeInOutTime(self.soundPlayerId, sampleId, variationSampleVariationId, variationFadeInTime, variationFadeOutTime)
            ambientSoundsSampleSetMinMaxVolume(self.soundPlayerId, sampleId, variationSampleVariationId, variationMinVolume, variationMaxVolume)
            ambientSoundsSampleSetMinMaxLoops(self.soundPlayerId, sampleId, variationSampleVariationId, variationMinLoops, variationMaxLoops)
            ambientSoundsSampleSetMinMaxPitch(self.soundPlayerId, sampleId, variationSampleVariationId, variationMinPitch, variationMaxPitch)
            ambientSoundsSampleSetMinMaxDelay(self.soundPlayerId, sampleId, variationSampleVariationId, variationMinDelay, variationMaxDelay)
            ambientSoundsSampleSetMinMaxLength(self.soundPlayerId, sampleId, variationSampleVariationId, variationMinLength, variationMaxLength)

        end

        -- Aggiunge il campione alla lista interna per eventuali query future.
        table.insert(self.samples, {
            ["filename"] = path,
            ["audioGroupId"] = audioGroup,
            ["requiredFlags"] = requiredFlags,
            ["preventFlags"] = preventFlags,
            ["minTimeOfDay"] = minTimeOfDay,
            ["maxTimeOfDay"] = maxTimeOfDay,
            ["minDayOfYear"] = minDayOfYear,
            ["maxDayOfYear"] = maxDayOfYear
        })

    end

    xmlFile:delete()

    return returnValue

end

AmbientSoundSystem.loadFromConfigFile = Utils.overwrittenFunction(AmbientSoundSystem.loadFromConfigFile, RW_AmbientSoundSystem.loadFromConfigFile)
