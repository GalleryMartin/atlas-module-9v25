local genv = getgenv()

if genv.VLHitbox then
	local old = genv.VLHitbox

	if old.render then
		old.render:Disconnect()
	end

	if old.added then
		old.added:Disconnect()
	end

	if old.removed then
		old.removed:Disconnect()
	end

	for _, v in pairs(old.balls or {}) do
		pcall(function()
			if v.box then
				v.box:Destroy()
			end

			if v.ring then
				v.ring:Destroy()
			end
		end)
	end
end

if genv.VolleyballLegendsHitboxExpander then
	pcall(function()
		genv.VolleyballLegendsHitboxExpander.cleanup()
	end)

	genv.VolleyballLegendsHitboxExpander = nil
end

local CS = game:GetService("CollectionService")
local RS = game:GetService("RunService")
local cam = workspace.CurrentCamera
local vec2 = Vector2.new

local rad = 12
local col = Color3.fromRGB(0, 255, 255)
local trans = 0.25
local thick = 2.5

local balls = {}

local function addBall(ball)
	if not ball:IsA("Model") or not ball:IsDescendantOf(workspace) then
		return
	end

	local root = ball.PrimaryPart or ball:FindFirstChildWhichIsA("BasePart", true)

	if not root or balls[ball] then
		return
	end

	local box = Instance.new("Part")
	box.Shape = Enum.PartType.Ball
	box.Size = Vector3.new(rad * 2, rad * 2, rad * 2)
	box.CFrame = root.CFrame
	box.Transparency = 1
	box.CanCollide = false
	box.CanTouch = false
	box.CanQuery = true
	box.Anchored = true
	box.CastShadow = false
	box.Massless = true
	box.Parent = ball

	local ring = Drawing.new("Circle")
	ring.Color = col
	ring.Filled = false
	ring.NumSides = 128
	ring.Thickness = thick
	ring.Transparency = trans
	ring.Visible = false

	balls[ball] = {
		box = box,
		ring = ring
	}
end

local function killBall(ball)
	local d = balls[ball]

	if not d then
		return
	end

	pcall(function()
		d.box:Destroy()
		d.ring:Destroy()
	end)

	balls[ball] = nil
end

local added = CS:GetInstanceAddedSignal("Ball"):Connect(addBall)
local removed = CS:GetInstanceRemovedSignal("Ball"):Connect(killBall)

local render = RS.RenderStepped:Connect(function()
	cam = workspace.CurrentCamera

	for ball, d in pairs(balls) do
		local root = ball.PrimaryPart or ball:FindFirstChildWhichIsA("BasePart", true)

		if not root or not ball.Parent then
			killBall(ball)
		else
			d.box.CFrame = root.CFrame

			local pos, on = cam:WorldToViewportPoint(root.Position)

			if on and pos.Z > 0 then
				local edge = cam:WorldToViewportPoint(root.Position + cam.CFrame.RightVector * rad)
				local r = math.abs(edge.X - pos.X)

				if r ~= r or r <= 0 then
					d.ring.Visible = false
				else
					d.ring.Position = vec2(pos.X, pos.Y)
					d.ring.Radius = r
					d.ring.Visible = true
				end
			else
				d.ring.Visible = false
			end
		end
	end
end)

for _, ball in ipairs(CS:GetTagged("Ball")) do
	addBall(ball)
end

genv.VLHitbox = {
	render = render,
	added = added,
	removed = removed,
	balls = balls
}