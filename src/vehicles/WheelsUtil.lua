-- WheelsUtil.lua (RW_WheelsUtil)
-- Riconfigurazione completa dei coefficienti di attrito per tutti i tipi di pneumatico di FS25.
-- I tipi vanilla vengono prima de-registrati e poi ri-registrati con i nuovi valori RW.
--
-- Tipi di pneumatico gestiti (6 totali):
--   mud         → pneumatici da fango (agricoli standard)
--   offRoad     → pneumatici off-road
--   street      → pneumatici stradali
--   crawler     → cingoli
--   chains      → catene da neve
--   metalSpikes → chiodi metallici (per neve/ghiaccio)
--
-- Ogni tipo ha tre set di coefficienti per 4 tipi di suolo:
--   GROUND_ROAD, GROUND_HARD_TERRAIN, GROUND_SOFT_TERRAIN, GROUND_FIELD
--   - coeffs     (asciutto): condizioni normali
--   - coeffsWet  (bagnato):  terreno umido/piovoso
--   - coeffsSnow (neve):     manto nevoso
--
-- Principi di progettazione RW rispetto ai valori vanilla:
--   MUD:         Più grip su strada/hard terrain, peggio su morbido/campo bagnato
--                → pneumatici agricoli eccellono su terreno duro, soffrono nel fango bagnato
--   OFF-ROAD:    Più grip su tutti i terreni (specialmente duri), ma peggio su neve
--                → priorità alla trazione su terreni duri e misti
--   STREET:      Molto più grip su asfalto (1.5 vs 1.25 vanilla), drasticamente peggio
--                su soft/field (0.55/0.45 vs 1.0/0.9 vanilla)
--                → simula pneumatici stradali reali: ottimi su asfalto, pericolosi fuori strada
--   CRAWLER:     Più grip su asfalto (1.35 vs 1.15), molto meglio su neve (0.9 vs 0.65)
--                → i cingoli sono più efficaci su superfici dure e neve profonda
--   CHAINS:      Alta trazione su asfalto/hard (1.55), eccellenti su neve (1.35 vs 1.05)
--                → le catene da neve funzionano meglio di quanto modellato nel vanilla
--   METAL SPIKES: Alta trazione su soft/field (1.75), media su strada (1.05)
--                → i chiodi mordono il terreno morbido, non l'asfalto

RW_WheelsUtil = {}

-- ##############################################################################

-- NOTES

-- Wheel types are registered when the game is launched through game.lua (source)
-- Wheel types have coefficients for normal, wet and snowy ground conditions
-- 6 wheel types in total, each coeffecient has 4 different coefficient types
-- GROUND_ROAD, GROUND_HARD_TERRAIN, GROUND_SOFT_TERRAIN, GROUND_FIELD

-- ##############################################################################


-- MUD TIRES
-- Coefficienti asciutto: +5% su strada/hard rispetto al vanilla, -5% su soft/field
-- Coefficienti bagnato:  comparabili al vanilla tranne field bagnato (0.75 vs 0.7)
-- Coefficienti neve:     leggermente migliori su tutti i terreni

local mudTireCoeffs = {
    [WheelsUtil.GROUND_ROAD] = 1.2,
    [WheelsUtil.GROUND_HARD_TERRAIN] = 1.2,
    [WheelsUtil.GROUND_SOFT_TERRAIN] = 1.05,
    [WheelsUtil.GROUND_FIELD] = 1.05
    -- ORIG: 1.15, 1.15, 1.1, 0.95
}
local mudTireCoeffsWet = {
    [WheelsUtil.GROUND_ROAD] = 1.05,
    [WheelsUtil.GROUND_HARD_TERRAIN] = 1.05,
    [WheelsUtil.GROUND_SOFT_TERRAIN] = 0.85,
    [WheelsUtil.GROUND_FIELD] = 0.75
    -- ORIG: 1.05, 1.05, 1, 0.7
}
local mudTireCoeffsSnow = {
    [WheelsUtil.GROUND_ROAD] = 0.5,
    [WheelsUtil.GROUND_HARD_TERRAIN] = 0.48,
    [WheelsUtil.GROUND_SOFT_TERRAIN] = 0.4,
    [WheelsUtil.GROUND_FIELD] = 0.38
    -- ORIG: 0.45, 0.45, 0.4, 0.35
}


-- OFF-ROAD TIRES
-- Coefficienti asciutto: migliori su tutti i terreni (+5 su strada, +10 su soft/field)
-- Coefficienti bagnato:  molto meglio su soft/field (1.0 vs 0.95/0.6 vanilla)
-- Coefficienti neve:     peggiori rispetto al vanilla (più scivolosi su neve)

