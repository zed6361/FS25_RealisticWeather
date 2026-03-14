-- WheelDestruction.lua (RW_WheelDestruction)
-- Override di WheelDestruction.destroySnowArea per simulare l'affondamento
-- realistico delle ruote nel manto nevoso in base alla massa del veicolo.
--
-- Logica principale:
--   - Chiama prima la funzione base/MoreRealistic con pcall (RW_COMPAT_FIX: additivo)
--   - Legge l'altezza della neve nell'area della ruota
--   - Calcola sinkHeight (altezza dopo l'affondamento) in base a:
--       massPerWheel = massaTotale / numRuote
--       sinkHeight = snowHeight - massPerWheel × 0.0075 (più pesante = affonda di più)
--   - minSinkHeight: limite inferiore che dipende dalla classe di massa del veicolo:
--       mass < 4t:  base 1 - massPerWheel × 0.08
--       mass < 8t:  base 1 - massPerWheel × 0.12
--       mass < 11t: base 1 - massPerWheel × 0.17
--       mass < 15t: base 1 - massPerWheel × 0.2
--     Il minSinkHeight viene ridotto proporzionalmente al groundWetness (neve bagnata = più compressa)
--     con un minimo al 75% del valore asciutto.
--   - Aggiorna il snowHeight nell'area con setSnowHeightAtArea solo se snowHeight > sinkHeight
--   - Gestisce le ruote gemellate: espande il range x dell'area per ogni ruota visiva aggiuntiva
--   - Aggiorna wheel.physics.snowHeight per permettere al sistema di frizione di conoscere
--     la profondità della neve sotto la ruota
--   - throttle con TICKS_PER_DESTRUCTION=12: il calcolo avviene solo ogni 12 tick per performance

RW_WheelDestruction = {}
RW_WheelDestruction.TICKS_PER_DESTRUCTION = 12  -- intervallo tick tra un calcolo di affondamento e il successivo


-- Override di WheelDestruction.destroySnowArea.
-- @param x0,z0  punto di partenza dell'area ruota
-- @param x1,z1  punto larghezza dell'area ruota
-- @param x2,z2  punto altezza dell'area ruota
function RW_WheelDestruction:destroySnowArea(superFunc, x0, z0, x1, z1, x2, z2)
    -- RW_COMPAT_FIX: preserve base / MoreRealistic snow destruction first
    pcall(superFunc, self, x0, z0, x1, z1, x2, z2)

    local snowSystem = g_currentMission.snowSystem
    local snowHeight = snowSystem:getSnowHeightAtArea(x0, z0, x1, z1, x2, z2)
    local sinkHeight

    if self.ticksSinceLastDestruction == nil then self.ticksSinceLastDestruction = RW_WheelDestruction.TICKS_PER_DESTRUCTION end

    if SnowSystem.MIN_LAYER_HEIGHT < snowHeight and self.ticksSinceLastDestruction >= RW_WheelDestruction.TICKS_PER_DESTRUCTION then
        local mass = self.vehicle:getTotalMass()
        local wheels = 0

        if self.vehicle.spec_wheels ~= nil and self.vehicle.spec_wheels.wheels ~= nil then wheels = #self.vehicle.spec_wheels.wheels end

        local wheelsFull = self.vehicle.spec_wheels ~= nil and self.vehicle.spec_wheels.wheels or nil
        if wheelsFull == nil then
            -- Fallback: nessuna lista ruote disponibile, aggiorna solo physics.snowHeight.
            if self.wheel ~= nil and self.wheel.physics ~= nil then
                self.wheel.physics.snowHeight = snowHeight
            end
            return
        end

        -- Gestione ruote gemellate: conta le ruote visive aggiuntive e espande l'area.
        for _, wheel in pairs(wheelsFull) do
            if wheel.visualWheels ~= nil and #wheel.visualWheels > 1 then
                wheels = wheels + #wheel.visualWheels - 1
                if wheel == self.wheel then
                    for i, visualWheel in pairs(wheel.visualWheels) do
                        if i == 1 then continue end
                        -- Espande il range laterale dell'area per le ruote gemellate.
                        x2 = x2 + visualWheel.width * 1.2
                        x1 = x1 - visualWheel.width * 1.2
                    end
                end
            end
        end

        local massPerWheel = mass / (wheels == 0 and 1 or wheels)
        -- Affondamento: più il veicolo è pesante, più la neve si comprime.
        sinkHeight = math.max(snowHeight - massPerWheel * 0.0075, SnowSystem.MIN_LAYER_HEIGHT)
        local minSinkHeight = 0

        -- Limiti minimi per classe di massa: veicoli leggeri affondano meno in proporzione.
        if mass < 4 then
            minSinkHeight = 1 - massPerWheel * 0.08
        elseif mass < 8 then
            minSinkHeight = 1 - massPerWheel * 0.12
        elseif mass < 11 then
            minSinkHeight = 1 - massPerWheel * 0.17
        elseif mass < 15 then
            minSinkHeight = 1 - massPerWheel * 0.2
        end

        -- Neve bagnata (groundWetness > 0) si comprime più facilmente (minSinkHeight ridotto).
        local groundWetness = g_currentMission.environment.weather:getGroundWetness()
        minSinkHeight = math.max(minSinkHeight * (1 - groundWetness), minSinkHeight * 0.75)

        sinkHeight = math.max(sinkHeight, minSinkHeight * snowSystem.height)

        if snowHeight > sinkHeight then

            -- RW_COMPAT_FIX: additive post-adjustment, never replace full base calculation
            snowSystem:setSnowHeightAtArea(x0, z0, x1, z1, x2, z2, sinkHeight)
            self.ticksSinceLastDestruction = 0

        end
    end

    -- Aggiorna la profondità neve nota dal sistema di fisica della ruota.
    if self.wheel ~= nil and self.wheel.physics ~= nil then
        self.wheel.physics.snowHeight = sinkHeight or snowHeight
    end

    -- Avanza il contatore tick (saturato a TICKS_PER_DESTRUCTION per evitare overflow).
    self.ticksSinceLastDestruction = self.ticksSinceLastDestruction >= RW_WheelDestruction.TICKS_PER_DESTRUCTION - 1 and RW_WheelDestruction.TICKS_PER_DESTRUCTION or self.ticksSinceLastDestruction + 1

end

WheelDestruction.destroySnowArea = Utils.overwrittenFunction(WheelDestruction.destroySnowArea, RW_WheelDestruction.destroySnowArea)
