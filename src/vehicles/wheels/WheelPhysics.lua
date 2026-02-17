RW_WheelPhysics = {}
local FRICTION_EPSILON = 0.00001

local function getRWAdditionalFrictionFactor(self, groundWetness)
    local densityType = self.densityType ~= FieldGroundType.NONE
    local snowFactor = 0

    if self.hasSnowContact then
        if self.snowHeight ~= nil then
            snowFactor = 1 + (self.snowHeight * 0.33)
        else
            snowFactor = 1
        end
        groundWetness = 0
    end

    local ground = WheelsUtil.getGroundType(densityType, self.contact ~= WheelContactType.GROUND, self.groundDepth)
    local rwFriction = WheelsUtil.getTireFriction(self.tireType, ground, groundWetness, snowFactor)
    local vanillaFriction = WheelsUtil.getTireFriction(self.tireType, ground, groundWetness, 0)

    if vanillaFriction == nil or vanillaFriction == 0 then
        return 1
    end

    local width = self.width
    local mass = self.vehicle:getTotalMass()
    local wheels = self.vehicle.spec_wheels ~= nil and self.vehicle.spec_wheels.wheels ~= nil and #self.vehicle.spec_wheels.wheels or 1
    local widthToMassRatio = math.min(width / (mass / math.max(wheels, 1)), 1)

    rwFriction = rwFriction / (1.5 - math.min(width, 1))
    vanillaFriction = vanillaFriction / (1.5 - math.min(width, 1))

    if self.hasSnowContact and mass < 8 then
        local widthFactor = widthToMassRatio > 0.06 and widthToMassRatio < 0.12 and (1 + (width / 5)) or (1 - (width / 5))
        rwFriction = rwFriction * widthFactor
        vanillaFriction = vanillaFriction * widthFactor
    end

    if self.hasSnowContact then
        local timeSinceLastRain = g_currentMission.environment.weather.timeSinceLastRain or 0
        local wetPenalty = math.clamp(timeSinceLastRain / 1440, 1, 3)
        rwFriction = rwFriction / wetPenalty
        vanillaFriction = vanillaFriction / wetPenalty
    end

    return math.max(rwFriction / vanillaFriction, 0.01)
end

function RW_WheelPhysics:updateFriction(superFunc, groundType, groundWetness)
    -- RW_COMPAT_FIX: preserve GIANTS/MoreRealistic friction pipeline first
    local ok = pcall(superFunc, self, groundType, groundWetness)
    if not ok then return end

    if self.vehicle:getLastSpeed() <= 0.2 then return end

    local baseFriction = self.tireGroundFrictionCoeff
    if baseFriction == nil then return end

    local rwFactor = getRWAdditionalFrictionFactor(self, groundWetness)
    local friction = baseFriction * rwFactor

    -- RW_COMPAT_FIX: avoid deterministic double-multiplication with MoreRealistic
    if g_modIsLoaded["morerealistic_25"] and self.rwLastAppliedFriction ~= nil and math.abs(baseFriction - self.rwLastAppliedFriction) < FRICTION_EPSILON then
        return
    end

    if friction ~= self.tireGroundFrictionCoeff then
        self.tireGroundFrictionCoeff = friction
        self.rwLastAppliedFriction = friction
        self.isFrictionDirty = true
    end

end

WheelPhysics.updateFriction = Utils.overwrittenFunction(WheelPhysics.updateFriction, RW_WheelPhysics.updateFriction)
