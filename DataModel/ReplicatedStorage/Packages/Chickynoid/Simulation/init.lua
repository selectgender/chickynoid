--[=[
    @class Simulation
    Simulation handles physics for characters on both the client and server.
]=]

local Types = require(script.Parent.Types)

local Simulation = {}
Simulation.__index = Simulation

local playerSize = Vector3.new(3,5,3)

Simulation.collisionModule = require(script.CollisionModule)



function Simulation.new(config: Types.ISimulationConfig)
    local self = setmetatable({}, Simulation)

    self.pos = Vector3.new(0, 5, 0)
    self.vel = Vector3.new(0, 0, 0)
    self.jump = 0
    
    

    self.whiteList = config.raycastWhitelist

    --players feet height - height goes from -2.5 to +2.5
    --So any point below this number is considered the players feet
    --the distance between middle and feetHeight is "ledge"
    self.feetHeight = config.feetHeight

    -- How big an object we can step over
    self.stepSize = config.stepSize

    --Scale for making units in "units per second"
    self.perSecond = 1 / 60

    local buildDebugSphereModelThing = true

    if buildDebugSphereModelThing == true then
        local model = Instance.new("Model")
        model.Name = "Chickynoid"

        local part = Instance.new("Part")
        self.debugMarker = part
        part.Size = playerSize
        part.Shape = Enum.PartType.Block
        part.CanCollide = false
        part.CanQuery = false
        part.CanTouch = false
        part.Parent = model
        part.Anchored = true
        part.TopSurface = Enum.SurfaceType.Smooth
        part.BottomSurface = Enum.SurfaceType.Smooth
        part.Transparency = 0.4
        part.Material = Enum.Material.SmoothPlastic
        part.Color = Color3.new(0, 1, 1)

        model.PrimaryPart = part
        model.Parent = game.Workspace
        self.debugModel = model

    
    end
    
    Simulation.collisionModule:MakeWorld(game.Workspace.GameArea, playerSize )

    
    return self
end

--	It is very important that this method rely only on whats in the cmd object
--	and no other client or server state can "leak" into here
--	or the server and client state will get out of sync.
--	You'll have to manage it so clients/server see the same thing in workspace.GameArea for raycasts...

function Simulation:ProcessCommand(cmd)
    --Ground parameters
    local maxSpeed = 24 * self.perSecond
    local accel = 400 * self.perSecond
    local jumpPunch = 50 * self.perSecond

    local brakeAccel = 400 * self.perSecond --how hard to brake if we're turning around

    local result = nil
    local onGround = nil
  
    --Check ground
    onGround  = self:DoGroundCheck(self.pos, self.feetHeight)

    --Figure out our acceleration (airmove vs on ground)
    if onGround == nil then
        --different if we're in the air?
    end

    --Did the player have a movement request?
    local wishDir = nil
    local flatVel = Vector3.new(self.vel.x, 0, self.vel.z)

    if cmd.x ~= 0 or cmd.z ~= 0 then
        wishDir = Vector3.new(cmd.x, 0, cmd.z).Unit
    end

    --see if we're accelerating back against our current flatvel
    local shouldBrake = false
    if wishDir ~= nil and wishDir:Dot(flatVel.Unit) < -0.1 then
        shouldBrake = true
    end
    if onGround ~= nil and wishDir == nil then
        shouldBrake = true
    end
    if shouldBrake == true then
        flatVel = self:Accelerate(Vector3.zero, maxSpeed, brakeAccel, flatVel, cmd.deltaTime)
    end

    --movement acceleration (walking/running/airmove)
    --Does nothing if we don't have an input
    if wishDir ~= nil then
        flatVel = self:Accelerate(wishDir, maxSpeed, accel, flatVel, cmd.deltaTime)
    end

    self.vel = Vector3.new(flatVel.x, self.vel.y, flatVel.z)

    --Do jumping?
    if onGround ~= nil then
        if self.jump > 0 then
            self.jump -= cmd.deltaTime
            if (self.jump < 0) then
                self.jump = 0
            end
        end

        --jump!
        if cmd.y > 0 and self.jump <= 0 then
            self.vel += Vector3.new(0, jumpPunch * (1 + self.jump), 0)
            self.jump = 0.2
        end
    end

    --Gravity
    if onGround == nil then
        --gravity
        self.vel += Vector3.new(0, -198 * self.perSecond * cmd.deltaTime, 0)
    end

    --Sweep the player through the world
    local walkNewPos, walkNewVel, hitSomething = self:ProjectVelocity(self.pos, self.vel)

    --STEPUP - the magic that lets us traverse uneven world geometry
    --the idea is that you redo the player movement but "if I was x units higher in the air"
    --it adds a lot of extra casts...
  
    local flatVel = Vector3.new(self.vel.x, 0, self.vel.z)
    
    -- Do we even need to?                               (not jumping!)
    if (onGround ~= nil  and hitSomething == true and self.jump == 0 ) then
        
        --first move upwards as high as we can go
        local headHit = self.collisionModule:Sweep(self.pos, self.pos + Vector3.new(0, self.stepSize, 0))
        
        --Project forwards
        local stepUpNewPos, stepUpNewVel, stepHitSomething = self:ProjectVelocity(headHit.endPos, flatVel)

        --Trace back down
        local traceDownPos = stepUpNewPos

        local hitResult = self.collisionModule:Sweep(
            traceDownPos,
            traceDownPos - Vector3.new(0, self.stepSize, 0)
        )

        stepUpNewPos = hitResult.endPos

        --See if we're mostly on the ground after this? otherwise rewind it
        local ground = self:DoGroundCheck(stepUpNewPos, (-2.5 + self.stepSize))

        if ground ~= nil then
            self.pos = stepUpNewPos
            self.vel = stepUpNewVel
        else
            --cancel the whole thing
            --NO STEPUP
            self.pos = walkNewPos
            self.vel = walkNewVel
        end
    else
        --NO STEPUP
        self.pos = walkNewPos
        self.vel = walkNewVel
    end

 
    
    
    --position the debug visualizer
    if self.debugModel then
        self.debugModel:PivotTo(CFrame.new(self.pos))
    end
