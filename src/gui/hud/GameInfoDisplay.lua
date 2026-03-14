-- GameInfoDisplay.lua (RW_GameInfoDisplay)
-- Estensione del pannello HUD superiore (GameInfoDisplay) per aggiungere:
--   1. Indicatore temperatura con alternanza °C/senza unità (ogni 75 tick)
--   2. Indicatore disastro corrente/prossimo (blizzard/siccità) con testo animato
--   3. Indicatore neve prevista (range min-max in cm)
--   4. Compatibilità con ExtendedGameInfoDisplay (mod terza parte)
--
-- Hook registrato:
--   GameInfoDisplay.draw (append) → RW_GameInfoDisplay.draw
--
-- Inizializzazione lazy:
--   Al primo frame, crea tutti gli overlay grafici (temperatureBg, disasterBg,
--   snowAmountBg, carouselBlock) e preleva i testi localizzati.
--   Gli overlay usano le texture "gui.gameInfo_left/middle" con HUD.COLOR.BACKGROUND.
--
-- Sistema aggiornamento (ogni TICKS_PER_UPDATE=200 tick):
--   - Legge il meteo corrente e successivo dalla previsione
--   - Determina currentDisaster (0=nessuno, 1=blizzard, 2=siccità) e nextDisaster
--   - Calcola snowHeightMin/Max sommando il snowForecast delle istanze meteo neve
--     attive (currentWeather) e future (nextWeather) fino a raggiungere SNOW_HEIGHT
--   - snowForecast per ogni istanza viene calcolato una sola volta e cachato
--     nell'istanza stessa (evita ricalcoli ad ogni frame)
--
-- Layout HUD (sinistra a destra):
--   [temperatureBgLeft] [temperatureBg: temperatura] [disasterBg: disastro/nebbia] [snowAmountBg: neve]
--   Separatori verticali bianchi semitrasparenti tra i pannelli.
--   Compatibilità ExtendedGameInfoDisplay: se isExtendedGameInfoDisplayLoaded=true,
--   temperatura e separatore vengono nascosti (li gestisce il mod esterno).
--
-- Sistema carosello (per blizzard + previsione neve):
--   Quando currentDisaster==1 o thickFog è attivo e carouselTextFull2 è disponibile,
--   il disasterBg si allarga (carouselWidth) e mostra due testi scorrevoli in loop:
--     carouselText1: testo disastro/nebbia principale
--     carouselText2: testo neve prevista
--   Il testo scorre da destra a sinistra con clip area per nascondere i bordi.
--   La logica gestisce: espansione caratteri, wrap-around, pendingCarouselReset
--   (attende che text1 sia completamente visibile prima di riportare text2 all'inizio).

RW_GameInfoDisplay = {}
RW_GameInfoDisplay.TICKS_PER_UPDATE = 200         -- intervallo tick tra aggiornamenti meteo
RW_GameInfoDisplay.isExtendedGameInfoDisplayLoaded = false  -- flag compatibilità mod esterno


-- Hook append su GameInfoDisplay.draw.
-- Gestisce l'intera logica di rendering RW per il pannello HUD superiore.
-- Il blocco di inizializzazione lazy viene eseguito solo al primo frame (self.temperatureBg == nil).
function RW_GameInfoDisplay:draw()

    if self.temperatureBg == nil then
        -- Inizializzazione lazy: creazione overlay e prefetch testi.
        self.updateTicks = RW_GameInfoDisplay.TICKS_PER_UPDATE  -- forza aggiornamento al primo frame
        self.currentDisaster = 0    -- 0=nessuno, 1=blizzard, 2=siccità
        self.nextDisaster = 0       -- disastro nel prossimo periodo meteo
        self.snowHeightMin = 0      -- altezza neve prevista minima (×0.985)
        self.snowHeightMax = 0      -- altezza neve prevista massima (×1.015)
        self.setSnow = g_currentMission.environment.weather.snowHeight

        -- Pannello temperatura: left (bordo arrotondato) + middle (corpo).
        self.temperatureBgLeft = g_overlayManager:createOverlay("gui.gameInfo_left", 0, 0, 0, 0)
        self.temperatureBg = g_overlayManager:createOverlay("gui.gameInfo_middle", 0, 0, 0, 0)
        local colour = HUD.COLOR.BACKGROUND
        self.temperatureBgLeft:setColor(colour[1], colour[2], colour[3], colour[4])
        self.temperatureBg:setColor(colour[1], colour[2], colour[3], colour[4])
        local width, height = self:scalePixelValuesToScreenVector(10, 65)
        self.temperatureBgLeft:setDimension(width, height)
        self.temperatureBg:setDimension(width * 8, height)
        self.temperatureTextSize = self:scalePixelToScreenHeight(17)
        self.temperatureTextOffsetX, self.temperatureTextOffsetY = self:scalePixelValuesToScreenVector(20, 27)

        -- Pannello disastro/nebbia.
        self.disasterBg = g_overlayManager:createOverlay("gui.gameInfo_middle", 0, 0, 0, 0)
        self.disasterBg:setColor(colour[1], colour[2], colour[3], colour[4])
        self.disasterBg:setDimension(width * 14, height)
        self.disasterTextOffsetX, self.disasterTextOffsetY = self:scalePixelValuesToScreenVector(5, 27)
        self.disasterWidth = width * 14     -- larghezza default del pannello disastro

        -- Prefetch testi localizzati per i messaggi HUD.
        self.blizzardComingText = g_i18n:getText("rw_ui_blizzard_coming")
        self.blizzardNowText = g_i18n:getText("rw_ui_blizzard_now")
        self.droughtComingText = g_i18n:getText("rw_ui_drought_coming")
        self.droughtNowText = g_i18n:getText("rw_ui_drought_now")
        self.fogText = g_i18n:getText("rw_ui_fog")

        -- Pannello neve prevista (larghezza variabile: wide per range, narrow per valore singolo).
        self.snowAmountBg = g_overlayManager:createOverlay("gui.gameInfo_middle", 0, 0, 0, 0)
        self.snowAmountBg:setColor(colour[1], colour[2], colour[3], colour[4])
        self.snowAmountBgWidth, self.snowAmountBgHeight = width * 20, height
        self.snowAmountBgOneWidth = width * 8   -- larghezza per valore singolo (min==max)
        self.snowAmountBg:setDimension(self.snowAmountBgWidth, self.snowAmountBgHeight)
        self.snowTextOffsetX, self.snowTextOffsetY = self:scalePixelValuesToScreenVector(6, 27)
        self.snowOneTextOffsetX, _ = self:scalePixelValuesToScreenVector(10, 27)
        self.snowText = g_i18n:getText("rw_ui_snowExpected")   -- formato "Neve: %dcm - %dcm"
        self.snowOneText = "%scm"

        -- Offset per compatibilità ExtendedGameInfoDisplay (sposta i pannelli a sinistra).
        self.extendedGameInfoDisplayOffsetX, _ = self:scalePixelValuesToScreenVector(95, 0)

        -- Stato sistema carosello (testo scorrevole per blizzard + neve).
        self.carouselText1 = nil           -- porzione visibile del testo principale
        self.carouselText2 = nil           -- porzione visibile del testo secondario
        self.carouselTextFull1 = nil       -- testo completo del canale 1
        self.carouselTextFull2 = nil       -- testo completo del canale 2
        self.carouselShownChars1 = 0
        self.carouselShownChars2 = 0
        self.carouselWidth = width * 28    -- larghezza totale dell'area carosello
        self.pendingCarouselReset = false  -- true = attende che text1 sia completo prima di resettare text2
        self.pendingCarouselResetThreshold = self.carouselWidth * 0.33
        self.carouselOffset = self.carouselWidth * 0.03
        self.carouselX1 = self.carouselWidth - self.carouselOffset   -- posizione X corrente testo 1
        self.carouselX2 = self.carouselWidth * 1.5 - self.carouselOffset  -- posizione X corrente testo 2

        -- Blocchi di clip per nascondere i bordi del carosello.
        self.carouselBlockLeft = g_overlayManager:createOverlay("gui.gameInfo_middle", 0, 0, 0, 0)
        self.carouselBlockLeft:setColor(colour[1], colour[2], colour[3], 1)
        self.carouselBlockLeft:setDimension(width, height)

        self.carouselBlockRight = g_overlayManager:createOverlay("gui.gameInfo_middle", 0, 0, 0, 0)
        self.carouselBlockRight:setColor(colour[1], colour[2], colour[3], 1)
        self.carouselBlockRight:setDimension(width, height)

        self.lastCarousel = nil        -- ultimo tipo di carosello attivo (1=disastro, 2=fog)
        self.temperatureUpdateTicks = 0
        self.useTemperatureSuffix = true  -- alterna tra "°C" e nessun suffisso ogni 75 tick
    end

    local _, y = self:getPosition()
    local elementLoaded = false  -- true se almeno un pannello extra deve essere renderizzato

    -- Posizionamento del pannello temperatura (compatibilità ExtendedGameInfoDisplay).
    if RW_GameInfoDisplay.isExtendedGameInfoDisplayLoaded then
        -- ExtendedGameInfoDisplay gestisce la temperatura: nascondi il pannello RW.
        self.temperatureBg:setPosition(self.infoBgLeft.x - self.extendedGameInfoDisplayOffsetX, y - self.weatherIcon.height)
        self.temperatureBg.width = 0
    else
        elementLoaded = true
        self.temperatureBg:setPosition(self.infoBgLeft.x - self.temperatureBg.width + (self.infoBgLeft.width / 3.5), y - self.temperatureBg.height)
        self.temperatureBg:render()
        -- Separatore verticale tra il pannello meteo vanilla e il pannello temperatura RW.
        drawLine2D(self.infoBgLeft.x, y - self.infoBgLeft.height + self.separatorOffsetY, self.infoBgLeft.x, y - self.infoBgLeft.height + self.separatorHeight + self.separatorOffsetY, self.separatorWidth, 1, 1, 1, 0.2)
    end

    -- Temperatura corrente dal temperatureUpdater (interpolata per dayTime).
    local temperature = g_currentMission.environment.weather.temperatureUpdater:getTemperatureAtTime(g_currentMission.environment.dayTime)

    -- Aggiornamento meteo ogni TICKS_PER_UPDATE tick.
    if self.updateTicks >= RW_GameInfoDisplay.TICKS_PER_UPDATE then
        self.updateTicks = 0
        local environment = g_currentMission.environment

        local _, currentWeather = environment.weather.forecast:dataForTime(environment.currentMonotonicDay, environment.dayTime)

        if currentWeather ~= nil then

            -- Determina il disastro corrente (blizzard/siccità), rispettando i flag globali abilitati.
            if currentWeather.isBlizzard and g_currentMission.missionInfo.isSnowEnabled and Weather.blizzardsEnabled then
                self.currentDisaster = 1
            elseif currentWeather.isDraught and Weather.droughtsEnabled then
                self.currentDisaster = 2
            else
                self.currentDisaster = 0
            end

            -- Calcola il timestamp di fine del meteo corrente (con gestione cambio giorno).
            local currentWeatherEndDay = currentWeather.startDay
            local currentWeatherEndTime = currentWeather.startDayTime + currentWeather.duration

            if currentWeather.startDayTime + currentWeather.duration >= 86400000 then
                currentWeatherEndDay = currentWeatherEndDay + 1
                currentWeatherEndTime = (currentWeather.startDayTime + currentWeather.duration) - 86400000
            end

            -- Legge il prossimo periodo meteo.
            local _, nextWeather = environment.weather.forecast:dataForTime(currentWeatherEndDay, currentWeatherEndTime + 1)

            if nextWeather ~= nil then
                if nextWeather.isBlizzard and g_currentMission.missionInfo.isSnowEnabled and Weather.blizzardsEnabled then
                    self.nextDisaster = 1
                elseif nextWeather.isDraught and Weather.droughtsEnabled then
                    self.nextDisaster = 2
                else
                    self.nextDisaster = 0
                end
            end

            local snowHeight = 0
            local weatherObject = environment.weather:getWeatherObjectByIndex(currentWeather.season, currentWeather.objectIndex)

            self.setSnow = environment.weather.snowHeight

            -- Calcola la neve prevista per il periodo corrente (se tipo SNOW e neve abilitata).
            if g_currentMission.missionInfo.isSnowEnabled and weatherObject.weatherType == WeatherType.SNOW then
                local variation = environment.weather:getForecastInstanceVariation(currentWeather)
                local timeLeft = 0

                if environment.currentDay == currentWeatherEndDay then
                    timeLeft = currentWeatherEndTime - environment.dayTime
                elseif currentWeatherEndDay ~= currentWeather.startDay then
                    timeLeft = currentWeatherEndTime + (86400000 - environment.dayTime)
                else
                    timeLeft = currentWeatherEndTime - environment.dayTime
                end

                if currentWeather.snowForecast == nil then
                    -- Calcola e casha il snowForecast nell'istanza meteo per evitare ricalcoli.
                    -- Formula: SNOW_FACTOR × snowfallScale × avgTempFactor × 0.7 × blizzardMultiplier
                    -- avgTempFactor = 1 - media_temperature * 0.1 (più freddo = più neve)
                    local minutesLeft = (timeLeft / 1000) / 60
                    local minutesMid = (((environment.dayTime / 1000) / 60) + minutesLeft) / 2
                    local endTemp = environment.weather.forecast:getHourlyForecast(math.floor(minutesLeft / 60)).temperature
                    local midTemp = environment.weather.forecast:getHourlyForecast(math.floor(minutesMid / 60)).temperature
                    local averageTemp = 1 - ((endTemp + temperature + midTemp) / 3) * 0.1
                    local snowScale = variation.rain.snowfallScale
                    currentWeather.snowForecast = math.clamp(RW_Weather.FACTOR.SNOW_FACTOR * snowScale * averageTemp * 0.7 * (currentWeather.isBlizzard and Weather.blizzardsEnabled and 10 or 1), 0, RW_Weather.FACTOR.SNOW_HEIGHT)
                end

                local snowForecast = currentWeather.snowForecast
                -- La neve accumulata dipende da quanto tempo è rimasto: più è rimasto → più neve.
                if snowForecast ~= nil then snowHeight = math.clamp(snowHeight + snowForecast * (1 - ((currentWeather.duration - timeLeft) / currentWeather.duration)), 0, RW_Weather.FACTOR.SNOW_HEIGHT) end
            end

            -- Itera sui periodi meteo futuri di tipo SNOW fino a raggiungere SNOW_HEIGHT.
            while nextWeather ~= nil and snowHeight < RW_Weather.FACTOR.SNOW_HEIGHT and g_currentMission.missionInfo.isSnowEnabled do

                weatherObject = environment.weather:getWeatherObjectByIndex(nextWeather.season, nextWeather.objectIndex)
                if weatherObject.weatherType ~= WeatherType.SNOW then break end

                local nextWeatherEndDay = nextWeather.startDay
                local nextWeatherEndTime = nextWeather.startDayTime + nextWeather.duration
                if nextWeather.startDayTime + nextWeather.duration >= 86400000 then
                    nextWeatherEndDay = nextWeatherEndDay + 1
                    nextWeatherEndTime = (nextWeather.startDayTime + nextWeather.duration) - 86400000
                end

                if nextWeather.snowForecast == nil then
                    local variation = environment.weather:getForecastInstanceVariation(nextWeather)
                    -- Calcola durata e temperatura media del periodo futuro.
                    local minutesEnd = ((((nextWeatherEndDay - environment.currentMonotonicDay) * 60000) + nextWeatherEndTime) / 1000) / 60
                    local minutesStart = ((((nextWeather.startDay - environment.currentMonotonicDay) * 60000) + nextWeather.startDayTime) / 1000) / 60
                    local minutesMid = (minutesEnd + minutesStart) / 2

                    local endForecast = environment.weather.forecast:getHourlyForecast(math.floor(minutesEnd / 60))
                    local startForecast = environment.weather.forecast:getHourlyForecast(math.floor(minutesStart / 60))
                    local midForecast = environment.weather.forecast:getHourlyForecast(math.floor(minutesMid / 60))

                    if startForecast ~= nil and endForecast ~= nil and midForecast ~= nil then
                        local averageTemp = 1 - ((endForecast.temperature + startForecast.temperature + midForecast.temperature) / 3) * 0.1
                        local snowScale = variation.rain.snowfallScale
                        -- Per i periodi futuri la neve è proporzionale alla durata in minuti.
                        nextWeather.snowForecast = math.clamp(RW_Weather.FACTOR.SNOW_FACTOR * snowScale * averageTemp * ((nextWeather.duration / 1000) / 60) * 0.7 * (nextWeather.isBlizzard and Weather.blizzardsEnabled and 10 or 1), 0, RW_Weather.FACTOR.SNOW_HEIGHT)
                    end
                end

                local snowForecast = nextWeather.snowForecast
                if snowForecast == nil then break end

                snowHeight = math.clamp(snowHeight + snowForecast, 0, RW_Weather.FACTOR.SNOW_HEIGHT)

                _, nextWeather = environment.weather.forecast:dataForTime(nextWeatherEndDay, nextWeatherEndTime + 1)

            end

            -- ±1.5% di variazione per il range min/max della previsione neve.
            self.snowHeightMin = math.clamp(self.setSnow + snowHeight * 0.985, 0, RW_Weather.FACTOR.SNOW_HEIGHT)
            self.snowHeightMax = math.clamp(self.setSnow + snowHeight * 1.015, 0, RW_Weather.FACTOR.SNOW_HEIGHT)

            -- Se snowHeight corrente == previsione: range puntuale (min == max).
            if environment.weather.snowHeight == snowHeight then
                self.snowHeightMin = snowHeight
                self.snowHeightMax = snowHeight
            end

        end
    end

    -- Aggiornamento contatore tick (clamped a TICKS_PER_UPDATE per evitare overflow).
    self.updateTicks = self.updateTicks >= RW_GameInfoDisplay.TICKS_PER_UPDATE and RW_GameInfoDisplay.TICKS_PER_UPDATE or self.updateTicks + 1

    setTextColor(1, 1, 1, 1)
    setTextBold(true)
    setTextAlignment(RenderText.ALIGN_LEFT)

    -- Rendering temperatura (solo se ExtendedGameInfoDisplay non è attivo).
    if not RW_GameInfoDisplay.isExtendedGameInfoDisplayLoaded then
        if self.temperatureUpdateTicks >= 75 then
            -- Ogni 75 tick alterna tra il formato con suffisso (°C) e senza.
            self.temperatureUpdateTicks = 0
            self.useTemperatureSuffix = not self.useTemperatureSuffix
        end
        renderText(self.temperatureBg.x + self.temperatureTextOffsetX, self.temperatureBg.y + self.temperatureTextOffsetY, self.temperatureTextSize, self.useTemperatureSuffix and g_i18n:formatTemperature(temperature, 0, false) or string.format("%1.0f", g_i18n:getTemperature(temperature)))
        self.temperatureUpdateTicks = self.temperatureUpdateTicks + 1
    end

    -- Rileva nebbia densa: groundFogGroundLevelDensity ≥ 0.65 nell'intervallo di orario attivo.
    local minutes = g_currentMission.environment:getMinuteOfDay()
    local fog = g_currentMission.environment.weather.fogUpdater.targetFog
    local thickFog = false
    if fog ~= nil then thickFog = minutes >= fog.groundFogStartDayTimeMinutes and minutes < fog.groundFogEndDayTimeMinutes and fog.groundFogGroundLevelDensity >= 0.65 end

    local offsetX, offsetY = self.disasterTextOffsetX, self.disasterTextOffsetY
    self.disasterBg.width = self.disasterWidth

    -- Mostra il pannello disastro/nebbia se c'è qualcosa da comunicare.
    if self.currentDisaster ~= 0 or self.nextDisaster ~= 0 or thickFog then

        if not RW_GameInfoDisplay.isExtendedGameInfoDisplayLoaded then
            -- Separatore tra pannello temperatura e pannello disastro.
            drawLine2D(self.temperatureBg.x, y - self.infoBgLeft.height + self.separatorOffsetY, self.temperatureBg.x, y - self.infoBgLeft.height + self.separatorHeight + self.separatorOffsetY, self.separatorWidth, 1, 1, 1, 0.2)
        end

        -- In modalità carosello (blizzard attivo + previsione neve): allarga il pannello.
        if (self.currentDisaster == 1 or self.nextDisaster == 1 or thickFog) and self.carouselTextFull2 ~= nil then self.disasterBg.width = self.carouselWidth end

        elementLoaded = true
        self.disasterBg:setPosition(self.temperatureBg.x - self.disasterBg.width, y - self.disasterBg.height)
        self.disasterBg:render()
        self.temperatureBgLeft:setPosition(self.disasterBg.x - self.temperatureBgLeft.width, y - self.temperatureBgLeft.height)

        local disaster = ""

        if self.currentDisaster ~= 0 then
            -- Disastro corrente: testo rosso intenso.
            setTextColor(1, 0.12, 0, 1)
            disaster = (self.currentDisaster == 1 and self.blizzardNowText) or (self.currentDisaster == 2 and self.droughtNowText) or ""
            self.carouselTextFull1 = disaster

            -- Resetta il carosello se il tipo è cambiato.
            if self.lastCarousel ~= 1 then
                self.pendingCarouselReset = false
                self.carouselX1 = self.carouselWidth
                self.carouselX2 = self.carouselWidth * 1.5
                self.carouselText1 = nil
                self.carouselText2 = nil
                self.lastCarousel = 1
            end
        elseif self.nextDisaster ~= 0 then
            -- Prossimo disastro: testo arancio (avvertimento).
            setTextColor(1, 0.5, 0, 1)
            disaster = (self.nextDisaster == 1 and self.blizzardComingText) or (self.nextDisaster == 2 and self.droughtComingText) or ""
        else
            -- Solo nebbia: testo arancio con tempo rimanente.
            setTextColor(1, 0.5, 0, 1)
            local minutesLeft = math.ceil(fog.groundFogEndDayTimeMinutes - minutes)
            local timeLeftString = minutesLeft >= 60 and "hour" or "minute"
            if (timeLeftString == "hour" and minutesLeft >= 120) or (timeLeftString == "minute" and minutesLeft >= 2) then timeLeftString = timeLeftString .. "s" end
            if timeLeftString == "hour" or timeLeftString == "hours" then minutesLeft = math.floor(minutesLeft / 60) end
            -- Per la nebbia: usa il carosello con testo nebbia + durata rimanente.
            self.carouselTextFull1 = self.fogText
            self.carouselTextFull2 = string.format(g_i18n:getText("rw_ui_" .. timeLeftString), minutesLeft)

            if self.lastCarousel ~= 2 then
                self.pendingCarouselReset = false
                self.carouselX1 = self.carouselWidth
                self.carouselX2 = self.carouselWidth * 1.5
                self.carouselText1 = nil
                self.carouselText2 = nil
                self.lastCarousel = 2
            end
        end

        -- Rendering testo: statico per siccità, carosello per blizzard/nebbia.
        if self.currentDisaster == 2 or self.nextDisaster == 2 or self.carouselTextFull2 == nil or self.carouselTextFull1 == nil then
            -- Rendering statico: testo centrato nel pannello.
            renderText(self.disasterBg.x + offsetX, self.disasterBg.y + offsetY, self.temperatureTextSize, disaster)
        else
            -- Rendering carosello: due testi scorrevoli con clip area.
            if self.carouselText1 == nil then self.carouselText1 = string.sub(self.carouselTextFull1, 1, 1) end

            self.carouselBlockLeft:setPosition(self.disasterBg.x, y - self.carouselBlockLeft.height)
            self.carouselBlockRight:setPosition(self.disasterBg.x + self.carouselWidth - self.carouselOffset, y - self.carouselBlockRight.height)

            local carouselX1 = self.carouselX1
            local carouselX2 = self.carouselX2

            local textWidth1 = getTextWidth(self.temperatureTextSize, self.carouselText1)
            local textWidth2 = getTextWidth(self.temperatureTextSize, self.carouselText2 or "")

            local shownChars = #self.carouselText1
            local shownChars2 = self.carouselText2 ~= nil and #self.carouselText2 or 0

            -- Avanza i testi verso sinistra (velocità proporzionale alla larghezza del pannello).
            carouselX1 = carouselX1 - self.disasterBg.width / 600
            carouselX2 = carouselX2 - self.disasterBg.width / 600

            -- Gestione wrap-around e riduzione caratteri visibili per testo 1.
            if carouselX1 < 0 then
                shownChars = shownChars - 1
                if shownChars <= 0 then
                    -- Testo 1 completamente uscito: riposiziona a destra e ricomincia da 1 char.
                    carouselX1 = self.disasterBg.width - self.carouselOffset
                    local textWidthFull2 = getTextWidth(self.temperatureTextSize, self.carouselTextFull2 or "")
                    if not self.pendingCarouselReset and carouselX2 >= self.carouselWidth - textWidthFull2 then carouselX1 = carouselX2 + (self.carouselWidth - carouselX2) + textWidthFull2 * 0.25 end
                    shownChars = 1
                    self.carouselText1 = string.sub(self.carouselTextFull1, 1, 1)
                else
                    -- Rimuove il carattere più a sinistra man mano che esce dall'area.
                    local singleTextWidth = getTextWidth(self.temperatureTextSize, string.sub(self.carouselText1, 1, 1))
                    self.carouselText1 = string.sub(self.carouselTextFull1, #self.carouselTextFull1 - shownChars + 1)
                    carouselX1 = carouselX1 + singleTextWidth
                end
            elseif carouselX1 > self.disasterBg.width * 0.2 and carouselX1 <= self.disasterBg.width - textWidth1 - self.carouselOffset and shownChars < #self.carouselTextFull1 then
                -- Espande progressivamente il testo visibile mentre entra nell'area.
                shownChars = math.min(shownChars + 1, #self.carouselTextFull1)
                self.carouselText1 = string.sub(self.carouselTextFull1, 1, shownChars)
            end

            -- Gestione pendingCarouselReset: attende che text1 sia completo prima di riposizionare text2.
            if self.pendingCarouselReset then
                local fullWidth1 = getTextWidth(self.temperatureTextSize, self.carouselTextFull1)
                local fullWidth2 = getTextWidth(self.temperatureTextSize, self.carouselTextFull2)
                if shownChars >= #self.carouselTextFull1 and self.carouselWidth - fullWidth1 >= fullWidth2 * 0.75 then
                    self.pendingCarouselReset = false
                    self.carouselText2 = string.sub(self.carouselTextFull2, 1, 1)
                    local charWidth = getTextWidth(self.temperatureTextSize, self.carouselText2)
                    carouselX2 = self.carouselWidth + charWidth
                end
            else
                -- Gestione wrap-around e riduzione caratteri per testo 2.
                if carouselX2 < 0 and self.carouselText2 ~= nil then
                    shownChars2 = math.min(shownChars2, #self.carouselText2) - 1
                    if shownChars2 <= 0 then
                        carouselX2 = self.disasterBg.width - self.carouselOffset
                        self.carouselText2 = string.sub(self.carouselTextFull2, 1, 1)
                        if carouselX1 < self.pendingCarouselResetThreshold then self.pendingCarouselReset = true end
                    else
                        local singleTextWidth = getTextWidth(self.temperatureTextSize, string.sub(self.carouselText2, 1, 1))
                        self.carouselText2 = string.sub(self.carouselTextFull2, #self.carouselTextFull2 - shownChars2 + 1)
                        carouselX2 = carouselX2 + singleTextWidth
                    end
                elseif carouselX2 > self.disasterBg.width * 0.2 and carouselX2 <= self.disasterBg.width - textWidth2 - self.carouselOffset and shownChars2 < #self.carouselTextFull2 then
                    shownChars2 = math.min(shownChars2 + 1, #self.carouselTextFull2)
                    self.carouselText2 = string.sub(self.carouselTextFull2, 1, shownChars2)
                end
            end

            -- Clip area: nasconde i testi oltre i blocchi border del carosello.
            setTextClipArea(self.carouselBlockLeft.x + self.carouselBlockLeft.width, 0, self.carouselBlockRight.x, 1)

            renderText(self.disasterBg.x + carouselX1, self.disasterBg.y + offsetY, self.temperatureTextSize, self.carouselText1)
            if self.carouselText2 ~= nil and not self.pendingCarouselReset then renderText(self.disasterBg.x + carouselX2, self.disasterBg.y + offsetY, self.temperatureTextSize, self.carouselText2) end

            -- Aggiorna le posizioni per il prossimo frame.
            self.carouselX1 = carouselX1
            self.carouselX2 = carouselX2

            self.carouselBlockLeft:render()
            self.carouselBlockRight:render()

            setTextClipArea(0, 0, 1, 1)   -- ripristina la clip area globale
        end

    else
        -- Nessun disastro né nebbia: il temperatureBgLeft si posiziona accanto al pannello temperatura.
        self.temperatureBgLeft:setPosition(self.temperatureBg.x - self.temperatureBgLeft.width, y - self.temperatureBgLeft.height)
    end

    -- Pannello neve prevista (solo se snowHeightMax > 0 e nessun blizzard attivo).
    if self.snowHeightMax > 0 then

        elementLoaded = true

        if self.currentDisaster ~= 1 and self.nextDisaster ~= 1 then
            -- Pannello neve autonomo (non blizzard): posizionato a sinistra del disasterBg o temperatureBg.
            if self.currentDisaster ~= 0 or self.nextDisaster ~= 0 or thickFog then
                self.snowAmountBg:setPosition(self.disasterBg.x - self.snowAmountBg.width, y - self.snowAmountBg.height)
                drawLine2D(self.disasterBg.x - offsetX, y - self.disasterBg.height + self.separatorOffsetY, self.disasterBg.x - offsetX, y - self.disasterBg.height + self.separatorHeight + self.separatorOffsetY, self.separatorWidth, 1, 1, 1, 0.2)
            else
                self.snowAmountBg:setPosition(self.temperatureBg.x - self.snowAmountBg.width, y - self.snowAmountBg.height)
                drawLine2D(self.temperatureBg.x - self.temperatureTextOffsetX, y - self.temperatureBg.height + self.separatorOffsetY, self.temperatureBg.x - self.temperatureTextOffsetX, y - self.temperatureBg.height + self.separatorHeight + self.separatorOffsetY, self.separatorWidth, 1, 1, 1, 0.2)
            end

            self.snowAmountBg:render()
            self.temperatureBgLeft:setPosition(self.snowAmountBg.x - self.temperatureBgLeft.width, y - self.temperatureBgLeft.height)

            -- Mostra valore singolo (min==max) o range (min≠max).
            if self.snowHeightMin == self.snowHeightMax then
                renderText(self.snowAmountBg.x + self.snowOneTextOffsetX, self.snowAmountBg.y + self.snowTextOffsetY, self.temperatureTextSize, string.format(self.snowOneText, math.round(self.snowHeightMax * 100)))
                self.snowAmountBg:setDimension(self.snowAmountBgOneWidth, self.snowAmountBgHeight)
            else
                renderText(self.snowAmountBg.x + self.snowTextOffsetX, self.snowAmountBg.y + self.snowTextOffsetY, self.temperatureTextSize, string.format(self.snowText, math.floor(self.snowHeightMin * 100), math.ceil(self.snowHeightMax * 100)))
                self.snowAmountBg:setDimension(self.snowAmountBgWidth, self.snowAmountBgHeight)
            end

        else
            -- In modalità blizzard: la previsione neve va nel carosello come carouselTextFull2.
            if self.snowHeightMin == self.snowHeightMax then
                self.carouselTextFull2 = string.format(self.snowOneText, math.round(self.snowHeightMax * 100))
            else
                self.carouselTextFull2 = string.format(self.snowText, math.floor(self.snowHeightMin * 100), math.ceil(self.snowHeightMax * 100))
            end
        end

    end

    setTextBold(false)
    -- Renderizza il pannello left (bordo arrotondato) solo se almeno un pannello extra è visibile.
    if elementLoaded then self.temperatureBgLeft:render() end

end

GameInfoDisplay.draw = Utils.appendedFunction(GameInfoDisplay.draw, RW_GameInfoDisplay.draw)
