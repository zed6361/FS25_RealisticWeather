-- InGameMenuMapFrameExtension.lua
-- Estensione della pagina mappa del menu in-game per aggiungere la tab
-- "Realistic Weather" con l'overlay visivo dell'umidità del terreno.
-- Fortemente ispirata al sistema PrecisionFarming di FS25 (parti PF
-- sono commentate/disabilitate ma lasciate come riferimento architetturale).
--
-- Responsabilità:
--   - Registra una nuova pagina "RealisticWeather" nel mapOverviewSelector
--   - Crea e gestisce un overlay DensityMapVisualization (1024×1024) per l'umidità
--   - Gestisce il selettore secondario (sub-selector) per le mappe disponibili
--   - Sincronizza il pannello filtri laterale con i dati del controller attivo
--   - Aggiorna l'overlay automaticamente ogni overlayUpdateInterval ms (1000ms)
--     mentre la tab RW è aperta
--   - Override di varie funzioni di InGameMenuMapFrame tramite g_realisticWeather:registerFunction
--
-- Struttura overlay:
--   self.overlays = {
--     ["groundMoisture"] = { id, ready, controller=GroundMoistureMap }
--   }
--   self.indexToOverlay = { "groundMoisture" } (mappa indice selettore → nome overlay)
--
-- Differenze rispetto alla versione precedente:
--   - onSelectorChanged() ora chiama updateMapOverlay() al cambio overlay
--     (in precedenza era commentato: l'overlay non si aggiornava al cambio selezione)
--   - Aggiunto hook su InGameMenuMapFrame.update: aggiorna l'overlay ogni
--     overlayUpdateInterval ms (1000ms) solo mentre la tab RW è visibile.
--     Il timer viene resettato a 0 quando si esce dalla tab RW.
--
-- Hook registrati su InGameMenuMapFrame tramite g_realisticWeather:registerFunction:
--   onLoadMapFinished    → aggiunge la callback del selettore e salva il ref. al frame
--   setupMapOverview     → inserisce la tab RW, crea selector/dotBox/helpButton
--   onClickMapOverviewSelector → mostra/nasconde i controlli RW in base alla tab attiva
--   populateCellForItemInSection → gestisce allowSelected per i filtri RW
--   getHasChangeableFilterList   → segnala che la lista filtri RW è modificabile
--   generateOverviewOverlay      → aggiorna l'overlay RW quando la mappa viene rigenerata
--   update                       → aggiorna l'overlay ogni 1000ms se la tab RW è aperta
--
-- Sezione "if 1 == 1 then return end":
--   Tutto il codice sotto questa guard è codice PrecisionFarming commentato
--   che non viene eseguito (return immediato). Lasciato come riferimento.

InGameMenuMapFrameExtension = {}

local modDirectory = g_currentModDirectory
local InGameMenuMapFrameExtension_mt = Class(InGameMenuMapFrameExtension)

-- Carica il controller per l'overlay umidità.
source(modDirectory .. "src/gui/maps/GroundMoistureMap.lua")


-- Costruttore: crea un'istanza vuota con le strutture dati necessarie.
-- @return istanza di InGameMenuMapFrameExtension
function InGameMenuMapFrameExtension.new()
    local self = setmetatable({}, InGameMenuMapFrameExtension_mt)

    self.valueMapToSelectorIndex = {}    -- mappa nome overlay → indice nel selettore
    self.selectorIndexToValueMap = {}    -- mappa indice selettore → nome overlay
    self.displayPrecisionFarmingData = {}
    self.activeValueMapIndex = 1         -- indice overlay attivo nel selettore secondario
    self.overlayUpdateTimer = 0          -- timer accumulatore per l'aggiornamento periodico
    self.overlayUpdateInterval = 1000    -- intervallo di aggiornamento overlay in ms (1 secondo)
    self.overlays = {}                   -- tabella degli overlay gestiti (nome → {id, ready, controller})

    return self
end


-- Distrugge gli overlay grafici allocati.
-- Elimina soilStateOverlay (se presente) e tutti i coverStateOverlays (PF, disabilitati).
function InGameMenuMapFrameExtension:delete()
    if self.soilStateOverlay ~= nil then delete(self.soilStateOverlay) end
    if self.coverStateOverlays ~= nil then
        for v9_ = 1, #self.coverStateOverlays do delete(self.coverStateOverlays[v9_].overlay) end
    end
end


-- Aggiornamento per frame (attualmente vuoto, la logica di update è gestita
-- dall'hook su InGameMenuMapFrame.update registrato in overwriteGameFunctions).
function InGameMenuMapFrameExtension:update(dt)

end


-- Chiamato quando il selettore secondario (sub-selector) cambia valore.
-- Aggiorna l'indice attivo, sincronizza il pannello filtri del menu mappa
-- con i dati e lo stato dei filtri del controller attivo, e rigenera l'overlay.
-- Rispetto alla versione precedente: la chiamata a updateMapOverlay() è ora
-- attiva (non più commentata), quindi l'overlay viene immediatamente rigenerato
-- quando si cambia sotto-mappa nel selettore.
-- @param state  indice del nuovo selettore (1-based)
function InGameMenuMapFrameExtension:onSelectorChanged(state)
    self.activeValueMapIndex = state
    local controller = self.overlays[self.indexToOverlay[state]].controller
    local v13_ = controller:getDisplayValues()
    local v14_, v15_ = controller:getValueFilter()
    -- Aggiorna le tabelle dati/filtri della pagina RW nel menu mappa.
    self.inGameMenuMapFrame.dataTables[self.inGameMenuMapFrame.realisticWeatherPageIndex] = v13_
    self.inGameMenuMapFrame.filterStates[self.inGameMenuMapFrame.realisticWeatherPageIndex] = v14_
    self.valueFilterEnabled = v15_

    -- Conta i filtri attivi per aggiornare il testo del pulsante "Seleziona/Deseleziona tutto".
    local v16_ = 0
    for v17_ = 1, #v14_ do
        if v14_[v17_] then v16_ = v16_ + 1 end
    end
    self.inGameMenuMapFrame.numSelectedFilters[self.inGameMenuMapFrame.realisticWeatherPageIndex] = v16_
    if v16_ == 0 then
        self.inGameMenuMapFrame.buttonDeselectAllText:setText(g_i18n:getText(InGameMenuMapFrame.L10N_SYMBOL.SELECT_ALL))
    else
        self.inGameMenuMapFrame.buttonDeselectAllText:setText(g_i18n:getText(InGameMenuMapFrame.L10N_SYMBOL.DESELECT_ALL))
    end
    self.inGameMenuMapFrame.filterList:reloadData()
    -- Rigenera immediatamente l'overlay per la nuova selezione.
    self:updateMapOverlay()
end


-- Bridge per la compatibilità con il sistema PrecisionFarming (delega a updateMapOverlay).
function InGameMenuMapFrameExtension:updatePrecisionFarmingOverlays()
    self:updateMapOverlay()
end


-- Rigenera l'overlay dell'indice attivo chiamando buildOverlay() sul controller
-- e poi generateDensityMapVisualizationOverlay() per aggiornare la texture GPU.
-- Imposta overlay.ready = false per indicare che l'overlay è in aggiornamento.
-- Chiamata da: onSelectorChanged, generateOverviewOverlay (hook), update (hook ogni 1s).
function InGameMenuMapFrameExtension:updateMapOverlay()
    local overlay = self.overlays[self.indexToOverlay[self.activeValueMapIndex]]
    if overlay ~= nil then
        local v21_, _ = overlay.controller:getValueFilter()
        overlay.controller:buildOverlay(overlay.id, v21_, self.isColorBlindMode)
        generateDensityMapVisualizationOverlay(overlay.id)
        overlay.ready = false
    end
end


-- Chiamato dopo il caricamento della mappa: crea gli overlay density map.
-- Inizializza l'overlay "groundMoisture" con il controller GroundMoistureMap.
-- Imposta self.indexToOverlay per la navigazione tramite selettore.
function InGameMenuMapFrameExtension:onLoadMapFinished()
    self.overlays = {
        ["groundMoisture"] = {
            ["id"] = createDensityMapVisualizationOverlay("groundMoisture", 1024, 1024),
            ["ready"] = false,
            ["controller"] = GroundMoistureMap.new(self)
        }
    }
    -- Mappa indice → nome overlay per la navigazione del selettore secondario.
    self.indexToOverlay = {
        "groundMoisture"
    }
    --self.groundMoistureOverlay = createDensityMapVisualizationOverlay("groundMoisture", 1024, 1024)
    --self.groundMoistureOverlayReady = false
    --local v26_ = self.precisionFarming.coverMap
    --if v26_ ~= nil then
        --self.coverStateOverlays = {}
        --for v27_ = 1, v26_:getNumCoverOverlays() do
            --local v28_ = {
                --["overlay"] = createDensityMapVisualizationOverlay("coverState" .. v27_, 1024, 1024),
                --["overlayReady"] = false
            --}
            --local v29_ = self.coverStateOverlays
            --table.insert(v29_, v28_)
        --end
    --end
    --self.precisionFarming:registerVisualizationOverlay(self.soilStateOverlay)
    --for v30_ = 1, #self.coverStateOverlays do
        --self.precisionFarming:registerVisualizationOverlay(self.coverStateOverlays[v30_].overlay)
    --end
end


-- Disegna gli overlay attivi sopra la mappa.
-- Controlla se l'overlay è pronto (GPU ha finito di generarlo),
-- imposta le UV (nessuna trasformazione: 0,0→1,1) e chiama renderOverlay.
-- @param x, y, width, height  coordinate e dimensioni dell'area mappa sullo schermo
function InGameMenuMapFrameExtension:onDrawStateOverlays(x, y, width, height)
    --if not self.soilStateOverlayReady and getIsDensityMapVisualizationOverlayReady(self.soilStateOverlay) then
        --self.soilStateOverlayReady = true
    --end
    --if self.soilStateOverlay ~= 0 then
        --setOverlayUVs(self.soilStateOverlay, 0, 0, 0, 1, 1, 0, 1, 1)
        --renderOverlay(self.soilStateOverlay, x, y, width, height)
    --end
    --local v36_ = self.precisionFarming:getValueMaps()[self.activeValueMapIndex]
    --local v37_
    --if v36_ == nil then
        --v37_ = false
    --else
        --v37_ = v36_:getAllowCoverage()
    --end
    --if v37_ and self.precisionFarming.coverMap ~= nil then
        --for v38_ = 1, #self.coverStateOverlays do
            --local v39_ = self.coverStateOverlays[v38_]
            --if not v39_.overlayReady and getIsDensityMapVisualizationOverlayReady(v39_.overlay) then
                --v39_.overlayReady = true
            --end
            --if v39_.overlay ~= 0 then
                --setOverlayUVs(v39_.overlay, 0, 0, 0, 1, 1, 0, 1, 1)
                --renderOverlay(v39_.overlay, x, y, width, height)
            --end
        --end
    --end

    for _, overlay in pairs(self.overlays) do
        -- Aggiorna il flag ready quando la GPU ha completato la generazione dell'overlay.
        if not overlay.ready and getIsDensityMapVisualizationOverlayReady(overlay.id) then overlay.ready = true end

        if overlay.id ~= 0 then
            -- UV standard senza trasformazione (copertura completa dell'area mappa).
            setOverlayUVs(overlay.id, 0, 0, 0, 1, 1, 0, 1, 1)
            renderOverlay(overlay.id, x, y, width, height)
        end
    end
end


-- Registra tutti gli override sulle funzioni di InGameMenuMapFrame
-- tramite g_realisticWeather:registerFunction (sistema di hooking RW).
-- Tutti gli hook vengono registrati all'avvio del mod e sono attivi
-- per tutta la durata della sessione.
function InGameMenuMapFrameExtension:overwriteGameFunctions()

    -- Hook su InGameMenuMapFrame.onLoadMapFinished:
    -- Dopo il caricamento vanilla, salva il riferimento al frame,
    -- registra la callback del selettore principale e chiama onLoadMapFinished di RW.
    g_realisticWeather:registerFunction(InGameMenuMapFrame, "onLoadMapFinished", function(inGameMenuMapFrame, superFunc)
        superFunc(inGameMenuMapFrame)
        self.inGameMenuMapFrame = inGameMenuMapFrame

        -- Override della callback del selettore principale per intercettare i click.
        function inGameMenuMapFrame.mapOverviewSelector.onClickCallback(_, p45_)
            inGameMenuMapFrame:onClickMapOverviewSelector(p45_)
        end

        --function inGameMenuMapFrame.onClickButtonResetStats()
            --if self.precisionFarming.farmlandStatistics ~= nil then
            --  self.precisionFarming.farmlandStatistics:onClickButtonResetStats()
            --end
        --end
        --function inGameMenuMapFrame.onClickButtonSwitchValues()
            --if self.precisionFarming.farmlandStatistics ~= nil then
                --self.precisionFarming.farmlandStatistics:onClickButtonSwitchValues()
            --end
        --end
        --local v46_ = {}
        --self.precisionFarming:collectFarmlandHotspotActions(v46_)
        --self.precisionFarmingHotspotActionIndices = {}
        --for _, v_u_47_ in ipairs(v46_) do
            --local v48_ = inGameMenuMapFrame.contextActions
            --local v49_ = {
                --["title"] = v_u_47_.title,
                --["callback"] = function()
                    --if inGameMenuMapFrame.selectedFarmland ~= nil then
                        --v_u_47_.callback(v_u_47_.callbackTarget, inGameMenuMapFrame.selectedFarmland.id)
                    --end
                    --return true
                --end,
                --["isActive"] = false
            --}
            --table.insert(v48_, v49_)
            --local v50_ = self.precisionFarmingHotspotActionIndices
            --local v51_ = #inGameMenuMapFrame.contextActions
            --table.insert(v50_, v51_)
        --end

        self:onLoadMapFinished()
        --pfModule:setMapFrame(p_u_44_)
    end)


    -- Hook su InGameMenuMapFrame.setupMapOverview:
    -- Aggiunge la tab "RealisticWeather" al selettore principale della mappa.
    -- Crea il selettore secondario (per le sotto-mappe), il dotBox (indicatori punto)
    -- e il helpButton clonato dal pulsante "Deseleziona tutto".
    g_realisticWeather:registerFunction(InGameMenuMapFrame, "setupMapOverview", function(inGameMenuMapFrame, superFunc)
        superFunc(inGameMenuMapFrame)

        -- Aggiunge la tab RW al selettore principale (mapOverviewSelector).
        table.insert(inGameMenuMapFrame.mapSelectorTexts, g_i18n:getText("ui_header"))
        inGameMenuMapFrame.realisticWeatherPageIndex = #inGameMenuMapFrame.mapSelectorTexts
        inGameMenuMapFrame.mapOverviewSelector:setTexts(inGameMenuMapFrame.mapSelectorTexts)
        -- Inizializza le strutture dati per la pagina RW.
        inGameMenuMapFrame.dataTables[inGameMenuMapFrame.realisticWeatherPageIndex] = {}
        inGameMenuMapFrame.filterStates[inGameMenuMapFrame.realisticWeatherPageIndex] = {}
        inGameMenuMapFrame.numSelectedFilters[inGameMenuMapFrame.realisticWeatherPageIndex] = 0
        -- Aggiunge un elemento al dotBox per il nuovo tab.
        inGameMenuMapFrame.subCategoryDotBox:addElement(inGameMenuMapFrame.subCategoryDotBox.elements[1]:clone(inGameMenuMapFrame.subCategoryDotBox))
        inGameMenuMapFrame.subCategoryDotBox:invalidateLayout()

        -- Aggiorna la funzione getIsSelected per tutti i dot in base all'indice del selettore.
        for v_u_66_, v67_ in pairs(inGameMenuMapFrame.subCategoryDotBox.elements) do
            function v67_.getIsSelected()
                return inGameMenuMapFrame.mapOverviewSelector:getState() == v_u_66_
            end
        end

        -- Crea il selettore secondario (sub-selector) clonando il selettore principale.
        self.selector = inGameMenuMapFrame.mapOverviewSelector:clone(inGameMenuMapFrame.filterBox)
        self.selectorTexts = {}

        -- Popola il sub-selector con le etichette degli overlay che devono comparire nel menu.
        for _, overlay in pairs(self.overlays) do
            if overlay.controller:getShowInMenu() then table.insert(self.selectorTexts, overlay.controller:getOverviewLabel()) end
        end

        self.selector:setTexts(self.selectorTexts)
        -- Sposta il selettore secondario 80px sopra la posizione default.
        local _, v72_ = getNormalizedScreenValues(0, 80)
        self.selector:setPosition(nil, self.selector.position[2] - v72_)

        -- Callback del sub-selector: delega a onSelectorChanged.
        function self.selector.onClickCallback(_, p73_)
            self:onSelectorChanged(p73_)
        end

        --self.selector.defaultProfileText = "pf_subCategorySelectorTextSmall"
        self.selector:addDefaultElements()
        --self.selector.textElement:applyProfile("pf_subCategorySelectorTextSmall")

        -- Crea il dotBox secondario clonando quello principale.
        self.dotBox = inGameMenuMapFrame.subCategoryDotBox:clone(inGameMenuMapFrame.filterBox)
        local _, v74_ = getNormalizedScreenValues(0, 75)
        self.dotBox:setPosition(nil, self.dotBox.position[2] - v74_)
        local v75_ = #self.selectorTexts
        local v76_ = #self.dotBox.elements

        -- Adatta il numero di elementi del dotBox secondario al numero di overlay.
        if v76_ < v75_ then
            for _ = 1, v75_ - v76_ do
                self.dotBox:addElement(self.dotBox.elements[1]:clone(self.dotBox))
            end
        elseif v75_ < v76_ then
            for _ = v75_ + 1, v76_ do
                self.dotBox.elements[#self.dotBox.elements]:delete()
            end
        end

        -- Ogni dot del dotBox secondario riflette lo stato del sub-selector.
        for i, element in pairs(self.dotBox.elements) do
            function element.getIsSelected()
                return self.selector:getState() == i
            end
        end

        self.dotBox:invalidateLayout()

        -- Crea il pulsante Help clonando il pulsante "Deseleziona tutto".
        self.helpButtonContainer = inGameMenuMapFrame.buttonDeselectAllContainer:clone(inGameMenuMapFrame.filterListContainer)
        inGameMenuMapFrame.filterListContainer:addElement(self.helpButtonContainer)
        local _, v79_ = getNormalizedScreenValues(0, 16)
        self.buttonPositionDeselectAllDefault = inGameMenuMapFrame.buttonDeselectAllContainer.position[2]
        self.buttonPositionDeselectAll = inGameMenuMapFrame.buttonDeselectAllContainer.position[2] + v79_
        self.helpButtonContainer:setPosition(nil, inGameMenuMapFrame.buttonDeselectAllContainer.position[2] - v79_)
        self.helpButtonContainer.elements[2]:setText(g_i18n:getText("ui_help"))
        self.helpButtonContainer.elements[3]:setInputAction("MENU_EXTRA_1")

        -- Callback del pulsante Help (attualmente senza azione, collegamento helpline commentato).
        self.helpButtonContainer.elements[3].onClickCallback = function()
            local overlay = self.overlays[self.activeValueMapIndex]
            if overlay == nil then
                --self.precisionFarming.helplineExtension:openHelpMenu(0)
            else
                --self.precisionFarming.helplineExtension:openHelpMenu(overlay:getHelpLinePage())
            end
        end

        -- Salva le dimensioni originali dei componenti per il ripristino al cambio tab.
        self.filterListContainerPositionY = inGameMenuMapFrame.filterListContainer.position[2]
        self.filterListContainerSizeY = inGameMenuMapFrame.filterListContainer.size[2]
        self.filterListSizeY = inGameMenuMapFrame.filterList.size[2]
        self.filterListSliderSizeY = inGameMenuMapFrame.filterListSlider.size[2]
        self.filterListSliderElementSizeY = inGameMenuMapFrame.filterListSlider.elements[1].size[2]
        inGameMenuMapFrame.ingameMap.onDrawPostIngameMapCallback = InGameMenuMapFrame.onDrawPostIngameMap
        inGameMenuMapFrame.ingameMap.onDrawPostIngameMapHotspotsCallback = InGameMenuMapFrame.onDrawPostIngameMapHotspots
        inGameMenuMapFrame.ingameMap.onClickMapCallback = InGameMenuMapFrame.onClickMap
        inGameMenuMapFrame.filterList:reloadData()
    end)


    -- Hook su InGameMenuMapFrame.onClickMapOverviewSelector:
    -- Mostra/nasconde i controlli RW (selector, dotBox, helpButton, filterList)
    -- quando l'utente cambia tab nel selettore principale.
    -- In modalità RW: ridimensiona il filterListContainer per fare spazio ai controlli extra (60px).
    -- Nelle altre tab: ripristina le dimensioni originali.
    g_realisticWeather:registerFunction(InGameMenuMapFrame, "onClickMapOverviewSelector", function(inGameMenuMapFrame, superFunc, state)
        superFunc(inGameMenuMapFrame, state)

        if state == inGameMenuMapFrame.realisticWeatherPageIndex then
            -- Tab RW attiva: mostra tutti i controlli extra e ridimensiona il filtro.
            self.selector:setVisible(true)
            self.dotBox:setVisible(true)
            self.helpButtonContainer:setVisible(true)
            inGameMenuMapFrame.filterListContainer:setVisible(true)
            inGameMenuMapFrame.buttonDeselectAllContainer:setVisible(true)
            local _, v84_ = getNormalizedScreenValues(0, 60)
            inGameMenuMapFrame.filterListContainer:setPosition(nil, self.filterListContainerPositionY - v84_)
            inGameMenuMapFrame.filterListContainer:setSize(nil, self.filterListContainerSizeY - v84_, true)
            inGameMenuMapFrame.filterList:setSize(nil, self.filterListSizeY - v84_, true)
            inGameMenuMapFrame.filterListSlider:setSize(nil, self.filterListSliderSizeY - v84_, true)
            inGameMenuMapFrame.filterListSlider.elements[1]:setSize(nil, self.filterListSliderElementSizeY - v84_, true)
            inGameMenuMapFrame.buttonDeselectAllContainer:setPosition(nil, self.buttonPositionDeselectAll)
            self:onSelectorChanged(self.selector:getState())
            --pfModule:onMapFrameOpen(inGameMenuMapFrame)
        else
            -- Altra tab: nasconde i controlli RW e ripristina le dimensioni originali.
            self.selector:setVisible(false)
            self.dotBox:setVisible(false)
            self.helpButtonContainer:setVisible(false)
            inGameMenuMapFrame.filterListContainer:setPosition(nil, self.filterListContainerPositionY)
            inGameMenuMapFrame.filterListContainer:setSize(nil, self.filterListContainerSizeY, true)
            inGameMenuMapFrame.filterList:setSize(nil, self.filterListSizeY, true)
            inGameMenuMapFrame.filterListSlider:setSize(nil, self.filterListSliderSizeY, true)
            inGameMenuMapFrame.filterListSlider.elements[1]:setSize(nil, self.filterListSliderElementSizeY, true)
            inGameMenuMapFrame.buttonDeselectAllContainer:setPosition(nil, self.buttonPositionDeselectAllDefault)
        end

        --if inGameMenuMapFrame.precisionFarmingOnlyElements ~= nil then
            --for _, v85_ in ipairs(inGameMenuMapFrame.precisionFarmingOnlyElements) do
                --v85_:setVisible(state == inGameMenuMapFrame.precisionFarmingPageIndex)
            --end
        --end
    end)


    -- Hook su InGameMenuMapFrame.populateCellForItemInSection:
    -- Gestisce la selezionabilità delle voci nella lista filtri della pagina RW.
    -- Se valueFilterEnabled è nil → tutti selezionabili.
    -- Altrimenti: selezionabile solo se valueFilterEnabled[index] == true.
    g_realisticWeather:registerFunction(InGameMenuMapFrame, "populateCellForItemInSection", function(inGameMenuMapFrame, superFunc, p88_, p89_, p90_, p91_)
        superFunc(inGameMenuMapFrame, p88_, p89_, p90_, p91_)

        if p88_ == inGameMenuMapFrame.contextButtonList or p88_ ~= inGameMenuMapFrame.contextButtonListFarmland then
            return
        elseif inGameMenuMapFrame.mapOverviewSelector:getState() == inGameMenuMapFrame.realisticWeatherPageIndex then
            if self.valueFilterEnabled == nil then
                p91_.allowSelected = true
            else
                p91_.allowSelected = self.valueFilterEnabled[p90_]
            end
        else
            p91_.allowSelected = true
            return
        end
    end)


    -- Hook su InGameMenuMapFrame.getHasChangeableFilterList:
    -- Segnala al menu che la lista filtri della pagina RW è modificabile
    -- (consente l'interazione con le voci della lista).
    g_realisticWeather:registerFunction(InGameMenuMapFrame, "getHasChangeableFilterList", function(inGameMenuMapFrame, superFunc, ...)
        return superFunc(inGameMenuMapFrame, ...) or inGameMenuMapFrame.mapOverviewSelector:getState() == inGameMenuMapFrame.realisticWeatherPageIndex
    end)


    -- Hook su InGameMenuMapFrame.generateOverviewOverlay:
    -- Dopo la rigenerazione vanilla dell'overlay mappa, aggiorna anche l'overlay RW.
    g_realisticWeather:registerFunction(InGameMenuMapFrame, "generateOverviewOverlay", function(inGameMenuMapFrame, superFunc, ...)
        superFunc(inGameMenuMapFrame, ...)
        self:updateMapOverlay()
    end)


    -- Hook su InGameMenuMapFrame.update (NUOVO rispetto alla versione precedente):
    -- Chiamato ad ogni frame dal sistema menu mentre il menu mappa è aperto.
    -- Aggiorna l'overlay umidità ogni overlayUpdateInterval ms (1000ms = 1 secondo)
    -- ma SOLO se la tab attiva è quella di RealisticWeather (controllo doppio:
    -- mapOverviewSelector non nil e realisticWeatherPageIndex non nil per sicurezza).
    -- Se si passa a un'altra tab, il timer viene resettato a 0 così che al prossimo
    -- ritorno sulla tab RW l'overlay si aggiorni dopo 1 secondo, non immediatamente.
    g_realisticWeather:registerFunction(InGameMenuMapFrame, "update", function(inGameMenuMapFrame, superFunc, dt)
        superFunc(inGameMenuMapFrame, dt)

        if inGameMenuMapFrame.mapOverviewSelector ~= nil
        and inGameMenuMapFrame.realisticWeatherPageIndex ~= nil
        and inGameMenuMapFrame.mapOverviewSelector:getState() == inGameMenuMapFrame.realisticWeatherPageIndex then
            -- Tab RW attiva: accumula il tempo trascorso e aggiorna ogni 1000ms.
            self.overlayUpdateTimer = self.overlayUpdateTimer + dt
            if self.overlayUpdateTimer >= self.overlayUpdateInterval then
                self:updateMapOverlay()
                self.overlayUpdateTimer = 0
            end
        else
            -- Tab diversa: azzera il timer (l'overlay non si aggiorna in background).
            self.overlayUpdateTimer = 0
        end
    end)


    -- Guard: tutto il codice sotto questa riga è codice PrecisionFarming non più attivo.
    -- Il "if 1 == 1 then return end" garantisce che non venga mai eseguito,
    -- ma il codice è conservato come riferimento architetturale per sviluppi futuri.
    if 1 == 1 then return end

    -- [CODICE PF DISABILITATO - non eseguito]
    -- Gli override seguenti sono stati copiati da PrecisionFarming come base
    -- e successivamente disabilitati/rimossi dalla logica attiva di RW.

    pfModule:overwriteGameFunction(InGameMenuMapFrame, "updateInputGlyphs", function(p94_, p95_, ...)
        p94_(p95_, ...)
        if self.precisionFarming.environmentalScore ~= nil then
            self.precisionFarming.environmentalScore:updateInputGlyphs()
        end
    end)
    pfModule:overwriteGameFunction(InGameMenuMapFrame, "onDrawPostIngameMap", function(p96_, p97_, p98_, p99_, ...)
        if p97_.mapOverviewSelector:getState() == p97_.precisionFarmingPageIndex then
            local v100_ = p97_.hideContentOverlay
            p97_.hideContentOverlay = true
            p96_(p97_, p98_, p99_, ...)
            p97_.hideContentOverlay = v100_
            local v101_, v102_ = p97_.ingameMapBase.fullScreenLayout:getMapSize()
            local v103_, v104_ = p97_.ingameMapBase.fullScreenLayout:getMapPosition()
            self:onDrawStateOverlays(v103_ + v101_ * 0.25, v104_ + v102_ * 0.25, v101_ * 0.5, v102_ * 0.5)
            if self.activeValueMapIndex == 1 and self.precisionFarming.environmentalScore ~= nil then
                self.precisionFarming.environmentalScore:onDraw(p98_, p99_)
                return
            end
        else
            p96_(p97_, p98_, p99_, ...)
        end
    end)
    pfModule:overwriteGameFunction(InGameMenuMapFrame, "onClickSwitchMapMode", function(p105_, p106_)
        if pfModule.additionalFieldBuyInfo ~= nil then
            pfModule.additionalFieldBuyInfo:onFarmlandSelectionChanged()
            p106_:resetUIDeadzones()
        end
        p105_(p106_)
    end)
    pfModule:overwriteGameFunction(InGameMenuMapFrame, "onFrameClose", function(p107_, p108_)
        p107_(p108_)
        if pfModule.additionalFieldBuyInfo ~= nil then
            pfModule.additionalFieldBuyInfo:onFarmlandSelectionChanged()
            p108_:resetUIDeadzones()
        end
    end)
    pfModule:overwriteGameFunction(InGameMenuMapFrame, "update", function(p109_, p110_, p111_)
        p109_(p110_, p111_)
        if p110_.mapOverviewSelector:getState() == p110_.precisionFarmingPageIndex then
            self.overlayUpdateTimer = self.overlayUpdateTimer + p111_
            if self.overlayUpdateTimer > self.overlayUpdateInterval then
                self:updateSoilStateMapOverlay()
                self.overlayUpdateTimer = 0
            end
        end
    end)
    pfModule:overwriteGameFunction(InGameMenuMapFrame, "setMapSelectionItem", function(p114_, p115_, p116_, ...)
        local v117_ = p115_.selectedFarmland
        local v118_ = false
        if self.precisionFarmingHotspotActionIndices ~= nil and (p115_.mapOverviewSelector:getState() == p115_.precisionFarmingPageIndex and (p116_ ~= nil and p116_:isa(FarmlandHotspot))) then
            local v119_ = p116_:getFarmland()
            v118_ = g_farmlandManager:getFarmlandOwner(v119_.id) == g_currentMission:getFarmId() and v119_.totalFieldArea ~= nil and true or v118_
        end
        p114_(p115_, p116_, ...)
        if v118_ then
            for _, v120_ in pairs(p115_.contextActions) do v120_.isActive = false end
        end
        if self.precisionFarmingHotspotActionIndices ~= nil then
            for _, v121_ in ipairs(self.precisionFarmingHotspotActionIndices) do
                p115_.contextActions[v121_].isActive = v118_
            end
        end
        if p115_.selectedFarmland ~= v117_ and pfModule.additionalFieldBuyInfo ~= nil then
            pfModule.additionalFieldBuyInfo:onFarmlandSelectionChanged(p115_.selectedFarmland)
            p115_:resetUIDeadzones()
        end
    end)
    pfModule:overwriteGameFunction(InGameMenuMapUtil, "showContextBox", function(p122_, p123_, p124_, p125_, p126_, p127_, p128_, p129_, p130_, p131_, p132_, ...)
        p122_(p123_, p124_, p125_, p126_, p127_, p128_, p129_, p130_, p131_, p132_, ...)
        if p123_ ~= nil and p132_ then
            local v133_ = p124_:getFarmland()
            if v133_ ~= nil then
                local v134_
                if v133_.totalFieldArea == nil then
                    v134_ = g_i18n:formatMoney(v133_.price, 0, true, false)
                else
                    v134_ = string.format("%s (%s / ha)", g_i18n:formatMoney(v133_.price, 0, true, false), g_i18n:formatMoney(v133_.price / v133_.totalFieldArea, 0, true, false))
                end
                p123_:getDescendantByName("farmlandValue"):setText(v134_)
                if v133_.totalFieldArea ~= nil then
                    local v135_ = string.format("%s (%s: %s)", g_i18n:formatArea(v133_.areaInHa, 2), g_i18n:getText("contract_details_field"), g_i18n:formatArea(v133_.totalFieldArea, 2))
                    p123_:getDescendantByName("farmlandSize"):setText(v135_)
                end
            end
        end
    end)
    pfModule:overwriteGameFunction(InGameMenuMapFrame, "resetUIDeadzones", function(p136_, p137_)
        p136_(p137_)
        if p137_.deadzoneElements ~= nil then
            for _, v138_ in ipairs(p137_.deadzoneElements) do
                if v138_:getIsVisible() then
                    p137_.ingameMap:addCursorDeadzone(v138_.absPosition[1], v138_.absPosition[2], v138_.size[1], v138_.size[2])
                end
            end
        end
    end)
    pfModule:overwriteGameFunction(MapOverlayGenerator, "getDisplaySoilStates", function(p139_, p140_)
        local v141_ = p139_(p140_)
        v141_[MapOverlayGenerator.SOIL_STATE_INDEX.FERTILIZED] = nil
        v141_[MapOverlayGenerator.SOIL_STATE_INDEX.NEEDS_LIME] = nil
        return v141_
    end)
end