end

function Simulation:Accelerate(wishdir, wishspeed, accel, velocity, dt)
    local wishVelocity = wishdir * wishspeed
    local pushDir = wishVelocity - velocity
    local pushLen = pushDir.Magnitude

    if pushLen < 0.01 then
        return velocity
    end

    local canPush = accel * dt * wishspeed
    if canPush > pushLen then
        canPush = pushLen
    end

    return velocity + (pushDir.Unit * canPush)
end

function Simulation:Destroy()
    if self.debugModel then
        self.debugModel:Destroy()
    end
end

function Simulation:DoGroundCheck(pos, feetHeight)
    local results = self.collisionModule:Sweep(pos, pos + Vector3.new(0, -0.1, 0))
    
    if (results.fraction < 1) then
        return results 
    end
    return nil 
end

function Simulation:ClipVelocity(input, normal, overbounce)
    local backoff = input:Dot(normal)

    if backoff < 0 then
        backoff = backoff * overbounce
    else
        backoff = backoff / overbounce
    end

    local changex = normal.x * backoff
    local changey = normal.y * backoff
    local changez = normal.z * backoff

    return Vector3.new(input.x - changex, input.y - changey, input.z - changez)
end

function Simulation:ProjectVelocity(startPos, startVel)
    local movePos = startPos
    local moveVel = startVel
    local hitSomething = false
    
  
    --Project our movement through the world
    local planes = {}
    
    for bumps = 0, 3 do
   
        if moveVel.magnitude < 0.001 then
            --done
            break
        end
        
        
        if moveVel:Dot(startVel) < 0 then
            --we projected back in the opposite direction from where we started. No.
            moveVel = Vector3.new(0, 0, 0)
   
            break
        end

        local result = self.collisionModule:Sweep(movePos, movePos + (moveVel))
        
 
        if (result.fraction > 0) then
            movePos = result.endPos
            
        end
        --See if we swept the whole way?
        if result.fraction == 1 then
            break
        end        
        
        if result.fraction < 1 then
            
            hitSomething = true
        end

        if result.allSolid == true then
            --all solid, don't do anything
            --(this doesn't mean we wont project along a normal!)
            moveVel = Vector3.new(0,0,0)
            break
        end
        --Hit!
        
        --timeLeft -= (timeLeft * result.fraction)
        
        if (planes[result.planeNum] == nil) then
            
            planes[result.planeNum] = true
            --Deflect the velocity and keep going
            
            local inVel = moveVel
            moveVel = self:ClipVelocity(moveVel, result.normal, 1.0)
        end
    end
    
    
    return movePos, moveVel, hitSomething
end

--This could be a lot more classy!
function Simulation:WriteState()
    local record = {}
    record.pos = self.pos
    record.vel = self.vel
    record.jump = self.jump
    
    return record
end

--This too!
function Simulation:ReadState(record)
     
    self.pos = record.pos 
    self.vel = record.vel
    self.jump = record.jump

end

return Simulation
