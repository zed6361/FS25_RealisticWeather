RW_FSBaseMission = {}
local modDirectory = g_currentModDirectory

RW_FSBaseMission.FRUIT_TYPES_MOISTURE = {
    ["DEFAULT"] = {
        ["LOW"] = 0.15,
        ["HIGH"] = 0.18
    },
    ["BARLEY"] = {
        ["LOW"] = 0.12,
        ["HIGH"] = 0.135
    },
    ["WHEAT"] = {
        ["LOW"] = 0.12,
        ["HIGH"] = 0.145
    },
    ["OAT"] = {
        ["LOW"] = 0.12,
        ["HIGH"] = 0.18
    },
    ["CANOLA"] = {
        ["LOW"] = 0.08,
        ["HIGH"] = 0.1
    },
    ["SOYBEAN"] = {
        ["LOW"] = 0.125,
        ["HIGH"] = 0.135
    },
    ["SORGHUM"] = {
        ["LOW"] = 0.17,
        ["HIGH"] = 0.2
    },
    ["RICELONGGRAIN"] = {
        ["LOW"] = 0.19,
        ["HIGH"] = 0.22
    },
    ["MAIZE"] = {
        ["LOW"] = 0.15,
        ["HIGH"] = 0.2
    },
    ["SUNFLOWER"] = {
        ["LOW"] = 0.09,
        ["HIGH"] = 0.1
    },
    ["GRASS"] = {
        ["LOW"] = 0.18,
        ["HIGH"] = 0.22
    },
    ["OILSEEDRADISH"] = {
        ["LOW"] = 0.2,
        ["HIGH"] = 0.22
    },
    ["PEA"] = {
        ["LOW"] = 0.14,
        ["HIGH"] = 0.15
    },
    ["SPINACH"] = {
        ["LOW"] = 0.2,
        ["HIGH"] = 0.22
    },
    ["SUGARCANE"] = {
        ["LOW"] = 0.22,
        ["HIGH"] = 0.26
    },
    ["SUGARBEET"] = {
        ["LOW"] = 0.22,
        ["HIGH"] = 0.26
    },
    ["COTTON"] = {
        ["LOW"] = 0.1,
        ["HIGH"] = 0.12
    },
    ["GREENBEAN"] = {
        ["LOW"] = 0.175,
        ["HIGH"] = 0.185
    },
    ["CARROT"] = {
        ["LOW"] = 0.135,
        ["HIGH"] = 0.155
    },
    ["PARSNIP"] = {
        ["LOW"] = 0.135,
        ["HIGH"] = 0.155
    },
    ["BEETROOT"] = {
        ["LOW"] = 0.15,
        ["HIGH"] = 0.17
    },
    ["RICE"] = {
        ["LOW"] = 0.22,
        ["HIGH"] = 0.24
    },
    ["POTATO"] = {
        ["LOW"] = 0.18,
        ["HIGH"] = 0.2
    }
}


local function fixInGameMenu(frame, pageName, uvs, position, predicateFunc)

	local inGameMenu = g_gui.screenControllers[InGameMenu]
	position = position or #inGameMenu.pagingElement.pages + 1

	for k, v in pairs({pageName}) do
		inGameMenu.controlIDs[v] = nil
	end

	for i = 1, #inGameMenu.pagingElement.elements do
		local child = inGameMenu.pagingElement.elements[i]
		if child == inGameMenu.pageAnimals then
			position = i
            break
		end
	end
	
	inGameMenu[pageName] = frame
	inGameMenu.pagingElement:addElement(inGameMenu[pageName])

	inGameMenu:exposeControlsAsFields(pageName)

	for i = 1, #inGameMenu.pagingElement.elements do
		local child = inGameMenu.pagingElement.elements[i]
		if child == inGameMenu[pageName] then
			table.remove(inGameMenu.pagingElement.elements, i)
			table.insert(inGameMenu.pagingElement.elements, position, child)
			break
		end
	end

	for i = 1, #inGameMenu.pagingElement.pages do
		local child = inGameMenu.pagingElement.pages[i]
		if child.element == inGameMenu[pageName] then
			table.remove(inGameMenu.pagingElement.pages, i)
			table.insert(inGameMenu.pagingElement.pages, position, child)
			break
		end
	end

	inGameMenu.pagingElement:updateAbsolutePosition()
	inGameMenu.pagingElement:updatePageMapping()
	
	inGameMenu:registerPage(inGameMenu[pageName], position, predicateFunc)
	inGameMenu:addPageTab(inGameMenu[pageName], modDirectory .. "gui/icons.dds", GuiUtils.getUVs(uvs))

	for i = 1, #inGameMenu.pageFrames do
		local child = inGameMenu.pageFrames[i]
		if child == inGameMenu[pageName] then
			table.remove(inGameMenu.pageFrames, i)
			table.insert(inGameMenu.pageFrames, position, child)
			break
		end
	end

	inGameMenu:rebuildTabList()

