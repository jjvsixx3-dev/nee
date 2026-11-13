--[[
    ESP + Chams v3 (Luau, executor com Drawing API)
    Teclas padrao: RightShift = menu | RightControl = liga/desliga tudo | End = descarregar
    Ajuste em runtime: getgenv().ESP_Settings
    Nao testado em jogo: veja a aba Debug do menu para diagnostico.
]]

local Players     = game:GetService("Players")
local RunService  = game:GetService("RunService")
local UIS         = game:GetService("UserInputService")
local Workspace   = game:GetService("Workspace")
local HttpService = game:GetService("HttpService")

local genv = (getgenv and getgenv()) or _G
if genv.__ESP_UNLOAD then pcall(genv.__ESP_UNLOAD) end

local LocalPlayer = Players.LocalPlayer
local Camera      = Workspace.CurrentCamera

local function try(fn)
    local ok, v = pcall(fn)
    if ok then return v end
    return nil
end

local hasDrawing = try(function()
    return type(Drawing) ~= "nil" and type(Drawing.new) == "function"
end) == true

------------------------------------------------------------------
-- Configuracao
------------------------------------------------------------------
local Settings = {
    Master       = true,
    TeamCheck    = true,   -- oculta aliados
    UseTeamColor = false,
    MaxDistance  = 2000,   -- studs
    OffsetY      = 0,      -- correcao vertical do Drawing (px), sem calibrar
    ESP = {
        Enabled      = true,
        BoxStyle     = "Full",     -- Full | Corner | Off
        BoxMode      = "Rig",      -- Rig (R6/R15 padrao) | Bounds (bounding box do modelo)
        Name         = true,
        NameMode     = "Display",  -- Display | Username
        Health       = true,
        HealthText   = false,
        Distance     = true,
        Tool         = true,
        HeadDot      = false,
        Skeleton     = false,
        Tracer       = false,
        TracerOrigin = "Bottom",   -- Bottom | Center | Mouse
        Arrows       = false,      -- seta para alvos fora da tela
        ArrowRadius  = 220,
        ArrowSize    = 14,
        VisCheck     = false,      -- raycast da camera ate o alvo
        TextSize     = 13,
        Thickness    = 1,
    },
    Chams = {
        Enabled             = true,
        Max                 = 28,   -- Roblox renderiza ~31 Highlights ao mesmo tempo (incluindo os do jogo)
        Rate                = 0.15, -- segundos entre atualizacoes
        FillTransparency    = 0.5,
        OutlineTransparency = 0,
        DepthMode           = "AlwaysOnTop", -- AlwaysOnTop | Occluded
        ParentMode          = "Auto",        -- Auto | Workspace | Character
        VisCheck            = false,
    },
    Colors = {
        Main             = Color3.fromRGB(255, 255, 255),
        Visible          = Color3.fromRGB(80, 255, 120),
        Text             = Color3.fromRGB(255, 255, 255),
        ChamsFill        = Color3.fromRGB(255, 60, 60),
        ChamsFillVisible = Color3.fromRGB(60, 255, 120),
        ChamsOutline     = Color3.fromRGB(255, 255, 255),
    },
}

local function deepCopy(t)
    local out = {}
    for k, v in pairs(t) do
        if type(v) == "table" then out[k] = deepCopy(v) else out[k] = v end
    end
    return out
end
local Defaults = deepCopy(Settings)
local Colors   = Settings.Colors

local Keys = {
    Menu   = Enum.KeyCode.RightShift,
    Master = Enum.KeyCode.RightControl,
    Unload = Enum.KeyCode.End,
}

local BLACK   = Color3.new(0, 0, 0)
local HP_LOW  = Color3.fromRGB(255, 0, 0)
local HP_HIGH = Color3.fromRGB(0, 255, 0)
local VIS_INTERVAL = 0.1
local CONFIG_FILE  = "esp_v3_config.json"

------------------------------------------------------------------
-- Containers
------------------------------------------------------------------
local GuiParent = try(function() return gethui and gethui() end)
    or try(function() return game:GetService("CoreGui") end)
    or LocalPlayer:WaitForChild("PlayerGui")

-- O Highlight so renderiza se estiver dentro do DataModel: testamos de verdade.
local function probeParent(p)
    if not p then return false end
    local ok, inGame = pcall(function()
        local h = Instance.new("Highlight")
        h.Parent = p
        local r = h:IsDescendantOf(game)
        h:Destroy()
        return r
    end)
    return ok and inGame == true
end