local offRoadTireCoeffs = {
    [WheelsUtil.GROUND_ROAD] = 1.25,
    [WheelsUtil.GROUND_HARD_TERRAIN] = 1.25,
    [WheelsUtil.GROUND_SOFT_TERRAIN] = 1.15,
    [WheelsUtil.GROUND_FIELD] = 1.1
    -- ORIG: 1.2, 1.15, 1.05, 1
}
local offRoadTireCoeffsWet = {
    [WheelsUtil.GROUND_ROAD] = 1,
    [WheelsUtil.GROUND_HARD_TERRAIN] = 1,
    [WheelsUtil.GROUND_SOFT_TERRAIN] = 1,
    [WheelsUtil.GROUND_FIELD] = 0.85
    -- ORIG: 1.05, 1, 0.95, 0.6
}
local offRoadTireCoeffsSnow = {
    [WheelsUtil.GROUND_ROAD] = 0.35,
    [WheelsUtil.GROUND_HARD_TERRAIN] = 0.33,
    [WheelsUtil.GROUND_SOFT_TERRAIN] = 0.32,
    [WheelsUtil.GROUND_FIELD] = 0.3
    -- ORIG: 0.45, 0.4, 0.35, 0.3
}


-- STREET TIRES
-- Asciutto: molto più grip su strada (1.5 vs 1.25), drasticamente meno su soft/field
-- Bagnato:  buono su asfalto (1.3), pessimo su soft/field (0.35/0.25 vs 0.85/0.45)
-- Neve:     molto peggiori su asfalto (0.28 vs 0.55), leggermente peggiori altrove

local streetTireCoeffs = {
    [WheelsUtil.GROUND_ROAD] = 1.5,
    [WheelsUtil.GROUND_HARD_TERRAIN] = 1.35,
    [WheelsUtil.GROUND_SOFT_TERRAIN] = 0.55,
    [WheelsUtil.GROUND_FIELD] = 0.45
    -- ORIG: 1.25, 1.15, 1, 0.9
}
local streetTireCoeffsWet = {
    [WheelsUtil.GROUND_ROAD] = 1.3,
    [WheelsUtil.GROUND_HARD_TERRAIN] = 1.2,
    [WheelsUtil.GROUND_SOFT_TERRAIN] = 0.35,
    [WheelsUtil.GROUND_FIELD] = 0.25
    -- ORIG: 1.15, 1, 0.85, 0.45
}
local streetTireCoeffsSnow = {
    [WheelsUtil.GROUND_ROAD] = 0.28,
    [WheelsUtil.GROUND_HARD_TERRAIN] = 0.26,
    [WheelsUtil.GROUND_SOFT_TERRAIN] = 0.22,
    [WheelsUtil.GROUND_FIELD] = 0.2
    -- ORIG: 0.55, 0.4, 0.3, 0.35
}


-- CRAWLER TRACKS
-- Asciutto: più grip su asfalto/hard (1.35 vs 1.15), invariato su soft/field
-- Bagnato:  meglio su asfalto (1.3 vs 1.05), molto meglio su soft (0.95 vs 1.05 vanilla errato?)
-- Neve:     molto migliori su tutti i terreni (0.9 vs 0.65 vanilla)

local crawlerCoeffs = {
    [WheelsUtil.GROUND_ROAD] = 1.35,
    [WheelsUtil.GROUND_HARD_TERRAIN] = 1.35,
    [WheelsUtil.GROUND_SOFT_TERRAIN] = 1.25,
    [WheelsUtil.GROUND_FIELD] = 1.25
    -- ORIG: 1.15, 1.15, 1.15, 1.15
}
local crawlerCoeffsWet = {
    [WheelsUtil.GROUND_ROAD] = 1.3,
    [WheelsUtil.GROUND_HARD_TERRAIN] = 1.3,
    [WheelsUtil.GROUND_SOFT_TERRAIN] = 0.95,
    [WheelsUtil.GROUND_FIELD] = 0.95
    -- ORIG: 1.05, 1.05, 1.05, 0.85
}
local crawlerCoeffsSnow = {
    [WheelsUtil.GROUND_ROAD] = 0.9,
    [WheelsUtil.GROUND_HARD_TERRAIN] = 0.9,
    [WheelsUtil.GROUND_SOFT_TERRAIN] = 0.8,
    [WheelsUtil.GROUND_FIELD] = 0.8
    -- ORIG: 0.65, 0.65, 0.65, 0.65
}


