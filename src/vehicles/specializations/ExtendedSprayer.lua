
ExtendedSprayer = {}


function ExtendedSprayer.prerequisitesPresent(specializations)
    return SpecializationUtil.hasSpecialization(Sprayer, specializations)
end


function ExtendedSprayer.registerFunctions(vehicleType) end


function ExtendedSprayer.registerOverwrittenFunctions(vehicleType)
    SpecializationUtil.registerOverwrittenFunction(vehicleType, "processSprayerArea", ExtendedSprayer.processSprayerArea)
    SpecializationUtil.registerOverwrittenFunction(vehicleType, "getSprayerUsage", ExtendedSprayer.getSprayerUsage)
    SpecializationUtil.registerOverwrittenFunction(vehicleType, "updateSprayerEffects", ExtendedSprayer.updateSprayerEffects)
end


function ExtendedSprayer:processSprayerArea(superFunc, workArea, dt)

    local changedArea, totalArea = superFunc(self, workArea, dt)

    if changedArea <= 0 then
        return changedArea, totalArea
    end

    if self.isServer then

        local moistureSystem = g_currentMission.moistureSystem

        if moistureSystem == nil then return changedArea, totalArea end

        local fillType = self.spec_sprayer.workAreaParameters.sprayFillType
        if fillType == nil or fillType == FillType.UNKNOWN then
            return changedArea, totalArea
        end

        local factor = MoistureSystem.SPRAY_FACTOR[self.spec_sprayer.isSlurryTanker and "slurry" or "fertilizer"]

        local target = { ["moisture"] = factor * (fillType == FillType.WATER and 4 or 1) * moistureSystem.moistureGainModifier }

        local sx, _, sz = getWorldTranslation(workArea.start)
        local wx, _, wz = getWorldTranslation(workArea.width)
        local hx, _, hz = getWorldTranslation(workArea.height)

        local widthX = wx - sx
        local widthZ = wz - sz
        local heightX = hx - sx
        local heightZ = hz - sz

        local widthSamples = math.max(1, math.floor(MathUtil.vector2Length(widthX, widthZ) * 2))
        local heightSamples = math.max(1, math.floor(MathUtil.vector2Length(heightX, heightZ) * 2))

        local fieldGroundSystem = g_currentMission.fieldGroundSystem

        for i = 0, widthSamples do

            local widthFactor = i / widthSamples

            for j = 0, heightSamples do

                local heightFactor = j / heightSamples

                local x = sx + widthX * widthFactor + heightX * heightFactor
                local z = sz + widthZ * widthFactor + heightZ * heightFactor

                local groundTypeValue = fieldGroundSystem:getValueAtWorldPos(FieldDensityMap.GROUND_TYPE, x, 0, z)
                local groundType = FieldGroundType.getTypeByValue(groundTypeValue)

                if groundType ~= FieldGroundType.NONE then
                    moistureSystem:setValuesAtCoords(x, z, target, true)
                end

            end

        end

    end

    return changedArea, totalArea

end


function ExtendedSprayer:getSprayerUsage(superFunc, fillType, dT)

    local usage = superFunc(self, fillType, dT)

    if fillType == FillType.WATER then usage = usage * 0.14 end

    return usage

end


function ExtendedSprayer:updateSprayerEffects(superFunc, force)

    local spec = self.spec_sprayer

    local fillType = self:getFillUnitLastValidFillType(self:getSprayerFillUnitIndex())
    if fillType == FillType.UNKNOWN then
        fillType = self:getFillUnitFirstSupportedFillType(self:getSprayerFillUnitIndex())
    end

    if fillType ~= FillType.WATER then
        return superFunc(self, force)
    end

    local effectsState = self:getAreEffectsVisible()
    if effectsState ~= spec.lastEffectsState or force then

        if effectsState then

            g_effectManager:setEffectTypeInfo(spec.effects, FillType.LIQUIDFERTILIZER)
            g_effectManager:startEffects(spec.effects)
            g_soundManager:playSamples(spec.samples.spray)
            g_animationManager:startAnimations(spec.animationNodes)

            spec.lastEffectsState = effectsState

        else
            g_effectManager:stopEffects(spec.effects)
            g_animationManager:stopAnimations(spec.animationNodes)

            spec.lastEffectsState = effectsState

        end

    end
end