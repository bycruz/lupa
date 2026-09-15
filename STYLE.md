# Style guide

The rules this repository is written to. They describe the code that is here and
bind everything added from now on.

## Naming

* camelCase for locals, parameters, fields and functions (`placeMesh`, `curTexture`).
* PascalCase for classes and their constructors (`Draw`, `Assets`, `Mesh`, `Math`).
* A method is `function Class:method(...)`, a module function is `function module.name(...)`,
  and a private helper is a `local function` above its first use.
* Names say what happened, not how: `placeMesh` not `uploadVerts`, `emitRect` not `pushQuad`.
  A caller should know what a call did without opening it.
* Booleans read as predicates (`headless`, `mapped`, `capturePending`).
* Units are spelled out when they are ambiguous (`dt`, `bytesPerRow`, `radians`), and one name
  means one thing everywhere (`layer` is always a texture array layer).
* Established short names are fine: `dt`, `uv`, `ffi`, `px`, `w`, `h`.

## Typing

Everything is typed: a value that crosses a function boundary has a type, and every function is
covered by one of the forms below.

* A signature that fits on a line is a single `---@type fun(...)` above the function. It types the
  parameters, the body and the call sites, for locals, module functions, methods and reassigned
  fields alike.

  ```lua
  ---@type fun(self: lupa.Draw, x: number, y: number, z: number, size: number?)
  function Draw:cube(x, y, z, size)
  ```

* A longer signature keeps the block form: `---@param` for each parameter and `---@return` for each
  result, including nil-able ones (`---@return lupa.Texture?`). Return types are named only in the
  block form; inside `fun(...)` they are bare types.
* `---@return` is dropped when the return is trivially inferred: a tail call, a returned local, or
  branches that each return a typed value. The checker infers those, conditional returns included.
* Shared shapes are declared once with `---@class` and `---@field`, covering the state a module
  writes as well as the methods it adds, which is what keeps a class split across files typed.
* `---@type` on module-level tables; `---@cast` after a narrowing `assert`, and where the layer
  below hands back more than its own types declare.
* A cached ctype is `---@type ffi.ctype*`. Where the result needs a precise type, annotate the
  constructor `---@type fun(...): T` with `---@diagnostic disable-next-line: assign-type-mismatch`
  directly above it.
* Annotations are the documentation: they replace prose, so a typed function needs no comment.

## Comments

Comments are for safety notes only — the non-obvious invariant that would otherwise look like a
mistake, and that removing would silently break something. The prefix is `-- safety:` and it sits
next to the code it is about:

```lua
-- safety: the frame's viewProj is written in place, so an ortho drawn after a camera
-- would keep the camera's terms if the write missed any of them
lpmath.mat4.orthoInto(draw.transforms.viewProj, 0, width, 0, height, -1, 1)
```

That is the whole list. Do not write:

* file headers, module preambles or section banners,
* a paragraph above a function explaining what it does,
* comments that restate the code (`-- increment the counter`),
* commented-out code (delete it, git remembers),
* TODO and FIXME notes,
* doc blocks that repeat what the LuaCATS annotations or the parameter names already say.

If code needs prose to be understood, rename it, split it, or annotate it. If it needs a note
about what would break without it, that is a one or two line `-- safety:` comment.

## Files and modules

* One module per file, named after the module (`src/draw/batch.lua` is `lupa.draw.batch`). A class
  that grows past a few hundred lines becomes a directory with an `init.lua` that composes the
  parts, each part holding one responsibility.
* A module builds its table at the top and returns it at the bottom; a class is that table with
  `Class.__index = Class` and a `Class.new` constructor.
* Dependencies run one way: `lupa` requires `hood` and `winit`, never the reverse, and a module
  never requires something that requires it.

## Functions

* Small and flat. Guard clauses first, early `return` over nested `if`.
* `assert(value, "message")` for invariants, with the message naming what was expected
  (`"lupa: texture array is full"`).
* Never mutate a parameter you do not own; return a new value instead.
* A function that writes into a caller's struct writes every element of it, so nothing of what was
  there before survives.

## FFI

* **FFI types are cached.** `ffi.new`, `ffi.cast` and `ffi.typeof` parse a type string on every
  call, so no type string appears at runtime: build the constructor once at module scope and call
  that.

  ```lua
  ---@type fun(count: number, initial: number[]?): ffi.cdata*
  local floatArray = ffi.typeof("float[?]")        -- module scope, once
  local vertices = floatArray(#values, values)     -- runtime, no type lookup

  ---@type ffi.cdata* float pointer ctype
  local floatPointer = ffi.typeof("float*")
  local floats = ffi.cast(floatPointer, scratch)   -- ffi.cast takes the ctype
  ```

  Casting through a cached ctype reinterprets a value; calling one converts, and refuses an array.
* A record layout that mirrors a shader is declared once (`src/draw/records.lua`) and the shader
  carries the matching declaration.
* A size the GPU needs is taken from `ffi.sizeof` of the type, never written out twice.

## Performance

* Nothing allocates per frame. Reuse scratch tables, matrices and vectors, write geometry in
  place, and keep closures out of loops.
* Hoist lookups out of loops, including metatable-driven ones.
* Plain `local` upvalues, field access and array-shaped data beat metatable indirection in code
  that runs every frame; keep the friendly API at the boundary.
* Changes that claim a speedup carry before and after numbers with them.

## Tests

* One file per area, `tests/<area>.test.lua`, written with `lde-test`:
  `test.it("third person sentence describing the behaviour", function() ... end)`.
* A test asserts observable behaviour — pixels, counts, emitted records — not implementation
  details.
* Rendering tests draw through `tests/fixtures/screen.lua`, which renders headless and reads the
  frame back.
* Anything that was broken once and could regress silently gets a test that would have caught it.
