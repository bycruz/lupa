# lupa

An incredibly fast, pure LuaJIT game creation framework.

![showcase](showcase.png)

## How does it compare to Love2D?

This is very experimental, so it's not ready to replace your love2d usage, not yet.

![comparison](compare.png)

Functionally identical code running on both results in 5x faster speeds on lupa compared to love2d.

## How is it so fast?

Sorted by impact

1. LuaJIT is used throughout the entire process. No Lua C Api overhead.
2. It is written from scratch, so everything can be scrutinized and optimized.
3. Vulkan is used.

## Drawing

Everything goes through the `draw` object your app is handed in `draw(self, draw)`.

### 2D

```lua
draw:setColor(1, 0.5, 0.2, 1)   -- r, g, b, a (alpha optional, defaults to 1)
draw:rect(x, y, w, h)
```

The default view is orthographic with `y = 0` at the **bottom** of the window.

### 3D

```lua
draw:setCamera({
    position = { x = 0, y = 6, z = 18 },
    target   = { x = 0, y = 0, z = 0 },
    up       = { x = 0, y = 1, z = 0 },   -- optional, this is the default
    fov      = math.pi / 3,               -- optional, radians
    near     = 0.1,                       -- optional
    far      = 1000,                      -- optional
})

draw:setLight({                           -- optional; off by default
    direction = { x = -0.4, y = -1, z = -0.3 },
    color     = { 1, 0.95, 0.88 },
    ambient   = { 0.16, 0.19, 0.28 },
})

draw:setColor(0.9, 0.5, 0.2, 1)
draw:cube(x, y, z, size)
draw:sphere(x, y, z, radius [, segments])
draw:plane(x, y, z, width, depth)         -- horizontal, facing +Y

draw:clearLight()
draw:setOrtho()                           -- back to the 2D view
```

Primitives batch into the same draw call as 2D rects, so a scene is one
`vkCmdDrawIndexed` no matter how many objects it holds.

#### Model transforms

```lua
draw:pushModel()
draw:translate(x, y, z)
draw:rotate(angle, axisX, axisY, axisZ)   -- axis defaults to +Y
draw:scale(s)                             -- or (sx, sy, sz)
draw:cube(0, 0, 0, 1)
draw:popModel()

draw:resetModel()                         -- clear the whole stack
```

The transform is applied on the CPU as vertices are written, in this order:

```
world = model * (localVertex * scale) + primitivePosition
```

so the position argument is **not** rotated -- `rotate(...)` then `cube(5, 0, 0, 1)`
spins the cube in place rather than orbiting it. Put the position inside the
transform (`translate(5, 0, 0)` then `cube(0, 0, 0, 1)`) if you want it to orbit.

### Textures

Setting a texture is state; drawing is separate. There is no `draw:image`:

```lua
local tex = assets:image("assets/player.png")   -- PNG, cached by path

draw:setTexture(tex)
draw:rect(x, y, tex.width, tex.height)           -- one quad, whole texture
draw:cube(x, y, z, size)                         -- or any 3D primitive
draw:clearTexture()                              -- back to flat colour
```

`draw:setTextureRect` picks which part of the texture maps onto each shape. It is
**per draw call**, so a sprite sheet can be sliced into as many cells as you like
in one frame:

```lua
draw:setTexture(sheet)

draw:setTextureRect(0.25, 0, 0.5, 0.5)           -- one cell
draw:rect(x, y, 64, 64)

draw:setTextureRect(0, 0, 8, 4)                  -- tile 8 by 4
draw:rect(x, y, 256, 128)
```

Values past 1 repeat rather than clamp, because the sampler address mode is
repeat -- so tiling is just a rectangle larger than the texture, and needs no
separate API. The rectangle also remaps the UVs of meshes, which is how a plane
gets a tiled ground texture.

`draw:setColor` tints, as it does for untextured shapes. Images live in a single
texture array, so textured and untextured geometry still batches into one draw
call. A PNG larger than `MAX_TEXTURE_WIDTH` x `MAX_TEXTURE_HEIGHT` is
box-filtered down to fit.

Textures can also be built from raw RGBA8 bytes: `assets:texture(w, h, pixels)`.

### Meshes

Meshes are resources, so they are built through `assets` alongside textures,
and drawn through `draw`:

```lua
local mesh = assets:obj("assets/torus.obj")      -- Wavefront .obj, cached

-- or build one directly: 8 floats per vertex -- x, y, z, nx, ny, nz, u, v --
-- followed by 0-based triangle indices
local tri = assets:mesh({
    0, 0, 0,  0, 0, 1,  0, 0,
    1, 0, 0,  0, 0, 1,  1, 0,
    0, 1, 0,  0, 0, 1,  0, 1,
}, { 0, 1, 2 })

draw:setTexture(tex)
draw:pushModel()
draw:translate(x, y, z)
draw:rotate(angle, 0, 1, 0)
draw:mesh(mesh, 0, 0, 0, scale)
draw:popModel()
```

Meshes are immutable: build once, draw as many times as you like. They take
vertex colours, the current texture and the model matrix exactly like the
built-in primitives, and batch into the same draw call.

The `.obj` loader handles positions, UVs, normals and n-gon faces (fan
triangulated). Files without normals get flat per-triangle normals so lighting
still works.

### Limits worth knowing

- **One projection and one shader per frame.** There is a single `viewProj`
  uniform, so a frame is drawn either with the 2D ortho or with a camera, not
  both. Mixing a 3D world with a 2D HUD needs per-batch state.
- **Textures are a fixed array** of `MAX_TEXTURES` layers, each
  `MAX_TEXTURE_WIDTH` x `MAX_TEXTURE_HEIGHT`, allocated up front.
- Loads are synchronous, and there are no mipmaps yet.

## Tests

`bench/` has verification scenarios that check emitted geometry without needing
to inspect the screen: `verify3d`, `verifytex`, `verifymesh`.

## Usage

Set up [lde](https://lde.sh).

```
lde add lupa --git https://github.com/bycruz/lupa
```
