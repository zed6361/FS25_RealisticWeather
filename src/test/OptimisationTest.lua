-- OptimisationTest.lua
-- Classe di utility per il profiling delle performance di RealisticWeather.
-- Permette di misurare il tempo medio di esecuzione di blocchi di codice arbitrari
-- e stampare i risultati ogni 250 tick in console.
--
-- Utilizzo tipico:
--   g_optimisationTest:registerTest("moistureUpdate")
--   g_optimisationTest:startTest("moistureUpdate")
--   -- ... codice da profilare ...
--   g_optimisationTest:endTest("moistureUpdate")
--   -- ogni 250 tick viene stampata la media in millisecondi
--
-- Un'istanza globale è sempre disponibile come g_optimisationTest.
-- I test non registrati prima di startTest causeranno un errore su table.insert.

OptimisationTest = {}

local OptimisationTest_mt = Class(OptimisationTest)


-- Costruttore: crea un'istanza vuota con contatore tick e tabelle interne.
function OptimisationTest.new()

	local self = setmetatable({}, OptimisationTest_mt)

	self.tests = {}   -- tabella nome → lista di tempi campionati (in secondi)
	self.ticks = 0    -- contatore tick dall'ultimo reset
	self.timer = {}   -- tabella nome → timestamp di startTest (getTimeSec)

	return self

end


-- Registra un nuovo test con il nome dato.
-- Deve essere chiamato prima di startTest/endTest.
-- @param name  identificatore univoco del test
function OptimisationTest:registerTest(name)

	self.tests[name] = {}

end


-- Avvia il timer per il test specificato.
-- Salva il timestamp corrente in self.timer[name].
-- @param name  nome del test (deve essere stato registrato)
function OptimisationTest:startTest(name)

	self.timer[name] = getTimeSec()

end


-- Termina il timer per il test specificato e salva il campione.
-- Calcola elapsed = getTimeSec() - startTime e lo aggiunge alla lista.
-- @param name  nome del test (deve essere stato avviato con startTest)
function OptimisationTest:endTest(name)

	table.insert(self.tests[name], getTimeSec() - self.timer[name])
	self.timer[name] = nil

end


-- Aggiorna il contatore tick. Ogni 250 tick:
--   - Calcola la media dei campioni per ogni test (in millisecondi)
--   - Stampa tutti i risultati in una singola riga CSV in console
--   - Svuota i campioni per il prossimo batch
-- Deve essere chiamato una volta per frame/tick dal loop principale di RW.
function OptimisationTest:update()

	self.ticks = self.ticks + 1

	if self.ticks >= 250 then

		self.ticks = 0
		local text = ""

		for name, times in pairs(self.tests) do

			if #times == 0 then continue end

			local totalTime = 0
			for _, time in pairs(times) do totalTime = totalTime + time end

			if #text > 0 then text = text .. ", " end
			-- Converte secondi in millisecondi (×1000) e calcola la media.
			text = text .. string.format("%s = %.5f", name, (totalTime / #times) * 1000)

			-- Svuota i campioni per il prossimo intervallo di 250 tick.
			self.tests[name] = {}

		end

		print(text)

	end

end

-- Istanza globale condivisa da tutti i sistemi RW che vogliono profilare le performance.
g_optimisationTest = OptimisationTest.new()
