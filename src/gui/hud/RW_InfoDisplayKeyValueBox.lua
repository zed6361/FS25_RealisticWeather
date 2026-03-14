-- RW_InfoDisplayKeyValueBox.lua
-- Box HUD personalizzato per visualizzare dati chiave-valore nell'info display di FS25.
-- Estende InfoDisplayBox con un layout grafico custom a tre sezioni (top/middle/bottom)
-- e righe chiave-valore con linea tratteggiata separatrice.
--
-- Usato da PlayerHUDUpdater.lua per il pannello umidità del campo.
-- Creato tramite g_currentMission.hud.infoDisplay:createBox(RW_InfoDisplayKeyValueBox).
--
-- Struttura visiva per ogni riga:
--   [keyOffsetX]  CHIAVE  ------  VALORE  [valueOffsetX da destra]
--   La linea tratteggiata occupa lo spazio tra la fine del testo chiave
--   e l'inizio del testo valore.
--
-- Gestione dimensioni:
--   storeScaledValues() viene chiamato dal sistema HUD a ogni cambio di scala UI.
--   Tutte le dimensioni sono espresse in coordinate schermo normalizzate.
--
-- Ciclo di rendering per frame:
--   1. clear()       → disattiva tutte le righe
--   2. setTitle()    → imposta il titolo (uppercase, limitato alla larghezza massima)
--   3. addLine(...)  → aggiunge righe (riutilizza slot esistenti o ne crea di nuovi)
--   4. showNextFrame() → abilita il rendering per il prossimo frame
--   5. draw(posX, posY) → esegue il rendering effettivo
--
-- Tipi di riga:
--   - Normale (isWarning=false): chiave a sinistra, valore a destra, linea tratteggiata
--   - Warning (isWarning=true/accentuate): testo chiave in arancio bold + icona warning,
--     nessun valore, offset Y aggiuntivo per spaziatura
--
-- canDraw() restituisce true solo se showNextFrame() è stato chiamato nel frame corrente.

RW_InfoDisplayKeyValueBox = {}
local rw_InfoDisplayKeyValueBox_mt = Class(RW_InfoDisplayKeyValueBox, InfoDisplayBox)


-- Costruttore: crea il box con gli overlay grafici per sfondo e icona warning.
-- Usa le texture standard dell'HUD di FS25 (fieldInfo_top/middle/bottom, fieldInfo_warning).
-- @param infoDisplay  riferimento all'InfoDisplay padre
-- @param uiScale      fattore di scala UI corrente
function RW_InfoDisplayKeyValueBox.new(infoDisplay, uiScale)

    local self = InfoDisplayBox.new(infoDisplay, uiScale, rw_InfoDisplayKeyValueBox_mt)

    self.lines = {}               -- lista di righe {key, value, colour, isWarning, isActive}
    self.title = "Unknown Title"  -- titolo del box (mostrato in cima, uppercase)

    -- Sfondo a tre sezioni: bottom → scale (altezza variabile) → top
    local r, g, b, a = unpack(HUD.COLOR.BACKGROUND)
    self.bgScale = g_overlayManager:createOverlay("gui.fieldInfo_middle", 0, 0, 0, 0)
    self.bgScale:setColor(r, g, b, a)
    self.bgBottom = g_overlayManager:createOverlay("gui.fieldInfo_bottom", 0, 0, 0, 0)
    self.bgBottom:setColor(r, g, b, a)
    self.bgTop = g_overlayManager:createOverlay("gui.fieldInfo_top", 0, 0, 0, 0)
    self.bgTop:setColor(r, g, b, a)

    -- Icona warning (colore ACTIVE = arancio) per le righe accentuate.
    r, g, b, a = unpack(HUD.COLOR.ACTIVE)
    self.warningIcon = g_overlayManager:createOverlay("gui.fieldInfo_warning", 0, 0, 0, 0)
    self.warningIcon:setColor(r, g, b, a)

    return self

end


-- Distrugge tutti gli overlay grafici allocati dal box.
function RW_InfoDisplayKeyValueBox:delete()

    self.bgScale:delete()
    self.bgBottom:delete()
    self.bgTop:delete()
    self.warningIcon:delete()

end