local HLParent = Workspace
do
    local cand = {}
    local function add(v) if v then cand[#cand + 1] = v end end
    add(try(function() return game:GetService("CoreGui") end))
    add(try(function() return gethui and gethui() end))
    add(try(function() return LocalPlayer:FindFirstChildOfClass("PlayerGui") end))
    add(Workspace)
    for _, p in ipairs(cand) do
        if probeParent(p) then HLParent = p break end
    end
end
local HLParentName = HLParent.ClassName .. "/" .. HLParent.Name

------------------------------------------------------------------
-- Estado
------------------------------------------------------------------
local entries, conns = {}, {}
local alive      = true
local frameNo    = 0
local lastChams  = 0
local idle       = false
local chamsWasOn = false
local chamsCount = 0
local lastErr, errCount = nil, 0
local fps        = 60
local nextUI     = 0
local stats      = { ok = 0, drawn = 0, noChar = 0, noRoot = 0, dead = 0, team = 0, far = 0, total = 0 }
local ctx        = { frame = 0, camPos = Vector3.zero, vx = 0, vy = 0, wantESP = false, needVis = false, mouse = nil }

local unload -- forward

local function track(signal, fn)
    local c = signal:Connect(fn)
    conns[#conns + 1] = c
    return c
end

local function noteError(err)
    errCount = errCount + 1
    lastErr = string.sub(tostring(err), 1, 160)
end

------------------------------------------------------------------
-- Raycast (checagem de visibilidade)
------------------------------------------------------------------
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true
local lastLocalChar, lastCam = nil, nil

local function refreshRayFilter()
    local list = {}
    local lc = LocalPlayer.Character
    if lc then list[#list + 1] = lc end
    if Camera then list[#list + 1] = Camera end
    rayParams.FilterDescendantsInstances = list
    lastLocalChar, lastCam = lc, Camera
end

local function isVisible(e)
    local target = e.head
    if not (target and target.Parent) then target = e.root end
    local origin = ctx.camPos
    local r = Workspace:Raycast(origin, target.Position - origin, rayParams)
    if r == nil then return true end
    return r.Instance:IsDescendantOf(e.char)
end

------------------------------------------------------------------
-- Personagem: resolucao preguicosa (corrige jogadores "perdidos" com StreamingEnabled/respawn)
------------------------------------------------------------------
local SK_R15 = {
    { "Head", "UpperTorso" }, { "UpperTorso", "LowerTorso" },
    { "UpperTorso", "LeftUpperArm" }, { "LeftUpperArm", "LeftLowerArm" }, { "LeftLowerArm", "LeftHand" },
    { "UpperTorso", "RightUpperArm" }, { "RightUpperArm", "RightLowerArm" }, { "RightLowerArm", "RightHand" },
    { "LowerTorso", "LeftUpperLeg" }, { "LeftUpperLeg", "LeftLowerLeg" }, { "LeftLowerLeg", "LeftFoot" },
    { "LowerTorso", "RightUpperLeg" }, { "RightUpperLeg", "RightLowerLeg" }, { "RightLowerLeg", "RightFoot" },
}
local SK_R6 = {
    { "Head", "Torso" }, { "Torso", "Left Arm" }, { "Torso", "Right Arm" },
    { "Torso", "Left Leg" }, { "Torso", "Right Leg" },
}
local SKEY = {}
for i = 1, 16 do SKEY[i] = "sk" .. i end

local function buildSkeleton(char)
    local rig
    if char:FindFirstChild("UpperTorso") then rig = SK_R15
    elseif char:FindFirstChild("Torso") then rig = SK_R6 end
    if not rig then return nil end
    local out = {}
    for _, pair in ipairs(rig) do
        local a, b = char:FindFirstChild(pair[1]), char:FindFirstChild(pair[2])
        if a and b and a:IsA("BasePart") and b:IsA("BasePart") then out[#out + 1] = { a, b } end
    end
    return out
end

local function skelValid(sk)
    for i = 1, #sk do
        if sk[i][1].Parent == nil or sk[i][2].Parent == nil then return false end
    end
    return true
end

local function resetChar(e, char)
    e.char = char
    e.root, e.hum, e.head, e.skel, e.tool = nil, nil, nil, nil, nil
    e.nextRef = 0
    e.visible = false
end

local function refresh(e, char, now)
    e.nextRef = now + 0.25
    local root = e.root
    if root == nil or root.Parent == nil then
        root = char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart or char:FindFirstChildWhichIsA("BasePart")
        if root and not root:IsA("BasePart") then
            root = char.PrimaryPart or char:FindFirstChildWhichIsA("BasePart")
        end
        e.root = root
    end
    if root == nil then return end
    if not (e.hum and e.hum.Parent) then e.hum = char:FindFirstChildOfClass("Humanoid") end
    if not (e.head and e.head.Parent) then
        local h = char:FindFirstChild("Head")
        if h and not h:IsA("BasePart") then h = nil end
        e.head = h
    end
    local tool = char:FindFirstChildOfClass("Tool")
    e.tool = tool and tool.Name or nil
    if Settings.ESP.Skeleton then
        if not e.skel or not skelValid(e.skel) then e.skel = buildSkeleton(char) end
    else
        e.skel = nil
    end
end

local function sameTeam(player)
    local mine, theirs = LocalPlayer.Team, player.Team
    return mine ~= nil and theirs ~= nil and mine == theirs
end

-- true se desenhavel; senao o motivo (string) para a aba Debug
local function evaluate(e, now)
    local player = e.player
    local char = player.Character
    if char ~= e.char then resetChar(e, char) end
    if not char then return "noChar" end
    local root = e.root
    if root == nil or root.Parent == nil then
        if now < e.nextRef then return "noRoot" end
        refresh(e, char, now)
    elseif now >= e.nextRef then
        refresh(e, char, now)
    end
    root = e.root
    if root == nil or root.Parent == nil then return "noRoot" end
    local hum = e.hum
    if hum and hum.Health <= 0 then return "dead" end
    if Settings.TeamCheck and sameTeam(player) then return "team" end
    local dist = (root.Position - ctx.camPos).Magnitude
    e.dist = dist
    if dist > Settings.MaxDistance then return "far" end
    return true
end

------------------------------------------------------------------
-- Drawing helpers
------------------------------------------------------------------
local INIT = {
    Line     = {},
    Square   = { Filled = false },
    Circle   = { Filled = false, NumSides = 20 },
    Triangle = { Filled = true },
    Text     = { Center = true, Outline = true },
}
local ZINDEX = { boxo = 1, hpb = 1 }

local function killDrawing(o)
    local ok = pcall(function() o:Remove() end)
    if not ok then pcall(function() o:Destroy() end) end
end

local function obj(e, key, class)
    local w = e.d[key]
    if w == nil then
        local ok, o = pcall(Drawing.new, class)
        if ok and o then
            for k, v in pairs(INIT[class]) do pcall(function() o[k] = v end) end
            pcall(function() o.ZIndex = ZINDEX[key] or 2 end)
            pcall(function() o.Visible = false end)
            w = { o = o, vis = false, stamp = 0, p = {} }
            e.list[#e.list + 1] = w
        else
            w = false
        end
        e.d[key] = w
    end
    return w or nil
end

local function put(w, frame)
    w.stamp = frame
    if not w.vis then
        w.vis = true
        w.o.Visible = true
    end
end

local function prop(w, k, v)
    local p = w.p
    if p[k] ~= v then
        p[k] = v
        w.o[k] = v
    end
end

local function sweep(e, frame)
    local list = e.list
    for i = 1, #list do
        local w = list[i]
        if w.vis and w.stamp ~= frame then
            w.vis = false
            w.o.Visible = false
        end
    end
end

local function drawLine(e, key, x1, y1, x2, y2, col, th)
    local w = obj(e, key, "Line")
    if not w then return end
    prop(w, "Color", col)
    prop(w, "Thickness", th)
    w.o.From = Vector2.new(x1, y1)
    w.o.To = Vector2.new(x2, y2)
    put(w, ctx.frame)
end

local function drawRect(e, key, x, y, wd, ht, col, th)
    local w = obj(e, key, "Square")
    if not w then return end
    prop(w, "Color", col)
    prop(w, "Thickness", th)
    w.o.Position = Vector2.new(x, y)
    w.o.Size = Vector2.new(wd, ht)
    put(w, ctx.frame)
end

local function drawText(e, key, text, x, y, size, col)
    local w = obj(e, key, "Text")
    if not w then return end
    prop(w, "Text", text)
    prop(w, "Size", size)
    prop(w, "Color", col)
    w.o.Position = Vector2.new(x, y)
    put(w, ctx.frame)
end

local function proj(pos)
    local v = Camera:WorldToViewportPoint(pos)
    return v.X, v.Y + Settings.OffsetY, v.Z
end

-- Caixa por proporcao de rig (R6/R15 padrao). Sem calibrar para rigs customizados: use BoxMode = Bounds.
local function rigRect(e)
    local root = e.root
    local rp = root.Position
    local head = e.head
    local topPos
    if head and head.Parent then
        topPos = head.Position + Vector3.new(0, head.Size.Y * 0.5 + 0.15, 0)
    else
        topPos = rp + Vector3.new(0, root.Size.Y * 0.5 + 1.5, 0)
    end
    local floorOff = 3
    local hum = e.hum
    if hum and hum.RigType == Enum.HumanoidRigType.R15 and hum.HipHeight > 0 then
        floorOff = hum.HipHeight + root.Size.Y * 0.5
    end
    local tx, ty, tz = proj(topPos)
    local bx, by, bz = proj(Vector3.new(rp.X, rp.Y - floorOff, rp.Z))
    if tz <= 0 or bz <= 0 then return nil end
    local h = math.max(math.abs(by - ty), 2)
    local w = h * 0.55
    return math.floor((tx + bx) * 0.5 - w * 0.5), math.floor(math.min(ty, by)), math.floor(w), math.floor(h)
end

-- Caixa pela bounding box do modelo (inclui acessorios/ferramentas grandes).
local function boundsRect(e)
    local cf, size = e.char:GetBoundingBox()
    local hx, hy, hz = size.X * 0.5, size.Y * 0.5, size.Z * 0.5
    local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
    for sx = -1, 1, 2 do
        for sy = -1, 1, 2 do
            for sz = -1, 1, 2 do
                local px, py, pz = proj(cf * Vector3.new(sx * hx, sy * hy, sz * hz))
                if pz <= 0 then return nil end
                if px < minX then minX = px end
                if px > maxX then maxX = px end
                if py < minY then minY = py end
                if py > maxY then maxY = py end
            end
        end
    end
    return math.floor(minX), math.floor(minY), math.floor(maxX - minX), math.floor(maxY - minY)
end

local function baseColor(e)
    local col = Colors.Main
    if Settings.UseTeamColor then
        local t = e.player.Team
        if t then col = t.TeamColor.Color end
    end
    if Settings.ESP.VisCheck and e.visible then col = Colors.Visible end
    return col
end

local function drawArrow(e, col)
    local E = Settings.ESP
    local rel = Camera.CFrame:PointToObjectSpace(e.root.Position)
    local dx, dy = rel.X, -rel.Y
    local mag = math.sqrt(dx * dx + dy * dy)
    if mag < 1e-4 then dx, dy, mag = 0, 1, 1 end
    dx, dy = dx / mag, dy / mag
    local cx, cy = ctx.vx * 0.5, ctx.vy * 0.5
    local r = math.min(E.ArrowRadius, math.min(cx, cy) - 20)
    local px, py = cx + dx * r, cy + dy * r
    local s = E.ArrowSize
    local nx, ny = -dy, dx
    local w = obj(e, "arrow", "Triangle")
    if not w then return end
    prop(w, "Color", col)
    w.o.PointA = Vector2.new(px + dx * s, py + dy * s)
    w.o.PointB = Vector2.new(px - dx * s * 0.5 + nx * s * 0.6, py - dy * s * 0.5 + ny * s * 0.6)
    w.o.PointC = Vector2.new(px - dx * s * 0.5 - nx * s * 0.6, py - dy * s * 0.5 - ny * s * 0.6)
    put(w, ctx.frame)
end

local function drawESP(e)
    local E = Settings.ESP
    local frame, vx, vy = ctx.frame, ctx.vx, ctx.vy
    local th, ts = E.Thickness, E.TextSize
    local txtCol = Colors.Text

    local _, _, rz = proj(e.root.Position)
    local x, y, w, h
    if rz > 0 then
        if E.BoxMode == "Bounds" then x, y, w, h = boundsRect(e) else x, y, w, h = rigRect(e) end
    end
    local onScreen = x ~= nil and x + w > 0 and x < vx and y + h > 0 and y < vy
    local col = baseColor(e)

    if onScreen then
        stats.drawn = stats.drawn + 1
        local cx = x + w * 0.5

        if E.BoxStyle == "Full" then
            drawRect(e, "boxo", x - 1, y - 1, w + 2, h + 2, BLACK, th + 2)
            drawRect(e, "box", x, y, w, h, col, th)
        elseif E.BoxStyle == "Corner" then
            local cl = math.max(3, math.min(w, h) * 0.28)
            local x2, y2 = x + w, y + h
            drawLine(e, "c1", x, y, x + cl, y, col, th)
            drawLine(e, "c2", x, y, x, y + cl, col, th)
            drawLine(e, "c3", x2, y, x2 - cl, y, col, th)
            drawLine(e, "c4", x2, y, x2, y + cl, col, th)
            drawLine(e, "c5", x, y2, x + cl, y2, col, th)
            drawLine(e, "c6", x, y2, x, y2 - cl, col, th)
            drawLine(e, "c7", x2, y2, x2 - cl, y2, col, th)
            drawLine(e, "c8", x2, y2, x2, y2 - cl, col, th)
        end

        if E.Name then
            local nm = (E.NameMode == "Username") and e.player.Name or e.player.DisplayName
            drawText(e, "name", nm, cx, y - ts - 3, ts, txtCol)
        end

        local ty = y + h + 2
        if E.Distance then
            local d = math.floor(e.dist + 0.5)
            if e.lastDist ~= d then
                e.lastDist = d
                e.distText = "[" .. d .. "]"
            end
            drawText(e, "dist", e.distText, cx, ty, ts - 1, txtCol)
            ty = ty + ts
        end
        if E.Tool and e.tool then
            drawText(e, "tool", e.tool, cx, ty, ts - 1, txtCol)
        end

        local hum = e.hum
        if E.Health and hum then
            local mh = hum.MaxHealth
            local frac = 1
            if mh > 0 then frac = math.clamp(hum.Health / mh, 0, 1) end
            local bx = x - 5
            drawLine(e, "hpb", bx, y + h + 1, bx, y - 1, BLACK, 4)
            drawLine(e, "hp", bx, y + h, bx, y + h - h * frac, HP_LOW:Lerp(HP_HIGH, frac), 2)
            if E.HealthText then
                drawText(e, "hpt", string.format("%d", math.floor(hum.Health + 0.5)),
                    bx - 12, y + h - h * frac - ts * 0.5, ts - 2, txtCol)
            end
        end

        if E.HeadDot and e.head and e.head.Parent then
            local hx, hy, hz = proj(e.head.Position)
            if hz > 0 then
                local o = obj(e, "hd", "Circle")
                if o then
                    prop(o, "Color", col)
                    prop(o, "Thickness", th)
                    prop(o, "Radius", math.max(2, h * 0.07))
                    o.o.Position = Vector2.new(hx, hy)
                    put(o, frame)
                end
            end
        end

        if E.Skeleton and e.skel then
            local sk = e.skel
            for i = 1, #sk do
                local a, b = sk[i][1], sk[i][2]
                if a.Parent and b.Parent then
                    local ax, ay, az = proj(a.Position)
                    local bx2, by2, bz = proj(b.Position)
                    if az > 0 and bz > 0 then
                        drawLine(e, SKEY[i], ax, ay, bx2, by2, col, th)
                    end
                end
            end
        end

        if E.Tracer then
            local ox, oy
            local mode = E.TracerOrigin
            if mode == "Center" then
                ox, oy = vx * 0.5, vy * 0.5
            elseif mode == "Mouse" and ctx.mouse then
                ox, oy = ctx.mouse.X, ctx.mouse.Y
            else
                ox, oy = vx * 0.5, vy
            end
            drawLine(e, "tr", ox, oy, cx, y + h, col, th)
        end
    elseif E.Arrows then
        drawArrow(e, col)
    end

    sweep(e, frame)
    e.active = true
end

local function processEntry(e, now)
    local reason = evaluate(e, now)
    if reason ~= true then
        stats[reason] = stats[reason] + 1
        e.ok = false
        if e.active then sweep(e, -1) e.active = false end
        return
    end
    e.ok = true
    stats.ok = stats.ok + 1
    if ctx.needVis and now >= e.nextVis then
        e.nextVis = now + VIS_INTERVAL
        e.visible = isVisible(e)
    end
    if not ctx.wantESP then
        if e.active then sweep(e, -1) e.active = false end
        return
    end
    drawESP(e)
end

------------------------------------------------------------------
-- Entradas por jogador
------------------------------------------------------------------
local function newEntry(player)
    if player == LocalPlayer or entries[player] then return end
    entries[player] = {
        player = player, d = {}, list = {},
        nextRef = 0, nextVis = 0, visible = false,
        ok = false, active = false,
    }
end

local function removeEntry(player)
    local e = entries[player]
    if not e then return end
    entries[player] = nil
    for i = 1, #e.list do killDrawing(e.list[i].o) end
    if e.hl then pcall(function() e.hl:Destroy() end) end
end

------------------------------------------------------------------
-- Chams
------------------------------------------------------------------
local function desiredHLParent(e)
    local m = Settings.Chams.ParentMode
    if m == "Character" then return e.char end
    if m == "Workspace" then return Workspace end
    return HLParent
end

local function releaseHL(e)
    local hl = e.hl
    if hl and (hl.Adornee ~= nil or hl.Enabled) then
        hl.Enabled = false
        hl.Adornee = nil
    end
end

local function applyHL(e)
    local C = Settings.Chams
    local hl = e.hl
    if hl == nil or hl.Parent == nil then
        if hl then pcall(function() hl:Destroy() end) end
        hl = Instance.new("Highlight")
        hl.Name = "HL"
        e.hl = hl
    end
    local fill = Colors.ChamsFill
    if Settings.UseTeamColor then
        local t = e.player.Team
        if t then fill = t.TeamColor.Color end
    end
    if C.VisCheck and e.visible then fill = Colors.ChamsFillVisible end

    local depth = Enum.HighlightDepthMode.AlwaysOnTop
    if C.DepthMode == "Occluded" then depth = Enum.HighlightDepthMode.Occluded end
    if hl.DepthMode ~= depth then hl.DepthMode = depth end
    if hl.FillColor ~= fill then hl.FillColor = fill end
    if hl.OutlineColor ~= Colors.ChamsOutline then hl.OutlineColor = Colors.ChamsOutline end
    if math.abs(hl.FillTransparency - C.FillTransparency) > 0.001 then hl.FillTransparency = C.FillTransparency end
    if math.abs(hl.OutlineTransparency - C.OutlineTransparency) > 0.001 then hl.OutlineTransparency = C.OutlineTransparency end
    if hl.Adornee ~= e.char then hl.Adornee = e.char end
    local want = desiredHLParent(e)
    if want and hl.Parent ~= want then hl.Parent = want end
    if not hl.Enabled then hl.Enabled = true end
end

local chamsList = {}
local function byDist(a, b) return a.dist < b.dist end

local function chamsTick()
    local C = Settings.Chams
    table.clear(chamsList)
    for _, e in pairs(entries) do
        if e.ok then chamsList[#chamsList + 1] = e else releaseHL(e) end
    end
    table.sort(chamsList, byDist)
    local cap = math.min(C.Max, 31)
    local n = 0
    for i = 1, #chamsList do
        local e = chamsList[i]
        if i <= cap then
            local ok, err = pcall(applyHL, e)
            if ok then n = n + 1 else noteError(err) end
        else
            releaseHL(e)
        end
    end
    chamsCount = n
end

------------------------------------------------------------------
-- Config (salvar/carregar)
------------------------------------------------------------------
local function serialize(t)
    local out = {}
    for k, v in pairs(t) do
        local tv = typeof(v)
        if tv == "table" then out[k] = serialize(v)
        elseif tv == "Color3" then out[k] = { __c3 = { v.R, v.G, v.B } }
        elseif tv == "number" or tv == "boolean" or tv == "string" then out[k] = v end
    end
    return out
end

local function merge(dst, src)
    for k, cur in pairs(dst) do
        local v = src[k]
        if v ~= nil then
            local tc = typeof(cur)
            if tc == "table" then
                if type(v) == "table" then merge(cur, v) end
            elseif tc == "Color3" then
                if type(v) == "table" and type(v.__c3) == "table" then
                    local r, g, b = tonumber(v.__c3[1]), tonumber(v.__c3[2]), tonumber(v.__c3[3])
                    if r and g and b then
                        dst[k] = Color3.new(math.clamp(r, 0, 1), math.clamp(g, 0, 1), math.clamp(b, 0, 1))
                    end
                end
            elseif tc == "number" then
                if type(v) == "number" and v == v then dst[k] = v end
            elseif tc == "boolean" or tc == "string" then
                if type(v) == tc then dst[k] = v end
            end
        end
    end
end

local function copyInto(dst, src)
    for k, v in pairs(src) do
        if type(v) == "table" then copyInto(dst[k], v) else dst[k] = v end
    end
end

------------------------------------------------------------------
-- Menu
------------------------------------------------------------------
local function buildUI()
    local ACCENT = Color3.fromRGB(90, 140, 255)
    local BG     = Color3.fromRGB(20, 20, 26)
    local PANEL  = Color3.fromRGB(30, 30, 38)
    local BTN    = Color3.fromRGB(48, 48, 60)
    local TEXT   = Color3.fromRGB(235, 235, 240)
    local DIM    = Color3.fromRGB(150, 150, 165)
    local GREEN  = Color3.fromRGB(46, 160, 80)
    local GRAY   = Color3.fromRGB(80, 80, 92)

    local ui = {}
    local refreshers, sanitizers = {}, {}
    local drag, capturing = nil, nil
    local orders = {}

    local function new(class, props, parent)
        local i = Instance.new(class)
        for k, v in pairs(props) do i[k] = v end
        if parent then i.Parent = parent end
        return i
    end
    local function corner(inst, r)
        return new("UICorner", { CornerRadius = UDim.new(0, r or 5) }, inst)
    end
    local function nextOrder(page)
        orders[page] = (orders[page] or 0) + 1
        return orders[page]
    end

    local Gui = new("ScreenGui", {
        Name = "ov" .. tostring(math.random(10000, 99999)),
        ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 1000,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    }, GuiParent)

    local Main = new("Frame", {
        Size = UDim2.new(0, 580, 0, 430), Position = UDim2.new(0, 60, 0, 80),
        BackgroundColor3 = BG, BorderSizePixel = 0, Active = true,
    }, Gui)
    corner(Main, 8)

    local Title = new("TextLabel", {
        Size = UDim2.new(1, 0, 0, 30), BackgroundColor3 = PANEL, BorderSizePixel = 0,
        Font = Enum.Font.GothamBold, TextSize = 14, TextColor3 = TEXT,
        Text = "  ESP / Chams v3", TextXAlignment = Enum.TextXAlignment.Left,
    }, Main)
    corner(Title, 8)
    -- botao modal invisivel: libera o mouse em jogos com camera travada enquanto o menu esta aberto
    new("TextButton", { Size = UDim2.new(0, 0, 0, 0), BackgroundTransparency = 1, Text = "", Modal = true }, Main)

    track(Title.InputBegan, function(input)
        local ut = input.UserInputType
        if ut == Enum.UserInputType.MouseButton1 or ut == Enum.UserInputType.Touch then
            local start, sp = input.Position, Main.Position
            drag = function(p)
                Main.Position = UDim2.new(sp.X.Scale, sp.X.Offset + (p.X - start.X),
                                          sp.Y.Scale, sp.Y.Offset + (p.Y - start.Y))
            end
        end
    end)
    track(UIS.InputChanged, function(input)
        if not drag then return end
        local ut = input.UserInputType
        if ut == Enum.UserInputType.MouseMovement or ut == Enum.UserInputType.Touch then
            drag(input.Position)
        end
    end)
    track(UIS.InputEnded, function(input)
        local ut = input.UserInputType
        if ut == Enum.UserInputType.MouseButton1 or ut == Enum.UserInputType.Touch then drag = nil end
    end)

    -- Abas
    local TAB_NAMES = { "ESP", "Chams", "Cores", "Config", "Debug" }
    local TabCol = new("Frame", {
        Position = UDim2.new(0, 8, 0, 38), Size = UDim2.new(0, 96, 1, -46), BackgroundTransparency = 1,
    }, Main)
    new("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, TabCol)

    local pages, tabBtns = {}, {}
    local function selectTab(name)
        for n, p in pairs(pages) do p.Visible = (n == name) end
        for n, b in pairs(tabBtns) do b.BackgroundColor3 = (n == name) and ACCENT or PANEL end
    end
    for i, name in ipairs(TAB_NAMES) do
        local btn = new("TextButton", {
            Size = UDim2.new(1, 0, 0, 28), BackgroundColor3 = PANEL, BorderSizePixel = 0,
            Font = Enum.Font.GothamMedium, TextSize = 13, TextColor3 = TEXT,
            Text = name, LayoutOrder = i, AutoButtonColor = false,
        }, TabCol)
        corner(btn, 5)
        local page = new("ScrollingFrame", {
            Position = UDim2.new(0, 112, 0, 38), Size = UDim2.new(1, -120, 1, -46),
            BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 4,
            CanvasSize = UDim2.new(0, 0, 0, 0), AutomaticCanvasSize = Enum.AutomaticSize.Y, Visible = false,
        }, Main)
        new("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, page)
        pages[name], tabBtns[name] = page, btn
        track(btn.MouseButton1Click, function() selectTab(name) end)
    end

    -- Controles
    local function rowFrame(page, h)
        local row = new("Frame", {
            Size = UDim2.new(1, -8, 0, h), BackgroundColor3 = PANEL, BorderSizePixel = 0,
            LayoutOrder = nextOrder(page),
        }, page)
        corner(row, 5)
        return row
    end
    local function rowLabel(row, text, w)
        return new("TextLabel", {
            Size = UDim2.new(w or 0.6, 0, 0, 22), Position = UDim2.new(0, 10, 0, 3),
            BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 13, TextColor3 = TEXT,
            TextXAlignment = Enum.TextXAlignment.Left, Text = text,
        }, row)
    end

    local function Section(page, text)
        new("TextLabel", {
            Size = UDim2.new(1, -8, 0, 22), BackgroundTransparency = 1, Font = Enum.Font.GothamBold,
            TextSize = 13, TextColor3 = ACCENT, TextXAlignment = Enum.TextXAlignment.Left,
            Text = text, LayoutOrder = nextOrder(page),
        }, page)
    end

    local function Info(page, text)
        return new("TextLabel", {
            Size = UDim2.new(1, -8, 0, 16), AutomaticSize = Enum.AutomaticSize.Y,
            BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 12, TextColor3 = DIM,
            TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
            Text = text, LayoutOrder = nextOrder(page),
        }, page)
    end

    local function Toggle(page, text, tbl, key, onChange)
        local row = rowFrame(page, 28)
        rowLabel(row, text, 0.75)
        local btn = new("TextButton", {
            Size = UDim2.new(0, 40, 0, 18), Position = UDim2.new(1, -50, 0.5, -9),
            AutoButtonColor = false, Text = "", BorderSizePixel = 0,
        }, row)
        corner(btn, 9)
        local function refresh() btn.BackgroundColor3 = tbl[key] and GREEN or GRAY end
        track(btn.MouseButton1Click, function()
            tbl[key] = not tbl[key]
            refresh()
            if onChange then onChange(tbl[key]) end
        end)
        refreshers[#refreshers + 1] = refresh
        sanitizers[#sanitizers + 1] = function() tbl[key] = tbl[key] == true end
        refresh()
    end

    local function Cycle(page, text, tbl, key, options, onChange)
        local row = rowFrame(page, 28)
        rowLabel(row, text, 0.5)
        local btn = new("TextButton", {
            Size = UDim2.new(0, 150, 0, 20), Position = UDim2.new(1, -160, 0.5, -10),
            BackgroundColor3 = BTN, BorderSizePixel = 0, Font = Enum.Font.GothamMedium,
            TextSize = 12, TextColor3 = TEXT, Text = "",
        }, row)
        corner(btn, 4)
        local function indexOf(v)
            for i, o in ipairs(options) do if o == v then return i end end
            return nil
        end
        local function refresh() btn.Text = tostring(tbl[key]) end
        local function step(dir)
            local i = indexOf(tbl[key]) or 0
            i = ((i - 1 + dir) % #options) + 1
            tbl[key] = options[i]
            refresh()
            if onChange then onChange(tbl[key]) end
        end
        track(btn.MouseButton1Click, function() step(1) end)
        track(btn.MouseButton2Click, function() step(-1) end)
        refreshers[#refreshers + 1] = refresh
        sanitizers[#sanitizers + 1] = function() if not indexOf(tbl[key]) then tbl[key] = options[1] end end
        refresh()
    end

    local function Slider(page, text, tbl, key, mn, mx, step, fmt, onChange)
        local row = rowFrame(page, 42)
        rowLabel(row, text, 0.6)
        local val = new("TextLabel", {
            Size = UDim2.new(0.4, -10, 0, 22), Position = UDim2.new(0.6, 0, 0, 3),
            BackgroundTransparency = 1, Font = Enum.Font.GothamMedium, TextSize = 12, TextColor3 = DIM,
            TextXAlignment = Enum.TextXAlignment.Right, Text = "",
        }, row)
        local hit = new("TextButton", {
            Size = UDim2.new(1, -20, 0, 16), Position = UDim2.new(0, 10, 0, 23),
            BackgroundTransparency = 1, Text = "", AutoButtonColor = false,
        }, row)
        local bar = new("Frame", {
            Size = UDim2.new(1, 0, 0, 6), Position = UDim2.new(0, 0, 0.5, -3),
            BackgroundColor3 = Color3.fromRGB(55, 55, 66), BorderSizePixel = 0,
        }, hit)
        corner(bar, 3)
        local fillF = new("Frame", { Size = UDim2.new(0, 0, 1, 0), BackgroundColor3 = ACCENT, BorderSizePixel = 0 }, bar)
        corner(fillF, 3)
        local function refresh()
            local v = tbl[key]
            fillF.Size = UDim2.new(math.clamp((v - mn) / (mx - mn), 0, 1), 0, 1, 0)
            val.Text = string.format(fmt, v)
        end
        local function setFromX(px)
            local w = bar.AbsoluteSize.X
            if w <= 0 then return end
            local t = math.clamp((px - bar.AbsolutePosition.X) / w, 0, 1)
            local v = mn + t * (mx - mn)
            v = math.clamp(math.floor(v / step + 0.5) * step, mn, mx)
            tbl[key] = v
            refresh()
            if onChange then onChange(v) end
        end
        track(hit.InputBegan, function(input)
            local ut = input.UserInputType
            if ut == Enum.UserInputType.MouseButton1 or ut == Enum.UserInputType.Touch then
                drag = function(p) setFromX(p.X) end
                setFromX(input.Position.X)
            end
        end)
        refreshers[#refreshers + 1] = refresh
        sanitizers[#sanitizers + 1] = function()
            local v = tbl[key]
            if type(v) ~= "number" or v ~= v then v = mn end
            tbl[key] = math.clamp(v, mn, mx)
        end
        refresh()
    end

    local function ColorRow(page, text, tbl, key)
        local row = rowFrame(page, 56)
        rowLabel(row, text, 0.7)
        local swatch = new("Frame", { Size = UDim2.new(0, 40, 0, 16), Position = UDim2.new(1, -50, 0, 6), BorderSizePixel = 0 }, row)
        corner(swatch, 4)
        local holder = new("Frame", { Size = UDim2.new(1, -20, 0, 20), Position = UDim2.new(0, 10, 0, 30), BackgroundTransparency = 1 }, row)
        local names = { "R", "G", "B" }
        local tints = { Color3.fromRGB(210, 70, 70), Color3.fromRGB(70, 190, 90), Color3.fromRGB(80, 120, 230) }
        local fills, texts = {}, {}
        local function chanOf(c, i)
            if i == 1 then return c.R elseif i == 2 then return c.G end
            return c.B
        end
        local function refresh()
            local c = tbl[key]
            swatch.BackgroundColor3 = c
            for i = 1, 3 do
                local v = math.floor(chanOf(c, i) * 255 + 0.5)
                fills[i].Size = UDim2.new(v / 255, 0, 1, 0)
                texts[i].Text = names[i] .. " " .. v
            end
        end
        for i = 1, 3 do
            local hit = new("TextButton", {
                Size = UDim2.new(1 / 3, -4, 1, 0), Position = UDim2.new((i - 1) / 3, 0, 0, 0),
                BackgroundColor3 = Color3.fromRGB(45, 45, 56), BorderSizePixel = 0, Text = "", AutoButtonColor = false,
            }, holder)
            corner(hit, 4)
            local f = new("Frame", {
                Size = UDim2.new(0, 0, 1, 0), BackgroundColor3 = tints[i], BorderSizePixel = 0, BackgroundTransparency = 0.35,
            }, hit)
            corner(f, 4)
            local t = new("TextLabel", {
                Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1, Font = Enum.Font.GothamMedium,
                TextSize = 11, TextColor3 = TEXT, Text = "",
            }, hit)
            fills[i], texts[i] = f, t
            local function setX(px)
                local w = hit.AbsoluteSize.X
                if w <= 0 then return end
                local v = math.floor(math.clamp((px - hit.AbsolutePosition.X) / w, 0, 1) * 255 + 0.5)
                local c = tbl[key]
                local r, g, b = math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5)
                if i == 1 then r = v elseif i == 2 then g = v else b = v end
                tbl[key] = Color3.fromRGB(r, g, b)
                refresh()
            end
            track(hit.InputBegan, function(input)
                local ut = input.UserInputType
                if ut == Enum.UserInputType.MouseButton1 or ut == Enum.UserInputType.Touch then
                    drag = function(p) setX(p.X) end
                    setX(input.Position.X)
                end
            end)
        end
        refreshers[#refreshers + 1] = refresh
        refresh()
    end

    local function Button(page, text, fn)
        local row = rowFrame(page, 28)
        local btn = new("TextButton", {
            Size = UDim2.new(1, -16, 0, 22), Position = UDim2.new(0, 8, 0.5, -11),
            BackgroundColor3 = BTN, BorderSizePixel = 0, Font = Enum.Font.GothamMedium,
            TextSize = 12, TextColor3 = TEXT, Text = text,
        }, row)
        corner(btn, 4)
        track(btn.MouseButton1Click, fn)
        return btn
    end

    local function forceChams() lastChams = 0 end

    ---------------- Aba ESP ----------------
    local pE = pages["ESP"]
    local E, C = Settings.ESP, Settings.Chams
    if not hasDrawing then
        Info(pE, "Drawing API indisponivel neste executor: o ESP fica desativado, apenas os Chams funcionam.")
    end
    Section(pE, "Geral")
    Toggle(pE, "Ativar tudo (ESP + Chams)", Settings, "Master", forceChams)
    Toggle(pE, "ESP ligado", E, "Enabled")
    Toggle(pE, "Ocultar aliados (Team Check)", Settings, "TeamCheck", forceChams)
    Toggle(pE, "Usar cor do time", Settings, "UseTeamColor", forceChams)
    Slider(pE, "Distancia maxima (studs)", Settings, "MaxDistance", 100, 5000, 50, "%.0f")
    Section(pE, "Caixa")
    Cycle(pE, "Estilo da caixa", E, "BoxStyle", { "Full", "Corner", "Off" })
    Cycle(pE, "Modo da caixa", E, "BoxMode", { "Rig", "Bounds" })
    Section(pE, "Informacoes")
    Toggle(pE, "Nome", E, "Name")
    Cycle(pE, "Tipo de nome", E, "NameMode", { "Display", "Username" })
    Toggle(pE, "Barra de vida", E, "Health")
    Toggle(pE, "Texto da vida", E, "HealthText")
    Toggle(pE, "Distancia", E, "Distance")
    Toggle(pE, "Ferramenta equipada", E, "Tool")
    Toggle(pE, "Ponto na cabeca", E, "HeadDot")
    Toggle(pE, "Esqueleto", E, "Skeleton")
    Section(pE, "Linhas e setas")
    Toggle(pE, "Tracer", E, "Tracer")
    Cycle(pE, "Origem do tracer", E, "TracerOrigin", { "Bottom", "Center", "Mouse" })
    Toggle(pE, "Setas para alvos fora da tela", E, "Arrows")
    Slider(pE, "Raio das setas (px)", E, "ArrowRadius", 60, 500, 5, "%.0f")
    Slider(pE, "Tamanho das setas", E, "ArrowSize", 6, 30, 1, "%.0f")
    Section(pE, "Visibilidade")
    Toggle(pE, "Checar visibilidade (raycast)", E, "VisCheck", forceChams)
    Section(pE, "Aparencia e calibracao")
    Slider(pE, "Tamanho do texto", E, "TextSize", 10, 20, 1, "%.0f")
    Slider(pE, "Espessura das linhas", E, "Thickness", 1, 4, 1, "%.0f")
    Slider(pE, "Deslocamento Y do Drawing (px)", Settings, "OffsetY", -60, 60, 1, "%.0f")

    ---------------- Aba Chams ----------------
    local pC = pages["Chams"]
    Section(pC, "Chams")
    Toggle(pC, "Chams ligado", C, "Enabled", forceChams)
    Slider(pC, "Maximo de jogadores (limite ~31)", C, "Max", 1, 31, 1, "%.0f", forceChams)
    Slider(pC, "Intervalo de atualizacao (s)", C, "Rate", 0.05, 1, 0.05, "%.2f")
    Slider(pC, "Transparencia do preenchimento", C, "FillTransparency", 0, 1, 0.05, "%.2f", forceChams)
    Slider(pC, "Transparencia do contorno", C, "OutlineTransparency", 0, 1, 0.05, "%.2f", forceChams)
    Cycle(pC, "Profundidade", C, "DepthMode", { "AlwaysOnTop", "Occluded" }, forceChams)
    Cycle(pC, "Onde criar o Highlight", C, "ParentMode", { "Auto", "Workspace", "Character" }, forceChams)
    Toggle(pC, "Cor diferente quando visivel (raycast)", C, "VisCheck", forceChams)
    Info(pC, "Se algum jogador nao recebe chams: veja a aba Debug, teste 'Onde criar o Highlight' = Character ou Workspace e lembre que o Roblox limita ~31 Highlights ativos, contando os do proprio jogo.")

    ---------------- Aba Cores ----------------
    local pK = pages["Cores"]
    Section(pK, "ESP")
    ColorRow(pK, "Principal (caixa, linhas, esqueleto)", Colors, "Main")
    ColorRow(pK, "Quando visivel", Colors, "Visible")
    ColorRow(pK, "Texto", Colors, "Text")
    Section(pK, "Chams")
    ColorRow(pK, "Preenchimento", Colors, "ChamsFill")
    ColorRow(pK, "Preenchimento quando visivel", Colors, "ChamsFillVisible")
    ColorRow(pK, "Contorno", Colors, "ChamsOutline")

    ---------------- Aba Config ----------------
    local pG = pages["Config"]
    Section(pG, "Arquivo de configuracao")
    local status = Info(pG, "Arquivo: " .. CONFIG_FILE)
    local function refreshAll()
        for _, f in ipairs(sanitizers) do f() end
        for _, f in ipairs(refreshers) do f() end
        lastChams = 0
    end
    Button(pG, "Salvar configuracao", function()
        if type(writefile) ~= "function" then status.Text = "writefile indisponivel neste executor." return end
        local ok, err = pcall(function() writefile(CONFIG_FILE, HttpService:JSONEncode(serialize(Settings))) end)
        status.Text = ok and ("Salvo em " .. CONFIG_FILE) or ("Falha ao salvar: " .. tostring(err))
    end)
    Button(pG, "Carregar configuracao", function()
        if type(readfile) ~= "function" then status.Text = "readfile indisponivel neste executor." return end
        if type(isfile) == "function" and not isfile(CONFIG_FILE) then status.Text = "Arquivo nao encontrado." return end
        local ok, data = pcall(function() return HttpService:JSONDecode(readfile(CONFIG_FILE)) end)
        if not ok or type(data) ~= "table" then status.Text = "Arquivo invalido." return end
        merge(Settings, data)
        refreshAll()
        status.Text = "Configuracao carregada."
    end)
    Button(pG, "Restaurar padrao", function()
        copyInto(Settings, Defaults)
        refreshAll()
        status.Text = "Padrao restaurado."
    end)
    Section(pG, "Teclas")
    local keyBtns = {}
    local function updateKeyButtons()
        keyBtns.Menu.Text = "Tecla do menu: " .. Keys.Menu.Name .. (capturing == "Menu" and "  (pressione uma tecla)" or "")
        keyBtns.Master.Text = "Tecla liga/desliga tudo: " .. Keys.Master.Name .. (capturing == "Master" and "  (pressione uma tecla)" or "")
    end
    keyBtns.Menu = Button(pG, "", function() capturing = "Menu" updateKeyButtons() end)
    keyBtns.Master = Button(pG, "", function() capturing = "Master" updateKeyButtons() end)
    updateKeyButtons()
    Info(pG, "Descarregar: tecla " .. Keys.Unload.Name .. " ou o botao abaixo.")
    Button(pG, "Descarregar script", function() unload() end)

    ---------------- Aba Debug ----------------
    local pD = pages["Debug"]
    Section(pD, "Estado em tempo real")
    local dbg = {
        engine = Info(pD, ""), players = Info(pD, ""), skips = Info(pD, ""), perf = Info(pD, ""), err = Info(pD, ""),
    }
    Button(pD, "Teste do Drawing (quadrado + texto no centro por 3s)", function()
        if not hasDrawing then dbg.err.Text = "Drawing API indisponivel." return end
        local vp = (Workspace.CurrentCamera or Camera).ViewportSize
        local ok, err = pcall(function()
            local sq = Drawing.new("Square")
            sq.Size = Vector2.new(120, 120)
            sq.Position = Vector2.new(vp.X * 0.5 - 60, vp.Y * 0.5 - 60)
            sq.Color = Color3.new(1, 0, 0)
            sq.Thickness = 2
            sq.Filled = false
            sq.Visible = true
            local tx = Drawing.new("Text")
            tx.Text = "DRAWING OK"
            tx.Size = 16
            tx.Center = true
            tx.Outline = true
            tx.Color = Color3.new(1, 1, 1)
            tx.Position = Vector2.new(vp.X * 0.5, vp.Y * 0.5 - 8)
            tx.Visible = true
            task.delay(3, function() killDrawing(sq) killDrawing(tx) end)
        end)
        if not ok then dbg.err.Text = "Teste do Drawing falhou: " .. tostring(err) end
    end)

    function ui.updateDebug()
        dbg.engine.Text = string.format("Drawing API: %s | Highlight parent (Auto): %s",
            hasDrawing and "OK" or "NAO", HLParentName)
        dbg.players.Text = string.format("Rastreados: %d | elegiveis: %d | ESP desenhado: %d | chams ativos: %d",
            stats.total, stats.ok, stats.drawn, chamsCount)
        dbg.skips.Text = string.format("Descartados -> sem personagem: %d | sem root (fora do stream?): %d | mortos: %d | aliados: %d | longe: %d",
            stats.noChar, stats.noRoot, stats.dead, stats.team, stats.far)
        dbg.perf.Text = string.format("FPS: %.0f | erros no loop: %d", fps, errCount)
        dbg.err.Text = "Ultimo erro: " .. (lastErr or "nenhum")
    end

    ---------------- Teclas globais ----------------
    track(UIS.InputBegan, function(input, processed)
        if capturing then
            if input.UserInputType == Enum.UserInputType.Keyboard then
                if input.KeyCode ~= Enum.KeyCode.Escape then Keys[capturing] = input.KeyCode end
                capturing = nil
                updateKeyButtons()
            end
            return
        end
        if processed then return end
        local kc = input.KeyCode
        if kc == Keys.Menu then
            Main.Visible = not Main.Visible
        elseif kc == Keys.Master then
            Settings.Master = not Settings.Master
            refreshAll()
        elseif kc == Keys.Unload then
            unload()
        end
    end)

    selectTab("ESP")
    ui.Gui, ui.Main = Gui, Main
    return ui
end

local UI = buildUI()

------------------------------------------------------------------
-- Loop principal
------------------------------------------------------------------
local function resetStats()
    stats.ok, stats.drawn, stats.noChar, stats.noRoot = 0, 0, 0, 0
    stats.dead, stats.team, stats.far, stats.total = 0, 0, 0, 0
end

local function onRender(dt)
    if not alive then return end
    frameNo = frameNo + 1
    if dt and dt > 0 then fps = fps * 0.9 + (1 / dt) * 0.1 end
    local now = os.clock()
    Camera = Workspace.CurrentCamera
    if not Camera then return end

    local S = Settings
    local E, C = S.ESP, S.Chams
    local wantESP = S.Master and E.Enabled and hasDrawing
    local wantChams = S.Master and C.Enabled

    if now >= nextUI then
        nextUI = now + 0.25
        if UI.Main.Visible then pcall(UI.updateDebug) end
    end

    if not (wantESP or wantChams) then
        if not idle then
            idle = true
            for _, e in pairs(entries) do
                e.ok = false
                if e.active then sweep(e, -1) e.active = false end
                releaseHL(e)
            end
            chamsCount = 0
            chamsWasOn = false
        end
        return
    end
    idle = false

    local vp = Camera.ViewportSize
    ctx.frame = frameNo
    ctx.camPos = Camera.CFrame.Position
    ctx.vx, ctx.vy = vp.X, vp.Y
    ctx.wantESP = wantESP
    ctx.needVis = (wantESP and E.VisCheck) or (wantChams and C.VisCheck)
    ctx.mouse = nil
    if wantESP and E.Tracer and E.TracerOrigin == "Mouse" then ctx.mouse = UIS:GetMouseLocation() end
    if ctx.needVis and (LocalPlayer.Character ~= lastLocalChar or Camera ~= lastCam) then refreshRayFilter() end

    resetStats()
    for _, e in pairs(entries) do
        stats.total = stats.total + 1
        local ok, err = pcall(processEntry, e, now)
        if not ok then
            noteError(err)
            e.ok = false
            pcall(sweep, e, -1)
            e.active = false
        end
    end

    if wantChams then
        chamsWasOn = true
        if now - lastChams >= C.Rate then
            lastChams = now
            chamsTick()
        end
    elseif chamsWasOn then
        chamsWasOn = false
        for _, e in pairs(entries) do releaseHL(e) end
        chamsCount = 0
    end
end

------------------------------------------------------------------
-- Inicializacao e limpeza (um unico caminho de cleanup)
------------------------------------------------------------------
unload = function()
    if not alive then return end
    alive = false
    for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    table.clear(conns)
    for player in pairs(entries) do removeEntry(player) end
    pcall(function() UI.Gui:Destroy() end)
    if genv.__ESP_UNLOAD == unload then genv.__ESP_UNLOAD = nil end
end

for _, p in ipairs(Players:GetPlayers()) do newEntry(p) end
track(Players.PlayerAdded, newEntry)
track(Players.PlayerRemoving, removeEntry)
track(RunService.RenderStepped, function(dt)
    local ok, err = pcall(onRender, dt)
    if not ok then noteError(err) end
end)

genv.__ESP_UNLOAD  = unload
genv.ESP_Settings  = Settings
