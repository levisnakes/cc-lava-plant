-- Lava Plant: runs a superheated-mixer lava farm and the thrusters and
-- liquid burners it fuels, from one computer.
--
--   * pushes cobblestone from Mechanical Generators into every basin
--   * drains lava out of every basin into your lava tank
--   * tops up every Create Propulsion thruster from the lava tank
--   * feeds lava to every Liquid Burner (the end burner of a line is enough)
--
-- Put a wired modem on every block you want it to run and join them all
-- with network cable. On first start it asks which fluid tank holds the
-- lava. Press S at any time to run that setup again.

-- The lava tank. Leave as nil to pick it on the setup screen instead.
LAVA_TANK = nil           -- e.g. "create:fluid_tank_0"

LAVA = "minecraft:lava"
COBBLE = "minecraft:cobblestone"

FARM_SECONDS = 0.5        -- how often basins are drained
COBBLE_SECONDS = 3        -- how often basins are refilled with cobble
THRUSTER_SECONDS = 0.25   -- how often thrusters are topped up
BURNER_SECONDS = 2        -- how often burners get lava
BURNER_PUSH_MB = 250      -- lava pushed into each burner peripheral per round
BURNER_RESERVE_MB = 1000  -- while burners still want lava, thrusters leave this much in the tank
AUTO_UPDATE = true        -- install new versions from GitHub automatically, keeping these settings