-- Ricalcola tutte le dimensioni in coordinate schermo normalizzate.
-- Chiamato dal sistema HUD a ogni cambio di scala UI o risoluzione.
-- Tutte le costanti in pixel vengono convertite tramite scalePixelToScreenWidth/Height.
function RW_InfoDisplayKeyValueBox:storeScaledValues()

    local infoDisplay = self.infoDisplay
    -- Dimensioni base del box: 340×6 px (larghezza fissa, altezza minima sezione)
    local x, z = infoDisplay:scalePixelValuesToScreenVector(340, 6)
    local y = infoDisplay:scalePixelToScreenHeight(6)

    self.bgBottom:setDimension(x, z)
    self.bgTop:setDimension(x, y)
    self.bgScale:setDimension(x, 0)          -- altezza variabile, impostata in draw()
    self.boxWidth = infoDisplay:scalePixelToScreenWidth(340)
    self.keyTextSize = infoDisplay:scalePixelToScreenHeight(14)
    self.valueTextSize = infoDisplay:scalePixelToScreenHeight(14)
    self.titleTextSize = infoDisplay:scalePixelToScreenHeight(15)
    self.titleToLineOffsetY = infoDisplay:scalePixelToScreenHeight(-24)   -- spazio titolo→prima riga
    self.lineToLineOffsetY = infoDisplay:scalePixelToScreenHeight(-21)    -- spazio tra righe
    self.lineHeight = infoDisplay:scalePixelToScreenHeight(21)
    self.titleAndBoxHeight = infoDisplay:scalePixelToScreenHeight(45)     -- altezza fissa titolo+padding
    self.dashedLineHeight = g_pixelSizeY                                   -- spessore linea tratteggiata (1px)
    self.dashWidth = infoDisplay:scalePixelToScreenWidth(6)
    self.dashGapWidth = infoDisplay:scalePixelToScreenWidth(3)
    self.keyOffsetX = infoDisplay:scalePixelToScreenWidth(30)             -- rientro del testo chiave

    local a, b = infoDisplay:scalePixelValuesToScreenVector(30, -3)
    self.warningOffsetX = a
    self.warningOffsetY = b                                               -- offset Y extra per righe warning
    self.valueOffsetX = infoDisplay:scalePixelToScreenWidth(-14)          -- offset dal bordo destro per il valore

    local c, d = infoDisplay:scalePixelValuesToScreenVector(14, -27)
    self.titleOffsetX = c
    self.titleOffsetY = d
    self.titleMaxWidth = infoDisplay:scalePixelToScreenWidth(312)         -- larghezza massima del titolo

    local e, f = infoDisplay:scalePixelValuesToScreenVector(20, 20)
    self.warningIcon:setDimension(e, f)
    local g, h = infoDisplay:scalePixelValuesToScreenVector(10, -4)
    self.warningIconOffsetX = g
    self.warningIconOffsetY = h

end