-- CHAINS (catene da neve)
-- Asciutto: molto più grip su asfalto/hard (1.55 vs 1.15), meglio su soft/field
-- Bagnato:  tutte le superfici migliori del vanilla (~1.12-1.15 vs ~1.05)
-- Neve:     molto più grip su asfalto/hard (1.35 vs 1.05), meglio su soft/field

local chainsCoeffs = {
    [WheelsUtil.GROUND_ROAD] = 1.55,
    [WheelsUtil.GROUND_HARD_TERRAIN] = 1.55,
    [WheelsUtil.GROUND_SOFT_TERRAIN] = 1.15,
    [WheelsUtil.GROUND_FIELD] = 1.15
    -- ORIG: 1.15, 1.15, 1.15, 1.15
}
local chainsCoeffsWet = {
    [WheelsUtil.GROUND_ROAD] = 1.15,
    [WheelsUtil.GROUND_HARD_TERRAIN] = 1.15,
    [WheelsUtil.GROUND_SOFT_TERRAIN] = 1.12,
    [WheelsUtil.GROUND_FIELD] = 1.12
    -- ORIG: 1.05, 1.05, 1.05, 0.95
}
local chainsCoeffsSnow = {
    [WheelsUtil.GROUND_ROAD] = 1.35,
    [WheelsUtil.GROUND_HARD_TERRAIN] = 1.35,
    [WheelsUtil.GROUND_SOFT_TERRAIN] = 1.1,
    [WheelsUtil.GROUND_FIELD] = 1.1
    -- ORIG: 1.05, 1.05, 1.05, 1.05
}


-- METAL SPIKES (chiodi metallici)
-- Asciutto: alto grip su soft/field (1.75 vs 1.15), basso su asfalto (1.05 vs 1.15)
-- Bagnato:  ottimi su soft/field bagnato (1.5), bassi su asfalto (0.95)
-- Neve:     buoni su soft/field (1.35), buoni su asfalto (0.9)
-- I chiodi mordono il terreno morbido, non l'asfalto dove consumano e scivolano.

local metalCoeffs = {
    [WheelsUtil.GROUND_ROAD] = 1.05,
    [WheelsUtil.GROUND_HARD_TERRAIN] = 1.05,
    [WheelsUtil.GROUND_SOFT_TERRAIN] = 1.75,
    [WheelsUtil.GROUND_FIELD] = 1.75
    -- ORIG: 1.15, 1.15, 1.15, 1.15
}
local metalCoeffsWet = {
    [WheelsUtil.GROUND_ROAD] = 0.95,
    [WheelsUtil.GROUND_HARD_TERRAIN] = 0.95,
    [WheelsUtil.GROUND_SOFT_TERRAIN] = 1.5,
    [WheelsUtil.GROUND_FIELD] = 1.5
    -- ORIG: 1.15, 1.15, 1.15, 1.15
}
local metalCoeffsSnow = {
    [WheelsUtil.GROUND_ROAD] = 0.9,
    [WheelsUtil.GROUND_HARD_TERRAIN] = 0.9,
    [WheelsUtil.GROUND_SOFT_TERRAIN] = 1.35,
    [WheelsUtil.GROUND_FIELD] = 1.35
    -- ORIG: 1.15, 1.15, 1.15, 1.15
}


-- De-registrazione dei tipi vanilla e ri-registrazione con i nuovi coefficienti RW.
-- L'ordine è importante: unregister prima di register per evitare conflitti.
WheelsUtil.unregisterTireType("mud")
WheelsUtil.unregisterTireType("offRoad")
WheelsUtil.unregisterTireType("street")
WheelsUtil.unregisterTireType("crawler")
WheelsUtil.unregisterTireType("chains")
WheelsUtil.unregisterTireType("metalSpikes")

WheelsUtil.registerTireType("mud", mudTireCoeffs, mudTireCoeffsWet, mudTireCoeffsSnow)
WheelsUtil.registerTireType("offRoad", offRoadTireCoeffs, offRoadTireCoeffsWet, offRoadTireCoeffsSnow)
WheelsUtil.registerTireType("street", streetTireCoeffs, streetTireCoeffsWet, streetTireCoeffsSnow)
WheelsUtil.registerTireType("crawler", crawlerCoeffs, crawlerCoeffsWet, crawlerCoeffsSnow)
WheelsUtil.registerTireType("chains", chainsCoeffs, chainsCoeffsWet, chainsCoeffsSnow)
WheelsUtil.registerTireType("metalSpikes", metalCoeffs, metalCoeffsWet, metalCoeffsSnow)
