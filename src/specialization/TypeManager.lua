-- TypeManager.lua
-- Iniezione automatica delle specializzazioni RW nei tipi veicolo esistenti.
-- Agganciato come hook append su TypeManager.finalizeTypes, che viene chiamato
-- da FS25 dopo che tutti i tipi veicolo sono stati registrati e prima che
-- le istanze vengano create.
--
-- Meccanismo:
--   Definisce una tabella `specialisations` che mappa il nome di una specializzazione
--   vanilla ("sprayer", "cutter", "mower") all'elenco delle specializzazioni RW
--   da iniettare in tutti i vehicleType che la contengono.
--
--   Per ogni vehicleType nel TypeManager "vehicle":
--     - Itera le specializzazioni in ordine inverso (per stabilità durante l'iterazione)
--     - Se il vehicleType contiene una specializzazione presente nella mappa,
--       aggiunge le specializzazioni RW corrispondenti (se non già presenti)
--
-- Specializzazioni iniettate:
--   sprayer → ExtendedSprayer  (gestione irrigazione / effetti acqua)
--   cutter  → ExtendedCutter   (raccolta con umidità terreno)
--   mower   → ExtendedMower    (falciatura con umidità terreno)
--
-- Questo approccio è più robusto rispetto a modificare direttamente i file
-- modDesc.xml dei veicoli: funziona automaticamente per tutti i mod che
-- aggiungono veicoli con le specializzazioni vanilla target.

local modName = g_currentModName
local specialisations = {
    ["sprayer"] = { modName .. ".extendedSprayer" },
    ["cutter"] = { modName .. ".extendedCutter" },
    ["mower"] = { modName .. ".extendedMower" }
}


-- Hook append su TypeManager.finalizeTypes.
-- Viene eseguito solo per il TypeManager dei veicoli (self.typeName == "vehicle").
-- Per ogni vehicleType: controlla se contiene specializzazioni vanilla target
-- e aggiunge le corrispondenti specializzazioni RW se non già presenti.
TypeManager.finalizeTypes = Utils.appendedFunction(TypeManager.finalizeTypes, function(self)

    if self.typeName == "vehicle" then

        for typeName, vehicleType in pairs(self:getTypes()) do
            local hasPrecisionFarmingSprayer = vehicleType.specializationsByName["FS25_precisionFarming.extendedSprayer"] ~= nil

            -- Iterazione in ordine inverso per evitare problemi di indici durante l'aggiunta.
            for i = #vehicleType.specializationNames, 1, -1 do

                for specName, specs in pairs(specialisations) do

                    -- Controlla se questa posizione nella lista corrisponde a una spec target.
                    if vehicleType.specializationNames[i] ~= specName then continue end

                    -- Aggiunge ogni spec RW solo se non è già presente nel vehicleType.
                    if spec == modName .. ".extendedSprayer" and hasPrecisionFarmingSprayer then
                        continue
                    end

                    if vehicleType.specializationsByName[spec] == nil then self:addSpecialization(typeName, spec) end

                end

            end

        end

    end

end)
