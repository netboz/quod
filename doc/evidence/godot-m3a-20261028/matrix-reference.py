#!/usr/bin/env python3
"""Independent matrix reference for the quaternion native-boundary check."""
import json
import math
import sys

def product(a, b):
    return [[sum(a[i][k] * b[k][j] for k in range(4)) for j in range(4)] for i in range(4)]

def pose(position, angles):
    x, y, z = angles
    cx, sx, cy, sy, cz, sz = math.cos(x), math.sin(x), math.cos(y), math.sin(y), math.cos(z), math.sin(z)
    rx = [[1,0,0,0],[0,cx,-sx,0],[0,sx,cx,0],[0,0,0,1]]
    ry = [[cy,0,sy,0],[0,1,0,0],[-sy,0,cy,0],[0,0,0,1]]
    rz = [[cz,-sz,0,0],[sz,cz,0,0],[0,0,1,0],[0,0,0,1]]
    result = product(product(rz, ry), rx)
    for i in range(3):
        result[i][3] = position[i]
    return result

frames = [[1300,-700,2900,17,43,89],[-1900,1100,2300,31,67,113]]
matrices = [pose(f[:3], [math.radians(v) for v in f[3:]]) for f in frames]
leaf = dict(position_mm=[300,500,-900], rotation_mrad=[230,470,710])
world = product(product(*matrices), pose(leaf['position_mm'], [v/1000 for v in leaf['rotation_mrad']]))
print(json.dumps(dict(reference='parent-first homogeneous matrices; Rz*Ry*Rx; no quaternion helper',
    python=sys.version, frames_degrees_mm=frames, leaf=leaf,
    position_metres=[world[i][3]/1000 for i in range(3)],
    transformed_basis=[[world[i][j] for i in range(3)] for j in range(3)]), indent=2))
