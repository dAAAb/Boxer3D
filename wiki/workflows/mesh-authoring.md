---
title: Authoring a canonical USDZ mesh
updated: 2026-04-23
---

# Mesh authoring

Each tracked class gets a "Tesla-style" ghost mesh rendered inside its
OBB. Style brief: extremely minimal, rounded, abstract silhouettes —
recognisable but not realistic. Current meshes: `cup`, `laptop`,
`keyboard`, `bottle`.

## The 10-minute recipe

1. **Pick a base primitive** — cube for rectilinear objects (laptop
   shell, keyboard deck), screw-revolved profile for cylindrical objects
   (bottle, cup), SDF/skeleton for organic shapes (avoid for now).
2. **Bevel edges generously** — that's where the "rounded abstract"
   look comes from.
3. **Keep polycount low** — our reference meshes sit around 500–1000
   vertices. We render dozens of these in AR; keep GPU cost low.
4. **Export USDZ at real-world size** — no runtime scaling.
   [`MeshLibrary`](../components/meshlibrary.md) assumes this.
5. **Drop `<label>.usdz` into `boxer/`** (label must match YOLO/COCO
   lowercase class name), add the label to `MeshLibrary.registeredLabels`.

## Blender scripts (external)

The four existing meshes were built procedurally in Blender with Python
scripts. These scripts live under the user's `~/Downloads/` and are not
tracked in this repo. For reference:

| Mesh | Script | Build method |
|---|---|---|
| `cup.usdz` | `~/Downloads/process_cup.py` | `tk_0028.glb` → Blender clean-up |
| `laptop.usdz` | `~/Downloads/build_laptop.py` | Two rounded boxes, hinged at 105° |
| `keyboard.usdz` | `~/Downloads/build_keyboard.py` | Frame + 7 mm raised deck |
| `bottle.usdz` | `~/Downloads/build_bottle.py` | Screw modifier on 18-point profile |

Preview script: `~/Downloads/render_laptop_preview.py` — Workbench-engine
still render for visual verification before you bring the USDZ into the
bundle. Useful because Blender's viewport shading ≠ Boxer3D's ghost
material.

If you want these scripts tracked in the repo, copy them into a new
`meshes/` directory and add a line to this doc.

## Gotchas

- **Blender `primitive_cube_add(size=1)` is a 1 m cube, not 2 m.** When
  scaling by `(w/2, d/2, h/2)` you'll get half the intended size. Scale
  by `(w, d, h)` instead. The `build_laptop.py` hit this early.
- **"Pure white preview render"** — if your Workbench render comes out
  blank, you probably called `read_factory_settings(use_empty=True)` and
  no World datablock exists. Create one explicitly:
  `bpy.data.worlds.new("world")`.
- **Flat-shaded exports look chunky.** Apply smooth shading on all
  objects before export: `bpy.ops.object.shade_smooth()`.
- **Avoid textures if you can** — the ghost material can bake an AO map
  onto the diffuse channel if your USDZ ships one, which is nice but not
  required. Solid white + alpha 0.80 is the baseline look.

## Real-world size targets

| Mesh | Max dim | Notes |
|---|---|---|
| `cup` | 10.5 cm | includes handle |
| `laptop` | 31 cm | closed: 28.5; open at 105°: height 22.9 |
| `keyboard` | 40 cm | 14 cm deep, 2.3 cm tall |
| `bottle` | 24 cm | 7 cm diameter |

These match typical real-world sizes so the mesh "fits" the detected
OBB without further scaling. If a user points at a 50 cm bottle, the
mesh is already tiny-ish inside the detected OBB — that's the intended
look ("canonical silhouette hint"), not a bug.
