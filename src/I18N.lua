-- I18N.lua (RW_I18N)
-- Modulo di integrazione di RealisticWeather con il sistema di localizzazione di FS.
-- Aggancia tramite override la funzione I18N.getText per intercettare specifiche chiavi
-- di testo e forzare il lookup nel namespace del mod RealisticWeather.
--
-- Problema risolto:
--   Le chiavi "rw_ui_irrigationUpkeep" e "finance_irrigationUpkeep" possono essere
--   richieste da altri sistemi (es. il pannello finanze di FS) senza specificare modEnv.
--   In quel caso, FS cerca la stringa nel namespace globale e non la trova nel mod.
--   Questo override forza il lookup nel namespace corretto (g_currentModName)
--   solo quando modEnv non è già specificato, evitando di interferire con altre richieste.

RW_I18N = {}
local modName = g_currentModName

-- Override di I18N.getText.
-- Intercetta le chiavi di testo specifiche del mod irrigazione e forza il modEnv corretto.
-- Per tutte le altre chiavi, delega alla funzione originale senza modifiche.
-- @param superFunc  funzione originale I18N.getText
-- @param text       chiave di localizzazione richiesta
-- @param modEnv     namespace del mod (nil se chiamata senza contesto specifico)
-- @return stringa localizzata
function RW_I18N:getText(superFunc, text, modEnv)

    -- Intercetta le chiavi del mod solo se non è già specificato un modEnv.
    if (text == "rw_ui_irrigationUpkeep" or text == "finance_irrigationUpkeep") and modEnv == nil then
        return superFunc(self, text, modName)
    end

    return superFunc(self, text, modEnv)

end

I18N.getText = Utils.overwrittenFunction(I18N.getText, RW_I18N.getText)
