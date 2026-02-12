import sys
import trimesh

inp = sys.argv[1]
out = sys.argv[2]

mesh = trimesh.load(inp, force="mesh")
mesh.export(out)
print("Wrote", out)

