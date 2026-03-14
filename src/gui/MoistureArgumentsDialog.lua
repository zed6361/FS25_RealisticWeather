-- MoistureArgumentsDialog.lua
-- Dialog modale per la configurazione manuale dei parametri della griglia del MoistureSystem.
-- Estende YesNoDialog e viene caricato da gui/MoistureArgumentsDialog.xml.
--
-- Permette all'utente di specificare manualmente cellWidth e cellHeight
-- (dimensione delle celle della griglia umidità) prima di rigenerare la mappa.
-- Offre anche un pulsante "Raccomandato" che calcola i valori ottimali
-- in base al performanceClassId del sistema (con incremento per server MP).
--
-- Ciclo di vita:
--   1. register()  → carica il file GUI XML e crea l'istanza INSTANCE
--   2. show()      → chiama register() se necessario, poi g_gui:showDialog
--   3. onOpen()    → imposta il focus su widthInput
--   4. setCurrentValues() → popola i selettori con i valori correnti del MoistureSystem
--   5. onClickRecommended() → calcola e imposta i valori consigliati
--   6. onClickOk()  → applica i nuovi valori e rigenera la mappa
--   7. onClickBack() → chiude senza applicare
--
-- Registrazione:
--   Il dialog viene registrato in FSBaseMission.lua (hook prepend su onStartMission)
--   tramite g_currentMission.moistureSystem o direttamente da createFromExistingGui.

MoistureArgumentsDialog = {}

local moistureArgumentsDialog_mt = Class(MoistureArgumentsDialog, YesNoDialog)
local modDirectory = g_currentModDirectory


-- Carica il file GUI XML e registra il dialog nel sistema GUI di FS25.
-- Salva l'istanza in MoistureArgumentsDialog.INSTANCE per accesso globale.
function MoistureArgumentsDialog.register()
    local dialog = MoistureArgumentsDialog.new()
    g_gui:loadGui(modDirectory .. "gui/MoistureArgumentsDialog.xml", "MoistureArgumentsDialog", dialog)
    MoistureArgumentsDialog.INSTANCE = dialog
end


-- Mostra il dialog. Chiama register() se l'istanza non è ancora stata creata.
-- Popola i valori correnti tramite setCurrentValues() prima di mostrare il dialog.
function MoistureArgumentsDialog.show()

    if MoistureArgumentsDialog.INSTANCE == nil then MoistureArgumentsDialog.register() end

    if MoistureArgumentsDialog.INSTANCE ~= nil then
        local instance = MoistureArgumentsDialog.INSTANCE

        -- Non aprire il dialog se il moistureSystem non è disponibile.
        if g_currentMission.moistureSystem == nil then return end

        instance:setCurrentValues()

        g_gui:showDialog("MoistureArgumentsDialog")
    end
end


-- Costruttore: crea il dialog estendendo YesNoDialog.
-- @param target    oggetto target (opzionale)
-- @param customMt  metatable custom (opzionale, usa moistureArgumentsDialog_mt di default)
function MoistureArgumentsDialog.new(target, customMt)
    local dialog = YesNoDialog.new(target, customMt or moistureArgumentsDialog_mt)
    return dialog
end


-- Callback del sistema GUI: chiamato quando il dialog viene creato da un XML esistente.
-- Registra e mostra il dialog immediatamente.
function MoistureArgumentsDialog.createFromExistingGui(gui, _)

    MoistureArgumentsDialog.register()
    MoistureArgumentsDialog.show()

end


-- Callback apertura dialog: imposta il focus sull'input cellWidth.
function MoistureArgumentsDialog:onOpen()

    MoistureArgumentsDialog:superClass().onOpen(self)
    FocusManager:setFocus(self.widthInput)

end


-- Callback chiusura dialog: delega alla superclass.
function MoistureArgumentsDialog:onClose()
    MoistureArgumentsDialog:superClass().onClose(self)
end


-- Popola i selettori widthInput e heightInput con i valori 1-50
-- e imposta lo stato corrente al cellWidth del MoistureSystem.
-- Nota: heightInput viene inizializzato con cellWidth (non cellHeight) —
-- potrebbe essere un comportamento intenzionale (celle quadrate di default).
function MoistureArgumentsDialog:setCurrentValues()

    local moistureSystem = g_currentMission.moistureSystem
    local sizes = {}

    -- Genera lista di dimensioni selezionabili da 1 a 50.
    for i = 1, 50 do sizes[i] = tostring(i) end

    self.widthInput:setTexts(sizes)
    self.heightInput:setTexts(sizes)

    self.sizes = sizes

    -- Imposta entrambi i selettori al cellWidth corrente (default celle quadrate).
    self.widthInput:setState(moistureSystem.cellWidth)
    self.heightInput:setState(moistureSystem.cellHeight)

end


-- Calcola e imposta i valori raccomandati in base al performanceClassId.
-- Su server MP con performance ≤ 3, usa almeno l'indice 4 per ridurre
-- il carico di rete (celle più grandi = meno aggiornamenti da sincronizzare).
-- Clamp al massimo disponibile nella lista se l'indice supera i 50 elementi.
function MoistureArgumentsDialog:onClickRecommended()

    local performanceIndex = Utils.getPerformanceClassId()

    -- Su server MP con hardware limitato, usa performance index minimo 4.
    if g_server ~= nil and g_server.netIsRunning and performanceIndex <= 3 then performanceIndex = 4 end

    local width, height = MoistureSystem.CELL_WIDTH[performanceIndex], MoistureSystem.CELL_HEIGHT[performanceIndex]

    -- Clamp al massimo disponibile nella lista se il valore supera i 50 elementi.
    if self.sizes[width] == nil then width = tonumber(self.sizes[#self.sizes]) end
    if self.sizes[height] == nil then height = tonumber(self.sizes[#self.sizes]) end

    self.widthInput:setState(width)
    self.heightInput:setState(height)

end


-- Applica i nuovi valori di cellWidth/cellHeight al MoistureSystem
-- e rigenera la mappa umidità con i nuovi parametri.
-- Il secondo parametro `true` di generateNewMapMoisture indica un reset completo.
function MoistureArgumentsDialog:onClickOk()

    local moistureSystem = g_currentMission.moistureSystem

    if moistureSystem ~= nil then

        moistureSystem.cellWidth = self.widthInput:getState()
        moistureSystem.cellHeight = self.heightInput:getState()
        -- Rigenera la mappa con i nuovi parametri (reset = true).
        moistureSystem:generateNewMapMoisture(nil, true)

    end

    self:close()

end


-- Chiude il dialog senza applicare modifiche.
function MoistureArgumentsDialog:onClickBack()

    self:close()

end