end


function RW_FSBaseMission:onStartMission()

    --g_realisticWeather:executeFunctionChanges()

	RWSettings.applyDefaultSettings()

    g_overlayManager:addTextureConfigFile(modDirectory .. "gui/icons.xml", "realistic_weather")
    g_overlayManager:addTextureConfigFile(modDirectory .. "gui/page_icons.xml", "realistic_weather_pages")

    if g_modIsLoaded["FS25_RealisticLivestock"] then RW_Weather.isRealisticLivestockLoaded = true end
    if g_modIsLoaded["FS25_ExtendedGameInfoDisplay"] then RW_GameInfoDisplay.isExtendedGameInfoDisplayLoaded = true end
    -- RW_COMPAT_FIX: keep yield logic deterministic with Precision Farming
    RW_FSBaseMission.isPrecisionFarmingLoaded = g_modIsLoaded["FS25_precisionFarming"] or g_modIsLoaded["FS25_PrecisionFarming"] or g_modIsLoaded["precisionFarming"]

    local realisticWeatherFrame = RealisticWeatherFrame.new() 
	g_gui:loadGui(modDirectory .. "gui/RealisticWeatherFrame.xml", "RealisticWeatherFrame", realisticWeatherFrame, true)

    fixInGameMenu(realisticWeatherFrame, "realisticWeatherFrame", {260,0,256,256}, 4, function() return true end)

    realisticWeatherFrame:initialize()

    MoistureArgumentsDialog.register()

end

FSBaseMission.onStartMission = Utils.prependedFunction(FSBaseMission.onStartMission, RW_FSBaseMission.onStartMission)


function RW_FSBaseMission:sendInitialClientState(connection, _, _)

    local puddleSystem = g_currentMission.puddleSystem
    local fireSystem = g_currentMission.fireSystem
    local fireSnapshot = {}

    -- RW_MP_FIX: clone fire list to avoid mutation races during serialization
    for i = 1, #fireSystem.fires do
        fireSnapshot[i] = fireSystem.fires[i]
    end

    connection:sendEvent(RW_BroadcastSettingsEvent.new())
    connection:sendEvent(PuddleSystemStateEvent.new(puddleSystem.updateIteration, puddleSystem.timeSinceLastUpdate, puddleSystem.puddles))
    connection:sendEvent(FireEvent.new(fireSystem.updateIteration, fireSystem.timeSinceLastUpdate, fireSystem.fieldId, fireSnapshot))

end

FSBaseMission.sendInitialClientState = Utils.prependedFunction(FSBaseMission.sendInitialClientState, RW_FSBaseMission.sendInitialClientState)


function RW_FSBaseMission:initTerrain(_, _)

    g_currentMission.puddleSystem:initialize()
    g_currentMission.fireSystem:initialize()

end

FSBaseMission.initTerrain = Utils.appendedFunction(FSBaseMission.initTerrain, RW_FSBaseMission.initTerrain)


function RW_FSBaseMission.onSettingChanged(name, state)
    g_currentMission[name] = state
end
