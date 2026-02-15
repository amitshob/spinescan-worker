import sys
import trimesh

inp = sys.argv[1]
out = sys.argv[2]

mesh = trimesh.load(inp, force="mesh")

# trimesh can return a Scene; convert to one mesh
if isinstance(mesh, trimesh.Scene):
    mesh = trimesh.util.concatenate(
        [g for g in mesh.geometry.values() if isinstance(g, trimesh.Trimesh)]
    )

if not isinstance(mesh, trimesh.Trimesh):
    raise RuntimeError(f"Expected Trimesh, got {type(mesh)}")

if mesh.faces is None or len(mesh.faces) == 0:
    raise RuntimeError("Loaded mesh has no faces/triangles")

mesh.export(out)
print(f"[convert] Wrote STL: {out}")
