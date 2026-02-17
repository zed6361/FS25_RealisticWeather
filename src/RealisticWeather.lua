RealisticWeather = {}
local RealisticWeather_mt = Class(RealisticWeather)
local modDirectory = g_currentModDirectory

--source(modDirectory .. "src/gui/InGameMenuMapFrameExtension.lua")
source(modDirectory .. "src/test/OptimisationTest.lua")


function RealisticWeather.new()

	local self = setmetatable({}, RealisticWeather_mt)

    self.changedFunctions = {}

	return self

end


function RealisticWeather:initialise()

    --self.inGameMenuMapFrameExtension = InGameMenuMapFrameExtension.new()
    --self.inGameMenuMapFrameExtension:overwriteGameFunctions()

end


function RealisticWeather.loadMap()

    g_realisticWeather:executeFunctionChanges()

end


function RealisticWeather:registerFunction(object, oldFunc, newFunc, changeFunc)

	table.insert(self.changedFunctions, {
		["object"] = object,
		["oldFunc"] = oldFunc,
		["newFunc"] = newFunc,
		["changeFunc"] = changeFunc or "overwritten"
	})

end


function RealisticWeather:executeFunctionChanges()

	for _, func in pairs(self.changedFunctions) do

		func.object[func.oldFunc] = Utils[func.changeFunc .. "Function"](func.object[func.oldFunc], func.newFunc)

	end

end


function RealisticWeather:getMoistureFromWorkArea(workArea)

    if workArea == nil then return nil end

    local xs, _ ,zs = getWorldTranslation(workArea.start)
    local xw, _, zw = getWorldTranslation(workArea.width)
    local xh, _, zh = getWorldTranslation(workArea.height)

    local target = { "moisture" }

    local startMoistureValues = g_currentMission.moistureSystem:getValuesAtCoords(xs, zs, target)
    local widthMoistureValues = g_currentMission.moistureSystem:getValuesAtCoords(xw, zw, target)
    local heightMoistureValues = g_currentMission.moistureSystem:getValuesAtCoords(xh, zh, target)

    local startMoisture = startMoistureValues ~= nil and startMoistureValues.moisture ~= nil and startMoistureValues.moisture or 0
    local widthMoisture = widthMoistureValues ~= nil and widthMoistureValues.moisture ~= nil and widthMoistureValues.moisture or 0
    local heightMoisture = heightMoistureValues ~= nil and heightMoistureValues.moisture ~= nil and heightMoistureValues.moisture or 0

    return (startMoisture + widthMoisture + heightMoisture) / 3

end


function RealisticWeather:preProcessMowerArea(mower, workArea, dt)

    self.mowerMoisture = self:getMoistureFromWorkArea(workArea)

end


function RealisticWeather:postProcessMowerArea(mower, workArea, dt, lastChangedArea)

    self.mowerMoisture = nil

end


function RealisticWeather:preProcessCutterArea(cutter, workArea, dt)

    self.cutterMoisture = self:getMoistureFromWorkArea(workArea)

end


function RealisticWeather:postProcessCutterArea(cutter, workArea, dt, lastChangedArea)

    self.cutterMoisture = nil

end


g_realisticWeather = RealisticWeather.new()
g_realisticWeather:initialise()
addModEventListener(RealisticWeather)


g_realisticWeather:registerFunction(FSBaseMission, "getHarvestScaleMultiplier", function(self, superFunc, fruitTypeIndex, sprayLevel, plowLevel, limeLevel, weedsLevel, stubbleLevel, rollerLevel, beeYieldBonusPercentage)

    -- RW_CRITICAL_FIX: preserve GIANTS base behavior and avoid hard-fail on upstream errors
    local okBase, baseYield = pcall(superFunc, self, fruitTypeIndex, sprayLevel, plowLevel, limeLevel, weedsLevel, stubbleLevel, rollerLevel, beeYieldBonusPercentage)
    if not okBase then
        print(string.format("RealisticWeather: getHarvestScaleMultiplier base call failed (%s)", tostring(baseYield)))
        return 1
    end

    -- RW_COMPAT_FIX: Precision Farming compatibility guard
    if RW_FSBaseMission ~= nil and RW_FSBaseMission.isPrecisionFarmingLoaded then
        return baseYield
    end

    if g_currentMission == nil or g_currentMission.moistureSystem == nil then
        return baseYield
    end

    local moisture = g_realisticWeather.mowerMoisture or g_realisticWeather.cutterMoisture or g_realisticWeather.fieldMoisture

    if moisture == nil then return baseYield end

    local moistureFactor = 1
    local fruitType = g_fruitTypeManager:getFruitTypeNameByIndex(fruitTypeIndex)
    local fruitTypeMoistureFactor = RW_FSBaseMission.FRUIT_TYPES_MOISTURE[fruitType] or RW_FSBaseMission.FRUIT_TYPES_MOISTURE.DEFAULT

    if fruitTypeMoistureFactor ~= nil then

        local lowMoisture = fruitTypeMoistureFactor.LOW
        local highMoisture = fruitTypeMoistureFactor.HIGH
        local perfectMoisture = (highMoisture + lowMoisture) / 2


        moistureFactor = moisture / perfectMoisture

        if moisture > perfectMoisture then moistureFactor = 2 - moistureFactor end

        moistureFactor = math.clamp(moistureFactor, 0.1, 1)

        if moisture >= lowMoisture and moisture <= highMoisture then moistureFactor = moistureFactor + math.max(1.5 - 2 * (1 - moistureFactor), 0.5) end

    end

    return math.max(baseYield + (-0.65 + moistureFactor) * self.moistureYieldFactor, 0)

end)