-- Rendering del box per il frame corrente.
-- Calcola l'altezza totale in base alle righe attive (incluse righe warning con offset extra).
-- Posiziona e disegna i tre overlay dello sfondo (bottom, scale, top).
-- Disegna il titolo in bold bianco in cima.
-- Per ogni riga attiva:
--   - Warning: testo chiave in arancio bold + icona warning, con offset Y aggiuntivo
--   - Normale: testo chiave a sinistra, testo valore a destra, linea tratteggiata al centro
-- @param posX  coordinata X del bordo destro del box (il box si estende a sinistra)
-- @param posY  coordinata Y del bordo inferiore del box
-- @return posX (invariato), posY del bordo superiore del box (per stacking verticale)
function RW_InfoDisplayKeyValueBox:draw(posX, posY)

    local leftX = posX - self.boxWidth
    -- Calcola l'altezza totale: titolo + tutte le righe attive.
    local height = self.titleAndBoxHeight

    for _, line in ipairs(self.lines) do
        if line.isActive then
            height = height + self.lineHeight
            if line.isWarning then height = height + math.abs(self.warningOffsetY) end
        end
    end

    -- Disegna i tre pannelli dello sfondo (dal basso verso l'alto).
    self.bgScale:setDimension(nil, height - self.bgBottom.height - self.bgTop.height)
    self.bgBottom:setPosition(leftX, posY)
    self.bgBottom:render()
    self.bgScale:setPosition(leftX, self.bgBottom.y + self.bgBottom.height)
    self.bgScale:render()
    self.bgTop:setPosition(leftX, self.bgScale.y + self.bgScale.height)
    self.bgTop:render()

    -- Titolo: testo uppercase bold bianco in cima al box.
    local a = leftX + self.titleOffsetX
    local b = self.bgTop.y + self.bgTop.height + self.titleOffsetY

    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextColor(1, 1, 1, 1)
    setTextBold(true)
    renderText(a, b, self.titleTextSize, self.title)
    setTextBold(false)

    -- Posizioni X pre-calcolate per le varie colonne.
    local c = leftX + self.keyOffsetX          -- X testo chiave
    local d = leftX + self.warningOffsetX      -- X testo warning
    local e = leftX + self.warningIconOffsetX  -- X icona warning
    local f = posX + self.valueOffsetX         -- X testo valore (dal bordo destro)
    local g = b + self.titleToLineOffsetY      -- Y corrente (aggiornata riga per riga)
    local h = HUD.COLOR.ACTIVE                 -- colore arancio per righe warning
    local i = HUD.COLOR.INACTIVE               -- colore grigio per la linea tratteggiata

    for _, line in ipairs(self.lines) do

        if line.isActive then
            local key = line.key
            local value = line.value

            if line.isWarning then
                -- Riga warning: testo chiave in arancio bold, icona a sinistra, nessun valore.
                setTextAlignment(RenderText.ALIGN_LEFT)
                setTextColor(h[1], h[2], h[3], h[4])
                setTextBold(true)
                g = g + self.warningOffsetY   -- spazio aggiuntivo prima della riga warning
                renderText(d, g, self.keyTextSize, key)
                setTextBold(false)
                self.warningIcon:setPosition(e, g + self.warningIconOffsetY)
                self.warningIcon:render()
            else
                -- Riga normale: chiave a sinistra, valore a destra, linea tratteggiata al centro.
                setTextColor(unpack(line.colour or { 1, 1, 1, 1 }))

                setTextAlignment(RenderText.ALIGN_LEFT)
                renderText(c, g, self.keyTextSize, key)
                local j = getTextWidth(self.keyTextSize, key)

                setTextAlignment(RenderText.ALIGN_RIGHT)
                renderText(f, g, self.valueTextSize, value)
                local k = getTextWidth(self.valueTextSize, value)

                -- Linea tratteggiata: occupa lo spazio tra fine chiave e inizio valore.
                local l = c + j + 3 * g_pixelSizeX          -- X iniziale linea (dopo la chiave)
                local m = f - k - l - 3 * g_pixelSizeX      -- larghezza linea (prima del valore)
                drawDashedLine(l, g, m, self.dashedLineHeight, self.dashWidth, self.dashGapWidth, i[1], i[2], i[3], i[4], true)
                setTextBold(false)
            end

            g = g + self.lineToLineOffsetY   -- avanza alla riga successiva
        end

    end

    local newPosY = self.bgTop.y + self.bgTop.height
    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextColor(1, 1, 1, 1)
    self.doShowNextFrame = false   -- reset: il box non si ridisegna automaticamente

    return posX, newPosY

end


-- @return true se il box deve essere disegnato nel frame corrente
function RW_InfoDisplayKeyValueBox:canDraw()
    return self.doShowNextFrame
end


-- Abilita il rendering del box per il prossimo frame.
-- Deve essere chiamato ogni frame per mantenere il box visibile.
function RW_InfoDisplayKeyValueBox:showNextFrame()
    self.doShowNextFrame = true
end


-- Disattiva tutte le righe senza deallocarle (riutilizzate al ciclo successivo).
-- Resetta l'indice corrente per il prossimo ciclo di addLine().
function RW_InfoDisplayKeyValueBox:clear()

    for _, lines in ipairs(self.lines) do
        lines.isActive = false
    end
    self.currentLineIndex = 0

end


-- Aggiunge (o aggiorna) una riga nel box.
-- Se lo slot all'indice corrente non esiste, ne crea uno nuovo.
-- Le righe vengono riutilizzate tra frame per evitare allocazioni continue.
-- @param key       testo chiave (colonna sinistra)
-- @param value     testo valore (colonna destra, default "")
-- @param colour    colore RGBA del testo {r,g,b,a} (default bianco)
-- @param accentuate  true per stile warning (arancio bold + icona, nessun valore)
function RW_InfoDisplayKeyValueBox:addLine(key, value, colour, accentuate)

    self.currentLineIndex = self.currentLineIndex + 1
    local line = self.lines[self.currentLineIndex]
    if line == nil then
        -- Crea un nuovo slot riga con valori di default.
        line = {
            ["key"] = "",
            ["value"] = "",
            ["colour"] = { 1, 1, 1, 1 },
            ["isWarning"] = false
        }
        table.addElement(self.lines, line)
    end
    line.key = key
    line.value = value or ""
    line.colour = colour or { 1, 1, 1, 1 }
    line.isWarning = accentuate
    line.isActive = true

end


-- Imposta il titolo del box.
-- Converte in uppercase e limita la lunghezza alla larghezza massima (con "..." se troncato).
-- Aggiorna solo se il titolo è cambiato rispetto al valore corrente.
-- @param title  testo del titolo (verrà convertito in uppercase)
function RW_InfoDisplayKeyValueBox:setTitle(title)

    local newTitle = utf8ToUpper(title)
    if newTitle ~= self.title then
        self.title = Utils.limitTextToWidth(newTitle, self.titleTextSize, self.titleMaxWidth, false, "...")
    end

end