-- Settings in /config.lua override the ones above. Use it for anything you
-- don't want to retype: it survives reinstalls and updates, and one file can
-- be shared by every computer (each program ignores settings it doesn't use).
do
  local path = "/config.lua"
  if fs.exists(path) then
    local fn, err = loadfile(path, "t", _ENV)
    if fn then
      local ok, runErr = pcall(fn)
      if not ok then printError("config.lua: " .. tostring(runErr)) sleep(3) end
    else
      printError("config.lua: " .. tostring(err))
      sleep(3)
    end
  end
end

-- ============================================================ state

local VERSION = "1.2.0"
local SETUP_FILE = "/lava_plant.cfg"
local BATCH = 100 -- CC drops events past 256 queued, so never wait on more at once

-- CC names most blocks after their block entity id, which some mods end in
-- "_block_entity", so these match any peripheral type containing the text.
local KINDS = {
  { list = "basins", match = "basin" },
  { list = "burners", match = "liquid_burner" },
  { list = "generators", match = "mechanical_generator" },
}

local roles = { lava = nil }
local found = { basins = {}, burners = {}, generators = {}, thrusters = {} }

local stats = {
  lavaIn = {}, lavaOut = {},   -- { time, mB } samples for the per-minute rates
  cobblePushed = 0,
  lavaStored = nil,
  thrusterLow = nil, thrusterBad = {}, thrusterFiring = false,
  burnersFed = 0, burnersFull = false,
  lastError = nil,
}

-- ============================================================ helpers

local function now() return os.clock() end

local function addSample(list, amount)
  if amount > 0 then table.insert(list, { now(), amount }) end
end

local function perMinute(list)
  local cutoff = now() - 60
  while list[1] and list[1][1] < cutoff do table.remove(list, 1) end
  local total = 0
  for _, s in ipairs(list) do total = total + s[2] end
  return total
end

-- Runs jobs in parallel, at most BATCH at a time.
local function runAll(jobs)
  local i = 1
  while i <= #jobs do
    local chunk = {}
    for j = i, math.min(i + BATCH - 1, #jobs) do chunk[#chunk + 1] = jobs[j] end
    parallel.waitForAll(table.unpack(chunk))
    i = i + BATCH
  end
end

local function fluidAmount(name, fluid)
  local ok, tanks = pcall(peripheral.call, name, "tanks")
  if not ok or type(tanks) ~= "table" then return nil end
  local total = 0
  for _, t in pairs(tanks) do
    if t.name == fluid then total = total + (t.amount or 0) end
  end
  return total
end

local function present(name)
  return name ~= nil and peripheral.isPresent(name)
end

local function lavaTank() return present(roles.lava) and roles.lava or nil end

-- ============================================================ peripherals

local function typeContains(name, text)
  for _, ty in ipairs({ peripheral.getType(name) }) do
    if type(ty) == "string" and ty:find(text, 1, true) then return true end
  end
  return false
end

-- Which list a peripheral belongs in, or nil.
local function kindOf(name)
  if peripheral.hasType(name, "thruster") then return "thrusters" end
  for _, k in ipairs(KINDS) do
    if typeContains(name, k.match) then return k.list end
  end
  return nil
end

local function scan()
  local seen = {}
  local f = { basins = {}, burners = {}, generators = {}, thrusters = {} }
  for _, name in ipairs(peripheral.getNames()) do
    if not seen[name] then
      seen[name] = true
      local kind = kindOf(name)
      if kind then table.insert(f[kind], name) end
    end
  end
  for _, list in pairs(f) do table.sort(list) end
  found = f
end

-- Anything that holds fluid and isn't a basin, burner or thruster
-- (fluid tanks, Platinum Fluid Vessels, hose pulleys...).
local function tankCandidates()
  local seen, out = {}, {}
  for _, name in ipairs(peripheral.getNames()) do
    if not seen[name] then
      seen[name] = true
      if peripheral.hasType(name, "fluid_storage") and not kindOf(name) then
        table.insert(out, name)
      end
    end
  end
  table.sort(out)
  return out
end

local function describeTank(name)
  local ok, tanks = pcall(peripheral.call, name, "tanks")
  if not ok or type(tanks) ~= "table" then return "?" end
  local parts = {}
  for _, t in pairs(tanks) do
    if t.name and (t.amount or 0) > 0 then
      parts[#parts + 1] = (t.amount) .. " " .. t.name:gsub("^minecraft:", "")
    end
  end
  return #parts > 0 and table.concat(parts, ", ") or "empty"
end

-- ============================================================ setup

local function saveSetup()
  local f = fs.open(SETUP_FILE, "w")
  f.write(textutils.serialize({ lava = roles.lava }))
  f.close()
end

local function loadSetup()
  if fs.exists(SETUP_FILE) then
    local f = fs.open(SETUP_FILE, "r")
    local data = textutils.unserialize(f.readAll())
    f.close()
    if type(data) == "table" then
      roles.lava = data.lava
    end
  end
  -- names written at the top of the file win over the setup screen
  if LAVA_TANK then roles.lava = LAVA_TANK end
end

local function runSetup()
  term.setBackgroundColour(colours.black)
  term.setTextColour(colours.white)
  term.clear()
  term.setCursorPos(1, 1)
  print("Lava Plant setup")
  print("")
  local tanks = tankCandidates()
  if #tanks == 0 then
    print("No fluid tanks found. Put a wired modem on")
    print("your tanks, then press any key.")
    os.pullEvent("key")
    return
  end
  for i, name in ipairs(tanks) do
    print(i .. ") " .. name .. "  [" .. describeTank(name) .. "]")
  end
  print("")
  local choice
  while not choice do
    write("Which number is the lava tank? ")
    choice = tanks[tonumber(read() or "")]
  end
  roles = { lava = choice }
  saveSetup()
  print("")
  print("Saved. Starting...")
  sleep(1)
end

local function needsSetup()
  return roles.lava == nil
end

-- ============================================================ jobs

-- Lava out of every basin into the lava tank.
local function drainBasins()
  local tank = lavaTank()
  if not tank then return end
  local jobs = {}
  for _, b in ipairs(found.basins) do
    jobs[#jobs + 1] = function()
      local ok, moved = pcall(peripheral.call, tank, "pullFluid", b, nil, LAVA)
      if ok and type(moved) == "number" then addSample(stats.lavaIn, moved) end
    end
  end
  runAll(jobs)
end

-- Cobblestone into every basin, shared out across the generators.
local function fillBasins()
  local gens = found.generators
  if #gens == 0 then return end
  local jobs = {}
  for i, b in ipairs(found.basins) do
    local gen = gens[(i - 1) % #gens + 1]
    jobs[#jobs + 1] = function()
      local ok, moved = pcall(peripheral.call, gen, "pushItems", b, 1, 64)
      if ok and type(moved) == "number" then stats.cobblePushed = stats.cobblePushed + moved end
    end
  end
  runAll(jobs)
end

-- Every thruster pulls lava from the lava tank until its tank is full.
-- Burners come first: until they are all full, thrusters only take what is
-- above BURNER_RESERVE_MB.
local function fuelThrusters()
  local tank = lavaTank()
  local spare = math.huge
  if tank and #found.burners > 0 and not stats.burnersFull then
    spare = math.max(0, (fluidAmount(tank, LAVA) or 0) - BURNER_RESERVE_MB)
  end
  local low, bad, firing = nil, {}, false
  local jobs = {}
  for _, t in ipairs(found.thrusters) do
    jobs[#jobs + 1] = function()
      local okA, amount = pcall(peripheral.call, t, "getFuelAmountMb")
      local okC, capacity = pcall(peripheral.call, t, "getFuelCapacityMb")
      local okP, power = pcall(peripheral.call, t, "getPower")
      if okP and type(power) == "number" and power > 0 then firing = true end
      if not (okA and okC) or type(amount) ~= "number" then
        bad[#bad + 1] = t
        return
      end
      if not low or amount < low then low = amount end
      local want = math.min(capacity - amount, spare)
      if tank and want > 0 then
        spare = spare - want -- claimed before the call, so parallel jobs share it
        local ok, moved = pcall(peripheral.call, t, "pullFluid", tank, want, LAVA)
        if ok and type(moved) == "number" then
          spare = spare + (want - moved)
          addSample(stats.lavaOut, moved)
        elseif not ok then
          bad[#bad + 1] = t -- usually a modem that isn't on the intake end
        end
      end
    end
  end
  runAll(jobs)
  stats.thrusterLow, stats.thrusterBad, stats.thrusterFiring = low, bad, firing
end

-- Lava into every burner. A burner passes what it can't hold to the next
-- burner in a straight line, so a modem on the end burner feeds the row.
local function fuelBurners()
  local tank = lavaTank()
  if not tank or #found.burners == 0 then return end
  -- an empty tank moves nothing, which says nothing about the burners
  if (fluidAmount(tank, LAVA) or 0) == 0 then
    stats.burnersFed, stats.burnersFull = 0, false
    return
  end
  local fed, full = 0, true
  local jobs = {}
  for _, b in ipairs(found.burners) do
    jobs[#jobs + 1] = function()
      local ok, moved = pcall(peripheral.call, tank, "pushFluid", b, BURNER_PUSH_MB, LAVA)
      if ok and type(moved) == "number" then
        addSample(stats.lavaOut, moved)
        if moved > 0 then fed = fed + 1 full = false end
      end
    end
  end
  runAll(jobs)
  stats.burnersFed, stats.burnersFull = fed, full
end


-- ============================================================ screen

local function line(text, colour)
  if colour and term.isColour() then term.setTextColour(colour) end
  print(text)
  term.setTextColour(colours.white)
end

local function draw()
  term.setBackgroundColour(colours.black)
  term.setTextColour(colours.white)
  term.clear()
  term.setCursorPos(1, 1)
  line("Lava Plant " .. VERSION .. "        S = setup", colours.orange)
  line("")
  local inRate, outRate = perMinute(stats.lavaIn), perMinute(stats.lavaOut)
  line("Lava tank: " .. (roles.lava or "not set"),
    lavaTank() and colours.white or colours.red)
  if stats.lavaStored then line("  stored  " .. stats.lavaStored .. " mB") end
  line(string.format("  in  %d mB/s   out %d mB/s", math.floor(inRate / 60), math.floor(outRate / 60)))
  line("")
  line("Basins " .. #found.basins .. "   generators " .. #found.generators ..
    "   cobble moved " .. stats.cobblePushed)
  if #found.basins > 0 and #found.generators == 0 then
    line("  no Mechanical Generator on the network", colours.red)
  end
  line("Thrusters " .. #found.thrusters ..
    (stats.thrusterLow and ("   lowest " .. stats.thrusterLow .. " mB") or ""))
  if #stats.thrusterBad > 0 then
    line("  " .. #stats.thrusterBad .. " can't be fuelled: " .. stats.thrusterBad[1], colours.red)
    line("  (modem must be on the intake end)", colours.red)
  end
  line("Burners " .. #found.burners ..
    (#found.burners > 0 and (stats.burnersFull and "   all full" or ("   taking lava: " .. stats.burnersFed)) or ""))
  if stats.lastError then
    line("")
    line("Error: " .. stats.lastError, colours.red)
  end
end

-- ============================================================ loops

local function guard(fn)
  local ok, err = pcall(fn)
  if not ok then stats.lastError = tostring(err) end
end

local function every(seconds, fn)
  return function()
    while true do
      guard(fn)
      sleep(seconds)
    end
  end
end

local function scanLoop()
  while true do
    scan()
    sleep(5)
  end
end

local function screenLoop()
  while true do
    local tank = lavaTank()
    stats.lavaStored = tank and fluidAmount(tank, LAVA) or nil
    draw()
    sleep(1)
  end
end

local setupRequested = false
local function keyLoop()
  while true do
    local _, key = os.pullEvent("key")
    if key == keys.s then
      setupRequested = true
      return -- ends parallel.waitForAny; the main loop runs setup and restarts
    end
  end
end

-- Only update between thruster burns, so a ship never loses fuel mid-flight.
local function readyToUpdate()
  return not stats.thrusterFiring
end

-- ============================================================ auto-update

-- Every UPDATE_CHECK_MINUTES this checks GitHub for a newer version. A new
-- version is downloaded, checked that it loads, given your current settings
-- (the UPPERCASE lines at the top of this file), saved, and the computer
-- reboots into it. Set AUTO_UPDATE = false at the top to turn this off.
local UPDATE_REPO = "levisnakes/cc-lava-plant"
local UPDATE_FILE = "lava_plant.lua"
local UPDATE_CHECK_MINUTES = 15
local PROGRAM_PATH = (shell and shell.getRunningProgram()) or "startup.lua"
local SHA_FILE = "/.version_" .. UPDATE_FILE

-- Settings are the top-of-file assignments to UPPERCASE names, before the
-- first "local" line or "-- ====" section. Tables can span several lines.
local function splitSettings(src)
  local settings, rest = {}, {}
  local inSettings = true
  for line in (src .. "\n"):gmatch("(.-)\n") do
    if inSettings and (line:match("^local ") or line:match("^%-%- ====")) then inSettings = false end
    table.insert(inSettings and settings or rest, line)
  end
  return settings, rest
end

local function braceDelta(line)
  local code = line:gsub('"[^"]*"', ""):gsub("%-%-.*$", "")
  local _, opens = code:gsub("{", "")
  local _, closes = code:gsub("}", "")
  return opens - closes
end

-- [NAME] = the full statement text, possibly several lines
local function statements(lines)
  local out = {}
  local i = 1
  while i <= #lines do
    local name = lines[i]:match("^([%u_][%u%d_]*)%s*=")
    if name then
      local block = { lines[i] }
      local depth = braceDelta(lines[i])
      while depth > 0 and i < #lines do
        i = i + 1
        table.insert(block, lines[i])
        depth = depth + braceDelta(lines[i])
      end
      out[name] = table.concat(block, "\n")
    end
    i = i + 1
  end
  return out
end

-- New file, with each setting that already exists replaced by your value.
local function mergeSettings(oldSrc, newSrc)
  local oldSettings = statements((splitSettings(oldSrc)))
  local newSettings, rest = splitSettings(newSrc)
  local out = {}
  local i = 1
  while i <= #newSettings do
    local line = newSettings[i]
    local name = line:match("^([%u_][%u%d_]*)%s*=")
    if name and oldSettings[name] then
      table.insert(out, oldSettings[name])
      local depth = braceDelta(line)
      while depth > 0 and i < #newSettings do
        i = i + 1
        depth = depth + braceDelta(newSettings[i])
      end
    else
      table.insert(out, line)
    end
    i = i + 1
  end
  for _, line in ipairs(rest) do table.insert(out, line) end
  local merged = table.concat(out, "\n")
  -- splitting added one trailing newline's worth of empty line; match the source
  if newSrc:sub(-1) == "\n" and merged:sub(-1) ~= "\n" then merged = merged .. "\n" end
  return (merged:gsub("\n\n$", "\n"))
end

local function fetch(url, headers)
  local ok, h = pcall(http.get, url, headers)
  if not ok or not h then return nil end
  local body = h.readAll()
  h.close()
  return body
end

local function readText(path)
  if not fs.exists(path) then return nil end
  local f = fs.open(path, "r")
  local t = f.readAll()
  f.close()
  return t
end

local function writeText(path, text)
  local f = fs.open(path, "w")
  f.write(text)
  f.close()
end

local function checkForUpdate(atBoot)
  if AUTO_UPDATE == false or not http then return end
  local sha = fetch("https://api.github.com/repos/" .. UPDATE_REPO .. "/commits/main",
    { ["Accept"] = "application/vnd.github.sha", ["User-Agent"] = "cc-auto-update" })
  if not sha then return end
  sha = sha:match("^%s*(%x+)%s*$")
  if not sha or #sha < 40 or readText(SHA_FILE) == sha then return end

  local newSrc = fetch("https://raw.githubusercontent.com/" .. UPDATE_REPO .. "/" .. sha .. "/" .. UPDATE_FILE)
  if not newSrc or not load(newSrc, UPDATE_FILE) then return end
  local oldSrc = readText(PROGRAM_PATH)
  if not oldSrc then return end
  local merged = mergeSettings(oldSrc, newSrc)
  if not load(merged, UPDATE_FILE) then return end
  if merged == oldSrc then
    writeText(SHA_FILE, sha)
    return
  end

  -- at boot nothing is running yet, so there is nothing to wait for
  while not atBoot and not readyToUpdate() do sleep(5) end
  writeText(PROGRAM_PATH .. ".old", oldSrc)
  writeText(PROGRAM_PATH, merged)
  writeText(SHA_FILE, sha)
  term.setBackgroundColor(colors.black)
  term.clear()
  term.setCursorPos(1, 1)
  print("Updated to " .. sha:sub(1, 7) .. ", restarting...")
  if not atBoot then sleep(1) end
  os.reboot()
end

local function updateLoop()
  while true do
    sleep(UPDATE_CHECK_MINUTES * 60)
    pcall(checkForUpdate)
  end
end

-- Check for a new version as soon as the computer starts, before the
-- program runs, so a restart always picks up the latest version.
local function bootUpdate()
  if AUTO_UPDATE == false or not http then return end
  term.setBackgroundColor(colors.black)
  term.clear()
  term.setCursorPos(1, 1)
  print("Checking for updates...")
  pcall(checkForUpdate, true)
end

-- ============================================================ main

bootUpdate()
loadSetup()
scan()
if needsSetup() then runSetup() end

while true do
  setupRequested = false
  parallel.waitForAny(
    scanLoop,
    screenLoop,
    keyLoop,
    updateLoop,
    every(FARM_SECONDS, drainBasins),
    every(COBBLE_SECONDS, fillBasins),
    every(THRUSTER_SECONDS, fuelThrusters),
    every(BURNER_SECONDS, fuelBurners)
  )
  if setupRequested then
    runSetup()
    scan()
  end
end
