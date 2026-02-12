import sys
import trimesh

inp = sys.argv[1]
out = sys.argv[2]

mesh = trimesh.load(inp, force="mesh")
# Ensure it's a triangular mesh
if hasattr(mesh, "triangles") and len(mesh.triangles) == 0:
    raise RuntimeError("Loaded mesh has no triangles")

mesh.export(out)
print(f"[convert] Wrote STL: {out}")
