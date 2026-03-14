-- RW_BroadcastSettingsEvent.lua
-- Evento di rete per la sincronizzazione delle impostazioni RW tra server e client.
-- Supporta due modalità operative:
--   1. Broadcast completo (setting == nil):
--      Trasmette tutte le impostazioni non-ignore in una sola volta.
--      Usato da sendInitialClientState quando un nuovo client si connette.
--   2. Aggiornamento singolo (setting = nome impostazione):
--      Trasmette solo l'impostazione modificata.
--      Usato da RWSettings.onSettingChanged quando il client cambia un'impostazione.
--
-- Flusso client → server:
--   Il client chiama sendEvent() sulla propria connessione al server.
--   Il server riceve, applica la modifica e la salva nel savegame.
--
-- Flusso server → client (broadcast completo):
--   Il server chiama broadcastEvent() su tutti i client connessi.
--   Ogni client riceve e applica lo stato corrente di tutte le impostazioni.
--
-- In run() sul client, le dipendenze tra impostazioni vengono ricalcolate
-- e i tooltip dinamici vengono aggiornati dopo ogni modifica.

RW_BroadcastSettingsEvent = {}

local RW_BroadcastSettingsEvent_mt = Class(RW_BroadcastSettingsEvent, Event)
InitEventClass(RW_BroadcastSettingsEvent, "RW_BroadcastSettingsEvent")


-- Costruttore base usato internamente dal sistema di eventi di FS.
function RW_BroadcastSettingsEvent.emptyNew()
    local self = Event.new(RW_BroadcastSettingsEvent_mt)
    return self
end


-- Costruttore principale dell'evento.
-- @param setting  nome dell'impostazione da trasmettere (nil = trasmetti tutte)
function RW_BroadcastSettingsEvent.new(setting)

    local self = RW_BroadcastSettingsEvent.emptyNew()

    self.setting = setting

    return self

end


-- Deserializza l'evento dallo stream di rete.
-- readAll=true → legge tutte le impostazioni in sequenza (nome + stato).
-- readAll=false → legge solo l'impostazione singola modificata.
function RW_BroadcastSettingsEvent:readStream(streamId, connection)
    
    local readAll = streamReadBool(streamId)

    if readAll then

        -- Broadcast completo: aggiorna lo stato locale di ogni impostazione.
        for _, setting in pairs(RWSettings.SETTINGS) do

            if setting.ignore then continue end
            
            local name = streamReadString(streamId)
            local state = streamReadUInt8(streamId)

            RWSettings.SETTINGS[name].state = state

        end

    else
            
        -- Aggiornamento singolo: aggiorna solo l'impostazione specificata.
        local name = streamReadString(streamId)
        local state = streamReadUInt8(streamId)

        RWSettings.SETTINGS[name].state = state
        self.setting = name

    end

    self:run(connection)

end


-- Serializza l'evento nello stream di rete.
-- setting == nil → writeAll=true, scrive tutte le impostazioni.
-- setting != nil → writeAll=false, scrive solo l'impostazione specificata.
function RW_BroadcastSettingsEvent:writeStream(streamId, connection)
        
    streamWriteBool(streamId, self.setting == nil)

    if self.setting == nil then

        -- Broadcast completo: serializza ogni impostazione con il suo stato corrente.
        for name, setting in pairs(RWSettings.SETTINGS) do
            if setting.ignore then continue end
            streamWriteString(streamId, name)
            streamWriteUInt8(streamId, setting.state)
        end

    else

        -- Aggiornamento singolo: serializza solo l'impostazione modificata.
        local setting = RWSettings.SETTINGS[self.setting]
        streamWriteString(streamId, self.setting)
        streamWriteUInt8(streamId, setting.state)

    end

end


-- Applica le impostazioni ricevute all'interfaccia e ai sistemi del mod.
-- Modalità broadcast completo (setting == nil):
--   Per ogni impostazione: aggiorna l'elemento UI, chiama la callback del sistema.
-- Modalità aggiornamento singolo (setting != nil):
--   Aggiorna l'elemento UI, chiama la callback, aggiorna il tooltip dinamico,
--   aggiorna le dipendenze tra controlli, salva nel savegame (solo server).
function RW_BroadcastSettingsEvent:run(connection)

    if self.setting == nil then

        -- Applica tutte le impostazioni: aggiorna UI e callback per ciascuna.
        for name, setting in pairs(RWSettings.SETTINGS) do
            if setting.ignore then continue end
            setting.element:setState(setting.state)
            if setting.callback ~= nil then setting.callback(name, setting.values[setting.state]) end 
        end

    else
            
        local setting = RWSettings.SETTINGS[self.setting]
        if setting.element ~= nil then setting.element:setState(setting.state) end
        if setting.callback ~= nil then setting.callback(self.setting, setting.values[setting.state]) end

        -- Aggiorna il tooltip dinamico se l'impostazione lo supporta.
        if setting.dynamicTooltip and setting.element ~= nil then setting.element.elements[1]:setText(g_i18n:getText("rw_settings_" .. self.setting .. "_tooltip_" .. setting.state)) end

        -- Aggiorna lo stato disabled dei controlli che dipendono da questa impostazione.
		for _, s in pairs(RWSettings.SETTINGS) do
			if s.dependancy and s.dependancy.name == self.setting and s.element ~= nil then
				s.element:setDisabled(s.dependancy.state ~= state)
			end
		end

        -- Sul server: salva le impostazioni aggiornate nel savegame.
        if g_server ~= nil then RWSettings.saveToXMLFile() end

    end

end


-- Metodo statico di invio dell'evento.
-- Sul server: broadcast a tutti i client.
-- Sul client: invia al server per propagazione.
-- @param setting  nome dell'impostazione da trasmettere (nil = tutte)
function RW_BroadcastSettingsEvent.sendEvent(setting)
	if g_server ~= nil then
		g_server:broadcastEvent(RW_BroadcastSettingsEvent.new(setting))
	else
		g_client:getServerConnection():sendEvent(RW_BroadcastSettingsEvent.new(setting))
	end
end
