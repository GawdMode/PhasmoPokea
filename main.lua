-- PhasmoPokea - 1.0.0
-- Baseline vertical-slice foundation:
--   * Adds a Spirit Warden NPC beside Mr. Fuji in SOUL_HOUSE.
--   * First conversation offers enrollment with YES/NO.
--   * Enrollment persists in mod save data.
--   * Enrollment also persists a Spirit Band unlock bit for the next build.
--
-- Dialogue is intentionally paginated to no more than two visible lines.

return function(mod)
  -- DEV2: Spirit Band integration. Crystal's Pokegear exposes its radio dial
  -- as a Lua table, so we add one genuine dial position rather than creating
  -- a separate menu. The station only resolves after Ezra has unlocked it.
  local Pokegear = require("src.ui.gen2.Pokegear")
  local Phone = require("src.core.gen2.Phone")
  local Gen2MapData = require("src.world.gen2.Map")
  local GameVersion = require("src.core.GameVersion")

  -- DEV9o: the haunting no longer reuses Goldenrod's live Radio Tower maps.
  -- These five private investigation maps copy only the vanilla geometry and
  -- tileset from the current Gen 2 dataset. All NPC/story/script content is
  -- intentionally omitted, so Goldenrod's real RADIO_TOWER_* maps remain
  -- completely untouched even while a Spirit Warden case is active.
  local SOURCE_TOWER_FLOORS = {
    "RADIO_TOWER_1F", "RADIO_TOWER_2F", "RADIO_TOWER_3F",
    "RADIO_TOWER_4F", "RADIO_TOWER_5F",
  }
  local HAUNTED_FLOORS = {
    "WARDEN_RADIO_TOWER_1F", "WARDEN_RADIO_TOWER_2F",
    "WARDEN_RADIO_TOWER_3F", "WARDEN_RADIO_TOWER_4F",
    "WARDEN_RADIO_TOWER_5F",
  }
  local SOURCE_TO_WARDEN, WARDEN_TO_SOURCE = {}, {}
  for i=1,#SOURCE_TOWER_FLOORS do
    SOURCE_TO_WARDEN[SOURCE_TOWER_FLOORS[i]] = HAUNTED_FLOORS[i]
    WARDEN_TO_SOURCE[HAUNTED_FLOORS[i]] = SOURCE_TOWER_FLOORS[i]
  end

  local function copyPlain(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local out = {}; seen[value] = out
    for k,v in pairs(value) do out[copyPlain(k,seen)] = copyPlain(v,seen) end
    return out
  end

  -- Background events are retained only as read-only metadata for our prop
  -- classifier. They are NOT installed on the private maps, so none of the
  -- retail Radio Tower text/scripts can ever fire inside an investigation.
  local WARDEN_BG_EVENTS = {}
  local WARDEN_EXIT_CELLS = {}
  do
    local version = GameVersion and GameVersion.get and GameVersion.get() or "crystal"
    local view, reason = mod.datasets:open(version)
    if not view then error("Spirit Wardens needs the active Gen 2 map dataset: "..tostring(reason),0) end
    for i,sourceId in ipairs(SOURCE_TOWER_FLOORS) do
      local targetId = HAUNTED_FLOORS[i]
      local src = view.content.maps:get(sourceId)
      if not src then error("Spirit Wardens could not copy "..sourceId,0) end
      WARDEN_BG_EVENTS[targetId] = copyPlain(src.bgEvents or {})
      local warps = {}
      for wi,w in ipairs(src.warps or {}) do
        local cw = copyPlain(w)
        local mapped = SOURCE_TO_WARDEN[cw.destMap]
        if mapped then
          cw.destMap = mapped
        else
          -- Keep the array index so internal destWarp numbers remain valid,
          -- but move every retail/outside/elevator warp to an impossible cell.
          -- The 1F Goldenrod door cells are remembered and handled by our own
          -- Ready to leave? prompt instead.
          if sourceId == "RADIO_TOWER_1F" and tostring(cw.destMap):find("GOLDENROD",1,true) then
            WARDEN_EXIT_CELLS[(tonumber(cw.y) or 0)*1024 + (tonumber(cw.x) or 0)] = true
          end
          cw.x, cw.y = 255, 255
          cw.destMap = targetId
          cw.destWarp = wi
          cw.destGroup, cw.destMapNum = nil, nil
        end
        warps[wi] = cw
      end
      -- Crystal's 3F tile callback opens these two blocks after the Card Key.
      -- Private investigations omit story callbacks, so register the open
      -- geometry directly. Retail Goldenrod and story flags are untouched.
      local privateBlocks = copyPlain(src.blocks or {})
      if sourceId == "RADIO_TOWER_3F" then
        privateBlocks[1 * src.width + 7 + 1] = 0x2a
        privateBlocks[2 * src.width + 7 + 1] = 0x01
      end
      mod.content.maps:register(targetId, {
        id = targetId, label = "Lavender Radio Tower", index = 1400 + i,
        tileset = src.tileset, width = src.width, height = src.height,
        blocks = privateBlocks, borderBlock = src.borderBlock,
        palette = src.palette, environment = src.environment, outdoor = src.outdoor,
        warps = warps, objects = {}, signs = {}, connections = {},
      })
      -- Ensures Music.playMap has a valid post-fanfare target on the private map.
      mod.content.map_songs:register(targetId, "Music_RuinsOfAlphRadio")
    end
  end

  local SPIRIT_STATION = "SPIRIT_BAND"
  -- 0.2.56 resolves tuner display names through the shared radio registry.
  -- Registering here fixes the blank station-name panel; STATION_NAMES below
  -- remains only a loader-free fallback.
  mod.content.radio_channels:register(SPIRIT_STATION, { name = "SPIRIT BAND" })
  local HAUNTED_MAP = "WARDEN_RADIO_TOWER_1F"
  local HAUNTED_MAPS = {
    WARDEN_RADIO_TOWER_1F=true, WARDEN_RADIO_TOWER_2F=true, WARDEN_RADIO_TOWER_3F=true,
    WARDEN_RADIO_TOWER_4F=true, WARDEN_RADIO_TOWER_5F=true,
  }
  local function isHauntedMapId(id) return id and HAUNTED_MAPS[id] == true end
  local ghostStepClock = 0
  local enragedMoveClock = 0
  local cleansingWhiteUntil = 0
  local cleansingRevealAt = 0
  local cleansingRevealWorld = nil
  local ghostContactFxUntil = 0
  local ghostContactBlackoutUntil = 0
  local devGhostNpcId = nil
  local clearDevGhostVisual = nil -- case return flow is defined before DEV ghost helper
  local showPaged = nil -- forward declaration; contact effects are defined before dialogue helpers
  local playNamed = nil -- forward declaration; contact effects also need SFX before helper definitions
  local wardenCasesFailed = nil -- failInvestigation is defined before the Ezra record helpers
  local clearCaseReport = nil -- failure cleanup is also defined before Ezra report helpers
  local returnToEzraAfterCase = nil -- TERRIFAINT failure is defined before Ezra result flow
  local restoreMusicAt = 0
  local restoreMusicWorld = nil
  local enragedGhostFlashUntil = 0
  local manifestationUntil = 0 -- reserved for TERRIFAINT GHOST overlay only
  local manifestationImage = nil
  local speciesFxUntil = 0
  local speciesFxStart = 0
  local speciesFxKind = nil
  local speciesFxSeed = 0
  local contactLockUntil = 0
  local ambientManifestUntil = 0
  -- DEV9h generic high-activity haunting events. These are deliberately short
  -- disruptions: scary/disorienting, but not long enough to become chores.
  local hauntFxKind = nil
  local hauntFxStart = 0
  local hauntFxUntil = 0
  local hauntFxSeed = 0
  local ambientHauntUntil = 0
  local reverseControlsUntil = 0
  local genericEventIndex = 0
  local falsePresenceNpcId = nil
  local falseCalmWorld = nil
  local falseCalmWasActive = false
  local falseCalmActiveNow = nil -- forward declaration; ambient event helpers use it below
  -- DEV9q: returning from an investigation must finish the map transition and
  -- render SOUL_HOUSE before Ezra starts the result conversation.  Keep this
  -- transient state on the mod object rather than adding more locals to this
  -- already-large init closure (Lua 5.1 caps locals per function at 200).
  mod._wardenReturnResolutionAt = 0
  mod._wardenReturnResolutionWorld = nil
  -- DEV10e field-test equipment keeps transient presentation state on `mod`.
  -- This avoids pushing the already-large initializer toward Lua 5.1's local
  -- variable ceiling while save-backed placement/progression survives reloads.
  mod._wardenUvUntil = 0
  mod._wardenUvNextUse = 0
  mod._wardenUvNextFlash = 0
  mod._wardenUvFlashUntil = 0
  mod._wardenUvFlashCount = 0
  mod._wardenAshSlowUntil = 0
  mod._wardenBookNpcId = nil
  mod._wardenAshNpcId = nil
  -- Exposed for deterministic verification and future balance passes. The
  -- Powerlight's 6.72-tile radius is exactly 40% wider than Candle's 4.8.
  mod._wardenCandleRadius = 4.8
  mod._wardenPowerlightRadius = 6.72
  local enragedFloorGraceUntil = 0
  local enragedEntryX, enragedEntryY, enragedEntryMap = nil, nil, nil
  local residentsMasked = false
  local savedMasks = {}
  local DARK_PIPELINE = "spirit_darkness"
  local Pipelines = require("src.render.Pipelines")
  local Sound = require("src.core.Sound")
  local Gen2Npc = require("src.world.gen2.Npc")

  -- User-authored 16x16 floor sprites for fresh and disturbed Binding Ash.
  -- Register them as still true-color sprites so their exact pixel art is
  -- preserved instead of being redrawn with vector shapes by the pipeline.
  if mod.content.sprites then
    mod.content.sprites:register("WARDEN_BINDING_ASH",{
      id="WARDEN_BINDING_ASH",image=(mod.path or ".").."/assets/binding_ash.png",
      frames=1,walker=false,trueColor=true,spriteType="STILL_SPRITE",
    })
    mod.content.sprites:register("WARDEN_BINDING_ASH_STEPPED",{
      id="WARDEN_BINDING_ASH_STEPPED",image=(mod.path or ".").."/assets/binding_ash_stepped.png",
      frames=1,walker=false,trueColor=true,spriteType="STILL_SPRITE",
    })
  end

  -- False Presence uses the same overworld monster sprite as the physical DEV
  -- spirit marker, but rendered as a pure black silhouette.  Keep this in the
  -- normal NPC draw path so the apparition obeys camera/zoom exactly like a
  -- real overworld object.
  if Gen2Npc and not Gen2Npc._wardenFalsePresenceDraw then
    Gen2Npc._wardenFalsePresenceDraw = true
    local vanillaNpcDraw = Gen2Npc.draw
    Gen2Npc.draw = function(self, ...)
      if self and self.def and self.def.name == "WARDEN_FALSE_PRESENCE" then
        local now = love.timer and love.timer.getTime and love.timer.getTime() or 0
        if not (hauntFxKind == "FALSE_PRESENCE" and now < hauntFxUntil) then return end
        -- Flicker rather than sit there continuously: about two-thirds of the
        -- event is visible, with quick irregular dropouts.
        local phase = math.floor((now - hauntFxStart) * 14 + hauntFxSeed)
        if phase % 5 == 1 or phase % 7 == 3 then return end
        local G = love.graphics
        G.push("all")
        G.setColor(0, 0, 0, 0.96)
        local result = {vanillaNpcDraw(self, ...)}
        G.pop()
        return result[1]
      end
      return vanillaNpcDraw(self, ...)
    end
  end

  -- DEV5e darkness prototype. Use only the engine-supported render pipeline.
  -- No direct World.draw monkey-patching: that path can escape the pipeline guard
  -- and was responsible for the hard application crash in DEV5d.
  -- DEV5h darkness pipeline. Render the WORLD into its own canvas, darken that
  -- canvas, and let Crystal composite text boxes / START / Pokegear / Pack on
  -- top afterward.  This is the engine-supported worldPresent seam and avoids
  -- both the DEV5d hard-crash path and DEV5g's "UI makes darkness disappear"
  -- compromise.
  local darknessWorldCanvas = nil
  mod.content.render_pipelines:register(DARK_PIPELINE, {
    label = "SPIRIT DARK",
    levels = { "OFF", "ON" },
    priority = 90,

    drawWorld = function(ctx)
      local ow = ctx and ctx.state
      if not (ow and ow.map and isHauntedMapId(ow.map.id)
        and mod.save:get("warden_enrolled") == true
        and mod.save:get("haunt_resolved") ~= true) then
        return nil
      end

      local G = love.graphics
      local w, h = ctx.width, ctx.height
      if not darknessWorldCanvas
        or darknessWorldCanvas:getWidth() ~= w
        or darknessWorldCanvas:getHeight() ~= h then
        darknessWorldCanvas = G.newCanvas(w, h)
      end

      local previous = G.getCanvas()
      G.push("all")
      G.origin()
      G.setCanvas(darknessWorldCanvas)
      G.clear(0.07, 0.05, 0.02, 1)
      G.setColor(1, 1, 1, 1)
      -- World:draw() has already followed the player/camera before the pipeline
      -- is called.  drawWorldBody is Crystal's normal ground + people pass.
      ow:drawWorldBody(ctx.scale)
      G.setCanvas(previous)
      G.pop()
      return darknessWorldCanvas
    end,

    worldPresent = function(canvas, ctx)
      local ow = ctx and ctx.state
      local now = love.timer and love.timer.getTime and love.timer.getTime() or 0
      -- A successful seal marks the haunting resolved before the cleansing
      -- sequence begins. Keep the presentation pipeline alive for the brief
      -- white-out so the flash is actually visible before normal lighting
      -- returns.
      if not (ow and ow.map and isHauntedMapId(ow.map.id)
        and mod.save:get("warden_enrolled") == true
        and (mod.save:get("haunt_resolved") ~= true or now < cleansingWhiteUntil)) then
        return canvas
      end

      local G = love.graphics
      local w, h = canvas:getWidth(), canvas:getHeight()
      local out = G.newCanvas(w, h)
      local previous = G.getCanvas()
      G.push("all")
      G.origin()
      G.setCanvas(out)
      G.clear(0, 0, 0, 1)
      G.setColor(1, 1, 1, 1)

      -- A direct spirit collision produces a short, ugly visual tear rather
      -- than a clean UI-style flash.  It is intentionally world-only so the
      -- text box remains readable if contact also produces a message.
      if now < cleansingWhiteUntil then
        -- A correct seal blows the haunted world out to white for a beat.
        G.clear(1, 1, 1, 1)
      elseif now < ghostContactBlackoutUntil then
        -- The spirit can simply swallow the room for a beat.
        G.clear(0, 0, 0, 1)
      elseif now < ghostContactFxUntil then
        local strips = 8
        local sh = math.max(1, math.floor(h / strips))
        for i=0,strips-1 do
          local sy = i * sh
          local hh = (i == strips-1) and (h-sy) or sh
          local jitter = math.random(-8,8)
          G.draw(canvas, jitter, sy, 0, 1, 1, 0, sy)
          -- occasional doubled slice makes the distortion less like camera shake
          if math.random(100) <= 35 then G.draw(canvas, -jitter, sy, 0, 1, 1, 0, sy) end
        end
      else
        G.draw(canvas, 0, 0)
      end

      -- Wrong-seal hunts drain the room almost monochrome and pulse red.
      if mod.save:get("case_state") == "ENRAGED HUNT" then
        G.setColor(0.075, 0.075, 0.085, 0.84)
        G.rectangle("fill", 0, 0, w, h)
        local pulse = 0.5 + 0.5 * math.sin(now * 5.2)
        G.setColor(0.30, 0.015, 0.02, 0.10 + pulse * 0.20)
        G.rectangle("fill", 0, 0, w, h)
      else
        G.setColor(0.055, 0.075, 0.105, 0.76)
        G.rectangle("fill", 0, 0, w, h)
      end

      local enraged = mod.save:get("case_state") == "ENRAGED HUNT"
      local uvActive = not enraged and now < (tonumber(mod._wardenUvUntil) or 0)
      local falseCalmActive = hauntFxKind == "FALSE_CALM" and now < hauntFxUntil
      local powerlightLit = mod.save:get("dev_powerlight") == true and not enraged
      local candleLit = mod.save:get("dev_candle") == true and not enraged
      local radiusTiles
      if enraged then
        -- Wrong-seal hunts keep the original claustrophobic radius.
        radiusTiles = 2
      elseif uvActive then
        -- The radial value is unused while UV bypasses the mask below, but
        -- retain a sane fallback for renderers that inspect it.
        radiusTiles = 4.05
      elseif powerlightLit then
        -- The late-game Powerlight projects a radius 40% wider than Candle.
        radiusTiles = falseCalmActive and mod._wardenPowerlightRadius
          or (mod._wardenPowerlightRadius + 0.32 * math.sin(now*1.85) + 0.12 * math.sin(now*4.9))
      elseif candleLit then
        -- Candlelight gently breathes instead of looking like a static UI mask.
        -- Two slow waves keep the motion organic without becoming distracting.
        radiusTiles = falseCalmActive and mod._wardenCandleRadius
          or (mod._wardenCandleRadius + 0.264 * math.sin(now * 2.15) + 0.096 * math.sin(now * 5.7))
      else
        -- Ordinary no-candle investigation is a little more forgiving.
        radiusTiles = 3.06
      end
      local p, cam = ow.player, ow.camera
      local worldScale = ctx.scale or ((ow.zoomScale and ow:zoomScale()) or 1)

      -- Player sprite centre in the world canvas. Keep the DEV5g vertical
      -- alignment that tested well, but there is no Playfield offset here:
      -- worldPresent receives only Crystal's world image.
      local cx, cy
      if p and cam then
        cx = (p.px - cam.x + 8) * worldScale
        cy = (p.py - cam.y + 4) * worldScale
      else
        cx, cy = w / 2, h / 2
      end
      cx, cy = math.floor(cx + 0.5), math.floor(cy + 0.5)

      -- Replace the usual blue-grey cast with a murky green while UV is live.
      -- This is applied before the light mask so darkness outside the beam
      -- remains black instead of turning into a full-screen green wash.
      if uvActive then
        G.setColor(0.04,0.34,0.10,0.46)
        G.rectangle("fill",0,0,w,h)
      end

      local tile = math.max(4, math.floor(8 * worldScale + 0.5))
      local r = math.max(tile * 1.5, radiusTiles * tile)
      local band = math.max(2, math.floor(r / 4))
      local top = math.floor(cy - r)
      local bottom = math.ceil(cy + r)
      local edges = {
        { -4, -3, 0.48 },
        { -3, -2, 0.72 },
        { -2, -1, 0.90 },
        { -1,  1, 1.00 },
        {  1,  2, 0.90 },
        {  2,  3, 0.72 },
        {  3,  4, 0.48 },
      }

      -- UV is a brief full-room exposure, not another flashlight radius. The
      -- map/view fills with green for eight seconds, then this exact darkness
      -- mask resumes. Other light sources retain their normal radius.
      if not uvActive then
        G.setColor(0.002, 0.006, 0.025, 0.965)
        if top > 0 then G.rectangle("fill", 0, 0, w, top) end
        if bottom < h then G.rectangle("fill", 0, bottom, w, h - bottom) end
        for edgeIndex, e in ipairs(edges) do
          -- Anchor the outer bands to the actual radius.  r is not always an
          -- exact multiple of four (especially while Candle light breathes),
          -- and the old rounded band math could leave a 1-3 px horizontal seam.
          local y1 = (edgeIndex == 1) and top or math.max(top, math.floor(cy + e[1] * band))
          local y2 = (edgeIndex == #edges) and bottom or math.min(bottom, math.ceil(cy + e[2] * band))
          if y2 > y1 then
            local half = math.floor(r * e[3])
            local left = math.max(0, math.floor(cx - half))
            local right = math.min(w, math.ceil(cx + half))
            if left > 0 then G.rectangle("fill", 0, y1, left, y2 - y1) end
            if right < w then G.rectangle("fill", right, y1, w - right, y2 - y1) end
          end
        end
      end

      -- During a successful UV pulse, expose a flashing black silhouette at
      -- the real roaming ghost coordinate. It is deliberately screen-clipped:
      -- knowing the spirit is elsewhere on the floor is not the same as seeing
      -- exactly where it stands.
      if uvActive and now < (tonumber(mod._wardenUvFlashUntil) or 0) then
        local gx=tonumber(mod.save:get("ghost_x"))
        local gy=tonumber(mod.save:get("ghost_y"))
        local gmap=mod.save:get("ghost_map")
        if gx and gy and gmap==ow.map.id and cam then
          local sx=(gx*16-cam.x+8)*worldScale
          local sy=(gy*16-cam.y+8)*worldScale
          local s=math.max(1,worldScale)
          local flicker=math.floor(now*30)%3~=1
          if flicker and sx>-18*s and sy>-22*s and sx<w+18*s and sy<h+22*s then
            G.setColor(0,0,0,0.98)
            G.circle("fill",sx,sy-4*s,3.5*s)
            G.ellipse("fill",sx,sy+2*s,5.5*s,8*s)
            G.polygon("fill",sx-5*s,sy+5*s, sx-8*s,sy+12*s,
              sx-2*s,sy+9*s, sx+2*s,sy+12*s, sx+6*s,sy+5*s)
          end
        end
      end

      -- Species manifestations are environmental tells, not battle-style GHOST
      -- reveals.  Give each one an actual visible world effect so the player can
      -- read the phenomenon instead of being told about it in a text box.
      if speciesFxKind and now < speciesFxUntil then
        local dur=math.max(0.01,speciesFxUntil-speciesFxStart)
        local t=math.max(0,math.min(1,(now-speciesFxStart)/dur))
        if speciesFxKind=="MAGNEMITE" then
          -- The investigation lights are already "off" aesthetically; this is
          -- the remaining visibility itself stuttering out in electrical bursts.
          local phase=math.floor((now-speciesFxStart)*13)
          if phase%3~=1 then
            G.setColor(0,0,0,0.82 + 0.14*math.abs(math.sin(now*31)))
            G.rectangle("fill",0,0,w,h)
          else
            G.setColor(0.75,0.90,1.0,0.10)
            G.rectangle("fill",0,0,w,h)
          end
        elseif speciesFxKind=="PORYGON" then
          -- Corrupt only the already-masked haunted presentation.  DEV9g drew
          -- raw `canvas` slices here, which accidentally revealed the entire
          -- bright room.  Instead tear/duplicate the visible darkness itself.
          local pulse=math.abs(math.sin(now*17))
          for i=1,9 do
            local yy=((i*31+speciesFxSeed*7)%math.max(1,h-8))
            local hh=2+((i*5+speciesFxSeed)%7)
            local off=((i+speciesFxSeed)%2==0 and 1 or -1)*(3+((i*9)%13))
            G.setColor(0.55,0.18,0.72,0.12+0.18*pulse)
            G.rectangle("fill",math.max(0,off),yy,math.max(1,w-math.abs(off)),hh)
            G.setColor(0.10,0.68,0.76,0.10+0.14*pulse)
            G.rectangle("fill",math.max(0,-off),yy+hh,math.max(1,w-math.abs(off)),2)
          end
          -- Blocky missing-data chunks stay inside the visible presentation;
          -- black gaps and chromatic bars read as a broken Game Boy frame.
          for i=1,16 do
            local bx=((i*37+speciesFxSeed*11)%math.max(1,w-14))
            local by=((i*23+speciesFxSeed*7)%math.max(1,h-9))
            local bw=5+((i*5)%18); local bh=2+((i*3)%8)
            if i%3==0 then G.setColor(0,0,0,0.72)
            elseif i%3==1 then G.setColor(0.55,0.14,0.70,0.34)
            else G.setColor(0.08,0.62,0.70,0.30) end
            G.rectangle("fill",bx,by,bw,bh)
          end
        elseif speciesFxKind=="MURKROW" then
          -- A fast, featureless shadow actually crosses the player's view.
          local x=-32 + (w+64)*t
          local y=h*0.36 + math.sin(t*math.pi*2)*10
          G.setColor(0.005,0.005,0.012,0.88)
          G.ellipse("fill",x,y,18,7)
          G.polygon("fill",x-5,y, x-25,y-12, x-16,y+2)
          G.polygon("fill",x+5,y, x+25,y-10, x+16,y+3)
          G.setColor(0,0,0,0.20*(1-math.abs(t-.5)*1.5))
          G.rectangle("fill",0,0,w,h)
        elseif speciesFxKind=="JIGGLYPUFF" then
          -- Soft concentric sound waves, kept ghostly/subtle rather than UI-like.
          local cx,cy=w*0.5,h*0.46
          for i=0,3 do
            local rr=((t+i*0.22)%1)*math.min(w,h)*0.42
            G.setColor(0.92,0.82,1.0,0.16*(1-((t+i*0.22)%1)))
            G.circle("line",cx,cy,rr)
          end
          G.setColor(0.45,0.32,0.62,0.08+0.06*math.sin(now*8))
          G.rectangle("fill",0,0,w,h)
        elseif speciesFxKind=="CUBONE" then
          -- The room briefly drains colder and a pale echo blooms at the edges.
          local a=0.18+0.16*math.sin(t*math.pi)
          G.setColor(0.12,0.15,0.20,a)
          G.rectangle("fill",0,0,w,h)
          G.setColor(0.88,0.86,0.78,0.10*math.sin(t*math.pi))
          G.rectangle("line",3,3,w-6,h-6)
          G.rectangle("line",6,6,w-12,h-12)
        elseif speciesFxKind=="HAUNTER" then
          -- Aggressive close-presence pulse: purple-black edge pressure and
          -- brief lateral tearing, without revealing a species sprite.
          local pulse=math.abs(math.sin(now*12))
          G.setColor(0.12,0.015,0.16,0.16+0.18*pulse)
          G.rectangle("fill",0,0,w,h)
          local edge=math.floor(10+14*pulse)
          G.setColor(0,0,0,0.55)
          G.rectangle("fill",0,0,edge,h); G.rectangle("fill",w-edge,0,edge,h)
        end
      end

      -- Generic high-activity haunting effects. These layer over the normal
      -- darkness rather than bypassing it, so none of them expose the raw map.
      if hauntFxKind and now < hauntFxUntil then
        local dur=math.max(0.01,hauntFxUntil-hauntFxStart)
        local t=math.max(0,math.min(1,(now-hauntFxStart)/dur))
        if hauntFxKind=="LIGHTS_OUT" then
          local a=0.34+0.42*math.sin(t*math.pi)
          G.setColor(0,0,0,a); G.rectangle("fill",0,0,w,h)
        elseif hauntFxKind=="STATIC" then
          -- Dense analog-TV snow: rapidly changing horizontal noise across the
          -- already-darkened presentation, without revealing hidden map tiles.
          local phase=math.floor((now-hauntFxStart)*24)
          G.setScissor(0,0,w,h)
          for i=1,95 do
            local yy=((i*17+hauntFxSeed*11+phase*7)%math.max(1,h))
            local xx=((i*37+hauntFxSeed*5+phase*19)%math.max(1,w))
            local ww=3+((i*13+phase*5)%34)
            local aa=0.16+0.34*((i+phase)%5)/4
            if (i+phase)%3==0 then G.setColor(0.86,0.90,0.92,aa)
            elseif (i+phase)%3==1 then G.setColor(0.28,0.34,0.38,aa)
            else G.setColor(0.04,0.05,0.06,aa) end
            G.rectangle("fill",xx,yy,ww,1+((i+phase)%3))
          end
          for i=1,9 do
            local yy=((i*31+phase*13+hauntFxSeed)%math.max(1,h))
            G.setColor(0.82,0.86,0.88,0.10+0.10*((i+phase)%2))
            G.rectangle("fill",0,yy,w,1)
          end
          G.setScissor()
        elseif hauntFxKind=="COLD" then
          G.setColor(0.10,0.16,0.24,0.18+0.18*math.sin(t*math.pi)); G.rectangle("fill",0,0,w,h)
        elseif hauntFxKind=="FALSE_PRESENCE" then
          -- The actual apparition is a temporary passable overworld actor so it
          -- really occupies a tile 2-3 spaces away. Its draw wrapper silhouettes
          -- and flickers it; no additional screen-space fake is needed here.
        elseif hauntFxKind=="FALSE_CALM" then
          -- False Calm is intentionally visually uneventful: steady light, no
          -- overlays, no manifestations, no ghost movement, and dead silence.
        elseif hauntFxKind=="POSSESSION" then
          local a=0.08+0.08*math.abs(math.sin(now*9))
          G.setColor(0.22,0.02,0.25,a); G.rectangle("fill",0,0,w,h)
        elseif hauntFxKind=="DISPLACE" or hauntFxKind=="DRAGGED" then
          local a=0.34*math.sin(t*math.pi)
          G.setColor(0,0,0,a); G.rectangle("fill",0,0,w,h)
        elseif hauntFxKind=="CANDLE" then
          local a=(math.floor((now-hauntFxStart)*15)%2==0) and 0.38 or 0.08
          G.setColor(0,0,0,a); G.rectangle("fill",0,0,w,h)
        end
      end

      -- The supplied Pokemon Tower GHOST image is now reserved for the actual
      -- TERRIFAINT/catch presentation, not ordinary species manifestations.
      if now < manifestationUntil then
        if not manifestationImage then
          local ok,img=pcall(mod.assets.image, mod.assets, "assets/spirit_ghost.png")
          if ok then manifestationImage=img end
        end
        if manifestationImage then
          local iw,ih=manifestationImage:getWidth(),manifestationImage:getHeight()
          local scale=math.max(2, math.floor(math.min(w/(iw*3),h/(ih*3))))
          local alpha=0.72 + 0.28*math.abs(math.sin(now*22))
          G.setColor(1,1,1,alpha)
          G.draw(manifestationImage, math.floor((w-iw*scale)/2),
            math.floor((h-ih*scale)/2)-4, 0, scale, scale)
        end
      end

      G.setColor(1, 1, 1, 1)
      G.setCanvas(previous)
      G.pop()
      return out
    end,

    invalidate = function()
      darknessWorldCanvas = nil
    end,
  })

  local function playHauntMusic()
    local ow = mod.world:overworld()
    if not (ow and ow.game and ow.game.data) then return end
    local ok, Music = pcall(require, "src.core.Music")
    if ok and Music and Music.play then
      -- Crystal's eerie Ruins of Alph / Unown transmission.
      pcall(Music.play, ow.game.data, "Music_RuinsOfAlphRadio", true,
        { kind = "map", mapId = ow.map.id })
    end
  end

  local function playEnragedMusic()
    local ow = mod.world:overworld()
    if not (ow and ow.game and ow.game.data) then return end
    local ok, Music = pcall(require, "src.core.Music")
    if ok and Music and Music.play then
      pcall(Music.play, ow.game.data, "Music_RocketHideout", true,
        { kind = "map", mapId = ow.map.id })
    end
  end

  -- Hide the vanilla residents without touching event flags/SRAM. Object masks
  -- are live-map state only and are rebuilt from the cart's flags on reload.
  local function maskResidents()
    local ow = mod.world:overworld()
    if residentsMasked or not (ow and ow.map and isHauntedMapId(ow.map.id)) then return end
    residentsMasked = true
    savedMasks = {}
    for i, obj in ipairs(ow.map.def.objects or {}) do
      if not obj.runtime then
        local key = ow:objectMaskKey(obj, i)
        savedMasks[key] = ow.objectMasks and ow.objectMasks[key] or nil
        ow:setObjectMask(obj, i, true)
      end
    end
    ow:rebuildPeople({ seamless = true })
  end

  local function restoreResidents()
    local ow = mod.world:overworld()
    if not residentsMasked then return end
    if ow and ow.map and isHauntedMapId(ow.map.id) then
      ow.objectMasks = ow.objectMasks or {}
      ow.maskScripted = ow.maskScripted or {}
      for key, old in pairs(savedMasks) do
        ow.objectMasks[key] = old
        ow.maskScripted[key] = nil
      end
      ow:rebuildPeople({ seamless = true })
    end
    residentsMasked = false
    savedMasks = {}
  end

  -- Keep the investigation copy visibly evacuated even if a vanilla Radio
  -- Tower scene tries to materialize an NPC after map load.  This touches only
  -- the live map entity lists/masks, never event flags or SRAM.
  local function purgeHauntedNpcs()
    local ow = mod.world:overworld()
    if not (ow and ow.map and isHauntedMapId(ow.map.id)) then return end
    if not (mod.save:get("warden_enrolled") == true and mod.save:get("haunt_resolved") ~= true) then return end
    ow.objectMasks = ow.objectMasks or {}
    ow.maskScripted = ow.maskScripted or {}
    local changed = false
    for i, obj in ipairs(ow.map.def.objects or {}) do
      if not obj.runtime then
        local key = ow:objectMaskKey(obj, i)
        if ow.objectMasks[key] ~= true then
          ow.objectMasks[key] = true
          ow.maskScripted[key] = true
          changed = true
        end
      end
    end
    if changed and ow.rebuildPeople then
      pcall(ow.rebuildPeople, ow, { seamless = true })
    end
    -- A story script can hold a trainer reference even after its sprite is
    -- masked. Clear those transient handles every frame while haunted.
    ow.talkNpc = nil
    ow.trainerSight = nil
    ow.trainerNpc = nil
    if ow.vm then ow.vm.trainerObject = nil end
  end

  local function hauntedNow()
    local ow = mod.world:overworld()
    return mod.save:get("warden_enrolled") == true
      and ow and ow.map and isHauntedMapId(ow.map.id)
  end

  local function activity() return tonumber(mod.save:get("haunt_activity")) or 0 end
  local function addActivity(n)
    n=tonumber(n) or 0
    -- Temperament applies to every positive activity trigger, not just passive
    -- walking. Magnemite and Murkrow add +1; Haunter adds +2, making it reach
    -- the same fuzzy stage thresholds substantially faster.
    if n>0 then
      local species=tostring(mod.save:get("case_species") or "")
      if species=="MAGNEMITE" or species=="MURKROW" then n=n+1
      elseif species=="HAUNTER" then n=n+2 end
    end
    local v = math.min(100, activity() + n)
    mod.save:set("haunt_activity", v)
    return v
  end
  mod._wardenAddActivity=addActivity

  local function interactionCount()
    return tonumber(mod.save:get("haunt_interactions")) or 0
  end

  local function ghostPresent()
    return mod.save:get("ghost_present") == true
  end

  local function ghostPos()
    return tonumber(mod.save:get("ghost_x")), tonumber(mod.save:get("ghost_y")), mod.save:get("ghost_map")
  end

  local function setGhostPos(x, y, mapId)
    mod.save:set("ghost_x", x); mod.save:set("ghost_y", y)
    if mapId then mod.save:set("ghost_map", mapId) end
  end

  local function manhattan(ax, ay, bx, by)
    if not (ax and ay and bx and by) then return 99 end
    return math.abs(ax-bx) + math.abs(ay-by)
  end

  local function validGhostCell(ow, x, y)
    if not (ow and ow.map and ow.map.inBounds and ow.map:inBounds(x,y)) then return false end
    if not ow.map:isWalkable(x,y) then return false end
    if ow.player and ow.player.cellX == x and ow.player.cellY == y then return false end
    for _, e in ipairs(ow.entities or {}) do
      if e ~= ow.player and e.cellX == x and e.cellY == y then return false end
    end
    return true
  end

  local function spawnInvisibleGhost(ow)
    if ghostPresent() or not ow then return end
    local px, py = ow.player.cellX, ow.player.cellY
    local choices = {}
    -- Retail Lavender test house is small, so discover valid cells from map bounds
    -- rather than hardcoding coordinates. Prefer cells at least 3 steps away.
    local w = tonumber(ow.map.width or (ow.map.def and ow.map.def.width)) or 12
    local h = tonumber(ow.map.height or (ow.map.def and ow.map.def.height)) or 12
    for y=0,h-1 do for x=0,w-1 do
      if validGhostCell(ow,x,y) and manhattan(px,py,x,y) >= 3 then
        choices[#choices+1] = {x=x,y=y}
      end
    end end
    if #choices == 0 then return end
    local pick = choices[math.random(#choices)]
    setGhostPos(pick.x,pick.y,ow.map.id)
    mod.save:set("ghost_present", true)
    mod.save:set("ghost_awakened", true)
  end

  local function maybeWakeGhost(ow)
    if ghostPresent() then return end
    local n = interactionCount()
    local threshold = tonumber(mod.save:get("ghost_wake_threshold")) or 2
    if n >= threshold then spawnInvisibleGhost(ow) end
  end

  local function ghostDistanceFrom(ow, x, y)
    if not ghostPresent() then return nil end
    local gx,gy,gmap=ghostPos()
    if gmap ~= ow.map.id then return nil end
    return manhattan(x,y,gx,gy)
  end

  local function moveGhostTowardPlayer(ow, allowContact)
    if not ghostPresent() then return end
    local gx,gy,gmap=ghostPos(); if not gx or gmap ~= ow.map.id then return end
    local px,py=ow.player.cellX,ow.player.cellY
    local candidates={{gx+1,gy},{gx-1,gy},{gx,gy+1},{gx,gy-1}}
    local valid={}
    for _,c in ipairs(candidates) do
      local isPlayer=(c[1]==px and c[2]==py)
      if (allowContact and isPlayer) or validGhostCell(ow,c[1],c[2]) then valid[#valid+1]=c end
    end
    if #valid==0 then return end
    table.sort(valid,function(a,b) return manhattan(a[1],a[2],px,py)<manhattan(b[1],b[2],px,py) end)
    local v=activity()
    local pick
    if allowContact or v >= 65 or math.random(100) <= math.min(85, 25+v) then pick=valid[1]
    else pick=valid[math.random(#valid)] end
    setGhostPos(pick[1],pick[2],ow.map.id)
  end

  local function spawnEnragedGhostBehind(ow)
    if not (ow and ow.player and ow.map) then return end
    local px,py=ow.player.cellX,ow.player.cellY
    local facing=ow.player.facing or "down"
    local forward=({up={0,-1},down={0,1},left={-1,0},right={1,0}})[facing] or {0,1}
    -- Behind the player is opposite the direction they are facing. Prefer a
    -- 5-7 tile head start so a decisive escape remains fair.
    local choices={}
    for dist=7,4,-1 do
      local bx,by=px-forward[1]*dist,py-forward[2]*dist
      if validGhostCell(ow,bx,by) then choices[#choices+1]={x=bx,y=by} end
      -- Small side offsets help when a straight corridor behind is blocked.
      local sx,sy=-forward[2],forward[1]
      for _,off in ipairs({-1,1}) do
        local x,y=bx+sx*off,by+sy*off
        if validGhostCell(ow,x,y) then choices[#choices+1]={x=x,y=y} end
      end
    end
    if #choices>0 then
      local pick=choices[1]
      setGhostPos(pick.x,pick.y,ow.map.id)
      mod.save:set("ghost_present",true)
      mod.save:set("ghost_awakened",true)
    else
      spawnInvisibleGhost(ow)
    end
  end


  local function spawnEnragedGhostAtEntry(ow)
    if not (ow and ow.player and ow.map) then return false end
    local ex,ey=enragedEntryX,enragedEntryY
    if enragedEntryMap ~= ow.map.id or ex==nil or ey==nil then return false end
    local px,py=ow.player.cellX,ow.player.cellY
    local choices={}
    -- Materialize around the doorway/stair tile the player just entered through,
    -- never by re-rolling a position around the player's current location.
    for r=1,3 do
      for dy=-r,r do for dx=-r,r do
        if math.abs(dx)+math.abs(dy)==r then
          local x,y=ex+dx,ey+dy
          if validGhostCell(ow,x,y) then
            choices[#choices+1]={x=x,y=y,entry=manhattan(x,y,ex,ey),player=manhattan(x,y,px,py)}
          end
        end
      end end
    end
    if #choices==0 and validGhostCell(ow,ex,ey) then choices[1]={x=ex,y=ey,entry=0,player=manhattan(ex,ey,px,py)} end
    if #choices==0 then return false end
    table.sort(choices,function(a,b)
      if a.entry==b.entry then return a.player>b.player end
      return a.entry<b.entry
    end)
    local pick=choices[1]
    setGhostPos(pick.x,pick.y,ow.map.id)
    mod.save:set("ghost_present",true)
    mod.save:set("ghost_awakened",true)
    return true
  end

  -- DEV8 case simulation ---------------------------------------------------
  -- Species and anchor are independent rolls. Species changes temperament
  -- and future event weights; it never decides which object is haunted.
  local CASE_SPECIES = {"JIGGLYPUFF","MAGNEMITE","PORYGON","MURKROW","CUBONE","HAUNTER"}
  -- HAUNTED_FLOORS is defined with the private map registrations above.
  -- Assigned later, after the Radio Tower survey helpers exist. Runtime calls
  -- happen after mod initialization, so resetCaseSimulation can safely use it.
  local buildContextualCase = nil
  local useSpiritSeal = nil
  local cluePhrase = nil
  local CASE_ANCHORS = {
    {"WARDEN_RADIO_TOWER_1F",3,0,"poster"},{"WARDEN_RADIO_TOWER_1F",5,1,"plant"},
    {"WARDEN_RADIO_TOWER_2F",15,5,"microphone"},{"WARDEN_RADIO_TOWER_2F",15,6,"papers"},
    {"WARDEN_RADIO_TOWER_2F",14,4,"equipment"},{"WARDEN_RADIO_TOWER_2F",17,4,"glass"},
    {"WARDEN_RADIO_TOWER_2F",7,0,"table"},{"WARDEN_RADIO_TOWER_2F",5,6,"table"},
    {"WARDEN_RADIO_TOWER_2F",6,0,"table"},{"WARDEN_RADIO_TOWER_2F",6,4,"plant"},
    {"WARDEN_RADIO_TOWER_2F",4,5,"cabinet"},{"WARDEN_RADIO_TOWER_3F",4,3,"phone"},
    {"WARDEN_RADIO_TOWER_3F",3,6,"phone"},{"WARDEN_RADIO_TOWER_5F",1,3,"desk"},
    {"WARDEN_RADIO_TOWER_5F",3,5,"pc"},
  }
  local SPECIES_ACTIVITY = { JIGGLYPUFF=.95, MAGNEMITE=1.0, PORYGON=1.0, MURKROW=1.05, CUBONE=.85, HAUNTER=1.25 }
  local SPECIES_EVENT_BIAS = {
    JIGGLYPUFF="music/audio", MAGNEMITE="lights/electrical", PORYGON="glitches/electronics",
    MURKROW="shadows/movement", CUBONE="mournful/quiet", HAUNTER="scares/aggression",
  }

  -- DEV8d baseline anchor clue vocabulary. Three distinct clue concepts are
  -- rolled per case. They identify the anchor, never the spirit species.
  local ANCHOR_CLUES = {
    poster={"WALL","IMAGE","PRINT","NOTICE","HANGING"},
    plant={"LEAVES","GREEN","GROW","SOIL","WATER"},
    microphone={"VOICE","SPEAK","LISTEN","SONG","BROADCAST"},
    papers={"WORDS","READ","PAGES","WRITE","INK"},
    equipment={"MACHINE","SIGNAL","CONTROL","POWER","SWITCH"},
    glass={"REFLECT","SEE","PANE","FACE","WINDOW"},
    table={"SURFACE","REST","WOOD","DESK","ABOVE"},
    cabinet={"OPEN","INSIDE","STORAGE","DOOR","SHELF"},
    phone={"RING","CALL","ANSWER","VOICE","LINE"},
    desk={"WORK","DRAWER","SURFACE","CHAIR","PAPERS"},
    pc={"SCREEN","DATA","KEYS","MACHINE","TERMINAL"},
  }
  local SPECIES_BAND_TELLS = {
    JIGGLYPUFF={"...A SOFT SONG...","...HUMMING..."},
    MAGNEMITE={"...ZZZT-KRRR...","...CURRENT..."},
    PORYGON={"...ERR//SIGNAL...","...DATA? DATA?..."},
    MURKROW={"...KRAA...","...WINGS..."},
    CUBONE={"...A LONELY CRY...","...MOTHER..."},
    HAUNTER={"...HEH...HEH...","...BEHIND YOU..."},
  }

  local function caseClueList()
    local out={}
    for i=1,3 do
      local c=mod.save:get("case_clue_"..i)
      if c then out[#out+1]=tostring(c) end
    end
    return out
  end

  local function installCaseClues(clues, matchCount, candidates)
    for i=1,3 do
      mod.save:set("case_clue_"..i,tostring(clues and clues[i] or "..."))
      mod.save:set("case_clue_found_"..i,false)
    end
    mod.save:set("case_clues",0)
    mod.save:set("case_clue_match_count",tonumber(matchCount) or 0)
    mod.save:set("case_clue_candidates",tostring(candidates or ""))
  end

  local function rollCaseClues(kind)
    local src=ANCHOR_CLUES[kind] or {"OBJECT","HERE","TOUCH","NEAR","ROOM"}
    local pool={}
    for i,v in ipairs(src) do pool[i]=v end
    for i=#pool,2,-1 do local j=math.random(i); pool[i],pool[j]=pool[j],pool[i] end
    installCaseClues({pool[1],pool[2],pool[3]},0,"baseline")
  end

  local function discoverAnchorClue()
    local missing={}
    for i=1,3 do if mod.save:get("case_clue_found_"..i) ~= true then missing[#missing+1]=i end end
    if #missing==0 then return nil,false end
    local idx=missing[math.random(#missing)]
    mod.save:set("case_clue_found_"..idx,true)
    local count=math.min(3,(tonumber(mod.save:get("case_clues")) or 0)+1)
    mod.save:set("case_clues",count)
    return tostring(mod.save:get("case_clue_"..idx) or "..."),true
  end

  -- A case can hide one to three optional follow-up clues after all three
  -- Spirit Band clues have been found. The supplied pool contains only facts
  -- derived from the real selected anchor; stable fallbacks keep older saves
  -- and baseline cases compatible.
  mod._wardenInstallFollowups = function(anchor,pool)
    local candidates,seen={},{}
    local function add(v)
      v=tostring(v or "")
      if v~="" and not seen[v] then seen[v]=true; candidates[#candidates+1]=v end
    end
    local floorHint="RELATIVE FLOOR"
    local kindHint="ODD KIND:"..tostring(anchor and anchor[4] or "object")..":"..tostring(anchor and anchor[6] or "")
    -- Slot one is always actionable. Additional slots can provide exact
    -- spatial relations/zones without risking a one-clue roll of only CENTER.
    add(math.random(2)==1 and floorHint or kindHint)
    for _,v in ipairs(pool or {}) do add(v) end
    add(floorHint)
    add(kindHint)
    add("FLOOR:"..tostring(anchor and anchor[1] or "WARDEN_RADIO_TOWER_1F"))
    for i=#candidates,3,-1 do
      local j=math.random(2,i); candidates[i],candidates[j]=candidates[j],candidates[i]
    end
    local total=math.min(#candidates,math.random(1,3))
    mod.save:set("case_followup_total",total)
    mod.save:set("case_followup_found",0)
    mod.save:set("case_followup_attempts",0)
    for i=1,3 do
      mod.save:set("case_followup_"..i,i<=total and candidates[i] or nil)
      mod.save:set("case_followup_found_"..i,false)
    end
  end

  -- Exactly one eerie unknown-number call is scheduled every three or four
  -- official cases. DEV/free-roam resets do not consume the countdown.
  mod._wardenAdvanceOddCallSchedule = function(official)
    if not official then
      mod.save:set("case_odd_call_due",false)
      mod.save:set("case_odd_call_done",false)
      return false
    end
    local remaining=tonumber(mod.save:get("warden_odd_call_countdown"))
    if not remaining or remaining<1 then remaining=math.random(3,4) end
    remaining=remaining-1
    local due=remaining<=0
    if due then remaining=math.random(3,4) end
    mod.save:set("warden_odd_call_countdown",remaining)
    mod.save:set("case_odd_call_due",due)
    mod.save:set("case_odd_call_done",false)
    mod.save:set("case_odd_call_at",math.random(45,95))
    return due
  end

  local function caseSpecies() return mod.save:get("case_species") end
  local function activityStage(v)
    v = tonumber(v) or activity()
    local wander = tonumber(mod.save:get("case_t_wander")) or 28
    local agitated = tonumber(mod.save:get("case_t_agitated")) or 58
    local hunting = tonumber(mod.save:get("case_t_hunting")) or 84
    if v >= hunting then return "HUNTING" end
    if v >= agitated then return "AGITATED" end
    if v >= wander then return "WANDERING" end
    return "LINGER"
  end

  local function chooseDifferentFloor(current)
    local choices={}
    for _,id in ipairs(HAUNTED_FLOORS) do if id ~= current then choices[#choices+1]=id end end
    return choices[math.random(#choices)]
  end

  local clearSpiritFaints

  local function resetCaseSimulation(official)
    for _,name in ipairs({"TELEPHONE","PAPERS","PLANT","SHELVING","WINDOW","DRAWERS",
      "MICROPHONE","DESK","EQUIPMENT","GLASS","CHAIRS"}) do
      mod.save:set("inspection_checked_"..name,false)
    end
    -- Real-time inspection exposure belongs to this case. Canonical desk IDs
    -- make every tile of a desk (including its telephone) share one clock.
    mod._wardenInspectionClocks={}
    local species=CASE_SPECIES[math.random(#CASE_SPECIES)]
    local anchor, contextualClues, matchCount, candidateText, followups
    if buildContextualCase then
      local ok,a,c,m,ct,fu=pcall(buildContextualCase,mod.world:overworld())
      if ok then anchor,contextualClues,matchCount,candidateText,followups=a,c,m,ct,fu
      else mod.log:warn("contextual case generation failed: "..tostring(a)) end
    end
    anchor=anchor or CASE_ANCHORS[math.random(#CASE_ANCHORS)]
    mod.save:set("case_species",species)
    mod.save:set("case_anchor_map",anchor[1]); mod.save:set("case_anchor_x",anchor[2]); mod.save:set("case_anchor_y",anchor[3]); mod.save:set("case_anchor_kind",anchor[4])
    mod.save:set("case_anchor_id",anchor[5] or "")
    mod.save:set("case_anchor_part",anchor[6])
    mod.save:set("case_serial",(tonumber(mod.save:get("case_serial")) or 0)+1)
    -- Fuzzy thresholds stop players from reverse-engineering stages by count.
    mod.save:set("case_t_wander",math.random(24,32))
    mod.save:set("case_t_agitated",math.random(54,64))
    mod.save:set("case_t_hunting",math.random(80,90))
    mod.save:set("case_steps",0); mod.save:set("case_floor_steps",0)
    mod.save:set("case_state","ACTIVE")
    mod.save:set("case_wrong_seal",false)
    mod.save:set("enraged_candle_locked",false)
    clearSpiritFaints()
    mod.save:set("case_next_floor_move",math.random(140,220))
    if contextualClues and #contextualClues >= 3 then
      installCaseClues(contextualClues,matchCount,candidateText)
    else
      rollCaseClues(anchor[4])
    end
    mod._wardenInstallFollowups(anchor,followups)
    mod._wardenAdvanceOddCallSchedule(official==true or mod.save:get("warden_case_official")==true)
    mod.save:set("band_last_probe_step",-999)
    mod.save:set("ghost_present",false)
    mod.save:set("ghost_x",nil); mod.save:set("ghost_y",nil); mod.save:set("ghost_map",nil)
    -- The spirit begins on a random floor, independent of its anchor. Its tile
    -- is chosen only when that floor is loaded, so validity uses real map data.
    mod.save:set("ghost_target_map",HAUNTED_FLOORS[math.random(#HAUNTED_FLOORS)])
  end

  local function scheduleFloorRelocation(currentMap)
    mod.save:set("ghost_present",false)
    mod.save:set("ghost_x",nil); mod.save:set("ghost_y",nil); mod.save:set("ghost_map",nil)
    mod.save:set("ghost_target_map",chooseDifferentFloor(currentMap))
    mod.save:set("case_floor_steps",0)
    local st=activityStage()
    local lo,hi=140,220
    if st=="WANDERING" then lo,hi=100,170 elseif st=="AGITATED" then lo,hi=70,130 elseif st=="HUNTING" then lo,hi=45,90 end
    mod.save:set("case_next_floor_move",math.random(lo,hi))
  end

  local function recoilGhostSameFloor(ow, minDist, maxDist)
    if not (ow and ghostPresent()) then return false end
    local gx,gy,gmap=ghostPos()
    if not gx or gmap ~= ow.map.id then return false end
    local choices={}
    local w = tonumber(ow.map.width or (ow.map.def and ow.map.def.width)) or 12
    local h = tonumber(ow.map.height or (ow.map.def and ow.map.def.height)) or 12
    for y=0,h-1 do for x=0,w-1 do
      local d=manhattan(gx,gy,x,y)
      if d >= (minDist or 2) and d <= (maxDist or 5) and validGhostCell(ow,x,y) then
        choices[#choices+1]={x=x,y=y}
      end
    end end
    if #choices == 0 then return false end
    local q=choices[math.random(#choices)]
    setGhostPos(q.x,q.y,ow.map.id)
    return true
  end

  local function playDistortedSpiritCry(ow)
    local species=caseSpecies()
    if not (species and ow and ow.game and ow.game.data) then return false end
    local ok,src=pcall(Sound.playCry, ow.game.data, species)
    if not ok or not src then return false end
    -- Distort the real species cry enough to be a clue rather than a reveal.
    -- Slow/low and fast/high variants keep repeated contacts unpredictable.
    local pitches={0.48,0.58,0.68,1.38,1.52,1.68}
    pcall(src.setPitch, src, pitches[math.random(#pitches)])
    pcall(src.setVolume, src, 0.72 + math.random()*0.22)
    return true
  end

  local function modLoaded(ow,id)
    local loaded=ow and ow.game and ow.game.modStatus and ow.game.modStatus.loaded or {}
    for _,m in ipairs(loaded) do if m and m.id==id then return true end end
    return false
  end

  local function spiritFaintedSlots()
    local raw=tostring(mod.save:get("spirit_fainted_slots") or "")
    local out={}
    for token in string.gmatch(raw,"[^,]+") do
      local n=tonumber(token); if n then out[n]=true end
    end
    return out
  end

  local function setSpiritFainted(index,on)
    local slots=spiritFaintedSlots(); slots[index]=on and true or nil
    local list={}
    for i=1,6 do if slots[i] then list[#list+1]=tostring(i) end end
    mod.save:set("spirit_fainted_slots",table.concat(list,","))
  end

  clearSpiritFaints = function() mod.save:set("spirit_fainted_slots","") end

  local function consciousParty(ow)
    local party=ow and ow.game and ow.game.save and ow.game.save.party or {}
    local spiritDown=spiritFaintedSlots()
    local out={}
    for i,mon in ipairs(party) do
      if mon and not mon.isEgg and (tonumber(mon.hp) or 0)>0 and not spiritDown[i] then
        out[#out+1]={mon=mon,index=i}
      end
    end
    return out
  end

  local function terrifaint(ow)
    local alive=consciousParty(ow)
    if #alive==0 then return 0,true end
    local wanted=math.min(#alive, math.random(2,3))
    -- Random conscious party members are investigation lives. With PokeSurvive
    -- loaded, TERRIFAINT is deliberately tracked only inside Spirit Wardens so
    -- its Nuzlocke/permadeath logic can never mistake a supernatural collapse
    -- for a genuine battle faint. Standalone keeps the visible 0-HP prototype.
    local psSafe=modLoaded(ow,"pokesurvive")
    for i=#alive,2,-1 do local j=math.random(i); alive[i],alive[j]=alive[j],alive[i] end
    for i=1,wanted do
      local pick=alive[i]
      setSpiritFainted(pick.index,true)
      if not psSafe then pick.mon.hp=0 end
    end
    return wanted,#consciousParty(ow)==0
  end

  local function failInvestigation(ow)
    -- Running out of conscious investigation lives now resolves through Ezra
    -- for official jobs. DEV-only cases still get the old simple cleanup.
    if returnToEzraAfterCase and mod.save:get("warden_case_official")==true then
      local handled=returnToEzraAfterCase(ow,"TERRIFAINT")
      if handled then return handled end
    end
    mod.save:set("case_state","FAILED")
    mod.save:set("haunt_resolved",true)
    mod.save:set("ghost_present",false)
    mod.save:set("ghost_x",nil); mod.save:set("ghost_y",nil); mod.save:set("ghost_map",nil)
    mod.save:set("ghost_target_map",nil)
    mod.save:set("enraged_candle_locked",false)
    clearSpiritFaints()
    if Pipelines and Pipelines.setLevel then pcall(Pipelines.setLevel,DARK_PIPELINE,0) end
    local party=ow and ow.game and ow.game.save and ow.game.save.party or {}
    for _,mon in ipairs(party) do if mon and mon.stats and mon.stats.hp then mon.hp=mon.stats.hp end end
    mod.world:warpTo("SOUL_HOUSE",5,3,"up")
  end

  local MANIFEST_SFX = {
    JIGGLYPUFF={"Sfx_Sing","Sfx_PerishSong","Sfx_SweetKiss","Sfx_HealBell"},
    MAGNEMITE={"Sfx_Thundershock","Sfx_Spark","Sfx_ZapCannon","Sfx_Thunder"},
    PORYGON={"Sfx_Psybeam","Sfx_Sharpen","Sfx_Kinesis2","Sfx_NoSignal"},
    MURKROW={"Sfx_WingAttack","Sfx_Peck","Sfx_Whirlwind","Sfx_RazorWind"},
    CUBONE={"Sfx_BoneClub","Sfx_Headbutt","Sfx_Leer","Sfx_Nightmare"},
    HAUNTER={"Sfx_Lick","Sfx_Nightmare","Sfx_Curse","Sfx_Spite","Sfx_Screech"},
  }

  local function playManifestSfx(ow,species)
    local pool=MANIFEST_SFX[species] or {"Sfx_Nightmare","Sfx_Damage"}
    local name=pool[math.random(#pool)]
    -- Manifestations should sound like warped attacks, not ordinary overworld
    -- UI SFX.  Use the battle move-audio path so the sound is not lost to the
    -- overworld SFX priority gate, then perturb pitch/tempo per event.
    local ok,Sound=pcall(require,"src.core.Sound")
    if ok and Sound and Sound.playMove and ow and ow.game and ow.game.data then
      local pitchChoices={0x00,0x08,0x10,0x18,0xf0,0xf8}
      local tempoChoices={0x68,0x74,0x80,0x8c,0x98}
      local anim={
        sound=name,
        pitch=pitchChoices[math.random(#pitchChoices)],
        tempo=tempoChoices[math.random(#tempoChoices)],
      }
      local played=pcall(Sound.playMove,ow.game.data,anim)
      if played then return end
    end
    -- Conservative fallback for older recomp audio paths.
    playNamed(ow,name,1)
  end

  local function triggerSpeciesManifestation(ow, opts)
    opts=opts or {}
    if not ow then return false end
    local now=love.timer and love.timer.getTime and love.timer.getTime() or 0
    local species=caseSpecies()
    -- Environmental manifestation: no Pokemon Tower GHOST overlay and no
    -- default species cry.  Attack-style SFX vary from event to event instead.
    speciesFxKind=species
    speciesFxStart=now
    local durations={JIGGLYPUFF=2.15,MAGNEMITE=1.65,PORYGON=1.85,MURKROW=0.80,CUBONE=2.0,HAUNTER=1.55}
    speciesFxUntil=now+(durations[species] or 1.5)+(opts.long and 0.35 or 0)
    speciesFxSeed=math.random(1,9999)
    playManifestSfx(ow,species)
    -- Let the audiovisual event carry the species clue.  Text boxes were
    -- starting immediately after the attack sound and could seize the same
    -- Game Boy audio channels, making the manifestation SFX effectively
    -- inaudible.  We can reintroduce selective text later if it adds value.
    if not opts.noActivity then addActivity(math.random(2,5)) end
    return true
  end

  -- Ambient audiovisual events are intentionally decoupled from the roaming
  -- ghost's WANDERING/AGITATED/HUNTING thresholds. A quiet case can start
  -- showing restrained phenomena at 20 activity without making the spirit
  -- home in on the player or attack early. The two ambient schedulers share
  -- one cooldown, so a species tell and a generic event cannot pile up on the
  -- same step.
  mod._wardenAmbientEventBand = function(v)
    v=tonumber(v) or 0
    if v<20 then return 0,0,0,0 end
    if v<=35 then return 1,24,36,1 end
    if v<=50 then return 2,18,30,2 end
    if v<=70 then return 3,14,24,3 end
    return 4,10,18,4
  end

  local function maybeAmbientManifestation(ow)
    if not ow or mod.save:get("case_state")=="ENRAGED HUNT" or falseCalmActiveNow() then return end
    local now=love.timer and love.timer.getTime and love.timer.getTime() or 0
    if now < ambientManifestUntil or now < ambientHauntUntil or now < hauntFxUntil then return end
    local v=activity()
    local chance,lo,hi=mod._wardenAmbientEventBand(v)
    if chance>0 and math.random(100)<=chance then
      ambientManifestUntil=now+math.random(lo,hi)
      ambientHauntUntil=ambientManifestUntil
      triggerSpeciesManifestation(ow,{noActivity=false})
    end
  end

  local GENERIC_EVENTS={"LIGHTS_OUT","DISPLACE","POSSESSION","FALSE_PRESENCE","COLD","STATIC","CANDLE","DRAGGED","FALSE_CALM"}

  local function safePlayerCell(ow,x,y)
    if not (ow and ow.map and ow.player and ow.map.inBounds and ow.map:inBounds(x,y)) then return false end
    if not ow.map:isWalkable(x,y) then return false end
    for _,e in ipairs(ow.entities or {}) do
      if e~=ow.player and not e.passable and e.cellX==x and e.cellY==y then return false end
    end
    return true
  end

  local function shiftPlayerTo(ow,x,y)
    local p=ow and ow.player
    if not (p and safePlayerCell(ow,x,y)) then return false end
    p.cellX=x; p.cellY=y; p.px=x*16; p.py=y*16
    p.targetX=nil; p.targetY=nil; p.moving=false; p.progress=0; p.turnTimer=0
    return true
  end

  local function randomNearbyCell(ow,minD,maxD,towardGhost)
    local p=ow.player; local gx,gy,gmap=ghostPos(); local choices={}
    for y=p.cellY-maxD,p.cellY+maxD do for x=p.cellX-maxD,p.cellX+maxD do
      local d=math.abs(x-p.cellX)+math.abs(y-p.cellY)
      if d>=minD and d<=maxD and safePlayerCell(ow,x,y) then
        local score=math.random(0,20)
        if towardGhost and gmap==ow.map.id then score=score-(math.abs(x-gx)+math.abs(y-gy))*8 end
        choices[#choices+1]={x=x,y=y,score=score}
      end
    end end
    table.sort(choices,function(a,b) return a.score>b.score end)
    return choices[1]
  end

  local function clearFalsePresence()
    if falsePresenceNpcId then
      pcall(mod.world.removeNpc, mod.world, falsePresenceNpcId)
      falsePresenceNpcId=nil
    end
  end

  local function spawnFalsePresence(ow,minDistance,maxDistance)
    clearFalsePresence()
    if not (ow and ow.map and ow.player) then return false end
    local q=randomNearbyCell(ow,minDistance or 2,maxDistance or 3,false)
    if not q then return false end
    local id,err=mod.world:spawnNpc(ow.map.id,{
      name="WARDEN_FALSE_PRESENCE", x=q.x, y=q.y,
      sprite="SPRITE_MONSTER", movement="STAY", range="DOWN",
    })
    if not id then
      mod.log:warn("Could not spawn false-presence silhouette: "..tostring(err))
      return false
    end
    falsePresenceNpcId=type(id)=="string" and id or (type(id)=="table" and (id.id or (id.npc and id.npc.id)))
    for _,npc in ipairs(ow.npcs or {}) do
      if npc.id==falsePresenceNpcId or (npc.def and npc.def.name=="WARDEN_FALSE_PRESENCE") then
        npc.passable=true
        falsePresenceNpcId=npc.id
      end
    end
    return true
  end

  falseCalmActiveNow = function()
    local now=love.timer and love.timer.getTime and love.timer.getTime() or 0
    return hauntFxKind=="FALSE_CALM" and now<hauntFxUntil
  end

  local function triggerGenericHauntEvent(ow,kind,opts)
    opts=opts or {}; if not (ow and hauntedNow()) then return false end
    local now=love.timer and love.timer.getTime and love.timer.getTime() or 0
    kind=kind or GENERIC_EVENTS[math.random(#GENERIC_EVENTS)]
    hauntFxKind=kind; hauntFxStart=now; hauntFxSeed=math.random(1,9999)
    local durations={LIGHTS_OUT=7.5,DISPLACE=3.0,POSSESSION=5.5,FALSE_PRESENCE=2.15,COLD=8.0,STATIC=4.2,CANDLE=5.5,DRAGGED=3.0,FALSE_CALM=9.0}
    hauntFxUntil=now+(durations[kind] or 4.0)
    -- Only use names that actually exist in Crystal's SFX table. Earlier
    -- prototypes included several Gen-I-ish labels (Teleport/IceBeam/etc.)
    -- that simply resolved to silence.
    local genericSfx={
      LIGHTS_OUT={"Sfx_Nightmare","Sfx_Spite","Sfx_Curse","Sfx_MeanLook"},
      DISPLACE={"Sfx_WarpTo","Sfx_WarpFrom","Sfx_Psybeam","Sfx_Kinesis2"},
      POSSESSION={"Sfx_Psychic","Sfx_Nightmare","Sfx_Kinesis","Sfx_MeanLook"},
      FALSE_PRESENCE={"Sfx_WingAttack","Sfx_Whirlwind","Sfx_MeanLook","Sfx_RazorWind"},
      COLD={"Sfx_Powder","Sfx_Shine","Sfx_Bubblebeam","Sfx_Supersonic"},
      STATIC={"Sfx_Thundershock","Sfx_Spark","Sfx_ZapCannon","Sfx_Screech","Sfx_Thunder"},
      CANDLE={"Sfx_Ember","Sfx_Burn","Sfx_Flash","Sfx_Curse"},
      DRAGGED={"Sfx_Whirlwind","Sfx_RazorWind","Sfx_Headbutt","Sfx_Bind"},
    }
    if kind~="FALSE_CALM" then
      local pool=genericSfx[kind] or {"Sfx_Nightmare"}
      local old=MANIFEST_SFX.__GENERIC
      MANIFEST_SFX.__GENERIC=pool
      playManifestSfx(ow,"__GENERIC")
      MANIFEST_SFX.__GENERIC=old
    end
    if kind=="POSSESSION" then
      reverseControlsUntil=now+5.0
    elseif kind=="DISPLACE" then
      local q=randomNearbyCell(ow,2,5,false); if q then shiftPlayerTo(ow,q.x,q.y) end
    elseif kind=="DRAGGED" then
      local q=randomNearbyCell(ow,1,3,true); if q then shiftPlayerTo(ow,q.x,q.y) end
    elseif kind=="FALSE_PRESENCE" then
      spawnFalsePresence(ow)
    elseif kind=="CANDLE" then
      if mod.save:get("dev_candle")==true and activityStage()=="HUNTING" and math.random(100)<=25 then
        mod.save:set("dev_candle",false)
      end
      -- Powerlight is sturdier than a Candle, but the strongest electrical
      -- disturbance can still knock it out temporarily.
      if mod.save:get("dev_powerlight")==true and activityStage()=="HUNTING" and math.random(100)<=10 then
        mod.save:set("dev_powerlight",false)
      end
    elseif kind=="FALSE_CALM" then
      -- An eerie hard stop: kill the current haunting ambience and freeze the
      -- spirit. Normal map/haunting music returns abruptly when the calm ends.
      falseCalmWorld=ow
      falseCalmWasActive=true
      local ok,Music=pcall(require,"src.core.Music")
      if ok and Music and Music.stop then pcall(Music.stop) end
    end
    if not opts.noActivity then addActivity(math.random(1,3)) end
    return true
  end

  local function maybeGenericHauntEvent(ow)
    if not ow or mod.save:get("case_state")=="ENRAGED HUNT" or falseCalmActiveNow() then return end
    local now=love.timer and love.timer.getTime and love.timer.getTime() or 0
    if now<ambientHauntUntil or now<ambientManifestUntil or now<hauntFxUntil then return end
    local v=activity()
    local chance,lo,hi,tier=mod._wardenAmbientEventBand(v)
    if chance>0 and math.random(100)<=chance then
      ambientHauntUntil=now+math.random(lo,hi)
      ambientManifestUntil=ambientHauntUntil
      local pool
      if tier==1 then pool={"FALSE_PRESENCE","COLD","STATIC"}
      elseif tier==2 then pool={"LIGHTS_OUT","FALSE_PRESENCE","COLD","STATIC","CANDLE","FALSE_CALM"}
      elseif tier==3 then pool={"LIGHTS_OUT","DISPLACE","POSSESSION","FALSE_PRESENCE","COLD","STATIC","CANDLE","FALSE_CALM"}
      else pool=GENERIC_EVENTS end
      triggerGenericHauntEvent(ow,pool[math.random(#pool)])
    end
  end

  local function spiritContactEffect(ow, st)
    local now = love.timer and love.timer.getTime and love.timer.getTime() or 0
    local roll=math.random(100)
    local candleLit = mod.save:get("dev_candle") == true
    local powerlightLit = mod.save:get("dev_powerlight") == true
    local snuffed=false

    -- DEV9a: a wrong-seal hunt finally has teeth. The pursuing spirit manifests
    -- as the unidentified Pokemon Tower GHOST and TERRIFAINTS 2-3 conscious
    -- party members. If none remain, the investigation fails.
    if mod.save:get("case_state") == "ENRAGED HUNT" then
      if now < contactLockUntil then return end
      contactLockUntil=now+2.25
      manifestationUntil=now+1.25
      ghostContactFxUntil=now+0.9
      playDistortedSpiritCry(ow)
      -- Species-specific tells can also occur on contact, but most catches in
      -- ENRAGED HUNT remain dangerous. Haunter never grants a reprieve.
      local species=caseSpecies()
      local specialRoll=math.random(100)
      local specialChance=(species=="HAUNTER") and 18 or 26
      if specialRoll<=specialChance then
        triggerSpeciesManifestation(ow,{long=true})
        if species~="HAUNTER" then
          recoilGhostSameFloor(ow,5,9)
          return
        end
      end
      if mod._wardenHasTool and mod._wardenHasTool("WARDING CHARM") and mod.save:get("warden_charm_used")~=true then
        mod.save:set("warden_charm_used",true)
        playNamed(ow,"Sfx_Shine",1)
        showPaged(ow,{
          "The WARDING CHARM\nflashes white!",
          "It cracks apart.\nTERRIFAINT fails!",
          "The spirit recoils.\nRUN!"
        })
        recoilGhostSameFloor(ow,5,8)
        return
      end
      local hit,failed=terrifaint(ow)
      local pages={"GHOST manifests!","TERRIFAINT tears\nthrough your party!"}
      if hit==1 then pages[#pages+1]="1 POKEMON\ncollapsed!"
      else pages[#pages+1]=tostring(hit).." POKEMON\ncollapsed!" end
      if failed then
        pages[#pages+1]="No one can go on.\nThe hunt is over."
        showPaged(ow,pages,function() failInvestigation(ow) end)
      else
        pages[#pages+1]="It's still coming.\nRUN!"
        showPaged(ow,pages)
        recoilGhostSameFloor(ow,4,7)
      end
      return
    end

    -- Every direct collision tears the world image. Some contacts also black
    -- the room out and extinguish the Candle, forcing the player to relight it.
    ghostContactFxUntil = now + 0.55 + math.random()*0.40
    if candleLit and roll <= 35 then
      mod.save:set("dev_candle", false)
      ghostContactBlackoutUntil = now + 0.65
      snuffed=true
    elseif powerlightLit and roll <= 18 then
      mod.save:set("dev_powerlight",false)
      ghostContactBlackoutUntil=now+0.48
      snuffed=true
    end

    -- Most contacts carry the spirit's own cry, heavily pitch-warped. This is
    -- deliberately useful species evidence without showing the actual Pokemon.
    local cried = (roll <= 75) and playDistortedSpiritCry(ow) or false
    if not cried then playNamed(ow, "Sfx_Damage", 1) end

    local lo,hi=5,10
    if st=="WANDERING" then lo,hi=6,12
    elseif st=="AGITATED" then lo,hi=7,13
    elseif st=="HUNTING" then lo,hi=8,15 end
    local gain=math.random(lo,hi)
    addActivity(gain)

    local pages={}
    if snuffed then
      pages[#pages+1]="The room vanishes\ninto black."
      pages[#pages+1]=(powerlightLit and not candleLit) and "Your POWERLIGHT\nblinks out!" or "Your CANDLE has\nbeen snuffed out!"
    elseif cried then
      pages[#pages+1]="A mangled cry tears\nthrough the room!"
    else
      pages[#pages+1]=(st=="LINGER") and "Reality buckles\nfor an instant." or "The presence tears\nthrough you!"
    end
    showPaged(ow,pages)

    -- Contact no longer automatically punts the spirit to another floor. It
    -- recoils locally. Wandering+ can occasionally flee upstairs/downstairs.
    local floorChance=0
    if st=="WANDERING" then floorChance=12
    elseif st=="AGITATED" then floorChance=22
    elseif st=="HUNTING" then floorChance=35 end
    if floorChance>0 and math.random(100)<=floorChance then
      scheduleFloorRelocation(ow.map.id)
    else
      recoilGhostSameFloor(ow,2,5)
    end
  end

  local function registerInvestigationInteraction(ow)
    local n=interactionCount()+1
    mod.save:set("haunt_interactions",n)
    -- Snooping is a gamble, not a fixed +7 tax. Most mundane checks do
    -- nothing; occasionally prodding the environment wakes the case up.
    local roll=math.random(100)
    local gain=0
    if roll <= 12 then gain=2 elseif roll <= 35 then gain=1 end
    local mult=SPECIES_ACTIVITY[caseSpecies() or ""] or 1
    if gain>0 and mult>1 and math.random(100)<=math.floor((mult-1)*100) then gain=gain+1 end
    if gain>0 and mult<1 and math.random(100)<=math.floor((1-mult)*100) then gain=math.max(0,gain-1) end
    if gain>0 then addActivity(gain) end
    return n
  end

  -- Investigation text is object-first and written more like a point-and-click
  -- adventure than a generic proximity meter.  Mundane details establish the
  -- room first; paranormal tells only intrude when the ghost is genuinely near.
  -- Each string is one explicit textbox page (max two visible lines).
  local function pick(t) return t[math.random(#t)] end

  local descriptions = {
    tv = {
      {"An old studio TV.\nDust on the glass.", "Dials are worn.\nIt saw heavy use."},
      {"A squat CRT set.\nThe power is off.", "A station sticker\npeels at one edge."},
      {"A monitor for the\nbroadcast floor.", "Fingerprints mark\nthe tuning knobs."},
    },
    bookcase = {
      {"Broadcast manuals\nfill the shelves.", "Some spines are\ncreased with age."},
      {"Old music guides\nand station logs.", "Two bookends look\nlike CLEFAIRY."},
      {"Rows of old books.\nMostly technical.", "A few are local\nhistory volumes."},
      {"Books sit neatly.\nAlmost too neat.", "Their titles form\nno clear pattern."},
    },
    window = {
      {"Reflective glass.\nLavender is dark.", "Your shape hangs\nfaint in the pane."},
      {"A broad window.\nIt mirrors inside.", "The station lights\nare dark behind."},
      {"Night crowds close\nto the glass.", "You barely see\nthe town below."},
    },
    radio = {
      {"A station radio.\nThe dial is still.", "Tiny pencil marks\nmark old presets."},
      {"A worn receiver.\nSpeaker is dusty.", "Someone labeled\nbuttons by hand."},
      {"An office radio.\nCord is coiled.", "The volume knob is\nworn smooth."},
    },
    pc = {
      {"The PC is dead.\nIts keys are worn.", "Years of work show\non every key."},
      {"A station PC.\nScreen is blank.", "Coffee rings mark\nthe desk below."},
      {"An aging terminal.\nNo power light.", "Several keys have\nletters worn off."},
    },
    plant = {
      {"A potted plant.\nIts soil is dry.", "Someone trimmed\nleaves carefully."},
      {"A broad-leaf plant.\nDust rims the pot.", "A watering date is\nwritten underneath."},
      {"A leafy plant.\nIt needs watering.", "A tiny station tag\nhangs on the pot."},
      {"Dust on leaves.\nOne leaf is brown.", "It must have been\nhere for years."},
    },
    incense = {
      {"An incense burner.\nOnly ash remains.", "A floral scent\nclings to it."},
      {"Old incense ash.\nNothing is lit.", "The ceramic rim is\nchipped on a side."},
    },
    map = {
      {"A wall map of the\nstation network.", "Colored pins mark\nrelay locations."},
      {"A regional map.\nNotes crowd Kanto.", "Several routes are\ncircled twice."},
    },
    shelf = {
      {"A storage shelf.\nLabels face out.", "Most boxes hold\npromo materials."},
      {"Station supplies.\nCables and forms.", "Everything is\ncarefully sorted."},
    },
    desk = {
      {"Scattered papers.\nRecording times.", "One artist was set\nfor 3 sessions."},
      {"Complaints here.\non the desk.", "Several mention\ntower renovations."},
      {"A stack of memos.\nMost are routine.", "One asks staff to\nreport odd static."},
      {"A work desk.\nPens and notes.", "Someone left in a\nhurry."},
    },
    microphone = {
      {"A studio mic.\nThe switch is off.", "The grille feels\npolished smooth."},
      {"A heavy microphone.\nCable trails away.", "A tiny ON AIR tag\nhangs from its base."},
      {"A broadcast mic.\nStand is locked.", "A faded name strip\nis taped below it."},
      {"A desk microphone.\nNo power light.", "The foam smells\nfaintly of dust."},
    },
    phone = {
      {"A desk telephone.\nThe line is dead.", "Several extensions\nsit beside it."},
      {"A beige desk phone.\nReceiver is worn.", "A sticker lists the\nnight engineer."},
      {"An office phone.\nReceiver in place.", "A note reads:\nCALL ENGINEERING."},
      {"A station phone.\nNo dial tone.", "The emergency list\nis taped below."},
    },
    cabinet = {
      {"A drawer cabinet.\nTabs mark files.", "RED says MUSIC.\nBLUE says ADS."},
      {"Colored drawers.\nEach is labeled.", "One holds old tape\nand spare cables."},
      {"A filing cabinet.\nDrawers tagged.", "Some records date\nback many years."},
      {"Colored drawers.\nEach has a number.", "One label has been\npeeled away."},
    },
    poster = {
      {"A station poster.\nCorners curl up.", "It promotes an old\nlate-night show."},
      {"A staff notice.\nInk is fading.", "It warns that upper\nfloors close at 9."},
      {"A faded poster.\nInk has dulled.", "A smiling singer\npoints to logo."},
      {"A framed notice.\nStaff signed it.", "It marks a station\nanniversary."},
    },
    glass = {
      {"A glass divider.\nIt mirrors inside.", "Beyond it sits an\nempty studio."},
      {"Studio glass.\nThicker than normal.", "Your reflection is\nsoft at the edges."},
      {"Thick glass pane.\nSmudges show.", "Someone drew a\nsmile in the dust."},
    },
    papers = {
      {"Loose paperwork.\nMostly logs.", "A margin reads:\nSTATIC AGAIN. 2AM."},
      {"Recording sheets.\nGuests are listed.", "One singer booked\nthree interviews."},
      {"Production sheets.\nNames and times.", "A canceled segment\nis crossed out."},
      {"Renovation forms.\nSome complain.", "Residents objected\nto the gutting."},
    },
    equipment = {
      {"Recording gear.\nPower is off.", "Meters sit frozen\nat their last mark."},
      {"Studio equipment.\nRows of controls.", "Tape labels mark\nold broadcasts."},
      {"A control unit.\nKnobs line its face.", "The station used it\nfor live recording."},
    },
    table = {
      {"A rounded table.\nChairs sit tucked in.", "Coffee rings mark\nthe laminate top."},
      {"A meeting table.\nNothing left on it.", "One chair is pulled\nslightly away."},
      {"A studio table.\nThe surface is bare.", "Small scratches show\nyears of use."},
    },
    fixture = {
      {"Station equipment.\nIts use is unclear.", "A faded asset tag\nis stuck below."},
      {"A fixed station\nfixture.", "Scuffs suggest it\nwas moved before."},
      {"Old office hardware.\nDust fills seams.", "Someone penciled\ninitials under it."},
    },
  }

  local paranormal = {
    tv = { near={"The dark screen\nbriefly ripples."}, close={"Static crawls over\nthe dead screen."} },
    bookcase = { near={"One page turns by\nitself."}, close={"Several books move\nat once."} },
    window = { near={"Your image lags\na beat too slow."}, close={"A shape forms too\nin the glass."} },
    radio = { near={"A soft burst of\nstatic clicks out."}, close={"The dead speaker\nwhispers a breath."} },
    pc = { near={"The blank monitor\nflickers once."}, close={"Green text blinks.\nthen disappears."} },
    plant = { near={"One leaf trembles.\nNo breeze is here."}, close={"The plant leans\ntoward the room."} },
    incense = { near={"Loose ash shifts\ninside the bowl."}, close={"Ash spirals upward\nwith no flame."} },
    map = { near={"One corner lifts\nsettles again."}, close={"Several pins shake\nat once."} },
    shelf = { near={"Something taps\ninside a box."}, close={"Items shake now\ntogether."} },
    desk = { near={"A page slides\nacross the desk."}, close={"Papers lift, slap\ndown together."} },
    papers = { near={"One sheet rustles\nwithout a draft."}, close={"A page flips to a\nblank on its own."} },
    microphone = { near={"A faint hiss leaks\nfrom the dead mic."}, close={"The mic clicks on.\nSomeone exhales."} },
    phone = { near={"The receiver gives\nsingle dry click."}, close={"The phone rings.\nThen silence."} },
    cabinet = { near={"A drawer shifts in\nits track."}, close={"Three drawers snap\nopen at once."} },
    poster = { near={"The paper puckers\nas if brushed."}, close={"The poster face\nlooks distorted."} },
    glass = { near={"A shape crosses\nthe reflection."}, close={"Something stands\nbehind you there."} },
    equipment = { near={"A dead meter jumps\nfor half a second."}, close={"The controls wake.\nNo power is connected."} },
    table = { near={"A chair gives a\nsmall wooden creak."}, close={"Something bumps the\ntable from below."} },
    fixture = { near={"Something nearby\nmakes a soft tick."}, close={"The air around it\nseems to tighten."} },
  }

  local function proximityText(kind, d)
    local pool = descriptions[kind] or descriptions.fixture
    local pages = {}
    local base = pick(pool)
    for _,p in ipairs(base) do pages[#pages+1]=p end
    if d and d <= 3 then
      local pset = paranormal[kind] or paranormal.fixture
      local extra = d <= 1 and pset.close or pset.near
      if extra then pages[#pages+1] = pick(extra) end
    elseif d and d <= 6 and math.random(100) <= 20 then
      -- Far-away tells are rare and intentionally ambiguous, so the whole
      -- tower does not constantly announce that everything is 'cold'.
      pages[#pages+1] = "For just a moment,\nyou hear a hum."
    end
    return pages
  end

  local spiritDialInstalled = false


  local function bandDistance(ow)
    if not (ow and ow.player and ghostPresent()) then return nil end
    return ghostDistanceFrom(ow,ow.player.cellX,ow.player.cellY)
  end

  local function rollSpiritBandResponse(ow)
    local function safeLine(text)
      text=tostring(text or "...")
      local stripped=text:gsub("^%.%.%.",""):gsub("%.%.%.$","")
        :gsub("ANOTHER ","OTHER ")
      local ok,Font=pcall(require,"src.render.Font")
      local function fits(s)
        return ok and Font and Font.width and Font.width(s)<=144 or (not ok and #s<=18)
      end
      if fits(text) then return text end
      if fits(stripped) then return stripped end
      local whole=stripped
      while not fits(whole) and whole:find(" ",1,true) do
        whole=whole:match("^(.*)%s+%S+$") or whole
      end
      if fits(whole) then return whole end
      if ok and Font and Font.split and Font.spansFitting then
        local spans=Font.split(stripped)
        local n=Font.spansFitting(spans,144)
        local out={}
        for i=1,n do out[#out+1]=stripped:sub(spans[i].from,spans[i].to) end
        return table.concat(out)
      end
      return stripped:sub(1,18)
    end
    if not hauntedNow() then return {safeLine("Ksssssh..."),safeLine("No spirits nearby.")} end
    if not caseSpecies() then resetCaseSimulation() end

    -- Prevent leaving the radio open (or flicking off/on without moving) from
    -- farming the entire case. A fresh meaningful probe needs some exploration.
    local steps=tonumber(mod.save:get("case_steps")) or 0
    local last=tonumber(mod.save:get("band_last_probe_step")) or -999
    if steps-last < 12 then return {safeLine("Ksssssh..."),safeLine("...only static...")} end
    mod.save:set("band_last_probe_step",steps)

    local d=bandDistance(ow)
    local v=activity()
    local clueChance=0
    if d then
      if d<=1 then clueChance=72 elseif d<=3 then clueChance=55 elseif d<=6 then clueChance=34 else clueChance=16 end
      clueChance=math.min(90,clueChance+math.floor(v/5))
    elseif v>=70 then
      clueChance=8 -- very active spirits can bleed weakly across floors
    end

    -- Probing is useful but provocative. Strong successful contact agitates it
    -- more than dead air; exact balance is intentionally easy to tune later.
    local clue=nil
    if math.random(100)<=clueChance then
      clue=discoverAnchorClue()
      if clue then
        addActivity(math.random(4,7))
        local spoken=cluePhrase(clue)
        -- A real breakthrough disturbs the spirit enough that it retreats to
        -- another floor.  This prevents camping beside it and farming all 3.
        local _,_,gmap=ghostPos()
        local fromFloor=gmap or mod.save:get("ghost_target_map") or (ow and ow.map and ow.map.id)
        if fromFloor and isHauntedMapId(fromFloor) then scheduleFloorRelocation(fromFloor) end
        return {safeLine("Ksssssh..."),safeLine(spoken)}
      end
    end

    -- Species tells are a separate optional mystery. They never increment the
    -- 3/3 anchor-clue counter and remain weighted behind actual anchor clues.
    local tellChance = d and ((d<=3 and 22) or (d<=6 and 12) or 6) or 2
    tellChance=math.min(35,tellChance+math.floor(v/10))
    if math.random(100)<=tellChance then
      addActivity(math.random(2,4))
      local tells=SPECIES_BAND_TELLS[caseSpecies()] or {"...something..."}
      return {safeLine("Ksssssh..."),safeLine(tells[math.random(#tells)])}
    end

    addActivity(math.random(1,3))
    if d and d<=3 then return {safeLine("KRRRSSSH..."),safeLine("...very close...")} end
    if d then return {safeLine("Ksssssh..."),safeLine("...faint signal...")} end
    return {safeLine("Ksssssh..."),safeLine("...dead air...")}
  end

  local bandResponse=nil
  local function installSpiritBandRadio()
    if spiritDialInstalled then return end
    spiritDialInstalled = true

    Pokegear.STATION_NAMES[SPIRIT_STATION] = "SPIRIT BAND"

    -- 11.5 sits in the large vanilla gap between Lucky Channel (08.5) and
    -- the Ruins of Alph signal (13.5). Keeping the knob ordered preserves the
    -- normal UP/DOWN tuner behavior and leaves every vanilla station intact.
    local row = {
      knob = 44,
      frequency = "11.5",
      signal = function(_ctx)
        return mod.save:get("spirit_band_unlocked") == true and SPIRIT_STATION or nil
      end,
    }
    local dial = Pokegear.RADIO_CHANNELS
    local at = #dial + 1
    for i, existing in ipairs(dial) do if (existing.knob or 0) > row.knob then at=i break end end
    table.insert(dial,at,row)

    local Radio=Pokegear.Radio
    if not Radio._lavenderSpiritBandPatched then
      Radio._lavenderSpiritBandPatched=true
      local vanillaStep=Radio.step
      Radio.step=function(self)
        if self.cur==SPIRIT_STATION then
          self:startStation()
          local ow=mod.world:overworld()
          bandResponse=rollSpiritBandResponse(ow)
          self:printLine(bandResponse[1] or "Ksssssh...","SPIRIT_BAND_RESPONSE")
          return
        elseif self.cur=="SPIRIT_BAND_RESPONSE" then
          self:printLine((bandResponse and bandResponse[2]) or "... ... ...","SPIRIT_BAND_END")
          return
        elseif self.cur=="SPIRIT_BAND_END" then
          self:printLine("... ... ...",SPIRIT_STATION)
          return
        end
        return vanillaStep(self)
      end
    end

    if not Pokegear._lavenderSpiritTunePatched then
      Pokegear._lavenderSpiritTunePatched=true
      local vanillaTune=Pokegear.tuneRadio
      Pokegear.tuneRadio=function(self)
        vanillaTune(self)
        if self.radioShow==SPIRIT_STATION then
          self.radioMusicPlaying="enterMap"; self.radioSong=nil
          local ok,Music=pcall(require,"src.core.Music")
          if ok and Music and Music.stop then pcall(Music.stop) end
        end
      end
    end
  end

  installSpiritBandRadio()
  local MAP_ID = "SOUL_HOUSE"
  local NPC_NAME = "LAVENDER_SPIRIT_WARDEN"

  local spawned = false
  local spawnedId = nil

  local function isEnrolled()
    return mod.save:get("warden_enrolled") == true
  end

  local function spiritBandUnlocked()
    return mod.save:get("spirit_band_unlocked") == true
  end

  local EZRA_PHONE_ID = 8 -- one of Crystal's unused PHONE_* slots

  -- Give Ezra a real slot in the native Pokegear contact list without replacing
  -- any retail trainer number. Slot 8 is one of the cart's const_skip holes.
  Phone.CONTACTS[EZRA_PHONE_ID] = {
    index = EZRA_PHONE_ID,
    number = EZRA_PHONE_ID,
    name = "EZRA",
    map = MAP_ID,
    calleeTime = Phone.ANYTIME,
    callerTime = Phone.NITE,
    callee = "UnusedPhoneScript",
    caller = "UnusedPhoneScript",
  }

  if not Phone._wardenEzraDeletePatched then
    Phone._wardenEzraDeletePatched = true
    local vanillaCanDelete = Phone.canDelete
    Phone.canDelete = function(id)
      if tonumber(id) == EZRA_PHONE_ID then return false end
      return vanillaCanDelete(id)
    end
  end

  local function addEzraPhoneContact(ow)
    local save = ow and ow.game and ow.game.save
    if not save then return false end
    if Phone.hasContact(save, EZRA_PHONE_ID) then
      mod.save:set("ezra_phone_added", true)
      return true
    end
    local ok = Phone.addContact(save, EZRA_PHONE_ID)
    if ok then mod.save:set("ezra_phone_added", true) end
    return ok and true or false
  end

  local function pendingCase()
    return mod.save:get("warden_case_pending") == true
  end

  local function setPendingCase(on)
    mod.save:set("warden_case_pending", on and true or false)
    if on then mod.save:set("warden_case_called", false) end
  end

  mod._wardenIsNight = function(ow)
    local hour=(ow and ow.hour and ow:hour()) or 12
    return hour>=18 or hour<4
  end

  local function wardenCasesClosed()
    return tonumber(mod.save:get("warden_cases_closed")) or 0
  end

  wardenCasesFailed = function()
    return tonumber(mod.save:get("warden_cases_failed")) or 0
  end

  local function wardenIdsReported()
    return tonumber(mod.save:get("warden_ids_reported")) or 0
  end

  local function wardenIdsCorrect()
    return tonumber(mod.save:get("warden_ids_correct")) or 0
  end

  local function wardenRankPoints()
    local points=tonumber(mod.save:get("warden_rank_points"))
    if points==nil then
      -- Existing DEV saves receive credit for their recorded work once. Rank
      -- points are permanent progress, never an expendable shop currency.
      points=wardenCasesClosed()*3+wardenIdsCorrect()
      mod.save:set("warden_rank_points",points)
      mod.save:set("warden_rank_v2_migrated",true)
    elseif mod.save:get("warden_rank_v2_migrated")~=true then
      -- DEV10e/f/g paid one point per cleanse. Add the missing two points for
      -- every recorded cleanse exactly once when upgrading.
      points=points+wardenCasesClosed()*2
      mod.save:set("warden_rank_points",points)
      mod.save:set("warden_rank_v2_migrated",true)
    end
    return points
  end
  mod._wardenRankPoints=wardenRankPoints
  mod._wardenRankName=function(points)
    points=tonumber(points) or wardenRankPoints()
    if points>=50 then return "ACE EXORCIST" end
    if points>=30 then return "GHOST GURU" end
    if points>=15 then return "SPECTOR SAGE" end
    return "WARDEN"
  end
  mod._wardenToolSlots=function(points)
    return (tonumber(points) or wardenRankPoints())>=30 and 3 or 2
  end
  mod._wardenAwardRankPoints=function(cleansed,correct)
    if mod.save:get("warden_case_rank_awarded")==true then return 0,wardenRankPoints() end
    local gain=(cleansed and 3 or 0)+(correct and 1 or 0)
    local total=wardenRankPoints()+gain
    mod.save:set("warden_rank_points",total)
    mod.save:set("warden_case_rank_awarded",true)
    mod.save:set("warden_last_rank_gain",gain)
    return gain,total
  end

  local function reportPending()
    return mod.save:get("warden_case_report_pending") == true
  end

  clearCaseReport = function()
    mod.save:set("warden_case_report_pending",false)
    mod.save:set("warden_case_report_species",nil)
  end

  local function setEnrolled()
    mod.save:set("warden_enrolled", true)
    mod.save:set("spirit_band_unlocked", true)
  end

  local function targetIsWarden(target)
    if not target then return false end
    if target.id and spawnedId and target.id == spawnedId then return true end
    if target.def and target.def.name == NPC_NAME then return true end
    if target.name == NPC_NAME then return true end
    return false
  end

  -- Dialogue rule for this mod: every page is authored as one or two short
  -- lines, and page boundaries are explicit `\f` markers.  This matters in
  -- Crystal: a plain newline only starts the second line; it does NOT force a
  -- button wait.  `\f` is the native paragraph/page break and guarantees the
  -- blinking-arrow A/B pause before the next page can begin.
  --
  -- We also keep lines comfortably under the 18-cell textbox width instead of
  -- riding the exact limit.  That prevents variable-width glyphs from causing
  -- an invisible soft-wrap and scrolling a single orphaned word upward.
  local function paginateTwoLineText(text)
    local lines = {}
    for raw in (tostring(text or "") .. "\n"):gmatch("(.-)\n") do
      if raw == "" then
        lines[#lines + 1] = ""
      else
        local current = ""
        for word in raw:gmatch("%S+") do
          if current == "" then
            current = word
          elseif #current + 1 + #word <= 18 then
            current = current .. " " .. word
          else
            lines[#lines + 1] = current
            current = word
          end
        end
        if current ~= "" then lines[#lines + 1] = current end
      end
    end
    local out = {}
    for i = 1, #lines, 2 do
      local page = lines[i] or ""
      if lines[i + 1] ~= nil then page = page .. "\n" .. lines[i + 1] end
      if page ~= "" then out[#out + 1] = page end
    end
    return out
  end

  showPaged = function(ow, pages, onDone, stay)
    -- Normalize every investigation passage before it reaches Crystal's text
    -- renderer. No page may contain more than two visible rows, and long rows
    -- are conservatively wrapped at 18 characters. Every resulting two-line
    -- page is separated with Crystal's native wait-for-input form feed.
    local clean = {}
    for _, page in ipairs(pages or {}) do
      if page and page ~= "" then
        for source in (tostring(page) .. "\f"):gmatch("(.-)\f") do
          if source ~= "" then
            for _, normalized in ipairs(paginateTwoLineText(source)) do
              clean[#clean + 1] = normalized
            end
          end
        end
      end
    end
    if #clean == 0 then
      if onDone then onDone() end
      return
    end
    ow:showText(table.concat(clean, "\f"), onDone, stay or false)
  end

  playNamed = function(ow, name, fallback)
    if ow.playSfxNamed then
      pcall(ow.playSfxNamed, ow, name, fallback)
    elseif ow.playSfx and fallback then
      pcall(ow.playSfx, ow, fallback)
    end
  end

  -- Tool feedback must not be discarded by Crystal's overworld SFX priority
  -- gate when the WARDEN menu click is still sounding. The stereo path uses
  -- the same named Gen 2 effect but deliberately bypasses that gate.
  mod._wardenPlayToolSfx = function(ow,name,fallback)
    local data=ow and ow.game and ow.game.data
    if data and Sound and Sound.playStereo then
      local ok,src=pcall(Sound.playStereo,data,name)
      if ok and src then return true end
    end
    -- Headless and older-engine fallback.
    playNamed(ow,name,fallback)
    return false
  end

  -- The Spirit Band and Spirit Seal are standard issue. Optional tools unlock
  -- permanently as Ezra promotes the player through the Warden ranks.
  mod._wardenToolList = {"CANDLE","INCENSE","WRITING BOOK","BINDING ASH","WARDING CHARM",
    "POWERLIGHT","THERMOMETER","SILPH SENSOR","UV LIGHT"}
  mod._wardenToolRequiredPoints = {
    ["CANDLE"]=0,["INCENSE"]=0,["WRITING BOOK"]=0,
    ["BINDING ASH"]=15,["WARDING CHARM"]=15,
    ["POWERLIGHT"]=30,["THERMOMETER"]=30,
    ["SILPH SENSOR"]=50,["UV LIGHT"]=50,
  }
  mod._wardenAvailableTools = function(points)
    local available={}
    points=tonumber(points) or wardenRankPoints()
    for _,name in ipairs(mod._wardenToolList) do
      if points>=(mod._wardenToolRequiredPoints[name] or 0) then
        available[#available+1]=name
      end
    end
    return available
  end

  -- DEV9s: loadout picker descriptions live in a second panel beneath the
  -- normal Crystal script menu.  The ScriptMenu patch is opt-in: only headers
  -- carrying wardenDescriptions get the extra panel, so every vanilla menu is
  -- drawn exactly as before.
  mod._wardenToolDescriptions = {
    ["CANDLE"] = "Widens your view.\nCan be put out.",
    ["POWERLIGHT"] = "40% wider light\nthan a CANDLE.",
    ["THERMOMETER"] = "Checks for sudden\ntemperature drops.",
    ["INCENSE"] = "Lowers activity.\nOne use per case.",
    ["WARDING CHARM"] = "Blocks one\nTERRIFAINT.",
    ["SILPH SENSOR"] = "Tracks the spirit.\nAnchors after 3/3.",
    ["BINDING ASH"] = "Slows a spirit.\nScatter on floor.",
    ["WRITING BOOK"] = "Spirit may write\na bonus clue.",
    ["UV LIGHT"] = "Green scan may\nreveal the spirit.",
  }
  mod._wardenScriptMenuClass = require("src.ui.gen2.ScriptMenu")
  if not mod._wardenScriptMenuClass._wardenToolDescPatched then
    mod._wardenScriptMenuClass._wardenToolDescPatched = true
    mod._wardenScriptMenuClass._wardenVanillaDraw = mod._wardenScriptMenuClass.draw
    mod._wardenScriptMenuClass.draw = function(self)
      local header = self.header
      local descriptions = header and header.wardenDescriptions
      local box = header and header.wardenDescriptionBox
      local Chrome = require("src.ui.gen2.Chrome")

      if header and header.wardenScrollWindow then
        -- The loadout list deliberately uses a shorter, five-row viewport so
        -- the description panel can be a full Crystal-sized textbox. Keep the
        -- menu's REAL row/index intact and only window what gets drawn.
        self:drawBalance()
        local left, top = header.left or 0, header.top or 0
        local right, bottom = header.right or 19, header.bottom or 11
        Chrome.box(left, top, right-left+1, bottom-top+1)

        local visible = math.max(1, tonumber(header.wardenScrollWindow) or 5)
        local total = #self.items
        local selected = math.max(1, math.min(total, self.row or 1))
        local first = tonumber(header.wardenScrollOffset) or 1
        if selected < first then first = selected end
        if selected > first + visible - 1 then first = selected - visible + 1 end
        first = math.max(1, math.min(first, math.max(1, total-visible+1)))
        header.wardenScrollOffset = first

        for slot=1,visible do
          local index = first + slot - 1
          if index <= total then
            Chrome.print(tostring(self.items[index] or ""), self.textX, self.textY + (slot-1)*2)
          end
        end
        if self.showCursor then
          local slot = selected - first + 1
          Chrome.cursor(self.textX - 1, self.textY + (slot-1)*2)
        end
        -- Match Crystal's own scrolling-list affordance: a black pixel ▼ in
        -- the lower-right of the menu when more choices are below.
        if first + visible - 1 < total then
          local Font = require("src.render.Font")
          love.graphics.setColor(0,0,0,1)
          -- Sit four pixels below the fifth label instead of sharing its text
          -- baseline (where it covered the end of WARDING CHARM).
          Font.drawCode(Chrome.DOWN_ARROW, (right-1)*8, (bottom-1)*8+4)
        end
      else
        getmetatable(self)._wardenVanillaDraw(self)
      end

      if type(descriptions) ~= "table" or type(box) ~= "table" then return end
      local index = (self.row - 1) * (self.cols or 1) + self.col
      local text = tostring(descriptions[index] or "")
      local left, top = box.left or 0, box.top or 12
      local right, bottom = box.right or 19, box.bottom or 17
      Chrome.box(left, top, right-left+1, bottom-top+1)
      -- Match Crystal's normal two-line textbox placement: a 6-row box at
      -- y=12 prints its text at rows 14 and 16 (two tile rows apart).  The
      -- previous DEV9u panel used rows 13/14, which made the description look
      -- cramped against the top border instead of like vanilla dialogue.
      local y = top + 2
      for line in (text .. "\n"):gmatch("(.-)\n") do
        if y >= bottom then break end
        Chrome.print(line, left + 1, y)
        y = y + 2
      end
      love.graphics.setColor(1,1,1,1)
    end
  end
  -- Separate patch flag matters when upgrading a build without restarting the
  -- recomp process: DEV9s may already have installed the draw patch above.
  if not mod._wardenScriptMenuClass._wardenToolConfirmPatched then
    mod._wardenScriptMenuClass._wardenToolConfirmPatched = true
    mod._wardenScriptMenuClass._wardenVanillaUpdate = mod._wardenScriptMenuClass.update
    -- Warden loadout menus need to remain visible underneath their YES/NO
    -- prompts. The vanilla ScriptMenu finishes (and World pops it) as soon as
    -- A is pressed, so opt-in menus intercept A and decide when to finish.
    mod._wardenScriptMenuClass.update = function(self, dt)
      local activate = self.header and self.header.wardenOnActivate
      local input = self.game and self.game.input
      if type(activate)=="function" and input and input:wasPressed("a") then
        self:playSfx("Sfx_ReadText2")
        local index = (self.row - 1) * (self.cols or 1) + self.col
        activate(index, self)
        return
      end
      return getmetatable(self)._wardenVanillaUpdate(self, dt)
    end
  end

  mod._wardenHasTool = function(name)
    return mod.save:get("warden_tool_1")==name or mod.save:get("warden_tool_2")==name
      or mod.save:get("warden_tool_3")==name
  end

  mod._wardenUseCandle = function(ow)
    if not mod._wardenHasTool("CANDLE") then
      showPaged(ow,{"You didn't pack\nthe CANDLE."})
      return
    end
    if mod.save:get("enraged_candle_locked")==true then
      mod.save:set("dev_candle",false)
      showPaged(ow,{"The CANDLE won't\nlight. RUN!"})
      return
    end
    local on=mod.save:get("dev_candle")==true
    mod.save:set("dev_candle",not on)
    if not on then mod.save:set("dev_powerlight",false) end
    playNamed(ow,on and "Sfx_Burn" or "Sfx_Ember",1)
    showPaged(ow,{on and "CANDLE put out.\nVision reduced." or "CANDLE lit.\nVision increased."})
  end

  mod._wardenUsePowerlight = function(ow)
    if not mod._wardenHasTool("POWERLIGHT") then
      showPaged(ow,{"You didn't pack the\nPOWERLIGHT."})
      return
    end
    if mod.save:get("enraged_candle_locked")==true then
      mod.save:set("dev_powerlight",false)
      showPaged(ow,{"The POWERLIGHT\nwon't start. RUN!"})
      return
    end
    local on=mod.save:get("dev_powerlight")==true
    mod.save:set("dev_powerlight",not on)
    if not on then mod.save:set("dev_candle",false) end
    playNamed(ow,on and "Sfx_ShutDownPc" or "Sfx_Flash",1)
    showPaged(ow,{on and "POWERLIGHT off.\nVision reduced." or "POWERLIGHT on.\nWide beam active."})
  end

  mod._wardenUseThermometer = function(ow)
    if not mod._wardenHasTool("THERMOMETER") then
      showPaged(ow,{"You didn't pack\nthe THERMOMETER."})
      return
    end
    local gx,gy,gmap=ghostPos()
    local temp=61+math.random(-2,2)
    local msg="No sharp change."
    if ghostPresent() and ow and ow.map and gmap==ow.map.id and gx and gy and ow.player then
      local d=math.abs(gx-ow.player.cellX)+math.abs(gy-ow.player.cellY)
      if d<=2 then temp=36+math.random(0,4); msg="A sudden drop."
      elseif d<=5 then temp=44+math.random(0,5); msg="It's colder here."
      elseif d<=8 then temp=52+math.random(0,4); msg="Slightly colder." end
    end
    playNamed(ow,"Sfx_TwoPcBeeps",1)
    showPaged(ow,{string.format("TEMP: %d F",temp),msg})
  end

  mod._wardenUseIncense = function(ow)
    if not mod._wardenHasTool("INCENSE") then
      showPaged(ow,{"You didn't pack\nthe INCENSE."})
      return
    end
    if mod.save:get("warden_incense_used")==true then
      showPaged(ow,{"The INCENSE is\nused up."})
      return
    end
    mod.save:set("warden_incense_used",true)
    mod.save:set("haunt_activity",math.max(0,(tonumber(mod.save:get("haunt_activity")) or 0)-20))
    local old=MANIFEST_SFX.__GENERIC
    MANIFEST_SFX.__GENERIC={"Sfx_HealBell","Sfx_SweetKiss","Sfx_Shine","Sfx_Powder"}
    playManifestSfx(ow,"__GENERIC")
    MANIFEST_SFX.__GENERIC=old
    showPaged(ow,{"The INCENSE burns.\nThe room settles."})
  end

  mod._wardenUseCharm = function(ow)
    if not mod._wardenHasTool("WARDING CHARM") then
      showPaged(ow,{"You didn't pack\nthe WARDING CHARM."})
      return
    end
    if mod.save:get("warden_charm_used")==true then
      showPaged(ow,{"The broken CHARM\nhangs uselessly."})
    else
      showPaged(ow,{"The WARDING CHARM\nis still intact.","It may block one\nTERRIFAINT."})
    end
  end

  mod._wardenSensorReading = function(ow)
    if not (ow and ow.map and ow.player) then return 0,"NONE",99 end
    local clues=tonumber(mod.save:get("case_clues")) or 0
    if clues<3 then
      local d=ghostDistanceFrom(ow,ow.player.cellX,ow.player.cellY)
      if not d then return 0,"SPIRIT",99 end
      local level=d<=1 and 5 or (d<=3 and 4 or (d<=6 and 3 or (d<=10 and 2 or 1)))
      return level,"SPIRIT",d
    end
    local delta=({up={0,-1},down={0,1},left={-1,0},right={1,0}})[ow.player.facing or "down"] or {0,1}
    local fx,fy=ow.player.cellX+delta[1],ow.player.cellY+delta[2]
    local amap=mod.save:get("case_anchor_map")
    local ax,ay=tonumber(mod.save:get("case_anchor_x")),tonumber(mod.save:get("case_anchor_y"))
    if amap~=ow.map.id or not ax or not ay then return 0,"ANCHOR",99,fx,fy end
    local d=manhattan(fx,fy,ax,ay)
    local level=d==0 and 5 or (d<=2 and 4 or (d<=5 and 2 or 1))
    return level,"ANCHOR",d,fx,fy
  end

  mod._wardenPlaySensorBeeps = function(ow,count,onDone)
    count=math.max(0,math.floor(tonumber(count) or 0))
    if count==0 then if onDone then onDone() end; return end
    local stack=ow and ow.game and ow.game.stack
    if not (stack and stack.push and stack.pop) then
      for _=1,count do mod._wardenPlayToolSfx(ow,"Sfx_ChoosePcOption",1) end
      if onDone then onDone() end
      return
    end
    -- The WARDEN menu has just played its A-button click. Delaying the first
    -- meter tone keeps that click from swallowing the Sensor's audio channel.
    local state={isOpaque=false,time=0,played=0,done=false}
    function state:update(dt)
      self.time=self.time+(tonumber(dt) or 0)
      while self.played<count and self.time>=.22+self.played*.20 do
        self.played=self.played+1
        mod._wardenPlayToolSfx(ow,"Sfx_ChoosePcOption",1)
      end
      if self.played>=count and self.time>=.22+(count-1)*.20+.12 and not self.done then
        self.done=true; stack:pop()
        if onDone then onDone() end
      end
    end
    function state:draw() end
    stack:push(state)
  end

  mod._wardenUseSilphSensor = function(ow)
    if not mod._wardenHasTool("SILPH SENSOR") then
      showPaged(ow,{"You didn't pack the\nSILPH SENSOR."})
      return
    end
    local level,mode,_,fx,fy=mod._wardenSensorReading(ow)
    local pages={"SILPH SENSOR",string.format("SIGNAL LEVEL: %d/5",level)}
    if mode=="SPIRIT" then
      if level==0 then pages[#pages+1]="No spirit signal\non this floor."
      elseif level<=2 then pages[#pages+1]="A faint signal."
      elseif level<=4 then pages[#pages+1]="The spirit is\nnearby."
      else pages[#pages+1]="The meter chatters!\nIt is very close." end
    else
      if level==0 then pages[#pages+1]="No bound resonance\non this floor."
      elseif level<=2 then pages[#pages+1]="A faint resonance."
      elseif level==4 then pages[#pages+1]="The signal is\nstrong."
      else pages[#pages+1]="The meter is\ngoing wild!" end

      -- Ordinary sweeps cost nothing. A new strong probe of the attachment
      -- provokes it, but reopening the menu on one cell cannot farm activity.
      if level>=4 then
        local key=tostring(ow.map.id)..":"..tostring(fx)..","..tostring(fy)
        local step=tonumber(mod.save:get("case_steps")) or 0
        local lastStep=tonumber(mod.save:get("sensor_last_hot_step")) or -999
        if mod.save:get("sensor_last_hot_cell")~=key or step-lastStep>=8 then
          mod.save:set("sensor_last_hot_cell",key)
          mod.save:set("sensor_last_hot_step",step)
          addActivity(level==5 and math.random(2,4) or 1)
        end
      end
    end
    local beeps=level==5 and 3 or (level>=3 and 1 or 0)
    mod._wardenPlaySensorBeeps(ow,beeps,function() showPaged(ow,pages) end)
  end

  -- Angler's Cove resolves its native logbook fallback to SPRITE_POKEDEX in
  -- Crystal. Reuse that same game sprite here instead of SPRITE_PAPER.
  mod._wardenBookSprite="SPRITE_POKEDEX"

  -- These are floor marks rather than standing actors. World:drawPeople sorts
  -- by pixel Y, so sort them one pixel earlier and compensate at draw time.
  -- They remain visually on the same tile but the player is layered above.
  mod._wardenGroundLayerNpc = function(npc)
    if not npc then return end
    npc.py=(tonumber(npc.cellY) or 0)*16-1
    npc.spriteYOffset=1
    npc.passable=true
  end

  mod._wardenClearBookVisual = function()
    local ids,seen={},{}
    if mod._wardenBookNpcId then ids[#ids+1]=mod._wardenBookNpcId; seen[mod._wardenBookNpcId]=true end
    local ow=mod.world:overworld()
    for _,npc in ipairs(ow and ow.npcs or {}) do
      if npc.def and npc.def.name=="WARDEN_WRITING_BOOK" and not seen[npc.id] then
        ids[#ids+1]=npc.id; seen[npc.id]=true
      end
    end
    for _,id in ipairs(ids) do pcall(mod.world.removeNpc,mod.world,id) end
    mod._wardenBookNpcId=nil
  end

  mod._wardenEnsureBookVisual = function(ow)
    if not (ow and ow.map and mod.save:get("warden_book_placed")==true
      and mod.save:get("warden_book_map")==ow.map.id) then return false end
    local bx,by=tonumber(mod.save:get("warden_book_x")),tonumber(mod.save:get("warden_book_y"))
    if not bx or not by then return false end
    -- Adopt an existing live copy after floor re-entry. This prevents the old
    -- implementation from stacking duplicates and leaving one behind at pickup.
    for _,npc in ipairs(ow.npcs or {}) do
      if npc.def and npc.def.name=="WARDEN_WRITING_BOOK" then
        if npc.cellX==bx and npc.cellY==by then
          mod._wardenGroundLayerNpc(npc); mod._wardenBookNpcId=npc.id; return true
        else
          pcall(mod.world.removeNpc,mod.world,npc.id)
        end
      end
    end
    mod._wardenBookNpcId=nil
    local id,err=mod.world:spawnNpc(ow.map.id,{
      name="WARDEN_WRITING_BOOK",x=bx,y=by,
      sprite=mod._wardenBookSprite,movement="STAY",range="DOWN",
    })
    if not id then
      mod.log:warn("Could not place Writing Book sprite: "..tostring(err))
      return false
    end
    mod._wardenBookNpcId=type(id)=="string" and id or (type(id)=="table" and (id.id or (id.npc and id.npc.id)))
    for _,npc in ipairs(ow.npcs or {}) do
      if npc.id==mod._wardenBookNpcId or (npc.def and npc.def.name=="WARDEN_WRITING_BOOK") then
        mod._wardenGroundLayerNpc(npc); mod._wardenBookNpcId=npc.id
      end
    end
    return true
  end

  mod._wardenClearAshVisual = function()
    local ids,seen={},{}
    if mod._wardenAshNpcId then ids[#ids+1]=mod._wardenAshNpcId; seen[mod._wardenAshNpcId]=true end
    local ow=mod.world:overworld()
    for _,npc in ipairs(ow and ow.npcs or {}) do
      if npc.def and npc.def.name=="WARDEN_BINDING_ASH_FLOOR" and not seen[npc.id] then
        ids[#ids+1]=npc.id; seen[npc.id]=true
      end
    end
    for _,id in ipairs(ids) do pcall(mod.world.removeNpc,mod.world,id) end
    mod._wardenAshNpcId=nil
  end

  mod._wardenEnsureAshVisual = function(ow,replace)
    local visible=mod.save:get("warden_ash_active")==true or mod.save:get("warden_ash_footprint")==true
    if not (visible and ow and ow.map and mod.save:get("warden_ash_map")==ow.map.id) then return false end
    local ax,ay=tonumber(mod.save:get("warden_ash_x")),tonumber(mod.save:get("warden_ash_y"))
    if not ax or not ay then return false end
    local sprite=mod.save:get("warden_ash_footprint")==true
      and "WARDEN_BINDING_ASH_STEPPED" or "WARDEN_BINDING_ASH"
    if replace then mod._wardenClearAshVisual() end
    for _,npc in ipairs(ow.npcs or {}) do
      if npc.def and npc.def.name=="WARDEN_BINDING_ASH_FLOOR" then
        if npc.cellX==ax and npc.cellY==ay and npc.def.sprite==sprite then
          mod._wardenGroundLayerNpc(npc); mod._wardenAshNpcId=npc.id; return true
        end
        pcall(mod.world.removeNpc,mod.world,npc.id)
      end
    end
    local id,err=mod.world:spawnNpc(ow.map.id,{
      name="WARDEN_BINDING_ASH_FLOOR",x=ax,y=ay,
      sprite=sprite,movement="STAY",range="DOWN",
    })
    if not id then
      mod.log:warn("Could not place Binding Ash sprite: "..tostring(err))
      return false
    end
    mod._wardenAshNpcId=type(id)=="string" and id or (type(id)=="table" and (id.id or (id.npc and id.npc.id)))
    for _,npc in ipairs(ow.npcs or {}) do
      if npc.id==mod._wardenAshNpcId or (npc.def and npc.def.name=="WARDEN_BINDING_ASH_FLOOR") then
        mod._wardenGroundLayerNpc(npc); mod._wardenAshNpcId=npc.id
      end
    end
    return true
  end

  mod._wardenClearPlacedTools = function()
    mod._wardenClearBookVisual()
    mod._wardenClearAshVisual()
    for _,key in ipairs({"warden_book_placed","warden_book_map","warden_book_x","warden_book_y",
      "warden_book_written","warden_book_text","warden_book_placed_step","warden_book_next_roll","warden_ash_active",
      "warden_ash_spent","warden_ash_footprint","warden_ash_map","warden_ash_x","warden_ash_y"}) do
      mod.save:set(key,nil)
    end
    mod._wardenAshSlowUntil=0
  end

  mod._wardenUseBindingAsh = function(ow)
    if not mod._wardenHasTool("BINDING ASH") then
      showPaged(ow,{"You didn't pack the\nBINDING ASH."})
      return
    end
    if mod.save:get("warden_ash_spent")==true then
      showPaged(ow,{"The BINDING ASH\nwas already used."})
      return
    end
    if mod.save:get("warden_ash_active")==true then
      showPaged(ow,{"The ASH is already\nspread on this floor."})
      return
    end
    if not (ow and ow.map and ow.player) then return end
    if (ow.map.isWarp and ow.map:isWarp(ow.player.cellX,ow.player.cellY))
      or (ow.map.isWarpTileCell and ow.map:isWarpTileCell(ow.player.cellX,ow.player.cellY)) then
      showPaged(ow,{"Don't scatter it\non the stairs."})
      return
    end
    showPaged(ow,{"Scatter BINDING\nASH here?"},function()
      ow:askYesNo(function(yes)
        if not yes then return end
        mod.save:set("warden_ash_active",true)
        mod.save:set("warden_ash_map",ow.map.id)
        mod.save:set("warden_ash_x",ow.player.cellX)
        mod.save:set("warden_ash_y",ow.player.cellY)
        mod.save:set("warden_ash_footprint",false)
        mod._wardenEnsureAshVisual(ow,true)
        playNamed(ow,"Sfx_Powder",1)
        showPaged(ow,{"You spread a thin\nring of ash."})
      end)
    end,true)
  end

  mod._wardenUseWritingBook = function(ow)
    if not mod._wardenHasTool("WRITING BOOK") then
      showPaged(ow,{"You didn't pack the\nWRITING BOOK."})
      return
    end
    if mod.save:get("warden_book_placed")==true then
      local floor=tostring(mod.save:get("warden_book_map") or "TOWER"):gsub("WARDEN_RADIO_TOWER_","")
      showPaged(ow,{"The BOOK is still\non "..floor..".","Inspect it there\nto take it back."})
      return
    end
    if mod.save:get("warden_book_written")==true then
      showPaged(ow,{"The marked page\nreads:","..."..tostring(mod.save:get("warden_book_text") or "WATCH").."...",
        "It won't take more\nwriting this case."})
      return
    end
    if not (ow and ow.map and ow.player) then return end
    if (ow.map.isWarp and ow.map:isWarp(ow.player.cellX,ow.player.cellY))
      or (ow.map.isWarpTileCell and ow.map:isWarpTileCell(ow.player.cellX,ow.player.cellY)) then
      showPaged(ow,{"Don't leave it on\nthe stairs."})
      return
    end
    showPaged(ow,{"Leave the WRITING\nBOOK here?"},function()
      ow:askYesNo(function(yes)
        if not yes then return end
        mod.save:set("warden_book_placed",true)
        mod.save:set("warden_book_map",ow.map.id)
        mod.save:set("warden_book_x",ow.player.cellX)
        mod.save:set("warden_book_y",ow.player.cellY)
        mod.save:set("warden_book_written",false)
        mod.save:set("warden_book_text",nil)
        mod.save:set("warden_book_placed_step",tonumber(mod.save:get("case_steps")) or 0)
        mod.save:set("warden_book_next_roll",(tonumber(mod.save:get("case_steps")) or 0)+12)
        mod._wardenEnsureBookVisual(ow)
        showPaged(ow,{"You leave the BOOK\nopen on the floor.","Check it after the\nspirit passes by."})
      end)
    end,true)
  end

  mod._wardenUseUvLight = function(ow)
    if not mod._wardenHasTool("UV LIGHT") then
      showPaged(ow,{"You didn't pack the\nUV LIGHT."})
      return
    end
    local now=love.timer and love.timer.getTime and love.timer.getTime() or 0
    if now<(tonumber(mod._wardenUvUntil) or 0) then
      showPaged(ow,{"The UV LIGHT is\nalready sweeping."})
      return
    end
    if now<(tonumber(mod._wardenUvNextUse) or 0) then
      showPaged(ow,{"The UV LIGHT needs\na moment to cool."})
      return
    end
    mod._wardenUvUntil=now+8
    mod._wardenUvNextUse=now+14
    mod._wardenUvNextFlash=now+0.35
    mod._wardenUvFlashUntil=0
    mod._wardenUvFlashCount=0
    -- A distinct electronic startup cue; unlike the short menu click it is
    -- audible while the green sweep begins immediately.
    mod._wardenPlayToolSfx(ow,"Sfx_BootPc",1)
    -- No textbox here: the full eight-second sweep should be spent watching
    -- the room, not dismissing a message while its real-time timer runs down.
  end

  mod._wardenUpdateUv = function(ow,now)
    now=tonumber(now) or (love.timer and love.timer.getTime and love.timer.getTime() or 0)
    if now>=(tonumber(mod._wardenUvUntil) or 0)
      or now<(tonumber(mod._wardenUvNextFlash) or 0)
      or (tonumber(mod._wardenUvFlashCount) or 0)>=2 then return false end
    local gx,gy,gmap=ghostPos()
    if not (ghostPresent() and gx and gy and ow and ow.map and gmap==ow.map.id) then
      mod._wardenUvNextFlash=now+0.8
      return false
    end
    local count=tonumber(mod._wardenUvFlashCount) or 0
    local chance=math.min(85,40+math.floor(activity()/2))
    -- Same-floor activation guarantees one useful reveal. A second flash is
    -- possible but not guaranteed, keeping repeated pulses eerie instead of noisy.
    if count==0 or math.random(100)<=chance then
      mod._wardenUvFlashUntil=now+0.24
      mod._wardenUvFlashCount=count+1
      playNamed(ow,"Sfx_Shine",1)
    end
    mod._wardenUvNextFlash=now+1.4+math.random()*1.5
    return now<(tonumber(mod._wardenUvFlashUntil) or 0)
  end

  mod._wardenCheckPlacedTools = function(ow)
    if not (ow and ow.map and ow.player) then return false end
    mod._wardenEnsureBookVisual(ow)
    mod._wardenEnsureAshVisual(ow)
    local gx,gy,gmap=ghostPos()
    local present=ghostPresent() and gx and gy and gmap
    local ghostFloor=present and gmap or mod.save:get("ghost_target_map")
    local did=false
    if present and gmap==ow.map.id and mod.save:get("warden_ash_active")==true
      and mod.save:get("warden_ash_map")==ow.map.id then
      local ax,ay=tonumber(mod.save:get("warden_ash_x")),tonumber(mod.save:get("warden_ash_y"))
      if ax and ay and manhattan(gx,gy,ax,ay)<=3 then
        mod.save:set("warden_ash_active",false)
        mod.save:set("warden_ash_spent",true)
        mod.save:set("warden_ash_footprint",true)
        local now=love.timer and love.timer.getTime and love.timer.getTime() or 0
        mod._wardenAshSlowUntil=now+math.random(20,30)
        mod._wardenEnsureAshVisual(ow,true)
        playNamed(ow,"Sfx_Powder",1)
        showPaged(ow,{"A black footprint\npresses into ASH!","The spirit's steps\ndrag and slow."})
        did=true
      end
    end
    if mod.save:get("warden_book_placed")==true and mod.save:get("warden_book_written")~=true then
      local bookMap=mod.save:get("warden_book_map")
      local steps=tonumber(mod.save:get("case_steps")) or 0
      local nextRoll=tonumber(mod.save:get("warden_book_next_roll"))
        or ((tonumber(mod.save:get("warden_book_placed_step")) or steps)+12)
      if bookMap and ghostFloor==bookMap and steps>=nextRoll then
        if mod._wardenTryFollowup then
          mod.save:set("warden_book_next_roll",steps+math.random(10,16))
          -- Proximity no longer guarantees evidence. Every eligible pass is a
          -- flat 30%, so some cases genuinely end with a blank Book.
          if math.random(100)<=30 then
            -- Resolve directional writing from the Book's floor even when the
            -- player is elsewhere in the tower.
            local clueWorld={map={id=bookMap}}
            local _,_,clue=mod._wardenTryFollowup(clueWorld,"BOOK","WRITING_BOOK",100)
            if clue then
              mod.save:set("warden_book_written",true)
              mod.save:set("warden_book_text",clue)
              if ow.map.id==bookMap then playNamed(ow,"Sfx_Scratch",1) end
              -- The spirit sometimes withdraws after making contact with the
              -- Book. Use normal relocation so the destination is a different
              -- floor and its eventual spawn uses the established safe cells.
              if math.random(100)<=40 then scheduleFloorRelocation(bookMap) end
              did=true
            end
          end
        end
      end
    end
    return did
  end

  mod._wardenPlacedToolPress = function(ow)
    if not (ow and ow.map and ow.player) then return false end
    local delta=({up={0,-1},down={0,1},left={-1,0},right={1,0}})[ow.player.facing or "down"] or {0,1}
    local fx,fy=ow.player.cellX+delta[1],ow.player.cellY+delta[2]
    if mod.save:get("warden_book_placed")==true and mod.save:get("warden_book_map")==ow.map.id
      and tonumber(mod.save:get("warden_book_x"))==fx and tonumber(mod.save:get("warden_book_y"))==fy then
      local pages
      if mod.save:get("warden_book_written")==true then
        pages={"Something has\nwritten on page:","..."..tostring(mod.save:get("warden_book_text") or "WATCH").."..."}
      else pages={"The pages are\nstill blank.","The spirit hasn't\nreached it yet."} end
      pages[#pages+1]="Take the BOOK back?"
      showPaged(ow,pages,function()
        ow:askYesNo(function(yes)
          if not yes then return end
          mod.save:set("warden_book_placed",false)
          mod._wardenClearBookVisual()
          showPaged(ow,{"WRITING BOOK\nrecovered."})
        end)
      end,true)
      return true
    end
    if mod.save:get("warden_ash_footprint")==true and mod.save:get("warden_ash_map")==ow.map.id
      and tonumber(mod.save:get("warden_ash_x"))==fx and tonumber(mod.save:get("warden_ash_y"))==fy then
      showPaged(ow,{"A long black print\ncuts through ash.","Whatever made it\nwas briefly slowed."})
      return true
    end
    return false
  end

  mod._wardenBeginCaseWithTools = function(ow,t1,t2,t3)
    mod.save:set("warden_tool_1",t1)
    mod.save:set("warden_tool_2",t2)
    mod.save:set("warden_tool_3",t3)
    mod.save:set("warden_incense_used",false)
    mod.save:set("warden_charm_used",false)
    mod.save:set("dev_candle",false)
    mod.save:set("dev_powerlight",false)
    mod._wardenClearPlacedTools()
    mod.save:set("sensor_last_hot_cell",nil)
    mod.save:set("sensor_last_hot_step",nil)
    mod.save:set("warden_case_rank_awarded",false)
    mod._wardenUvUntil=0; mod._wardenUvNextUse=0; mod._wardenUvFlashUntil=0
    setPendingCase(false)
    clearCaseReport()
    mod.save:set("warden_case_called",false)
    mod.save:set("haunt_resolved",false)
    mod.save:set("haunt_false_exit",false)
    resetCaseSimulation(true)
    mod.save:set("warden_case_official",true)
    mod.save:set("warden_case_recorded",false)
    mod.save:set("warden_case_resolution_pending",false)
    mod.save:set("warden_case_outcome",nil)
    mod.save:set("warden_case_result_species",nil)
    mod.save:set("warden_last_reward_tier",nil)
    showPaged(ow,{
      "EZRA: Tools packed.\nStay alert.",
      "The RADIO TOWER\nhas gone quiet.",
      "Find what binds it.\nSet the spirit free.",
      "Be careful in\nthere."
    },function()
      local ok,err=mod.world:warpTo(HAUNTED_MAP,3,7,"down")
      if not ok then mod.log:warn("Warden case warp failed: "..tostring(err)) end
    end)
  end

  mod._wardenChooseTools = function(ow)
    -- Keep one live ScriptMenu on screen for the entire loadout session.  Tool
    -- confirmations stack their question/YES-NO box over this menu instead of
    -- closing it, so the list and description panel stay visible underneath.
    local chosen = {}
    local toolList=mod._wardenAvailableTools()
    local slots=mod._wardenToolSlots()
    local slotWord=slots==3 and "three" or "two"
    local function chosenCount()
      local n=0
      for _,name in ipairs(toolList) do if chosen[name] then n=n+1 end end
      return n
    end
    local function refreshPicker(menu)
      if not (menu and menu.header) then return end
      for i,name in ipairs(toolList) do
        menu.header.items[i] = (chosen[name] and "[X] " or "[ ] ") .. name
      end
      local readyIndex=#toolList+1
      menu.header.wardenDescriptions[readyIndex] = chosenCount()==slots
        and "Ready to begin.\nUse chosen tools."
        or ("Choose exactly "..slotWord.."\ntools to continue.")
      -- ScriptMenu.layout keeps self.items pointed at header.items for vertical
      -- menus, but assign it too so this stays correct if that ever changes.
      menu.items=menu.header.items
    end
    local function questionOverMenu(menu, body, onAnswer)
      -- stay=true leaves the question box standing so askYesNo can place the
      -- native choice box above it while the Warden menu remains underneath.
      ow:showText(body,function()
        ow:askYesNo(function(yes)
          if onAnswer then onAnswer(yes) end
          refreshPicker(menu)
        end)
      end,true)
    end
    local function openPicker()
      local items, descriptions = {}, {}
      for _,name in ipairs(toolList) do
        items[#items+1] = (chosen[name] and "[X] " or "[ ] ") .. name
        descriptions[#descriptions+1] = mod._wardenToolDescriptions[name] or ""
      end
      items[#items+1] = "READY"
      descriptions[#descriptions+1] = "Choose exactly "..slotWord.."\ntools to continue."
      items[#items+1] = "CANCEL"
      descriptions[#descriptions+1] = "Leave tool setup.\nCase stays open."

      local header={
        items=items,
        left=0,top=0,right=19,bottom=11,dataFlags=0x80,cursor=1,
        wardenDescriptions=descriptions,
        wardenDescriptionBox={left=0,top=12,right=19,bottom=17},
        wardenScrollWindow=5,
        wardenScrollOffset=1,
      }
      header.wardenOnActivate=function(choice, menu)
        local cancelIndex=#header.items
        local readyIndex=cancelIndex-1
        if choice==cancelIndex then
          menu:finish(0)
          return
        end
        if choice==readyIndex then
          if chosenCount()~=slots then
            ow:showText("Choose exactly "..slotWord.."\ntools first.")
            return
          end
          local packed={}
          for _,name in ipairs(toolList) do
            if chosen[name] then packed[#packed+1]=name end
          end
          questionOverMenu(menu,"Begin the case\nwith these tools?",function(yes)
            if not yes then return end
            -- Finish now, not when READY was first selected, so the loadout
            -- menu remains behind the confirmation prompt until YES is chosen.
            menu:finish(readyIndex)
            mod._wardenBeginCaseWithTools(ow,packed[1],packed[2],packed[3])
          end)
          return
        end

        local name=toolList[choice]
        if not name then return end
        local isChosen=chosen[name]==true
        if not isChosen and chosenCount()>=slots then
          ow:showText("You already chose\n"..slotWord.." tools.\fReturn one before\nchoosing another.")
          return
        end
        questionOverMenu(menu,(isChosen and "Return this tool?" or "Take this tool?").."\n"..name,function(yes)
          if not yes then return end
          -- Do not use `isChosen and nil or true` here: in Lua that always
          -- resolves to true because nil is falsey, which made RETURN a no-op.
          if isChosen then chosen[name]=nil else chosen[name]=true end
        end)
      end

      ow:openScriptMenu(header,"vertical",function(_) end)
    end

    showPaged(ow,{"Choose "..slotWord.." Warden\ntools to bring."},openPicker)
  end

  local function startPendingCase(ow)
    if not pendingCase() or not mod._wardenIsNight(ow) then
      showPaged(ow,{
        "No case is open\nright now.",
        "Cases are taken\nafter dark."
      })
      return
    end
    mod._wardenChooseTools(ow)
  end

  local openWardenMenu

  local function caseResolutionPending()
    return mod.save:get("warden_case_resolution_pending") == true
  end

  local function clearCaseResolution()
    mod.save:set("warden_case_resolution_pending",false)
    mod.save:set("warden_case_outcome",nil)
    mod.save:set("warden_case_result_species",nil)
    clearCaseReport()
  end

  local function finishOfficialCaseRecord(success)
    if mod.save:get("warden_case_recorded") == true then return end
    if success then mod.save:set("warden_cases_closed",wardenCasesClosed()+1)
    else mod.save:set("warden_cases_failed",wardenCasesFailed()+1) end
    mod.save:set("warden_case_recorded",true)
  end

  local function finishCaseIdentification(ow, guess)
    local actual=tostring(mod.save:get("warden_case_result_species") or caseSpecies() or "UNKNOWN")
    local outcome=tostring(mod.save:get("warden_case_outcome") or "ABANDONED")
    local cleansed=(outcome=="CLEANSED")
    local reported=wardenIdsReported()+1
    mod.save:set("warden_ids_reported",reported)
    local correct=(guess==actual)
    if correct then mod.save:set("warden_ids_correct",wardenIdsCorrect()+1) end
    mod.save:set("warden_last_species",actual)
    mod.save:set("warden_last_guess",tostring(guess or "NOT SURE"))

    -- A successful cleansing is the main career achievement (+3); correctly
    -- identifying the species adds +1 even after a failed investigation.
    local beforePoints=wardenRankPoints()
    local rankGain,totalPoints=mod._wardenAwardRankPoints(cleansed,correct)
    mod.save:set("warden_last_reward_tier",rankGain==1 and "1 RANK POINT"
      or (rankGain>1 and (tostring(rankGain).." RANK POINTS") or "NO RANK POINTS"))

    mod.save:set("warden_case_official",false)
    mod.save:set("case_state",cleansed and "COMPLETE" or "FAILED")
    clearCaseResolution()

    local pages
    if correct and cleansed then
      pages={
        "EZRA: That's the\nsame read I had.",
        "The cleanse and ID\nboth count.",
        "4 RANK POINTS\nearned.",
        "TOTAL: "..tostring(totalPoints)
      }
    elseif correct then
      pages={
        "EZRA: That's the\nsame read I had.",
        "You couldn't free\nit this time,",
        "but that ID is\nstill useful.",
        "1 RANK POINT\nearned.",
        "TOTAL: "..tostring(totalPoints)
      }
    elseif guess=="NOT SURE" then
      pages={
        "EZRA: That's fine.\nNo need to guess.",
        cleansed and "The cleanse earns\n3 RANK POINTS." or "No RANK POINTS\nthis time.",
        "TOTAL: "..tostring(totalPoints)
      }
    else
      pages={
        "EZRA: No... I don't\nthink that's right.",
        "Maybe next time.",
        cleansed and "The cleanse earns\n3 RANK POINTS." or "No RANK POINTS\nthis time.",
        "TOTAL: "..tostring(totalPoints)
      }
    end
    local oldRank=mod._wardenRankName(beforePoints)
    local newRank=mod._wardenRankName(totalPoints)
    if newRank~=oldRank then
      pages[#pages+1]="PROMOTED:\n"..newRank
      if beforePoints<15 and totalPoints>=15 then
        pages[#pages+1]="EZRA: SPECTOR SAGE\nsuits you."
        pages[#pages+1]="BINDING ASH and\nWARDING CHARM"
        pages[#pages+1]="are now available\nfor your cases."
      end
      if beforePoints<30 and totalPoints>=30 then
        pages[#pages+1]="POWERLIGHT and\nTHERMOMETER"
        pages[#pages+1]="are now available\nfor your cases."
        pages[#pages+1]="You may now bring\nthree Warden tools."
      end
      if beforePoints<50 and totalPoints>=50 then
        pages[#pages+1]="SILPH SENSOR and\nUV LIGHT"
        pages[#pages+1]="are now available.\nUse them wisely."
      end
    end
    showPaged(ow,pages)
  end

  local function openSpeciesResultMenu(ow)
    local REPORT_DECOYS={
      "GASTLY","MISDREAVUS","UNOWN","DROWZEE","HYPNO","CLEFAIRY",
      "DITTO","PORYGON2","NOCTOWL","MAROWAK","VOLTORB","NATU",
    }
    local function shuffleList(t)
      for i=#t,2,-1 do
        local j=math.random(i)
        t[i],t[j]=t[j],t[i]
      end
      return t
    end
    -- Twelve plausible answers per report: all six spirits currently used by
    -- cases plus six shuffled decoys.  A Crystal vertical script menu spaces
    -- rows two tiles apart, so show six Pokemon at a time rather than drawing
    -- a 12-item list off the bottom of the screen.
    local picks={"JIGGLYPUFF","MAGNEMITE","PORYGON","MURKROW","CUBONE","HAUNTER"}
    local decoys={}
    for i=1,#REPORT_DECOYS do decoys[i]=REPORT_DECOYS[i] end
    shuffleList(decoys)
    for i=1,6 do picks[#picks+1]=decoys[i] end
    shuffleList(picks)

    local function page(which)
      local first=which==1 and 1 or 7
      local items={}
      for i=first,first+5 do items[#items+1]=picks[i] end
      items[#items+1]=which==1 and "MORE..." or "BACK..."
      items[#items+1]="NOT SURE"
      ow:openScriptMenu({
        items=items,
        left=1, top=0, right=18, bottom=17, dataFlags=0x80, cursor=1,
      },"vertical",function(choice)
        if choice==0 or choice==8 then
          finishCaseIdentification(ow,"NOT SURE")
        elseif choice==7 then
          page(which==1 and 2 or 1)
        else
          finishCaseIdentification(ow,picks[first+choice-1] or "NOT SURE")
        end
      end)
    end
    page(1)
  end

  local function resolveReturnedCase(ow)
    if not caseResolutionPending() then return false end
    local outcome=tostring(mod.save:get("warden_case_outcome") or "ABANDONED")
    local cleansed=(outcome=="CLEANSED")
    -- Migrate old DEV records before this case increments the counters, then
    -- add the current case's points only after the species report is filed.
    wardenRankPoints()
    finishOfficialCaseRecord(cleansed)

    if cleansed then
      mod.save:set("warden_last_reward_tier","1 RANK POINT PENDING")
      showPaged(ow,{
        "EZRA: You did it.\nIt is gone.",
        "You released the\nspirit safely.",
        "The cleanse counts\ntoward your rank.",
        "One more thing.",
        "Which POKéMON was\nhaunting there?"
      },function() openSpeciesResultMenu(ow) end)
      return true
    end

    -- A failed case grants no automatic progress, but a truthful correct ID
    -- still earns one rank point for useful field information.
    mod.save:set("warden_last_reward_tier","ID POINT PENDING")
    if outcome=="WRONG_SEAL" then
      showPaged(ow,{
        "EZRA: I felt that\nflare from here.",
        "The SEAL hit the\nwrong anchor.",
        "Leaving was the\nright call.",
        "It wasn't freed\ntonight.",
        "But did you learn\nwhat it was?",
        "Which POKéMON was\nhaunting there?"
      },function() openSpeciesResultMenu(ow) end)
    elseif outcome=="TERRIFAINT" then
      showPaged(ow,{
        "EZRA: Easy. Sit\ndown a minute.",
        "Too many of your\nPOKéMON went down.",
        "You were pushed\npast your limit.",
        "But did you learn\nwhat it was?",
        "Which POKéMON was\nhaunting there?"
      },function() openSpeciesResultMenu(ow) end)
    else
      showPaged(ow,{
        "EZRA: You're back.\nYou made it out.",
        "The spirit wasn't\nreleased tonight.",
        "But did you learn\nwhat it was?",
        "Which POKéMON was\nhaunting there?"
      },function() openSpeciesResultMenu(ow) end)
    end
    return true
  end

  returnToEzraAfterCase = function(ow, outcome)
    local official=mod.save:get("warden_case_official") == true
    outcome=tostring(outcome or "ABANDONED")
    if official then
      mod.save:set("warden_case_resolution_pending",true)
      mod.save:set("warden_case_outcome",outcome)
      mod.save:set("warden_case_result_species",caseSpecies())
    else
      mod.save:set("warden_case_resolution_pending",false)
      mod.save:set("warden_case_outcome",nil)
      mod.save:set("warden_case_result_species",nil)
    end
    mod.save:set("haunt_resolved",true)
    mod.save:set("case_state",outcome=="CLEANSED" and "CLEANSED" or "FAILED")
    mod.save:set("ghost_present",false)
    mod.save:set("ghost_x",nil); mod.save:set("ghost_y",nil); mod.save:set("ghost_map",nil)
    mod.save:set("ghost_target_map",nil)
    mod.save:set("enraged_candle_locked",false)
    mod.save:set("dev_candle",false)
    mod.save:set("dev_powerlight",false)
    mod.save:set("warden_tool_1",nil)
    mod.save:set("warden_tool_2",nil)
    mod.save:set("warden_tool_3",nil)
    mod.save:set("warden_incense_used",false)
    mod.save:set("warden_charm_used",false)
    mod._wardenClearPlacedTools()
    mod._wardenUvUntil=0; mod._wardenUvFlashUntil=0; mod._wardenUvNextUse=0
    clearDevGhostVisual()
    clearSpiritFaints()
    if Pipelines and Pipelines.setLevel then pcall(Pipelines.setLevel,DARK_PIPELINE,0) end
    local party=ow and ow.game and ow.game.save and ow.game.save.party or {}
    for _,mon in ipairs(party) do
      if mon and mon.stats and mon.stats.hp then mon.hp=mon.stats.hp end
    end
    local ok,err=mod.world:warpTo("SOUL_HOUSE",5,3,"up")
    if not ok then mod.log:warn("Warden return warp failed: "..tostring(err)) end
    return ok
  end

  openWardenMenu = function(ow)
    local caseAvailable=pendingCase() and mod._wardenIsNight(ow)
    local firstItem=caseAvailable and "START CASE" or "NO OPEN CASE"
    local items={
      firstItem,
      "EXPLANATION",
      "WARDEN RANK",
      "CASE RECORDS",
      "TOOL GUIDE",
      "CANCEL",
    }
    ow:openScriptMenu({
      items=items,
      left=1, top=2, right=18, bottom=16,
      dataFlags=0x80, cursor=1,
    },"vertical",function(choice)
      if choice==1 then
        if caseAvailable then startPendingCase(ow)
        else
          showPaged(ow,{
            mod._wardenIsNight(ow) and "EZRA: Nothing has\ncome in tonight."
              or "EZRA: I only send\nWardens at night.",
            mod._wardenIsNight(ow) and "Keep your POKéGEAR\nclose."
              or "Come back after\ndark."
          })
        end
      elseif choice==2 then
        showPaged(ow,{
          "Hauntings usually\nhappen at night.",
          "If I hear of one,\nI'll call you.",
          "Come see me before\nyou take the case.",
          mod._wardenToolSlots()==3 and "Pick three Warden\ntools to bring." or "Pick two Warden\ntools to bring.",
          "Your goal is to\nfind what binds it",
          "Search the objects\nin the building.",
          "If something seems\nodd, investigate.",
          "Your SPIRIT BAND\ncan reveal more.",
          "Tune the station\non your POKéGEAR.",
          "When it's nearby,\nlisten closely.",
          "It may give clues\nto what binds it.",
          "Gather three clues\nbefore you decide.",
          "Once you're sure,\nuse SPIRIT SEAL.",
          "Use it on what\nyou think binds it",
          "If you're right,\nyou set it free.",
          "But be careful.\nA spirit can turn.",
          "Push it too far,\nand it may attack.",
          "A wrong SEAL can\nenrage it too.",
          "If that happens,\nget out if you can",
          "You can try again\nanother night.",
          "One last thing:\nwatch the spirit.",
          "Every spirit acts\ndifferently.",
          "Tell me what you\nthink it was.",
          "A correct ID earns\none RANK POINT.",
          "Take your time.\nObserve, then act."
        },function() openWardenMenu(ow) end)
      elseif choice==3 then
        local points=wardenRankPoints()
        local rank=mod._wardenRankName(points)
        local nextText=points<15 and "NEXT: 15 POINTS"
          or (points<30 and "NEXT: 30 POINTS"
          or (points<50 and "NEXT: 50 POINTS" or "HIGHEST RANK"))
        showPaged(ow,{"WARDEN RANK:\n"..rank,
          string.format("RANK POINTS: %d",points),nextText},function() openWardenMenu(ow) end)
      elseif choice==4 then
        showPaged(ow,{
          string.format("CLEANSED: %d",wardenCasesClosed()),
          string.format("FAILED: %d",wardenCasesFailed()),
          string.format("IDENTIFIED: %d/%d",wardenIdsCorrect(),wardenIdsReported())
        },function() openWardenMenu(ow) end)
      elseif choice==5 then
        showPaged(ow,{
          "TOOL GUIDE",
          mod._wardenToolSlots()==3 and "Choose exactly three\nfor each case."
            or "Choose exactly two\nfor each case.",
          "WARDEN TOOLS:",
          "CANDLE\nWidens your view.",
          "INCENSE\nLowers activity.",
          "WRITING BOOK\nFinds bonus clues.",
          "SPECTOR SAGE:",
          "BINDING ASH\nSlows the spirit.",
          "WARDING CHARM\nBlocks one attack.",
          "GHOST GURU:",
          "POWERLIGHT\n40% wider light.",
          "THERMOMETER\nTracks cold spots.",
          "May bring three\nWarden tools.",
          "ACE EXORCIST:",
          "SILPH SENSOR\nTracks signals.",
          "UV LIGHT\nReveals the room."
        },function() openWardenMenu(ow) end)
      end
    end)
  end

  local function talkWarden(ow)
    if isEnrolled() then
      addEzraPhoneContact(ow)
      local greeting
      if pendingCase() and mod._wardenIsNight(ow) then greeting="EZRA: Good timing.\nA case is open."
      else greeting="EZRA: What do you\nneed?" end
      showPaged(ow,{greeting},function() openWardenMenu(ow) end)
      return
    end

    showPaged(ow, {
      "EZRA: Most POKéMON\nrest peacefully.",
      "Some spirits stay\nbehind.",
      "I investigate the\nones that do not.",
      "Want to help?\nIt can get rough.",
    }, function()
      ow:showText("Become a SPIRIT\nWARDEN?", function()
        ow:askYesNo(function(yes)
          if not yes then
            showPaged(ow, {
              "I understand.\nCome back anytime."
            })
            return
          end

          setEnrolled()
          local added=addEzraPhoneContact(ow)

          ow:showText("Let me see your\nPOKéGEAR...", function()
            playNamed(ow, "Sfx_TwoPcBeeps")
            ow:showText("Hold still...\nTuning the RADIO.", function()
              playNamed(ow, "Sfx_ChoosePcOption")
              showPaged(ow, {
                "There. Your RADIO\nis tuned.",
                "SPIRIT BAND is\nnow active.",
                added and "I added my number\nto your POKéGEAR."
                  or "Keep my number\nhandy.",
                "If a case comes\nin after dark...",
                "I will call you.\nCome see me.",
              }, function()
                playNamed(ow, "Sfx_Item", 1)
                ow:showText("SPIRIT BAND\nunlocked!")
              end)
            end)
          end)
        end)
      end, true)
    end)
  end

  -- Native Pokegear contact behavior for Ezra. We use one unused Crystal phone
  -- slot for list/name integration, then provide the conversation ourselves so
  -- no retail bank-$41 phone script has to be replaced.
  if not Pokegear._wardenEzraCallPatched then
    Pokegear._wardenEzraCallPatched=true
    local vanillaCallContact=Pokegear.callContact
    Pokegear.callContact=function(self,id)
      if tonumber(id)~=EZRA_PHONE_ID or mod.save:get("warden_enrolled")~=true then
        return vanillaCallContact(self,id)
      end
      local context=self:phoneContext()
      if not Phone.mapHasService(context) then
        self.call={contact=id,kind="nosignal",text=self:phoneText("GearOutOfService")}
        return
      end
      local world=self.game and self.game.world
      if world then world:playSfxNamed("Sfx_Call",106) end
      local text
      if world and world.map and world.map.id==MAP_ID then
        text="EZRA: I'm right here.\nCome talk to me."
      elseif caseResolutionPending() then
        text="EZRA: Get back here.\nWe'll go over it."
      elseif mod.save:get("warden_case_official")==true then
        text="EZRA: Stay sharp.\nFinish the case."
      elseif pendingCase() then
        text="EZRA: A case came in.\nCome see me."
      else
        text="EZRA: Nothing open\nright now. Stay sharp."
      end
      self.call={contact=id,kind="warden_ezra",name="EZRA",text=text}
    end
  end

  local function ringEzraCaseCall(world)
    if not (world and world.showText) then return false end
    mod.save:set("warden_case_called",true)
    -- Two real phone-ring cues before the message. The text follows Crystal's
    -- caller rhythm but stays inside the mod's strict two-line paging rule.
    playNamed(world,"Sfx_Call",106)
    playNamed(world,"Sfx_Call",106)
    showPaged(world,{
      "RING! RING!\nEZRA:",
      "A case just came\nin for tonight.",
      "Come see me in\nLAVENDER.",
      "I will brief you\nwhen you get here."
    })
    return true
  end

  local function maybeEzraNightCall(world)
    if not (world and world.map and isEnrolled()) then return end
    addEzraPhoneContact(world)
    if world.map.id==MAP_ID or isHauntedMapId(world.map.id) then return end
    local state=tostring(mod.save:get("case_state") or "")
    if state=="ACTIVE" or state=="ENRAGED HUNT" then return end
    local hour=(world.hour and world:hour()) or 12
    local isNight=(hour>=18 or hour<4)
    if not isNight then
      -- An ignored nightly lead expires with daylight, and daylight rearms the
      -- next night so Ezra never becomes a constant spam caller.
      if mod.save:get("warden_case_pending")==true then
        mod.save:set("warden_case_pending",false)
        mod.save:set("warden_case_called",false)
      end
      mod.save:set("warden_night_roll_done",false)
      return
    end
    if caseResolutionPending() or mod.save:get("warden_case_official")==true or pendingCase() or mod.save:get("warden_night_roll_done")==true then return end
    local busy=false
    if world.busy then local ok,v=pcall(world.busy,world); busy=ok and v or false end
    if busy then return end
    mod.save:set("warden_night_roll_done",true)
    -- One modest opportunity per night. This is intentionally conservative;
    -- the DEV tool below exists so testing never depends on the roll.
    if math.random(100)<=38 then
      setPendingCase(true)
      ringEzraCaseCall(world)
    end
  end

  -- Rare unknown-number interruption, paced like PokeSurvive's unsettling
  -- calls but self-contained so Spirit Wardens also works standalone.
  mod._wardenTriggerOddCall = function(world,forced)
    if not (world and world.showText) then return false end
    if not forced and mod.save:get("case_odd_call_done")==true then return false end
    mod.save:set("case_odd_call_done",true)
    local anchorHints={
      plant="The soil was turned\nbefore you came.",
      microphone="That microphone\nis still live.",
      papers="Read the last page.\nIt knows your name.",
      equipment="The dead meters\nare watching you.",
      glass="Do not trust the\nstudio glass.",
      table="Someone is seated\nat that table.",
      cabinet="Leave the drawer\nclosed this time.",
      phone="That other phone\nis off the hook.",
      desk="Someone is seated\nat that desk.",
      pc="The screen knows\nwhich floor you are on.",
      poster="The face in that\nposter has moved.",
    }
    local speciesHints={
      JIGGLYPUFF="Do you hear singing\nunder the static?",
      MAGNEMITE="Your signal bends\nwhen it gets close.",
      PORYGON="It lives between\nthe broken pixels.",
      MURKROW="The tapping is not\ncoming from outside.",
      CUBONE="That crying is not\ncoming from a child.",
      HAUNTER="It laughs whenever\nyou face away.",
    }
    local hint
    if math.random(2)==1 then hint=anchorHints[tostring(mod.save:get("case_anchor_kind") or "")]
    else hint=speciesHints[caseSpecies()] end
    hint=hint or "You are not alone\nin that tower."
    playNamed(world,"Sfx_Call",106); playNamed(world,"Sfx_Call",106)
    addActivity(2)
    showPaged(world,{
      "RING! RING!\nUNKNOWN:",
      "...Is this the\nnight investigator?",
      hint,
      "You should leave\nbefore it notices.",
      "CLICK!"
    })
    return true
  end

  mod._wardenMaybeOddCall = function(world)
    if not (world and world.map and isHauntedMapId(world.map.id)) then return false end
    if mod._wardenInspection or mod.save:get("warden_case_official")~=true
      or mod.save:get("case_state")~="ACTIVE" or mod.save:get("case_odd_call_due")~=true
      or mod.save:get("case_odd_call_done")==true then return false end
    if (tonumber(mod.save:get("case_steps")) or 0)<(tonumber(mod.save:get("case_odd_call_at")) or 60) then return false end
    local now=love.timer and love.timer.getTime and love.timer.getTime() or 0
    if now<hauntFxUntil or now<speciesFxUntil or now<manifestationUntil then return false end
    local busy=false
    if world.busy then local ok,v=pcall(world.busy,world); busy=ok and v or false end
    if busy then return false end
    return mod._wardenTriggerOddCall(world,false)
  end

  local function spawnWarden()
    if spawned then return end

    -- Mr. Fuji stands at (4,2) in Crystal's SOUL_HOUSE.
    -- (5,2) places the Warden immediately beside him.
    local result, err = mod.world:spawnNpc(MAP_ID, {
      name = NPC_NAME,
      x = 5,
      y = 2,
      sprite = "SPRITE_SAGE",
      movement = "STAY",
      range = "DOWN",
    })

    if not result then
      mod.log:warn("Could not spawn Spirit Warden: " .. tostring(err))
      return
    end

    spawned = true
    if type(result) == "string" then
      spawnedId = result
    elseif type(result) == "table" then
      spawnedId = result.id or (result.npc and result.npc.id) or nil
    end
    mod.log:info("Spirit Warden spawned in SOUL_HOUSE")
  end

  mod.events:on("map.entered", function(ev)
    if ev and ev.mapId == MAP_ID then
      spawnWarden()
      -- DEV9n save migration: an old REPORT CASE pending state becomes the
      -- new automatic return-resolution flow instead of stranding the case.
      if reportPending() and not caseResolutionPending() then
        mod.save:set("warden_case_resolution_pending",true)
        mod.save:set("warden_case_outcome","CLEANSED")
        mod.save:set("warden_case_result_species",mod.save:get("warden_case_report_species"))
        clearCaseReport()
      end
      if caseResolutionPending() then
        local world=mod.world:overworld()
        if world then
          -- Let the Soul House draw first.  Starting Ezra's textbox from the
          -- map-enter callback can occur while the transition surface is still
          -- white, which hid the room behind the result conversation.
          mod._wardenReturnResolutionWorld=world
          mod._wardenReturnResolutionAt=(love.timer and love.timer.getTime and love.timer.getTime() or 0)+0.60
        end
      end
    end
  end)

  -- Remove any older-build debug marker while preserving the real invisible
  -- spirit state used by movement, tools, manifestations, and contact logic.
  clearDevGhostVisual = function()
    local ids={}
    if devGhostNpcId then ids[#ids+1]=devGhostNpcId end
    local ow=mod.world:overworld()
    for _,npc in ipairs(ow and ow.npcs or {}) do
      if npc.def and npc.def.name=="WARDEN_DEV_SPIRIT" and npc.id~=devGhostNpcId then
        ids[#ids+1]=npc.id
      end
    end
    for _,id in ipairs(ids) do pcall(mod.world.removeNpc,mod.world,id) end
    devGhostNpcId=nil
  end

  local function refreshDevGhostVisual(ow)
    clearDevGhostVisual()
  end
  -- Re-entering preserves activity so the investigation can build over time.
  mod.events:on("map.entered", function(ev)
    if not ev then return end
    if Pipelines and Pipelines.setLevel then pcall(Pipelines.setLevel, DARK_PIPELINE, isHauntedMapId(ev.mapId) and 1 or 0) end

    -- Private Warden maps have no retail exits. If a DEV warp or another mod
    -- forcibly pulls the player out mid-case, mark the simulation resolved so
    -- no darkness/chase state can leak into ordinary Crystal. Normal gameplay
    -- leaves only through the explicit Ready to leave? door prompt below.
    if not isHauntedMapId(ev.mapId) and mod.save:get("warden_case_official")==true
      and not caseResolutionPending() and mod.save:get("haunt_resolved") ~= true then
      mod.save:set("haunt_resolved",true)
      mod.save:set("case_state","FAILED")
      mod.save:set("warden_case_resolution_pending",true)
      mod.save:set("warden_case_outcome","ABANDONED")
      mod.save:set("warden_case_result_species",caseSpecies())
      mod.save:set("ghost_present",false); mod.save:set("ghost_target_map",nil)
      clearSpiritFaints()
    end

    if isHauntedMapId(ev.mapId) and isEnrolled() and mod.save:get("haunt_resolved") ~= true then
      -- Cache the positively identified 1F plant's visual signature so every
      -- identical plant on later floors receives plant dialogue automatically.
      if ev.mapId == "WARDEN_RADIO_TOWER_1F" then
        local auditMap = mod.world:overworld() and mod.world:overworld().map
        if auditMap and auditMap.tileAt then
          local sig = table.concat({
            tostring(auditMap:tileAt(10,2)), tostring(auditMap:tileAt(11,2)),
            tostring(auditMap:tileAt(10,3)), tostring(auditMap:tileAt(11,3)),
          }, ",")
          mod.save:set("warden_rt_plant_sig", sig)
        end
      end
      -- Each floor is treated as part of one evacuated Lavender Radio Tower
      -- investigation instance. Runtime NPC masks are rebuilt per floor.
      residentsMasked = false
      savedMasks = {}
      if mod.save:get("haunt_activity") == nil then mod.save:set("haunt_activity", 0) end
      if not caseSpecies() then resetCaseSimulation() end
      -- A relocated spirit materializes only when the player reaches its
      -- selected floor. This lets floor selection be truly random without
      -- fabricating walkability for an unloaded map.
      local target=mod.save:get("ghost_target_map")
      if mod.save:get("case_state") ~= "ENRAGED HUNT" and not ghostPresent() and target == ev.mapId then
        spawnInvisibleGhost(mod.world:overworld())
        mod.save:set("ghost_target_map",nil)
      end
      mod._wardenEnsureBookVisual(mod.world:overworld())
      mod._wardenEnsureAshVisual(mod.world:overworld())
      refreshDevGhostVisual(mod.world:overworld())
      maskResidents()
      purgeHauntedNpcs()
      if mod.save:get("case_state") == "ENRAGED HUNT" then
        mod.save:set("dev_candle",false)
        mod.save:set("dev_powerlight",false)
        mod.save:set("enraged_candle_locked",true)
        local now=love.timer and love.timer.getTime and love.timer.getTime() or 0
        enragedEntryX=mod.world:overworld() and mod.world:overworld().player and mod.world:overworld().player.cellX or nil
        enragedEntryY=mod.world:overworld() and mod.world:overworld().player and mod.world:overworld().player.cellY or nil
        enragedEntryMap=ev.mapId
        enragedFloorGraceUntil=now+1.15
        -- The pursuer remains conceptually behind on the prior floor. It will
        -- enter through this transition point after the grace period.
        mod.save:set("ghost_present",false)
        mod.save:set("ghost_map",nil)
        mod.save:set("ghost_target_map",ev.mapId)
        playEnragedMusic()
      else
        playHauntMusic()
      end
    else
      clearDevGhostVisual()
      restoreResidents()
    end
  end)

  local exitPromptActive=false
  local function onInvestigationExitCell(ow)
    if not (ow and ow.map and ow.player and ow.map.id==HAUNTED_MAP) then return false end
    return WARDEN_EXIT_CELLS[(ow.player.cellY or 0)*1024 + (ow.player.cellX or 0)] == true
  end

  local function promptInvestigationExit(ow)
    if exitPromptActive then return end
    exitPromptActive=true
    ow:showText("Ready to leave?",function()
      ow:askYesNo(function(yes)
        exitPromptActive=false
        if not yes then return end
        local state=tostring(mod.save:get("case_state") or "ACTIVE")
        local outcome
        if mod.save:get("haunt_resolved")==true or state=="CLEANSED" then
          outcome="CLEANSED"
        elseif mod.save:get("case_wrong_seal")==true or state=="ENRAGED HUNT" then
          outcome="WRONG_SEAL"
        else
          outcome="ABANDONED"
        end
        returnToEzraAfterCase(ow,outcome)
      end)
    end,true)
  end

  mod.events:on("world.stepped", function()
    if mod._wardenInspection then return end
    if not hauntedNow() then return end
    local ow = mod.world:overworld(); if not ow then return end
    if onInvestigationExitCell(ow) then
      promptInvestigationExit(ow)
      return
    end
    if mod.save:get("haunt_resolved") == true then return end
    purgeHauntedNpcs()
    if not caseSpecies() then resetCaseSimulation() end

    local total=(tonumber(mod.save:get("case_steps")) or 0)+1
    local floorSteps=(tonumber(mod.save:get("case_floor_steps")) or 0)+1
    mod.save:set("case_steps",total); mod.save:set("case_floor_steps",floorSteps)

    -- Walking only very slowly raises tension. Species temperament biases it.
    local stepChance=2
    local mult=SPECIES_ACTIVITY[caseSpecies() or ""] or 1
    if math.random(1000) <= math.floor(stepChance*10*mult) then addActivity(1) end

    -- If this is the spirit's destination floor and it has not yet spawned,
    -- entering/stepping here gives the loader another safe chance to place it.
    if mod.save:get("case_state") ~= "ENRAGED HUNT" and not ghostPresent() and mod.save:get("ghost_target_map") == ow.map.id then
      spawnInvisibleGhost(ow); mod.save:set("ghost_target_map",nil)
    end

    -- Placed equipment resolves before ordinary roaming/contact. Binding Ash
    -- therefore gets its promised chance to catch and slow an approaching
    -- spirit instead of triggering on the same step as an uncontrolled hit.
    if mod._wardenCheckPlacedTools(ow) then
      refreshDevGhostVisual(ow)
      return
    end

    if ghostPresent() and not falseCalmActiveNow() then
      ghostStepClock = ghostStepClock + 1
      local st=activityStage()
      local interval = st=="LINGER" and 50 or (st=="WANDERING" and 30 or (st=="AGITATED" and 15 or 6))
      if mod.save:get("case_state") == "ENRAGED HUNT" then interval=999999 end
      local clockNow=love.timer and love.timer.getTime and love.timer.getTime() or 0
      if clockNow<(tonumber(mod._wardenAshSlowUntil) or 0) then interval=math.floor(interval*2.5) end
      if ghostStepClock >= interval then
        ghostStepClock=0
        if st=="HUNTING" then moveGhostTowardPlayer(ow)
        else
          -- Early stages drift rather than homing in on the player.
          local gx,gy,gmap=ghostPos()
          if gmap==ow.map.id then
            local c={{gx+1,gy},{gx-1,gy},{gx,gy+1},{gx,gy-1}}; local v={}
            for _,q in ipairs(c) do if validGhostCell(ow,q[1],q[2]) then v[#v+1]=q end end
            if #v>0 then local q=v[math.random(#v)]; setGhostPos(q[1],q[2],ow.map.id) end
          end
        end
      end

      local nextMove=tonumber(mod.save:get("case_next_floor_move")) or 180
      if floorSteps >= nextMove then scheduleFloorRelocation(ow.map.id) end

      -- Direct contact is now a meaningful paranormal event even during
      -- LINGER: distortion, a possible warped species cry / Candle snuff,
      -- and a sizeable activity spike. Battle manifestations/TERRIFAINT will
      -- attach to this same seam later.
      local gx,gy,gmap=ghostPos()
      if gmap==ow.map.id and gx==ow.player.cellX and gy==ow.player.cellY then
        spiritContactEffect(ow, activityStage())
      end
    end
    maybeAmbientManifestation(ow)
    maybeGenericHauntEvent(ow)
    mod._wardenMaybeOddCall(ow)
    if falsePresenceNpcId and not falseCalmActiveNow() then
      local n=love.timer and love.timer.getTime and love.timer.getTime() or 0
      if not (hauntFxKind=="FALSE_PRESENCE" and n<hauntFxUntil) then clearFalsePresence() end
    end
    refreshDevGhostVisual(ow)
  end)

  -- During official cases, add the player's packed Warden equipment to the
  -- normal START menu. No developer shortcuts are registered in this build.
  mod.hooks:wrap("ui.start_menu.items", function(next, game, items)
    local out = next(game, items)
    if type(out) ~= "table" then return out end

    -- Final-facing case equipment entry. Spirit Band remains on the Pokegear;
    -- Spirit Seal plus the two packed optional tools live here during a case.
    if hauntedNow() and mod.save:get("warden_case_official")==true then
      out = mod.ui.insertBefore(out, "SAVE", {
        label = "WARDEN",
        onSelect = function(g)
          local world=mod.world:overworld()
          if g and g.stack and g.stack.top and g.stack.pop then
            local ok,top=pcall(g.stack.top,g.stack); if ok and top then pcall(g.stack.pop,g.stack) end
          end
          if not world then return end
          local names={"CASE NOTES","SPIRIT SEAL"}
          local actions={"NOTES","SEAL"}
          local t1=mod.save:get("warden_tool_1")
          local t2=mod.save:get("warden_tool_2")
          local t3=mod.save:get("warden_tool_3")
          if t1 then names[#names+1]=t1; actions[#actions+1]=t1 end
          if t2 and t2~=t1 then names[#names+1]=t2; actions[#actions+1]=t2 end
          if t3 and t3~=t1 and t3~=t2 then names[#names+1]=t3; actions[#actions+1]=t3 end
          names[#names+1]="CANCEL"; actions[#actions+1]="CANCEL"
          world:openScriptMenu({items=names,left=1,top=2,right=18,bottom=15,dataFlags=0x80,cursor=1},"vertical",function(choice)
            local action=actions[choice]
            if not action or action=="CANCEL" then return end
            if action=="NOTES" then mod._wardenShowCaseNotes(world)
            elseif action=="SEAL" then useSpiritSeal(world)
            elseif action=="CANDLE" then mod._wardenUseCandle(world)
            elseif action=="POWERLIGHT" then mod._wardenUsePowerlight(world)
            elseif action=="THERMOMETER" then mod._wardenUseThermometer(world)
            elseif action=="INCENSE" then mod._wardenUseIncense(world)
            elseif action=="WARDING CHARM" then mod._wardenUseCharm(world)
            elseif action=="SILPH SENSOR" then mod._wardenUseSilphSensor(world)
            elseif action=="BINDING ASH" then mod._wardenUseBindingAsh(world)
            elseif action=="WRITING BOOK" then mod._wardenUseWritingBook(world)
            elseif action=="UV LIGHT" then mod._wardenUseUvLight(world) end
          end)
        end,
      })
    end

    return out
  end)

  local OverworldController = require("src.world.OverworldController")
  local Gen2World = require("src.world.gen2.World")

  -- DEV7h: evacuate the Radio Tower BEFORE Gen2 constructs its people list.
  -- map.entered is too late for sight-trigger trainers: the cart-compatible
  -- world may already have spawned a Rocket and begun its trainer script on
  -- the first idle frame.  rebuildPeople is the source of all retail map
  -- actors, so mask them before the vanilla builder sees them. Runtime/mod
  -- guests (Ezra, future ghost actors, etc.) are not map-def objects and are
  -- preserved. This changes only live object masks, never SRAM event flags.
  if Gen2World and not Gen2World._spiritWardenPreSpawnEvacuation then
    Gen2World._spiritWardenPreSpawnEvacuation = true
    local vanillaRebuildPeople = Gen2World.rebuildPeople
    Gen2World.rebuildPeople = function(world, opts, ...)
      if world and world.map and isHauntedMapId(world.map.id)
        and mod.save:get("warden_enrolled") == true
        and mod.save:get("haunt_resolved") ~= true then
        world.objectMasks = world.objectMasks or {}
        world.maskScripted = world.maskScripted or {}
        for i, obj in ipairs(world.map.def.objects or {}) do
          if not obj.runtime then
            local key = world:objectMaskKey(obj, i)
            world.objectMasks[key] = true
            world.maskScripted[key] = true
          end
        end
      end
      return vanillaRebuildPeople(world, opts, ...)
    end
  end

  -- DEV7f: remove trainer encounters at the actual Gen2 seams. The Rocket
  -- Executive was bypassing the compatibility-controller guards, so during a
  -- haunting the retail Radio Tower trainer system is simply inert. NPC masks
  -- still evacuate the visible people; these guards make sure no hidden/story
  -- trainer script can start anyway.
  if Gen2World and not Gen2World._spiritWardenTrainerHardOff then
    Gen2World._spiritWardenTrainerHardOff = true
    local vanillaCheckTrainerBattle = Gen2World.checkTrainerBattle
    Gen2World.checkTrainerBattle = function(world, ...)
      if world and world.map and isHauntedMapId(world.map.id)
        and mod.save:get("warden_enrolled") == true
        and mod.save:get("haunt_resolved") ~= true then
        return false
      end
      return vanillaCheckTrainerBattle(world, ...)
    end
    local vanillaStartTrainerScript = Gen2World.startTrainerScript
    Gen2World.startTrainerScript = function(world, npc, script, sight, ...)
      if world and world.map and isHauntedMapId(world.map.id)
        and mod.save:get("warden_enrolled") == true
        and mod.save:get("haunt_resolved") ~= true then
        if npc then npc.frozen = false end
        world.talkNpc = nil
        world.trainerSight = nil
        world.trainerNpc = nil
        if world.vm then world.vm.trainerObject = nil end
        return false
      end
      return vanillaStartTrainerScript(world, npc, script, sight, ...)
    end
  end

  -- DEV7g hard backstop: some Radio Tower story encounters call
  -- startScriptedBattle directly instead of entering through trainer sight or
  -- startTrainerScript.  During an investigation, trainer battles simply do
  -- not exist.  Wild battles remain untouched for future Spirit Warden use.
  if Gen2World and not Gen2World._spiritWardenScriptedBattleHardOff then
    Gen2World._spiritWardenScriptedBattleHardOff = true
    local vanillaStartScriptedBattle = Gen2World.startScriptedBattle
    Gen2World.startScriptedBattle = function(world, record, wild, onDone, ...)
      if world and world.map and isHauntedMapId(world.map.id)
        and mod.save:get("warden_enrolled") == true
        and mod.save:get("haunt_resolved") ~= true
        and record then
        world.talkNpc = nil
        world.trainerSight = nil
        world.trainerNpc = nil
        if world.vm then world.vm.trainerObject = nil end
        if onDone then pcall(onDone, "win") end
        return false
      end
      return vanillaStartScriptedBattle(world, record, wild, onDone, ...)
    end

    local vanillaStartBattle = Gen2World.startBattle
    Gen2World.startBattle = function(world, opts, onDone, ...)
      if world and world.map and isHauntedMapId(world.map.id)
        and mod.save:get("warden_enrolled") == true
        and mod.save:get("haunt_resolved") ~= true
        and type(opts) == "table" and opts.trainer then
        world.talkNpc = nil
        world.trainerSight = nil
        world.trainerNpc = nil
        if world.vm then world.vm.trainerObject = nil end
        if onDone then pcall(onDone, "win") end
        return false
      end
      return vanillaStartBattle(world, opts, onDone, ...)
    end
  end

  -- DEV7i: the Executive ambush is a retail Radio Tower coordinate/scene
  -- script, not merely trainer sight.  This investigation is an evacuated copy
  -- of the tower, so none of the original map story coordinate/scene scripts
  -- should execute here.  Stop them at their source before dialogue, movement,
  -- or battle commands can begin. Ordinary A-button furniture handling and
  -- warps are separate paths and remain active.
  if Gen2World and not Gen2World._spiritWardenRetailSceneHardOff then
    Gen2World._spiritWardenRetailSceneHardOff = true
    local vanillaTryCoordScript = Gen2World.tryCoordScript
    Gen2World.tryCoordScript = function(world, ...)
      if world and world.map and isHauntedMapId(world.map.id)
        and mod.save:get("warden_enrolled") == true
        and mod.save:get("haunt_resolved") ~= true then
        return false
      end
      return vanillaTryCoordScript(world, ...)
    end
    local vanillaTrySceneScript = Gen2World.trySceneScript
    Gen2World.trySceneScript = function(world, ...)
      if world and world.map and isHauntedMapId(world.map.id)
        and mod.save:get("warden_enrolled") == true
        and mod.save:get("haunt_resolved") ~= true then
        return false
      end
      return vanillaTrySceneScript(world, ...)
    end
  end

  -- Absolute trainer suppression for the haunted Radio Tower instance.  This
  -- catches both line-of-sight trainers and story-script EngageMapTrainer calls.
  if OverworldController and not OverworldController._spiritWardenTrainerGuard then
    OverworldController._spiritWardenTrainerGuard = true
    local vanillaCheckTrainerSight = OverworldController.checkTrainerSight
    OverworldController.checkTrainerSight = function(ow, ...)
      if hauntedNow() then return end
      return vanillaCheckTrainerSight(ow, ...)
    end
    local vanillaEngageTrainer = OverworldController.engageTrainer
    OverworldController.engageTrainer = function(ow, npc, onDone, ...)
      if hauntedNow() then
        if npc then npc.frozen = false end
        ow.engaging = false
        if onDone then onDone() end
        return
      end
      return vanillaEngageTrainer(ow, npc, onDone, ...)
    end
  end
  -- Haunted-house furniture replaces vanilla TV/radio/bookshelf text while
  -- the case is active. Any standard furniture/sign press can reveal the next
  -- clue, so the player must actually search the room instead of camping on FM.
  local previousInteract = OverworldController and OverworldController.interact

  -- Radio Tower prop map. These exact-cell identities belong only to the
  -- private Lavender investigation copies of Goldenrod's floor geometry.
  -- They keep common scenery from falling through to generic fixture text.
  -- DEV7g: stop guessing decorative prop identity from broad map regions.
  -- Those guesses were the reason posters became plants and tables became
  -- posters.  Only explicit collision/BG-script identities are trusted now.
  -- Unknown decorative scenery stays neutral until its exact tile signature
  -- has been mapped from the audit log.
  -- Exact overrides are intentionally coordinate-specific. The prior broad
  -- region guesses caused the plant/poster/table mixups. As we positively
  -- identify a prop, add only that exact faced cell here.
  local RADIO_PROP_OVERRIDES = {
    -- Positively identified from DEV7h's on-screen cell audit. These remain as
    -- certainty anchors, but DEV7j also learns each anchor's 2x2 tile signature
    -- and applies that identity to every visually identical copy in the tower.
    ["WARDEN_RADIO_TOWER_1F:3,0"]  = "poster",
    ["WARDEN_RADIO_TOWER_1F:5,1"]  = "plant",
    -- The 1F reception counter is one physical work desk. Its telephone is
    -- the decorated counter cell at 12,5; the remaining exact cells are desk.
    ["WARDEN_RADIO_TOWER_1F:5,5"]  = "desk",
    ["WARDEN_RADIO_TOWER_1F:6,5"]  = "desk",
    ["WARDEN_RADIO_TOWER_1F:7,5"]  = "desk",
    ["WARDEN_RADIO_TOWER_1F:8,5"]  = "desk",
    ["WARDEN_RADIO_TOWER_1F:9,5"]  = "desk",
    ["WARDEN_RADIO_TOWER_1F:10,5"] = "desk",
    ["WARDEN_RADIO_TOWER_1F:11,5"] = "desk",
    ["WARDEN_RADIO_TOWER_1F:12,5"] = "phone",
    ["WARDEN_RADIO_TOWER_1F:13,5"] = "desk",
    ["WARDEN_RADIO_TOWER_1F:4,6"]  = "desk",
    ["WARDEN_RADIO_TOWER_1F:13,6"] = "desk",
    ["WARDEN_RADIO_TOWER_1F:4,7"]  = "desk",
    ["WARDEN_RADIO_TOWER_1F:13,7"] = "desk",
    ["WARDEN_RADIO_TOWER_2F:15,5"] = "microphone",
    ["WARDEN_RADIO_TOWER_2F:15,6"] = "papers",
    ["WARDEN_RADIO_TOWER_2F:14,4"] = "equipment",
    ["WARDEN_RADIO_TOWER_2F:17,4"] = "glass",
    ["WARDEN_RADIO_TOWER_2F:7,0"]  = "table",
    ["WARDEN_RADIO_TOWER_2F:5,6"]  = "table",
    ["WARDEN_RADIO_TOWER_2F:6,0"]  = "table",
    ["WARDEN_RADIO_TOWER_2F:6,4"]  = "plant",
    ["WARDEN_RADIO_TOWER_2F:4,5"]  = "cabinet",
    ["WARDEN_RADIO_TOWER_3F:4,3"]  = "phone",
    ["WARDEN_RADIO_TOWER_3F:3,6"]  = "phone",
    ["WARDEN_RADIO_TOWER_3F:3,3"]  = "desk",
    ["WARDEN_RADIO_TOWER_3F:7,3"]  = "desk",
    ["WARDEN_RADIO_TOWER_3F:8,3"]  = "phone",
    ["WARDEN_RADIO_TOWER_3F:2,6"]  = "desk",
    ["WARDEN_RADIO_TOWER_3F:6,6"]  = "desk",
    ["WARDEN_RADIO_TOWER_3F:7,6"]  = "phone",
    ["WARDEN_RADIO_TOWER_3F:10,6"] = "desk",
    ["WARDEN_RADIO_TOWER_3F:11,6"] = "phone",
    -- DEV8c: positively identified 4F props from the latest screenshot audit.
    ["WARDEN_RADIO_TOWER_4F:15,0"] = "poster",
    ["WARDEN_RADIO_TOWER_4F:15,5"] = "microphone",
    ["WARDEN_RADIO_TOWER_4F:15,6"] = "papers",
    ["WARDEN_RADIO_TOWER_4F:17,4"] = "glass",
    ["WARDEN_RADIO_TOWER_4F:5,3"]  = "desk",
    ["WARDEN_RADIO_TOWER_4F:6,3"]  = "phone",
    ["WARDEN_RADIO_TOWER_4F:1,5"]  = "desk",
    ["WARDEN_RADIO_TOWER_4F:2,5"]  = "phone",
    ["WARDEN_RADIO_TOWER_4F:7,5"]  = "desk",
    ["WARDEN_RADIO_TOWER_4F:8,5"]  = "phone",
    ["WARDEN_RADIO_TOWER_5F:1,3"]  = "desk",
    ["WARDEN_RADIO_TOWER_5F:2,3"]  = "phone",
    ["WARDEN_RADIO_TOWER_5F:3,5"]  = "pc",
    ["WARDEN_RADIO_TOWER_5F:4,5"]  = "desk",
    ["WARDEN_RADIO_TOWER_5F:5,5"]  = "phone",
  }

  -- Canonical cells supplied by the player's screenshots. When one of these
  -- floors is active we can read all four 8x8 tile IDs for each canonical prop
  -- directly from the loaded map, then reuse the resulting signature anywhere
  -- else in WARDEN_RADIO_TOWER_1F..5F. No coordinate regions or visual guessing.
  local RADIO_PROP_SIGNATURE_SEEDS = {
    WARDEN_RADIO_TOWER_1F = {
      {3,0,"poster"}, {5,1,"plant"},
    },
    WARDEN_RADIO_TOWER_2F = {
      {15,5,"microphone"}, {15,6,"papers"}, {14,4,"equipment"},
      {17,4,"glass"}, {7,0,"table"}, {5,6,"table"}, {6,0,"table"},
      {6,4,"plant"}, {4,5,"cabinet"},
    },
    WARDEN_RADIO_TOWER_3F = {
      {4,3,"phone"}, {3,6,"phone"},
    },
    WARDEN_RADIO_TOWER_4F = {
      {15,0,"poster"}, {15,5,"microphone"}, {15,6,"papers"},
      {17,4,"glass"},
    },
    WARDEN_RADIO_TOWER_5F = {
      {1,3,"desk"}, {3,5,"pc"},
    },
  }

  local function propTileSignature(map, x, y)
    if not (map and map.tileAt) then return nil end
    local a,b,c,d = map:tileAt(x*2,y*2), map:tileAt(x*2+1,y*2),
                    map:tileAt(x*2,y*2+1), map:tileAt(x*2+1,y*2+1)
    if a == nil or b == nil or c == nil or d == nil then return nil end
    return table.concat({tostring(a),tostring(b),tostring(c),tostring(d)}, ",")
  end

  -- A category can have more than one visual tile signature. For example the
  -- tower uses multiple table and telephone graphics. DEV7j only retained one
  -- signature per category, so learning a second table could overwrite the
  -- first. DEV7k stores a set of signatures for each category instead.
  local learnedPropSignatures = {}

  local function signatureSet(kind)
    local set = learnedPropSignatures[kind]
    if set then return set end
    set = {}
    local packed = mod.save:get("warden_rt_sigs_" .. kind)
    if type(packed) == "string" then
      for sig in string.gmatch(packed, "[^;]+") do set[sig] = true end
    end
    -- Import the single-signature DEV7j/DEV7i save keys once so old saves keep
    -- everything they already learned.
    local legacy = mod.save:get("warden_rt_sig_" .. kind)
    if legacy then set[tostring(legacy)] = true end
    if kind == "plant" then
      local oldPlant = mod.save:get("warden_rt_plant_sig")
      if oldPlant then set[tostring(oldPlant)] = true end
    end
    learnedPropSignatures[kind] = set
    return set
  end

  local function rememberSignature(kind, sig)
    if not sig then return end
    local set = signatureSet(kind)
    if set[sig] then return end
    set[sig] = true
    local all = {}
    for known in pairs(set) do all[#all + 1] = known end
    table.sort(all)
    mod.save:set("warden_rt_sigs_" .. kind, table.concat(all, ";"))
    -- Keep the old key populated for backwards compatibility/debug inspection.
    mod.save:set("warden_rt_sig_" .. kind, sig)
    if kind == "plant" then mod.save:set("warden_rt_plant_sig", sig) end
  end

  local function learnRadioPropSignatures(mapId, map)
    local seeds = RADIO_PROP_SIGNATURE_SEEDS[mapId]
    if not (seeds and map and map.tileAt) then return end
    for _, seed in ipairs(seeds) do
      local sx,sy,kind = seed[1],seed[2],seed[3]
      rememberSignature(kind, propTileSignature(map,sx,sy))
    end
  end

  local RADIO_PROP_SIGNATURE_KINDS = {
    "poster","plant","microphone","papers","equipment",
    "glass","table","cabinet","phone","desk","pc",
  }

  local function radioTowerPropKind(mapId, x, y, fallback, map)
    -- Learn all positively identified graphics on the current floor. Every
    -- signature remains valid, so alternate table/phone/PC graphics can coexist.
    learnRadioPropSignatures(mapId, map)

    local exact = RADIO_PROP_OVERRIDES[tostring(mapId) .. ":" .. tostring(x) .. "," .. tostring(y)]
    if exact then return exact end

    local sig = propTileSignature(map, x, y)
    if sig then
      for _, kind in ipairs(RADIO_PROP_SIGNATURE_KINDS) do
        if signatureSet(kind)[sig] then return kind end
      end
    end
    return fallback
  end

  -- DEV8e anchor survey. Label every *recognized* sealable Radio Tower prop
  -- directly in the world so a screenshot can audit the individual instances.
  -- IDs are stable within a floor: PL1/PL2, MIC1, POST1, etc., assigned in
  -- top-to-bottom/left-to-right cell order. Unknown scenery is intentionally
  -- omitted; that makes missing recognition obvious in the screenshots.


  local SURVEY_PREFIX = {
    plant="PL", microphone="MIC", poster="POST", papers="PAP", glass="GL",
    table="TAB", cabinet="CAB", phone="PH", desk="DSK", pc="PC",
    equipment="EQ", radio="RAD", bookcase="BK", window="WIN", map="MAP",
    shelf="SH", tv="TV", incense="INC",
  }

  local function surveyKindAt(ow,x,y)
    local map=ow and ow.map; if not map then return nil end
    local c=map:cellCollision(x,y)
    local bg=nil
    for _,ev in ipairs(WARDEN_BG_EVENTS[map.id] or {}) do
      if tonumber(ev.x)==x and tonumber(ev.y)==y then bg=ev; break end
    end
    local known={ [0x90]="desk",[0x91]="bookcase",[0x93]="pc",[0x94]="radio",
      [0x95]="map",[0x96]="shelf",[0x97]="tv",[0x98]="desk",
      [0x9d]="window",[0x9f]="incense" }
    local kind=known[c]
    if not kind and bg then
      local key=string.lower(tostring(bg.scriptKey or bg.name or ""))
      if key:find("plant",1,true) or key:find("flower",1,true) then kind="plant"
      elseif key:find("tv",1,true) then kind="tv"
      elseif key:find("book",1,true) or key:find("shelf",1,true) then kind="bookcase"
      elseif key:find("window",1,true) then kind="window"
      elseif key:find("radio",1,true) then kind="radio"
      elseif key:find("computer",1,true) or key:find("pc",1,true) then kind="pc"
      elseif key:find("mic",1,true) then kind="microphone"
      elseif key:find("phone",1,true) or key:find("telephone",1,true) then kind="phone"
      elseif key:find("cabinet",1,true) or key:find("drawer",1,true) then kind="cabinet"
      elseif key:find("poster",1,true) or key:find("picture",1,true) or key:find("notice",1,true) then kind="poster"
      elseif key:find("glass",1,true) or key:find("mirror",1,true) then kind="glass"
      elseif key:find("paper",1,true) or key:find("memo",1,true) or key:find("form",1,true) then kind="papers"
      elseif key:find("desk",1,true) or key:find("counter",1,true) then kind="desk" end
    end
    return radioTowerPropKind(map.id,x,y,kind,map)
  end

  local function surveyObjects(ow)
    if not (ow and ow.map and isHauntedMapId(ow.map.id)) then return {} end
    local map=ow.map; learnRadioPropSignatures(map.id,map)
    local out,counters={},{}
    local w=tonumber(map.widthCells) or ((tonumber(map.width) or 0)*2)
    local h=tonumber(map.heightCells) or ((tonumber(map.height) or 0)*2)
    for y=0,h-1 do for x=0,w-1 do
      local kind=surveyKindAt(ow,x,y)
      if kind and SURVEY_PREFIX[kind] then
        local solid=map.isWalkable and not map:isWalkable(x,y)
        local bg=nil
        for _,ev in ipairs(WARDEN_BG_EVENTS[map.id] or {}) do
          if tonumber(ev.x)==x and tonumber(ev.y)==y then bg=ev; break end
        end
        local exact=RADIO_PROP_OVERRIDES[tostring(map.id)..":"..x..","..y]
        if solid or bg or exact then
          counters[kind]=(counters[kind] or 0)+1
          out[#out+1]={x=x,y=y,kind=kind,id=SURVEY_PREFIX[kind]..tostring(counters[kind])}
        end
      end
    end end
    return out
  end


  -- DEV8g contextual-anchor solver -----------------------------------------
  -- Build the same surveyed inventory for all five floors directly from the
  -- loaded Gen2 map definitions, then generate clue triples whose intersection
  -- identifies exactly ONE sealable object. If an object has no fair unique
  -- triple, it simply is not eligible to become the case anchor.
  local KIND_CLUE_TEXT = {
    plant="LEAVES", microphone="MICROPHONE", poster="POSTER", papers="PAPERS",
    glass="REFLECTION", table="TABLE", cabinet="CABINET", phone="TELEPHONE",
    desk="DESK", pc="COMPUTER", equipment="EQUIPMENT", radio="RADIO",
    bookcase="BOOKS", window="WINDOW", map="WALL MAP", shelf="SHELVES",
    tv="TELEVISION", incense="INCENSE",
  }
  local RELATION_TEXT = {
    plant="PLANT", microphone="MIC", poster="POSTER", papers="PAPERS",
    glass="GLASS", table="TABLE", cabinet="CABINET", phone="PHONE",
    desk="DESK", pc="COMPUTER", equipment="EQUIPMENT", radio="RADIO",
    bookcase="BOOKS", window="WINDOW", map="MAP", shelf="SHELVES",
    tv="TV", incense="INCENSE",
  }
  local FLOOR_CLUE_TEXT = {
    WARDEN_RADIO_TOWER_1F="FIRST FLOOR", WARDEN_RADIO_TOWER_2F="SECOND FLOOR",
    WARDEN_RADIO_TOWER_3F="THIRD FLOOR", WARDEN_RADIO_TOWER_4F="FOURTH FLOOR",
    WARDEN_RADIO_TOWER_5F="FIFTH FLOOR",
  }

  -- DEV8h presentation layer.  The solver stores literal semantic clue text;
  -- Spirit Band output is chosen separately so repeated cases do not sound
  -- like a debug database reciting the same labels every time.
  local CLUE_PHRASES = {
    ["LEAVES"]={"LEAVES","ROOTS BELOW","IT STILL GROWS","GREEN AND STILL"},
    ["UPPER PLANT LEAVES"]={"UPPER PLANT LEAVES","ATOP A PLANT","HIGH IN ITS LEAVES"},
    ["A PLANT'S SOIL"]={"A PLANT'S SOIL","BURIED IN THE SOIL","IN THE FLOWERPOT"},
    ["MICROPHONE"]={"MICROPHONE","WHERE VOICES ENTER","SPEAK INTO IT","THE LISTENING MIC"},
    ["POSTER"]={"POSTER","PRINT ON THE WALL","BENEATH THE NOTICE","THE WALL IMAGE"},
    ["PAPERS"]={"PAPERS","WORDS ON A DESK","THE WRITTEN PAGES","INK AND PAPER"},
    ["REFLECTION"]={"REFLECTION","GLASS REMEMBERS","LOOK INTO THE PANE","A FACE IN GLASS"},
    ["TABLE"]={"TABLE","THE FLAT SURFACE","WHERE THINGS REST","ON THE TABLE"},
    ["CABINET"]={"CABINET","BEHIND A DOOR","THINGS KEPT INSIDE","THE CLOSED STORAGE"},
    ["TELEPHONE"]={"TELEPHONE","WAITING TO RING","ANSWER THE LINE","WHERE CALLS ARRIVE"},
    ["DESK"]={"DESK","THE WORK PLACE","BEHIND THE DESK","WHERE HANDS WORKED"},
    ["COMPUTER"]={"COMPUTER","THE DARK SCREEN","KEYS WITHOUT HANDS","THE TERMINAL"},
    ["EQUIPMENT"]={"EQUIPMENT","THE CONTROLS","THE SIGNAL MACHINE","AMONG THE SWITCHES"},
    ["RADIO"]={"RADIO","THE RECEIVER","SIGNALS SPEAK","THE OLD RADIO"},
    ["BOOKS"]={"BOOKS","BETWEEN THE PAGES","ON THE SHELF","THE SILENT BOOKS"},
    ["WINDOW"]={"WINDOW","BEYOND THE GLASS","AT THE WINDOW","THE OUTSIDE PANE"},
    ["WALL MAP"]={"WALL MAP","MAP ON THE WALL","ROADS WITHOUT FEET","THE HANGING MAP"},
    ["SHELVES"]={"SHELVES","ON THE SHELVES","WHERE GOODS REST","THE DISPLAY SHELF"},
    ["TELEVISION"]={"TELEVISION","THE DARK SCREEN","THE SILENT TV","A DEAD SCREEN"},
    ["INCENSE"]={"INCENSE","ASH AND SCENT","WHERE SMOKE ROSE","THE BURNER"},
    ["FIRST FLOOR"]={"FIRST FLOOR","THE LOWEST FLOOR","ABOVE THE STREET","TOWER'S BASE"},
    ["SECOND FLOOR"]={"SECOND FLOOR","ONE FLOOR ABOVE","THE SECOND LEVEL","ABOVE THE LOBBY"},
    ["THIRD FLOOR"]={"THIRD FLOOR","THE MIDDLE FLOOR","THREE LEVELS HIGH","TOWER'S MIDDLE"},
    ["FOURTH FLOOR"]={"FOURTH FLOOR","ONE BELOW THE TOP","HIGH IN THE TOWER","THE FOURTH LEVEL"},
    ["FIFTH FLOOR"]={"FIFTH FLOOR","THE HIGHEST FLOOR","AT THE VERY TOP","THE TOP LEVEL"},
    ["WEST SIDE"]={"WEST SIDE","TO THE LEFT","THE WESTERN SIDE","LEFT OF CENTER"},
    ["EAST SIDE"]={"EAST SIDE","TO THE RIGHT","THE EASTERN SIDE","RIGHT OF CENTER"},
    ["CENTER"]={"CENTER","NEAR THE MIDDLE","AT THE CENTER","NOT BY THE EDGES"},
    ["NORTH END"]={"NORTH END","TOWARD THE BACK","THE FAR END","AT THE NORTH END"},
    ["SOUTH END"]={"SOUTH END","TOWARD THE FRONT","THE NEAR END","AT THE SOUTH END"},
    ["MIDDLE"]={"MIDDLE","MIDWAY THROUGH","IN THE MIDDLE","BETWEEN THE ENDS"},
  }
  mod._wardenCluePhrases=CLUE_PHRASES

  cluePhrase = function(clue)
    local function safeLine(text)
      text=tostring(text or "...")
      -- Pokegear radio output is a single fixed-width row, not showPaged text.
      -- Measure the actual active font against its 144-pixel interior, and
      -- shorten at a word boundary before falling back to a glyph-safe cut.
      -- This keeps semantic words such as PLANT intact at every font/zoom.
      local stripped=text:gsub("^%.%.%.",""):gsub("%.%.%.$","")
        :gsub("ANOTHER ","OTHER ")
      local ok,Font=pcall(require,"src.render.Font")
      local function fits(s)
        return ok and Font and Font.width and Font.width(s)<=144 or (not ok and #s<=18)
      end
      if fits(text) then return text end
      if fits(stripped) then return stripped end
      local whole=stripped
      while not fits(whole) and whole:find(" ",1,true) do
        whole=whole:match("^(.*)%s+%S+$") or whole
      end
      if fits(whole) then return whole end
      if ok and Font and Font.split and Font.spansFitting then
        local spans=Font.split(stripped)
        local n=Font.spansFitting(spans,144)
        local out={}
        for i=1,n do out[#out+1]=stripped:sub(spans[i].from,spans[i].to) end
        return table.concat(out)
      end
      return stripped:sub(1,18)
    end
    clue=tostring(clue or "...")
    local direct=CLUE_PHRASES[clue]
    if direct and #direct>0 then
      -- Filter defensively so future prose additions cannot overflow the radio.
      local safe={}
      for _,v in ipairs(direct) do if safeLine(v)==v then safe[#safe+1]=v end end
      if #safe>0 then return safe[math.random(#safe)] end
      return safeLine(clue)
    end

    -- Context relations remain semantically exact but use compact variants.
    -- The longest relation target currently used is EQUIPMENT (9 chars), so
    -- RIGHT/LEFT OF EQUIPMENT still fits exactly inside the 18-char row.
    local lead,target=clue:match("^(NEAR) (.+)$")
    if lead then
      local forms={"NEAR "..target,"BY "..target,"CLOSE TO "..target}
      return safeLine(forms[math.random(#forms)])
    end
    lead,target=clue:match("^(LEFT OF) (.+)$")
    if lead then
      local forms={"LEFT OF "..target,target.." TO RIGHT"}
      return safeLine(forms[math.random(#forms)])
    end
    lead,target=clue:match("^(RIGHT OF) (.+)$")
    if lead then
      local forms={"RIGHT OF "..target,target.." TO LEFT"}
      return safeLine(forms[math.random(#forms)])
    end
    lead,target=clue:match("^(ABOVE) (.+)$")
    if lead then
      local forms={"ABOVE "..target,"OVER "..target,target.." BELOW"}
      return safeLine(forms[math.random(#forms)])
    end
    lead,target=clue:match("^(BELOW) (.+)$")
    if lead then
      local forms={"BELOW "..target,"UNDER "..target,target.." ABOVE"}
      return safeLine(forms[math.random(#forms)])
    end
    return safeLine(clue)
  end
  mod._wardenCluePhrase=cluePhrase

  local function bgEventAtMap(map,x,y)
    local id=map and map.id
    for _,ev in ipairs(WARDEN_BG_EVENTS[id] or {}) do
      if tonumber(ev.x)==x and tonumber(ev.y)==y then return ev end
    end
    return nil
  end

  local function kindFromBgEvent(bg)
    if not bg then return nil end
    local key=string.lower(tostring(bg.scriptKey or bg.name or ""))
    if key:find("plant",1,true) or key:find("flower",1,true) then return "plant"
    elseif key:find("tv",1,true) then return "tv"
    elseif key:find("book",1,true) or key:find("shelf",1,true) then return "bookcase"
    elseif key:find("window",1,true) then return "window"
    elseif key:find("radio",1,true) then return "radio"
    elseif key:find("computer",1,true) or key:find("pc",1,true) then return "pc"
    elseif key:find("mic",1,true) then return "microphone"
    elseif key:find("phone",1,true) or key:find("telephone",1,true) then return "phone"
    elseif key:find("cabinet",1,true) or key:find("drawer",1,true) then return "cabinet"
    elseif key:find("poster",1,true) or key:find("picture",1,true) or key:find("notice",1,true) then return "poster"
    elseif key:find("glass",1,true) or key:find("mirror",1,true) then return "glass"
    elseif key:find("paper",1,true) or key:find("memo",1,true) or key:find("form",1,true) then return "papers"
    elseif key:find("desk",1,true) or key:find("counter",1,true) then return "desk" end
    return nil
  end

  local function surveyKindAtMap(map,x,y)
    if not map then return nil end
    local c=map:cellCollision(x,y)
    local known={ [0x90]="desk",[0x91]="bookcase",[0x93]="pc",[0x94]="radio",
      [0x95]="map",[0x96]="shelf",[0x97]="tv",[0x98]="desk",
      [0x9d]="window",[0x9f]="incense" }
    local bg=bgEventAtMap(map,x,y)
    local kind=known[c] or kindFromBgEvent(bg)
    return radioTowerPropKind(map.id,x,y,kind,map)
  end

  -- Shared with the isolated validation harness so the physical two-cell
  -- plant rule is tested independently of map loading.
  mod._wardenPrepareAnchorContext = function(all)
    -- A Radio Tower plant is drawn as two vertically adjacent cells. Mark its
    -- leafy top and soil/pot bottom as positions on ONE physical plant, rather
    -- than letting the solver describe either half as another plant.
    for _,o in ipairs(all or {}) do
      if o.kind=="plant" then
        local hasAbove,hasBelow=false,false
        for _,b in ipairs(all) do
          if b~=o and b.map==o.map and b.kind=="plant" and b.x==o.x then
            if b.y==o.y-1 then hasAbove=true elseif b.y==o.y+1 then hasBelow=true end
          end
        end
        if hasBelow and not hasAbove then o.plantPart="top"
        elseif hasAbove then o.plantPart="soil" end
      end
    end

    -- Context is derived from the actual surveyed objects, not handwritten
    -- guesses. These are deliberately simple, legible spatial relationships.
    for _,o in ipairs(all or {}) do
      o.nearKinds={}; o.leftKinds={}; o.rightKinds={}; o.aboveKinds={}; o.belowKinds={}
      for _,b in ipairs(all) do
        if b~=o and b.map==o.map then
          local dx,dy=b.x-o.x,b.y-o.y
          local d=math.abs(dx)+math.abs(dy)
          local samePlant=o.kind=="plant" and b.kind=="plant" and dx==0 and math.abs(dy)==1
          if not samePlant then
            if d<=3 then o.nearKinds[b.kind]=true end
            if math.abs(dy)<=1 and dx>=1 and dx<=4 then o.rightKinds[b.kind]=true end
            if math.abs(dy)<=1 and dx<=-1 and dx>=-4 then o.leftKinds[b.kind]=true end
            if math.abs(dx)<=1 and dy>=1 and dy<=4 then o.belowKinds[b.kind]=true end
            if math.abs(dx)<=1 and dy<=-1 and dy>=-4 then o.aboveKinds[b.kind]=true end
          end
        end
      end
      local w,h=math.max(1,o.width or 1),math.max(1,o.height or 1)
      o.hzone = o.x < w/3 and "WEST SIDE" or (o.x >= (w*2/3) and "EAST SIDE" or "CENTER")
      o.vzone = o.y < h/3 and "NORTH END" or (o.y >= (h*2/3) and "SOUTH END" or "MIDDLE")
    end
    return all
  end

  local function fullAnchorInventory(ow)
    if not (ow and ow.maps and ow.tilesets and Gen2MapData) then return {} end
    local all={}
    for _,mapId in ipairs(HAUNTED_FLOORS) do
      local def=ow.maps[mapId]
      local tileset=def and ow.tilesets[def.tileset]
      if def and tileset then
        local map=Gen2MapData.new(def,tileset)
        learnRadioPropSignatures(mapId,map)
        local counters={}
        for y=0,(map.heightCells or 0)-1 do for x=0,(map.widthCells or 0)-1 do
          local kind=surveyKindAtMap(map,x,y)
          if kind and SURVEY_PREFIX[kind] and KIND_CLUE_TEXT[kind] then
            local bg=bgEventAtMap(map,x,y)
            local exact=RADIO_PROP_OVERRIDES[tostring(mapId)..":"..x..","..y]
            local solid=map.isWalkable and not map:isWalkable(x,y)
            if solid or bg or exact then
              counters[kind]=(counters[kind] or 0)+1
              all[#all+1]={map=mapId,x=x,y=y,kind=kind,
                id=tostring(mapId):gsub("WARDEN_RADIO_TOWER_","").."-"..SURVEY_PREFIX[kind]..tostring(counters[kind]),
                width=map.widthCells or 0,height=map.heightCells or 0}
            end
          end
        end end
      end
    end

    mod._wardenPrepareAnchorContext(all)
    return all
  end

  local function descriptorsFor(anchor)
    local ds={}
    local function add(id,text,test,weight)
      ds[#ds+1]={id=id,text=text,test=test,weight=weight or 1}
    end
    if anchor.kind=="plant" and anchor.plantPart=="top" then
      add("kind:plant-top","UPPER PLANT LEAVES",function(o) return o.kind=="plant" and o.plantPart=="top" end,12)
    elseif anchor.kind=="plant" and anchor.plantPart=="soil" then
      add("kind:plant-soil","A PLANT'S SOIL",function(o) return o.kind=="plant" and o.plantPart=="soil" end,12)
    else
      add("kind:"..anchor.kind,KIND_CLUE_TEXT[anchor.kind],function(o) return o.kind==anchor.kind end,10)
    end
    add("floor:"..anchor.map,FLOOR_CLUE_TEXT[anchor.map] or anchor.map,function(o) return o.map==anchor.map end,9)
    add("hz:"..anchor.hzone,anchor.hzone,function(o) return o.hzone==anchor.hzone end,2)
    add("vz:"..anchor.vzone,anchor.vzone,function(o) return o.vzone==anchor.vzone end,2)

    local function relationSet(field,lead)
      for kind in pairs(anchor[field] or {}) do
        local targetKind=kind
        local label=RELATION_TEXT[targetKind]
        if label then
          local same=(targetKind==anchor.kind)
          local text=lead.." "..(same and ("OTHER "..label) or label)
          add(field..":"..targetKind,text,function(o) return o[field] and o[field][targetKind]==true end,6)
        end
      end
    end
    relationSet("nearKinds","NEAR")
    relationSet("leftKinds","RIGHT OF")
    relationSet("rightKinds","LEFT OF")
    relationSet("aboveKinds","BELOW")
    relationSet("belowKinds","ABOVE")
    return ds
  end

  local function matchingObjects(inventory,descs)
    local out={}
    for _,o in ipairs(inventory) do
      local good=true
      for _,d in ipairs(descs) do if not d.test(o) then good=false; break end end
      if good then out[#out+1]=o end
    end
    return out
  end

  local function uniqueTriplesFor(anchor,inventory)
    local ds=descriptorsFor(anchor)
    local found={}
    for i=1,#ds-2 do for j=i+1,#ds-1 do for k=j+1,#ds do
      local triple={ds[i],ds[j],ds[k]}
      local matches=matchingObjects(inventory,triple)
      if #matches==1 and matches[1].id==anchor.id then
        local hasKind=(ds[i].id:find("^kind:") or ds[j].id:find("^kind:") or ds[k].id:find("^kind:")) and true or false
        local hasFloor=(ds[i].id:find("^floor:") or ds[j].id:find("^floor:") or ds[k].id:find("^floor:")) and true or false
        local score=(ds[i].weight or 0)+(ds[j].weight or 0)+(ds[k].weight or 0)+(hasKind and 12 or 0)+(hasFloor and 8 or 0)
        found[#found+1]={triple=triple,score=score,matches=matches}
      end
    end end end
    table.sort(found,function(a,b) return a.score>b.score end)
    return found
  end

  buildContextualCase = function(ow)
    local inventory=fullAnchorInventory(ow)
    local eligible={}
    for _,o in ipairs(inventory) do
      local triples=uniqueTriplesFor(o,inventory)
      if #triples>0 then eligible[#eligible+1]={anchor=o,triples=triples} end
    end
    if #eligible==0 then return nil end
    local chosen=eligible[math.random(#eligible)]
    -- Keep variety while preferring readable kind/floor/context combinations.
    local top=math.min(4,#chosen.triples)
    local selected=chosen.triples[math.random(top)]
    local clues={selected.triple[1].text,selected.triple[2].text,selected.triple[3].text}
    -- Follow-ups use true descriptors that were not part of the winning
    -- three-clue intersection. Prefer spatial context; kind/floor have their
    -- own deliberately clearer fallback forms installed at case start.
    local used,followups={},{ }
    for _,d in ipairs(selected.triple) do used[d.id]=true end
    for _,d in ipairs(descriptorsFor(chosen.anchor)) do
      if not used[d.id] and not d.id:find("^kind:") and not d.id:find("^floor:") then
        followups[#followups+1]=d.text
      end
    end
    -- Randomize discovery order; the meaning stays the same.
    for i=3,2,-1 do local j=math.random(i); clues[i],clues[j]=clues[j],clues[i] end
    local candidateText=chosen.anchor.id
    return {chosen.anchor.map,chosen.anchor.x,chosen.anchor.y,chosen.anchor.kind,
      chosen.anchor.id,chosen.anchor.plantPart},clues,1,candidateText,followups
  end

  mod._wardenFollowupPhrase = function(ow,raw)
    raw=tostring(raw or "...")
    if raw=="RELATIVE FLOOR" then
      local current,anchor
      for i,id in ipairs(HAUNTED_FLOORS) do
        if ow and ow.map and id==ow.map.id then current=i end
        if id==mod.save:get("case_anchor_map") then anchor=i end
      end
      if current and anchor then
        if anchor<current then return "DOWNSTAIRS"
        elseif anchor>current then return "UPSTAIRS"
        else return "THIS FLOOR" end
      end
      return "INSIDE THE TOWER"
    end
    local kind,part=raw:match("^ODD KIND:([^:]+):?(.*)$")
    if kind then
      kind=string.lower(kind); part=string.lower(part or "")
      if kind=="plant" and part=="top" then return "ODD UPPER LEAVES" end
      if kind=="plant" and part=="soil" then return "DISTURBED SOIL" end
      local labels={microphone="MIC",papers="PAPERS",equipment="EQUIPMENT",
        glass="GLASS",table="TABLE",cabinet="CABINET",phone="PHONE",desk="DESK",
        pc="COMPUTER",plant="PLANT",poster="POSTER",radio="RADIO",
        bookcase="BOOKS",window="WINDOW",shelf="SHELVES",tv="TV",incense="INCENSE"}
      return "STRANGE "..tostring(labels[kind] or string.upper(kind))
    end
    local floor=raw:match("^FLOOR:(.+)$")
    if floor then return FLOOR_CLUE_TEXT[floor] or floor:gsub("WARDEN_RADIO_TOWER_","") end
    return raw
  end

  -- Ordinary environmental follow-ups begin after the three core clues. The
  -- placed Writing Book is the exception: it may earn one of these truthful,
  -- capped bonus clues earlier if the spirit reaches its floor.
  mod._wardenTryFollowup = function(ow,source,sourceKey,baseChance)
    if (tonumber(mod.save:get("case_clues")) or 0)<3 and sourceKey~="WRITING_BOOK" then return nil end
    local total=tonumber(mod.save:get("case_followup_total"))
    if not total then
      local oldAnchor={mod.save:get("case_anchor_map"),mod.save:get("case_anchor_x"),
        mod.save:get("case_anchor_y"),mod.save:get("case_anchor_kind"),
        mod.save:get("case_anchor_id"),mod.save:get("case_anchor_part")}
      mod._wardenInstallFollowups(oldAnchor,nil)
      total=tonumber(mod.save:get("case_followup_total")) or 0
    end
    local found=tonumber(mod.save:get("case_followup_found")) or 0
    if found>=total then return nil end
    local serial=tonumber(mod.save:get("case_serial")) or 0
    local checked="case_followup_checked_"..serial..":"..tostring(sourceKey or source)
    if mod.save:get(checked)==true then return nil end
    mod.save:set(checked,true)
    local attempts=(tonumber(mod.save:get("case_followup_attempts")) or 0)+1
    mod.save:set("case_followup_attempts",attempts)
    local chance=math.min(90,(tonumber(baseChance) or 35)+(attempts-1)*8)
    if math.random(100)>chance then return nil end
    local missing={}
    for i=1,total do
      if mod.save:get("case_followup_found_"..i)~=true and mod.save:get("case_followup_"..i) then
        missing[#missing+1]=i
      end
    end
    if #missing==0 then return nil end
    local index=missing[math.random(#missing)]
    mod.save:set("case_followup_found_"..index,true)
    mod.save:set("case_followup_found",math.min(total,found+1))
    addActivity(math.random(2,4))
    local clue=mod._wardenFollowupPhrase(ow,mod.save:get("case_followup_"..index))
    local intro
    source=string.upper(tostring(source or ""))
    if source=="GLASS" or source=="WINDOW" then intro="Scratched in dust:"
    elseif source=="PC" or source=="EQUIPMENT" then intro="The dead screen says:"
    elseif source=="MICROPHONE" or source=="TELEPHONE" or source=="PHONE" then intro="A broken voice says:"
    else intro="A marked note reads:" end
    return {"FOLLOW-UP CLUE",intro.."\n"..clue},index,clue
  end

  mod._wardenShowCaseNotes = function(ow)
    local pages={"CASE NOTES"}
    local known=0
    for i=1,3 do
      if mod.save:get("case_clue_found_"..i)==true then
        known=known+1; pages[#pages+1]="BAND CLUE "..i.."\n"..tostring(mod.save:get("case_clue_"..i) or "...")
      end
    end
    local total=tonumber(mod.save:get("case_followup_total")) or 0
    for i=1,total do
      if mod.save:get("case_followup_found_"..i)==true then
        known=known+1
        pages[#pages+1]="FOLLOW-UP "..i.."\n"..mod._wardenFollowupPhrase(ow,mod.save:get("case_followup_"..i))
      end
    end
    if known==0 then pages[#pages+1]="Nothing useful has\nbeen recorded yet." end
    showPaged(ow,pages)
  end

  -- DEV8h Spirit Seal.  This is a development-menu stand-in for the eventual
  -- Key Item, but it already resolves the exact faced object instance.
  useSpiritSeal = function(ow,confirmed)
    if not (ow and ow.map and ow.player and isHauntedMapId(ow.map.id)) then
      if ow and ow.showText then ow:showText("The SPIRIT SEAL\nis still.",nil,false) end
      return false
    end
    if mod.save:get("haunt_resolved") == true then
      showPaged(ow,{"The haunting has\nalready been cleansed."})
      return true
    end
    if not confirmed then
      if mod._wardenSealPrompt then return true end
      mod._wardenSealPrompt=true
      showPaged(ow,{"Use the SPIRIT\nSEAL here?"},function()
        ow:askYesNo(function(yes)
          mod._wardenSealPrompt=false
          if yes then useSpiritSeal(ow,true) end
        end)
      end,true)
      return true
    end
    local delta=({up={0,-1},down={0,1},left={-1,0},right={1,0}})[ow.player.facing or "down"]
    local fx,fy=ow.player.cellX+delta[1],ow.player.cellY+delta[2]
    local c=ow.map:cellCollision(fx,fy)
    local bg=nil
    for _,ev in ipairs(WARDEN_BG_EVENTS[ow.map.id] or {}) do
      if tonumber(ev.x)==fx and tonumber(ev.y)==fy then bg=ev; break end
    end
    local known={ [0x90]="desk",[0x91]="bookcase",[0x93]="pc",[0x94]="radio",
      [0x95]="map",[0x96]="shelf",[0x97]="tv",[0x98]="desk",
      [0x9d]="window",[0x9f]="incense" }
    local kind=known[c] or kindFromBgEvent(bg)
    if not kind and ow.map.isWalkable and not ow.map:isWalkable(fx,fy) then
      local isWarp=ow.map.isWarp and ow.map:isWarp(fx,fy)
      if not isWarp then kind="fixture" end
    end
    kind=radioTowerPropKind(ow.map.id,fx,fy,kind,ow.map)
    if not (kind and SURVEY_PREFIX and SURVEY_PREFIX[kind]) then
      showPaged(ow,{"The seal finds no\nanchor here."})
      return true
    end

    local amap=mod.save:get("case_anchor_map")
    local ax=tonumber(mod.save:get("case_anchor_x"))
    local ay=tonumber(mod.save:get("case_anchor_y"))
    local correct=(amap==ow.map.id and ax==fx and ay==fy)
    local now=love.timer and love.timer.getTime and love.timer.getTime() or 0
    ghostContactFxUntil=now+1.35

    if correct then
      playDistortedSpiritCry(ow)
      mod.save:set("enraged_candle_locked",false)
      mod.save:set("haunt_resolved",true)
      mod.save:set("case_state","CLEANSED")
      if mod.save:get("warden_case_official")==true then
        -- Final scoring/identification happens only when the player chooses to
        -- leave the private tower and is returned directly to Ezra.
        mod.save:set("warden_case_result_species",caseSpecies())
      end
      mod.save:set("ghost_present",false)
      mod.save:set("ghost_x",nil); mod.save:set("ghost_y",nil); mod.save:set("ghost_map",nil)
      mod.save:set("ghost_target_map",nil)
      clearDevGhostVisual()
      showPaged(ow,{"The SPIRIT SEAL\nbegins to glow..."},function()
        local t=love.timer and love.timer.getTime and love.timer.getTime() or 0
        cleansingWhiteUntil=t+0.48
        cleansingRevealAt=t+0.50
        cleansingRevealWorld=ow
      end)
      return true
    end

    -- A wrong seal does not instantly fail the case.  It enrages the spirit,
    -- maxes activity, starts a hunt on the player's floor, and leaves escape
    -- open.  TERRIFAINT / party-life consequences attach to this later.
    mod.save:set("case_wrong_seal",true)
    mod.save:set("case_state","ENRAGED HUNT")
    local packedCandle = mod._wardenHasTool and mod._wardenHasTool("CANDLE")
    local packedPowerlight = mod._wardenHasTool and mod._wardenHasTool("POWERLIGHT")
    mod.save:set("dev_candle",false)
    mod.save:set("dev_powerlight",false)
    mod.save:set("enraged_candle_locked",true)
    mod.save:set("haunt_activity",100)
    mod.save:set("haunt_false_exit",true)
    -- Do not teleport the spirit when the player guesses wrong.  The hunt
    -- begins from the spirit's real current position, so the player's prior
    -- awareness of where it was remains meaningful.  Only recover a missing
    -- spirit if the simulation somehow has none.
    if not ghostPresent() then
      mod.save:set("ghost_target_map",ow.map.id)
      spawnEnragedGhostBehind(ow)
      mod.save:set("ghost_target_map",nil)
    end
    ghostContactBlackoutUntil=now+0.55
    ghostContactFxUntil=now+1.8
    enragedMoveClock=0
    playDistortedSpiritCry(ow)
    playEnragedMusic()
    local wrongSealPages={
      "The seal turns ice\ncold in your hand!",
      "Wrong anchor."
    }
    if packedCandle and packedPowerlight then
      wrongSealPages[#wrongSealPages+1]="Both lights die.\nThey won't restart."
    elseif packedPowerlight then
      wrongSealPages[#wrongSealPages+1]="Your POWERLIGHT dies.\nIt won't restart."
    elseif packedCandle then
      wrongSealPages[#wrongSealPages+1]="Your CANDLE dies.\nIt won't relight."
    end
    wrongSealPages[#wrongSealPages+1]="Something in the\ntower is furious."
    wrongSealPages[#wrongSealPages+1]="RUN!"
    showPaged(ow,wrongSealPages)
    return true
  end
  mod._wardenUseSpiritSeal=function(ow) return useSpiritSeal(ow) end


  -- Exact first-person inspection surfaces. The 1F reception is intentionally
  -- excluded; upper-floor desk/phone pairs share office scenes, while each
  -- microphone/papers pair shares one studio scene. No generic counter or
  -- solid-furniture rule can enter first-person inspection.
  mod._wardenDeskCells={
    ["WARDEN_RADIO_TOWER_2F:15,5"]="2F-STUDIO", ["WARDEN_RADIO_TOWER_2F:16,5"]="2F-STUDIO",
    ["WARDEN_RADIO_TOWER_2F:15,6"]="2F-STUDIO", ["WARDEN_RADIO_TOWER_2F:16,6"]="2F-STUDIO",
    ["WARDEN_RADIO_TOWER_3F:3,3"]="3F-A", ["WARDEN_RADIO_TOWER_3F:4,3"]="3F-A",
    ["WARDEN_RADIO_TOWER_3F:7,3"]="3F-B", ["WARDEN_RADIO_TOWER_3F:8,3"]="3F-B",
    ["WARDEN_RADIO_TOWER_3F:2,6"]="3F-C", ["WARDEN_RADIO_TOWER_3F:3,6"]="3F-C",
    ["WARDEN_RADIO_TOWER_3F:6,6"]="3F-D", ["WARDEN_RADIO_TOWER_3F:7,6"]="3F-D",
    ["WARDEN_RADIO_TOWER_3F:10,6"]="3F-E", ["WARDEN_RADIO_TOWER_3F:11,6"]="3F-E",
    ["WARDEN_RADIO_TOWER_4F:5,3"]="4F-A", ["WARDEN_RADIO_TOWER_4F:6,3"]="4F-A",
    ["WARDEN_RADIO_TOWER_4F:1,5"]="4F-B", ["WARDEN_RADIO_TOWER_4F:2,5"]="4F-B",
    ["WARDEN_RADIO_TOWER_4F:7,5"]="4F-C", ["WARDEN_RADIO_TOWER_4F:8,5"]="4F-C",
    ["WARDEN_RADIO_TOWER_4F:15,5"]="4F-STUDIO", ["WARDEN_RADIO_TOWER_4F:16,5"]="4F-STUDIO",
    ["WARDEN_RADIO_TOWER_4F:15,6"]="4F-STUDIO", ["WARDEN_RADIO_TOWER_4F:16,6"]="4F-STUDIO",
    ["WARDEN_RADIO_TOWER_5F:1,3"]="5F-A", ["WARDEN_RADIO_TOWER_5F:2,3"]="5F-A",
    ["WARDEN_RADIO_TOWER_5F:4,5"]="5F-B", ["WARDEN_RADIO_TOWER_5F:5,5"]="5F-B",
  }

  -- DEV10d: one opaque, widescreen-aware inspection state owns input and
  -- suspends the ordinary roaming/contact systems. Its explicit danger rolls
  -- are the only way the ghost can act while this state is on the stack.
  do
    local Chrome = require("src.ui.gen2.Chrome")
    local Assets = require("src.render.Assets")
    local officeSpots = {
      {name="TELEPHONE",x=46,y=68,w=20,h=13,clue=true,texts={
        "The desk phone has been disconnected at the wall.",
        "A faded label beneath the receiver reads STUDIO 5.",
        "An old extension list is taped beneath the phone."},nearby={
        "The dead receiver clicks once against your ear.",
        "A breath whispers through the disconnected line."}},
      {name="PAPERS",x=66,y=77,w=50,h=9,clue=true,texts={
        "Unfinished program notes circle the final segment.",
        "A weather report stops halfway through a sentence.",
        "A memo schedules repairs that were never completed."},nearby={
        "One page lifts and settles without a draft.",
        "Fresh black ink spreads across an old signature."}},
      {name="PLANT",x=59,y=34,w=34,h=42,clue=true,texts={
        "The office plant is dry and brittle from neglect.",
        "A plastic care tag is half buried in the soil.",
        "An empty fertilizer packet rests behind the pot."},nearby={
        "One dead leaf slowly bends toward your hand.",
        "The brittle stems tick against the pot by themselves."}},
      {name="SHELVING",x=117,y=33,w=26,h=59,clue=true,texts={
        "Old broadcast gear fills the narrow shelves.",
        "A reel is labeled LAVENDER NIGHT SERVICE.",
        "Station manuals are stacked by department."},nearby={
        "A powerless speaker cone flexes once in silence.",
        "A dead indicator lamp blinks behind the glass."}},
      {name="WINDOW",x=8,y=14,w=36,h=61,clue=true,texts={
        "Dust has gathered thickly between the closed blinds.",
        "Lavender Town is barely visible through the slats.",
        "The blind cord has been knotted around a wall hook."},nearby={
        "One blind slat trembles though the air is still.",
        "Three quiet taps sound from the other side of the glass."}},
      {name="DRAWERS",x=52,y=86,w=63,h=31,clue=true,texts={
        "The top drawer sticks where the runners have rusted.",
        "Old keys share a tray with a blank employee badge.",
        "A maintenance log records years of power outages."},nearby={
        "A lower drawer eases open after you release it.",
        "A hollow knock answers from inside the cabinet."}},
    }
    local studioSpots = {
      {name="GLASS",x=29,y=5,w=76,h=53,clue=true,texts={
        "Thick studio glass separates this booth from the floor.",
        "Old fingerprints cloud the edges of the glass panes.",
        "A faded safety notice is fixed beneath the window."},nearby={
        "A reflection crosses the glass after the room is still.",
        "Three soft taps answer from beyond the studio glass."}},
      {name="EQUIPMENT",x=8,y=38,w=35,h=27,clue=true,texts={
        "A rack of broadcast equipment sits powered down.",
        "Channel labels mark news, music, and emergency feeds.",
        "Dust fills the gaps around the old control switches."},nearby={
        "A dead level meter jumps once without a signal.",
        "One powerless dial turns a fraction by itself."}},
      {name="DRAWERS",x=8,y=65,w=35,h=43,clue=true,texts={
        "The storage drawers are packed with blank tape labels.",
        "Spare cables and pencils fill the lower drawers.",
        "An inventory sheet lists equipment long since removed."},nearby={
        "A metal drawer slides open after you step away.",
        "Something scratches once inside the closed cabinet."}},
      {name="MICROPHONE",x=74,y=59,w=22,h=29,clue=true,texts={
        "A heavy studio microphone is fixed to the desk.",
        "The microphone's station plate has been polished smooth.",
        "A brittle foam cover rests beside the microphone."},nearby={
        "The dead microphone clicks on by itself.",
        "A breath fogs the microphone's metal grille."}},
      {name="PAPERS",x=43,y=78,w=79,h=19,clue=true,texts={
        "Loose scripts cover most of the broadcast desk.",
        "A program rundown ends before the final time slot.",
        "Corrections in red pencil cover an old news script."},nearby={
        "A loose script turns one page without a draft.",
        "A new line appears beneath the final broadcast cue."}},
      {name="CHAIRS",x=120,y=52,w=31,h=59,clue=true,texts={
        "A padded studio chair faces the microphone.",
        "The chair's vinyl has split along one armrest.",
        "A second chair has been pushed against the wall."},nearby={
        "The studio chair slowly swivels toward the microphone.",
        "The empty seat cushion sinks as though bearing weight."}},
      {name="DESK",x=43,y=97,w=83,h=31,clue=true,texts={
        "The broadcast desk is worn smooth around the microphone.",
        "Cable channels have been cut through the heavy desktop.",
        "Coffee rings overlap years of handwritten time marks."},nearby={
        "A vibration runs through the desk beneath your hand.",
        "A muted thump answers from inside the hollow desk."}},
    }
    mod._wardenInspectionHints={
      JIGGLYPUFF={"A log mentions listeners dozing off during a soft melody.","Someone underlined LULLABY on an old program sheet."},
      MAGNEMITE={"Metal filings cling in a ring around one loose screw.","A repair note blames recurring magnetic interference."},
      PORYGON={"A printout ends in rows of broken square symbols.","A transfer log records corrupted digital data."},
      MURKROW={"A small black feather is caught behind the blinds.","A note mentions tapping at the glass after sunset."},
      CUBONE={"A pale crescent has been gouged into the desktop.","The night log mentions a small, solitary knocking sound."},
      HAUNTER={"A report says recorded shadows did not match the crew.","A technician circled several bursts of unexplained laughter."},
    }
    -- Kept visible to the isolated audit harness so every authored office and
    -- studio response is passed through the exact temporary-panel wrapper.
    mod._wardenInspectionTextSources={office=officeSpots,studio=studioSpots,
      hints=mod._wardenInspectionHints}
    -- One modest, permanent pickup per upper-floor desk. The fixed mapping
    -- makes the hiding place stable across exits and future investigations.
    mod._wardenInspectionRewards={
      ["3F-A"]={spot="DRAWERS",item="POTION"},
      ["3F-B"]={spot="SHELVING",item="ANTIDOTE"},
      ["3F-C"]={spot="PLANT",item="BERRY"},
      ["3F-D"]={spot="DRAWERS",item="POKE_BALL"},
      ["3F-E"]={spot="SHELVING",item="REPEL"},
      ["4F-A"]={spot="DRAWERS",item="AWAKENING"},
      ["4F-B"]={spot="PLANT",item="BERRY"},
      ["4F-C"]={spot="SHELVING",item="ETHER"},
      ["5F-A"]={spot="DRAWERS",item="SUPER_POTION"},
      ["5F-B"]={spot="SHELVING",item="SUPER_REPEL"},
      ["2F-STUDIO"]={spot="DRAWERS",item="PARLYZ_HEAL"},
      ["4F-STUDIO"]={spot="EQUIPMENT",item="GREAT_BALL"},
    }

    mod._wardenOpenInspection = function(ow,deskKey)
      if mod._wardenInspection then return true end
      if mod.save:get("case_state")=="ENRAGED HUNT" then
        ow:showText("No time to search!\nRUN!"); return true
      end
      local sceneKind=(deskKey=="2F-STUDIO" or deskKey=="4F-STUDIO") and "STUDIO" or "OFFICE"
      local scenePath=sceneKind=="STUDIO" and "assets/inspection_studio.png" or "assets/inspection_desk.png"
      local spots=sceneKind=="STUDIO" and studioSpots or officeSpots
      local ok, scene=pcall(mod.assets.image,mod.assets,scenePath)
      if not ok then
        mod.log:warn("Desk inspection image unavailable: "..tostring(scene))
        ow:showText("Too dark to inspect\nthe desk."); return true
      end
      scene:setFilter("nearest","nearest")
      deskKey=tostring(deskKey or ((ow.map and ow.map.id) or "TOWER")..":DESK")
      mod._wardenInspectionClocks=mod._wardenInspectionClocks or {}
      local clock=mod._wardenInspectionClocks[deskKey]
      if not clock then
        clock={age=0,tension=0,nextScare=math.random(20,34),nextDanger=60,seen={}}
        mod._wardenInspectionClocks[deskKey]=clock
      end
      clock.seen=clock.seen or {}
      local state={isOpaque=true,x=80,y=82,clock=clock,scare=0,
        messagePages={},messagePage=0,messageTimer=0,deskKey=deskKey,sceneKind=sceneKind}
      local def=ow.game.data.pokemon[caseSpecies()]
      if def and def.spriteFront then
        local loaded,img=pcall(Assets.image,def.spriteFront)
        if loaded then
          state.spirit=img
          -- Frontpics may retain opaque white paper; discard it so the scare
          -- is the species silhouette, never a black rectangular sprite sheet.
          local compiled, shader=pcall(love.graphics.newShader, [[
            vec4 effect(vec4 color, Image tex, vec2 uv, vec2 screen) {
              vec4 p = Texel(tex, uv);
              if (min(p.r, min(p.g, p.b)) > 0.95) discard;
              return vec4(0.0, 0.0, 0.0, p.a);
            }
          ]])
          if compiled then state.silhouetteShader=shader end
        end
      end

      function state:setMessage(chunks,seconds)
        local pages={}
        for _,chunk in ipairs(chunks or {}) do
          -- The continuation arrow occupies the panel's eighteenth interior
          -- cell. Wrap every authored response to the remaining 17 cells using
          -- Chrome's real-font measurement, so the arrow can never overwrite
          -- the final letter (the reported "buried i▼" / "from thi▼" bug).
          local lines=Chrome.wrap(tostring(chunk or ""),17)
          if #lines==0 then lines[1]="" end
          for i=1,#lines,2 do
            pages[#pages+1]=(lines[i] or "")..(lines[i+1] and ("\n"..lines[i+1]) or "")
          end
        end
        self.messagePages=pages
        self.messagePage=#pages>0 and 1 or 0
        self.messageTimer=#pages>0 and (seconds or 3) or 0
      end

      function state:advanceMessage()
        if self.messagePage<=0 then return false end
        if self.messagePage<#self.messagePages then
          self.messagePage=self.messagePage+1; self.messageTimer=3
        else
          self.messagePages={}; self.messagePage=0; self.messageTimer=0
        end
        return true
      end

      function state:inspectHotspot()
        local found
        for _,spot in ipairs(spots) do
          if self.x>=spot.x and self.x<spot.x+spot.w and self.y>=spot.y and self.y<spot.y+spot.h then
            found=spot; break
          end
        end
        if not found then self:setMessage({"Only dust and shadows here."}); return end
        -- Every press repeats a useful area description. Only the first check
        -- of this hotspot for this canonical desk can raise activity or roll
        -- clue/species evidence, so repeated reads cannot farm progression.
        local firstCheck=not self.clock.seen[found.name]
        if firstCheck then
          self.clock.seen[found.name]=true
          registerInvestigationInteraction(ow)
        end
        local reward=mod._wardenInspectionRewards[self.deskKey]
        if reward and reward.spot==found.name then
          local takenKey="inspection_reward_taken_"..self.deskKey
          if mod.save:get(takenKey)==true then
            local emptyText=found.name=="DRAWERS" and "You already took the item from this drawer."
              or (found.name=="SHELVING" and "You already took the item from this shelf."
              or (found.name=="EQUIPMENT" and "You already took the item from this equipment rack."
              or "You already took the item buried in this soil."))
            self:setMessage({emptyText})
            return
          end
          local game=ow.game
          local itemDef=game and game.data and game.data.items and game.data.items[reward.item]
          local itemName=tostring((itemDef and itemDef.name) or reward.item):gsub("_"," ")
          if game and game.save and require("src.inventory.Bag").add(game.save,reward.item,1,game.data) then
            mod.save:set(takenKey,true)
            playNamed(ow,"Sfx_Item",1)
            self:setMessage({"You found "..itemName.." hidden here!"})
          else
            self:setMessage({itemName.." is hidden here, but your PACK is full."})
          end
          return
        end
        local followupEligible=found.name=="GLASS" or found.name=="WINDOW"
          or found.name=="PAPERS" or found.name=="EQUIPMENT"
          or found.name=="DESK" or found.name=="SHELVING"
          or found.name=="MICROPHONE" or found.name=="TELEPHONE"
        if followupEligible then
          local followup=mod._wardenTryFollowup(ow,found.name,self.deskKey..":"..found.name,45)
          if followup then self:setMessage(followup); return end
        end
        local key="inspection_checked_"..found.name
        if firstCheck and found.clue and mod.save:get(key)~=true then
          mod.save:set(key,true)
          if math.random(100)<=18 then
            local clue=discoverAnchorClue()
            if clue then
              self:setMessage({"A penciled note reads: "..cluePhrase(clue)})
              return
            end
          end
        end
        if firstCheck and math.random(100)<=10 then
          local hints=mod._wardenInspectionHints[caseSpecies()]
          if hints and #hints>0 then self:setMessage({hints[math.random(#hints)]}); return end
        end
        local distance=ghostDistanceFrom(ow,ow.player.cellX,ow.player.cellY)
        local pool=(distance and distance<=5 and math.random(100)<=55) and found.nearby or found.texts
        self:setMessage({pool[math.random(#pool)]})
      end

      function state:placeGhostInRoom(message)
        -- Flood-fill the walkable component containing the player, then choose
        -- a non-warp cell at least three steps away. This prevents an inspection
        -- consequence from dropping the ghost directly onto a stair/warp tile.
        local map,p=ow.map,ow.player
        if not (map and p) then return false end
        local frontier={{p.cellX,p.cellY}}
        local seen={[p.cellY*1024+p.cellX]=true}
        local choices,head={},1
        while head<=#frontier do
          local c=frontier[head]; head=head+1
          for _,n in ipairs({{c[1]+1,c[2]},{c[1]-1,c[2]},{c[1],c[2]+1},{c[1],c[2]-1}}) do
            local x,y=n[1],n[2]
            local sk=y*1024+x
            if not seen[sk] and map:inBounds(x,y) and map:isWalkable(x,y) then
              seen[sk]=true; frontier[#frontier+1]=n
              local warp=map.isWarpTileCell and map:isWarpTileCell(x,y)
              if not warp and validGhostCell(ow,x,y) and manhattan(p.cellX,p.cellY,x,y)>=3 then
                choices[#choices+1]={x=x,y=y}
              end
            end
          end
        end
        if #choices==0 then return false end
        local cell=choices[math.random(#choices)]
        mod.save:set("ghost_present",false)
        setGhostPos(cell.x,cell.y,map.id)
        mod.save:set("ghost_present",true); mod.save:set("ghost_awakened",true)
        mod.save:set("ghost_target_map",nil)
        if message then self:setMessage({message}) end
        return true
      end

      function state:pullGhostCloser()
        local current=ow.map and ow.map.id
        local source=ghostPresent() and select(3,ghostPos()) or mod.save:get("ghost_target_map")
        local currentIndex,sourceIndex
        for i,id in ipairs(HAUNTED_FLOORS) do
          if id==current then currentIndex=i end
          if id==source then sourceIndex=i end
        end
        sourceIndex=sourceIndex or math.random(#HAUNTED_FLOORS)
        if not currentIndex then return false end
        if sourceIndex==currentIndex then
          if ghostPresent() and select(3,ghostPos())==current then
            moveGhostTowardPlayer(ow,false)
          else
            self:placeGhostInRoom()
          end
          self:setMessage({"Footsteps scrape closer across this floor."})
          addActivity(1)
          return true
        end
        if sourceIndex<currentIndex then sourceIndex=sourceIndex+1
        elseif sourceIndex>currentIndex then sourceIndex=sourceIndex-1 end
        if sourceIndex==currentIndex then
          self:placeGhostInRoom("Footsteps stop somewhere on this floor.")
        else
          mod.save:set("ghost_present",false)
          mod.save:set("ghost_x",nil); mod.save:set("ghost_y",nil); mod.save:set("ghost_map",nil)
          mod.save:set("ghost_target_map",HAUNTED_FLOORS[sourceIndex])
          self:setMessage({"A distant door slams one floor nearer."})
        end
        addActivity(1)
        return true
      end

      function state:rollDanger()
        local st=activityStage()
        local chance=st=="LINGER" and 15 or (st=="WANDERING" and 30 or (st=="AGITATED" and 48 or 68))
        if math.random(100)>chance then return end
        local roll=math.random(100)
        if st=="LINGER" then
          if roll<=80 then self:pullGhostCloser()
          else
            self:placeGhostInRoom("Something enters the room. The air tightens.")
          end
        elseif st=="WANDERING" then
          if roll<=55 then self:pullGhostCloser()
          elseif roll<=85 then
            self:placeGhostInRoom("Something enters the room. The air tightens.")
          else self.exitPresence=true; self:setMessage({"A shape moves just beyond the flashlight."}) end
        elseif st=="AGITATED" then
          if roll<=35 then self:pullGhostCloser()
          elseif roll<=65 then
            self:placeGhostInRoom("The presence has reached this floor.")
          else self.exitPresence=true; self:setMessage({"A shape waits beyond the edge of the light."}) end
        else
          if roll<=20 then self:pullGhostCloser()
          elseif roll<=45 then
            self:placeGhostInRoom("The presence is here now.")
          elseif roll<=80 then self.exitPresence=true; self:setMessage({"A black shape waits behind you."})
          else
            self.exitReason="attack"
            ow.game.stack:pop()
          end
        end
      end

      function state:exit()
        mod._wardenInspection=nil
        local now=love.timer and love.timer.getTime and love.timer.getTime() or 0
        contactLockUntil=now+1
        enragedMoveClock=0
        if self.exitReason=="attack" then
          contactLockUntil=now+2.5
          manifestationUntil=now+1.25
          ghostContactFxUntil=now+0.9
          playDistortedSpiritCry(ow)
          if mod._wardenHasTool and mod._wardenHasTool("WARDING CHARM")
            and mod.save:get("warden_charm_used")~=true then
            mod.save:set("warden_charm_used",true)
            playNamed(ow,"Sfx_Shine",1)
            showPaged(ow,{"The WARDING CHARM\nflashes white!","It cracks apart.\nTERRIFAINT fails!"})
            if not ghostPresent() or select(3,ghostPos())~=ow.map.id then
              mod.save:set("ghost_present",false); mod.save:set("ghost_target_map",ow.map.id)
              spawnInvisibleGhost(ow); mod.save:set("ghost_target_map",nil)
            end
            recoilGhostSameFloor(ow,5,8)
            return
          end
          local hit,failed=terrifaint(ow)
          local pages={"GHOST manifests!","TERRIFAINT tears\nthrough your party!"}
          pages[#pages+1]=(hit==1) and "1 POKEMON\ncollapsed!" or (tostring(hit).." POKEMON\ncollapsed!")
          if failed then
            pages[#pages+1]="No one can go on.\nThe hunt is over."
            showPaged(ow,pages,function() failInvestigation(ow) end)
          else
            pages[#pages+1]="It fades back into\nthe tower."
            showPaged(ow,pages)
            if not ghostPresent() or select(3,ghostPos())~=ow.map.id then
              mod.save:set("ghost_present",false); mod.save:set("ghost_target_map",ow.map.id)
              spawnInvisibleGhost(ow); mod.save:set("ghost_target_map",nil)
            end
            recoilGhostSameFloor(ow,4,7)
          end
        elseif self.exitPresence and mod.save:get("haunt_resolved")~=true then
          hauntFxKind="FALSE_PRESENCE"; hauntFxStart=now; hauntFxUntil=now+1.35
          hauntFxSeed=math.random(0,99)
          if spawnFalsePresence(ow,1,1) then playNamed(ow,"Sfx_MeanLook",nil) end
        end
      end

      function state:update(dt)
        local input=ow.game.input
        if input:wasPressed("b") then self.exitReason="leave"; ow.game.stack:pop(); return end
        dt=math.min(dt or 1/60,0.1)
        self.clock.age=self.clock.age+dt
        self.clock.tension=self.clock.tension+dt
        if self.clock.tension>=20 then self.clock.tension=self.clock.tension-20; addActivity(1) end
        self.scare=math.max(0,self.scare-dt)
        if self.messagePage>0 then
          self.messageTimer=self.messageTimer-dt
          if self.messageTimer<=0 then self:advanceMessage() end
        end
        if self.clock.age>=self.clock.nextScare then
          self.clock.nextScare=self.clock.age+math.random(20,34)
          local near=ghostDistanceFrom(ow,ow.player.cellX,ow.player.cellY)
          if near and near<=5 and math.random(100)<=math.min(60,12+math.floor(activity()/3)) then
            self.scare=0.65; self.glass=math.random(2)==1
            self.sx=math.max(8,math.min(124,self.x+18)); self.sy=math.max(4,math.min(108,self.y-20))
            addActivity(1)
            playNamed(ow,"Sfx_Nightmare",nil)
          end
        end
        if self.clock.age>=self.clock.nextDanger then
          self.clock.nextDanger=self.clock.age+math.random(10,16)
          self:rollDanger()
          if self.exitReason=="attack" then return end
        end
        local dx=(input:isDown("right") and 1 or 0)-(input:isDown("left") and 1 or 0)
        local dy=(input:isDown("down") and 1 or 0)-(input:isDown("up") and 1 or 0)
        local speed=dx~=0 and dy~=0 and 29 or 40
        self.x=math.max(9,math.min(150,self.x+dx*speed*dt))
        self.y=math.max(1,math.min(142,self.y+dy*speed*dt))
        if input:wasPressed("a") then
          if not self:advanceMessage() then self:inspectHotspot() end
        end
      end

      function state:draw()
        local G=love.graphics
        G.push("all")
        G.setShader(); G.setColor(0,0,0,1); G.rectangle("fill",0,0,160,144)
        -- Contain the whole square source in the GB panel. The old 160px-tall
        -- draw clipped its bottom 16px and made the drawers barely reachable.
        G.setColor(1,1,1,1); G.draw(scene,8,0,0,144/scene:getWidth(),144/scene:getHeight())
        if self.scare>0 and self.spirit then
          G.setColor(0,0,0,1)
          local x,y=self.glass and 17 or self.sx,self.glass and 36 or self.sy
          G.setShader(self.silhouetteShader)
          G.draw(self.spirit,x,y,0,25/self.spirit:getWidth(),25/self.spirit:getHeight())
          G.setShader()
          if self.glass then
            G.setColor(0.02,0.08,0.09,1)
            for yy=36,61,3 do G.rectangle("fill",x,yy,25,1) end
          end
        end
        -- Four-pixel cells keep the beam chunky and exactly inside the image.
        for y=0,140,4 do for x=8,148,4 do
          local d=((x+2-self.x)^2+(y+2-self.y)^2)^0.5
          local a=d<17 and 0 or (d<25 and 0.48 or 0.96)
          G.setColor(0,0,0,a); G.rectangle("fill",x,y,4,4)
        end end
        G.setColor(0.75,0.8,0.65,1)
        G.rectangle("fill",math.floor(self.x)-1,math.floor(self.y),3,1)
        G.rectangle("fill",math.floor(self.x),math.floor(self.y)-1,1,3)
        -- The panel exists only while a response is live. Chrome.wrap measured
        -- every line against the real font's 144px interior before this draw.
        if self.messagePage>0 and self.messagePages[self.messagePage] then
          Chrome.box(0,13,20,5)
          local n=0
          for line in (self.messagePages[self.messagePage].."\n"):gmatch("(.-)\n") do
            Chrome.print(line,1,14+n*2); n=n+1; if n==2 then break end
          end
          if self.messagePage<#self.messagePages then Chrome.print("▼",18,16) end
        end
        G.pop()
      end

      -- Paint the actual host-window surround black at every integer zoom.
      -- draw() remains the classic 160x144 path for engines without this seam.
      function state:drawsWidescreen() return true end
      function state:drawWidescreen(winW,winH)
        local G=love.graphics
        G.push("all")
        G.setColor(0,0,0,1); G.rectangle("fill",0,0,winW,winH)
        local scale=Chrome.fitScale(winW,winH)
        local ox,oy=Chrome.fitOrigin(winW,winH,scale)
        G.translate(ox,oy); G.scale(scale,scale)
        Chrome.clipTo(0,0,160,144)
        self:draw()
        G.pop()
      end

      state:setMessage({"D-PAD: MOVE LIGHT\nA: CHECK B: LEAVE"})
      mod._wardenInspection=state
      ow.game.stack:push(state)
      return true
    end

    mod._wardenConfirmInspection = function(ow,deskKey)
      if mod._wardenInspectionPrompt then return true end
      if mod.save:get("case_state")=="ENRAGED HUNT" then
        ow:showText("No time to search!\nRUN!"); return true
      end
      mod._wardenInspectionPrompt=true
      showPaged(ow,{"Inspect the work\ndesk?"},function()
        ow:askYesNo(function(yes)
          mod._wardenInspectionPrompt=false
          if yes then mod._wardenOpenInspection(ow,deskKey) end
        end)
      end,true)
      return true
    end
  end

  local function hauntedFurniturePress(ow)
    if not hauntedNow() or mod.save:get("haunt_resolved") == true then return false end
    if ow:facingObject() then return false end
    local p=ow.player
    local delta=({up={0,-1},down={0,1},left={-1,0},right={1,0}})[p.facing or "down"]
    local fx,fy=p.cellX+delta[1],p.cellY+delta[2]
    local deskKey=mod._wardenDeskCells[tostring(ow.map.id)..":"..tostring(fx)..","..tostring(fy)]
    if deskKey then
      return mod._wardenConfirmInspection(ow,deskKey)
    end
    local c=ow.map:cellCollision(fx,fy)
    local bg=nil
    for _,ev in ipairs(WARDEN_BG_EVENTS[ow.map.id] or {}) do
      if tonumber(ev.x)==fx and tonumber(ev.y)==fy then bg=ev; break end
    end

    -- Broad investigation surface: known household collisions plus every BG
    -- event and most solid interior props. This deliberately includes plants.
    -- Known Crystal household collision IDs. Keep identity specific where the
    -- retail map exposes it; unknown BG events still fall back to furniture.
    -- These are Crystal's actual TileCollisionStdScripts IDs.  DEV6a had
    -- these shifted/mislabelled (0x91 was called TV and 0x9d Plant), which is
    -- why bookshelves talked about screens and windows talked about leaves.
    local known={
      [0x90]="desk",     -- COLL_COUNTER: desks/counters in Radio Tower
      [0x91]="bookcase", -- COLL_BOOKSHELF
      [0x93]="pc",       -- COLL_PC
      [0x94]="radio",    -- COLL_RADIO
      [0x95]="map",      -- COLL_TOWN_MAP
      [0x96]="shelf",    -- COLL_MART_SHELF
      [0x97]="tv",       -- COLL_TV
      [0x98]="desk",     -- alternate counter collision
      [0x9d]="window",   -- COLL_WINDOW
      [0x9f]="incense",  -- COLL_INCENSE_BURNER
    }
    local kind=known[c]
    if not kind and bg then
      local key=string.lower(tostring(bg.scriptKey or bg.name or ""))
      if key:find("plant",1,true) or key:find("flower",1,true) then kind="plant"
      elseif key:find("tv",1,true) then kind="tv"
      elseif key:find("book",1,true) or key:find("shelf",1,true) then kind="bookcase"
      elseif key:find("window",1,true) then kind="window"
      elseif key:find("radio",1,true) then kind="radio"
      elseif key:find("computer",1,true) or key:find("pc",1,true) then kind="pc"
      elseif key:find("mic",1,true) then kind="microphone"
      elseif key:find("phone",1,true) or key:find("telephone",1,true) then kind="phone"
      elseif key:find("cabinet",1,true) or key:find("drawer",1,true) then kind="cabinet"
      elseif key:find("poster",1,true) or key:find("picture",1,true) or key:find("notice",1,true) then kind="poster"
      elseif key:find("glass",1,true) or key:find("mirror",1,true) then kind="glass"
      elseif key:find("paper",1,true) or key:find("memo",1,true) or key:find("form",1,true) then kind="papers"
      elseif key:find("desk",1,true) or key:find("counter",1,true) then kind="desk"
      else kind="fixture" end
    end

    -- The Radio Tower contains a lot of decorative 16x16 props (phones,
    -- microphones, papers, cabinets, plants) that are not vanilla BG events
    -- and do not use one of Crystal's eight standard A-press collision IDs.
    -- During an investigation, let blocked non-warp scenery participate even
    -- when Crystal does not expose a semantic BG event for it. Unknown props
    -- deliberately use neutral wording; never guess that scenery is broadcast
    -- equipment just because it is solid.
    if not kind and ow.map and ow.map.isWalkable and not ow.map:isWalkable(fx,fy) then
      local isWarp = ow.map.isWarp and ow.map:isWarp(fx,fy)
      if not isWarp then kind="fixture" end
    end
    kind = radioTowerPropKind(ow.map.id, fx, fy, kind, ow.map)
    if not kind then return false end

    local followupEligible=kind=="pc" or kind=="glass" or kind=="papers"
      or kind=="equipment" or kind=="microphone" or kind=="phone" or kind=="desk"
    if followupEligible then
      local followup=mod._wardenTryFollowup(ow,kind,tostring(ow.map.id)..":"..fx..","..fy,35)
      if followup then showPaged(ow,followup); return true end
    end
    registerInvestigationInteraction(ow)
    local d=ghostDistanceFrom(ow,fx,fy)
    local pages=proximityText(kind,d)
    showPaged(ow,pages)
    return true
  end

  -- The private tower has no retail outward warps. Leaving is handled by the
  -- explicit 1F Ready to leave? prompt, so Goldenrod's door logic is never
  -- involved in a Spirit Warden case.

  -- The private Radio Tower strips Goldenrod's story trainers at registration time.  The public
  -- pre-battle hook is kept as a backstop, but Gen2 can engage trainers through
  -- sight/script paths before some mod contexts are populated, so we also hard-
  -- guard the overworld methods below while the investigation instance is live.
  mod.hooks:wrap("trainer.before_battle", function(next, game, context, continue)
    if hauntedNow() then
      continue({ cancel = true })
      return true
    end
    return next(game, context, continue)
  end)

  -- Story scripts can try to re-appear masked Rocket NPCs after map entry.
  -- Ignore those appear commands only while the tower is being used as a
  -- Spirit Warden investigation; retail progression remains untouched outside it.
  if Gen2World and not Gen2World._spiritWardenAppearPatched then
    Gen2World._spiritWardenAppearPatched = true
    local vanillaAppearObject = Gen2World.appearObject
    Gen2World.appearObject = function(world, objectId)
      if hauntedNow() and world and world.map and isHauntedMapId(world.map.id) then
        return
      end
      return vanillaAppearObject(world, objectId)
    end
  end

  -- Wrong-seal ENRAGED HUNT pursuit runs in real time rather than waiting
  -- for world.stepped. Blocking dialogue/menus pause the chase.
  if Gen2World and not Gen2World._wardenEnragedRealtimeStep then
    Gen2World._wardenEnragedRealtimeStep=true
    local vanillaWorldStep=Gen2World.step
    Gen2World.step=function(world,...)
      if mod._wardenInspection then return end
      local result=vanillaWorldStep(world,...)
      local clockNow=love.timer and love.timer.getTime and love.timer.getTime() or 0
      mod._wardenUpdateUv(world,clockNow)
      maybeEzraNightCall(world)
      if (mod._wardenReturnResolutionAt or 0)>0 and clockNow>=(mod._wardenReturnResolutionAt or 0) and mod._wardenReturnResolutionWorld then
        local rw=mod._wardenReturnResolutionWorld
        local busy=false
        if rw.busy then local ok,v=pcall(rw.busy,rw); busy=ok and v or false end
        if rw.map and rw.map.id==MAP_ID and not busy then
          mod._wardenReturnResolutionAt=0
          mod._wardenReturnResolutionWorld=nil
          resolveReturnedCase(rw)
        end
      end
      if falsePresenceNpcId and not (hauntFxKind=="FALSE_PRESENCE" and clockNow<hauntFxUntil) then
        clearFalsePresence()
      end
      if falseCalmWasActive and clockNow>=hauntFxUntil and hauntFxKind=="FALSE_CALM" then
        falseCalmWasActive=false
        local rw=falseCalmWorld or world
        falseCalmWorld=nil
        -- The silence breaks with a warped sting, then the map's haunting
        -- ambience snaps back on.
        local old=MANIFEST_SFX.__GENERIC
        MANIFEST_SFX.__GENERIC={"Sfx_Nightmare","Sfx_Curse","Sfx_Screech","Sfx_MeanLook"}
        playManifestSfx(rw,"__GENERIC")
        MANIFEST_SFX.__GENERIC=old
        local ok,Music=pcall(require,"src.core.Music")
        if ok and Music and Music.playMap and rw and rw.game and rw.game.data and rw.map then
          pcall(Music.playMap,rw.game.data,rw.map.id,false,false,false)
        end
      end
      if restoreMusicAt>0 and clockNow>=restoreMusicAt and restoreMusicWorld then
        local rw=restoreMusicWorld
        restoreMusicAt=0; restoreMusicWorld=nil
        local ok,Music=pcall(require,"src.core.Music")
        if ok and Music and Music.playMap and rw.game and rw.game.data then
          pcall(Music.playMap,rw.game.data,rw.map.id,false,false,false)
        end
      end
      if cleansingRevealAt>0 and clockNow>=cleansingRevealAt and cleansingRevealWorld then
        local revealWorld=cleansingRevealWorld
        cleansingRevealAt=0; cleansingRevealWorld=nil
        if Pipelines and Pipelines.setLevel then pcall(Pipelines.setLevel,DARK_PIPELINE,0) end
        showPaged(revealWorld,{
          "The signal clears\nthrough the static.",
          "Then... silence.",
          "The spirit has\nbeen set free."
        },function()
          -- Use a real Crystal jingle name, then explicitly restore the map
          -- theme so cleansing never leaves the tower silent.
          playNamed(revealWorld,"Sfx_Fanfare",nil)
          -- Do not restart map music on the same frame as the fanfare; doing
          -- so can stomp the jingle entirely. Give it a short clean window.
          restoreMusicAt=(love.timer and love.timer.getTime and love.timer.getTime() or 0)+1.8
          restoreMusicWorld=revealWorld
        end)
      end
      if enragedGhostFlashUntil>0 and clockNow>=enragedGhostFlashUntil then
        enragedGhostFlashUntil=0
        if mod.save:get("case_state") == "ENRAGED HUNT" then clearDevGhostVisual() end
      end
      if world and world.map and world.player and isHauntedMapId(world.map.id)
        and mod.save:get("case_state") == "ENRAGED HUNT"
        and mod.save:get("haunt_resolved") ~= true then
        local busy=false
        if world.busy then local ok,v=pcall(world.busy,world); busy=ok and v or false end
        if not busy then
          if mod._wardenCheckPlacedTools(world) then
            enragedMoveClock=0
            return result
          end
          if clockNow < enragedFloorGraceUntil then
            enragedMoveClock=0
          else
            enragedMoveClock=enragedMoveClock+(1/60)
          end
          local chaseBeat=clockNow<(tonumber(mod._wardenAshSlowUntil) or 0) and 1.65 or 0.75
          if enragedMoveClock >= chaseBeat then
            enragedMoveClock=enragedMoveClock-chaseBeat
            local gx,gy,gmap=ghostPos()
            if not ghostPresent() or gmap ~= world.map.id then
              mod.save:set("ghost_present",false)
              mod.save:set("ghost_target_map",world.map.id)
              if not spawnEnragedGhostAtEntry(world) then spawnEnragedGhostBehind(world) end
              mod.save:set("ghost_target_map",nil)
              -- First beat after entering a new floor only establishes the
              -- pursuer at the doorway/stair. It does not also gain a tile.
            else
              moveGhostTowardPlayer(world,true)
            end
            -- During the enraged hunt the DEV marker becomes a fleeting
            -- silhouette instead of a permanently visible pursuer.  Each
            -- movement beat has a chance to expose it briefly.
            if math.random(100) <= 42 then
              enragedGhostFlashUntil=clockNow+0.18
              refreshDevGhostVisual(world)
            else
              clearDevGhostVisual()
            end
            local nx,ny,nmap=ghostPos()
            if nmap==world.map.id and nx==world.player.cellX and ny==world.player.cellY then
              spiritContactEffect(world,"HUNTING")
            end
          end
        end
      else enragedMoveClock=0 end
      return result
    end
  end

  -- Investigations deliberately feel heavier. movement.speed is frame count,
  -- so +1/3 duration produces ~25% lower movement speed (16 -> ~21 frames).
  mod.hooks:wrap("movement.speed", function(next, frames, ctx)
    local base=next(frames,ctx)
    if hauntedNow() and mod.save:get("haunt_resolved") ~= true then
      local mult=4/3
      local now=love.timer and love.timer.getTime and love.timer.getTime() or 0
      -- COLD is meant to be felt, not merely tinted: while its visual effect is
      -- active, movement becomes noticeably heavier, then cleanly returns.
      if hauntFxKind=="COLD" and now<hauntFxUntil then mult=mult*1.45 end
      return math.max(1, math.floor((tonumber(base) or 16) * mult + 0.5))
    end
    return base
  end)

  -- Brief high-activity possession reverses only overworld movement. Menus and
  -- dialogue keep normal controls, and the effect expires after four seconds.
  local vanillaMovePlayer=Gen2World.movePlayer
  Gen2World.movePlayer=function(self,dir)
    local now=love.timer and love.timer.getTime and love.timer.getTime() or 0
    if hauntedNow() and now<reverseControlsUntil then
      local opposite={up="down",down="up",left="right",right="left"}
      dir=opposite[dir] or dir
    end
    return vanillaMovePlayer(self,dir)
  end

  -- Night palette for the whole investigation. This is intentionally a normal
  -- palette hook, not persistent map data, so leaving the case restores Crystal.
  mod.hooks:wrap("map.palette", function(next, value, map, ctx)
    local v = next(value, map, ctx)
    if map and isHauntedMapId(map.id) and isEnrolled()
      and mod.save:get("haunt_resolved") ~= true then return "NITE" end
    return v
  end)

  -- Gen 2 does not dispatch runtime-object conversations through the public
  -- world.talk Runtime hook used by Gen 1. Instead, World:interactBody() checks
  -- the Gen1 compatibility facade's talkTo seam. Patch that seam directly so
  -- the spawned Warden can actually answer an A-press in Crystal.
  local vanillaInteract = OverworldController.interact
  OverworldController.interact = function(ow)
    if mod._wardenPlacedToolPress and mod._wardenPlacedToolPress(ow) then return true end
    if hauntedFurniturePress(ow) then return true end
    return vanillaInteract(ow)
  end

  local previousTalkTo = OverworldController.talkTo

  OverworldController.talkTo = function(ow, target)
    if targetIsWarden(target) then
      if target and target.scriptFace and ow and ow.player then
        -- Face toward the player when possible; dialogue still works if this
        -- cosmetic call is unavailable for a particular object implementation.
        local dx = (ow.player.cellX or 0) - (target.cellX or 0)
        local dy = (ow.player.cellY or 0) - (target.cellY or 0)
        local dir
        if math.abs(dx) > math.abs(dy) then
          dir = dx < 0 and "left" or "right"
        else
          dir = dy < 0 and "up" or "down"
        end
        pcall(target.scriptFace, target, dir)
      end

      talkWarden(ow)
      return true -- suppress Crystal's built-in object-script path
    end

    if previousTalkTo then
      return previousTalkTo(ow, target)
    end
    return false
  end
end
