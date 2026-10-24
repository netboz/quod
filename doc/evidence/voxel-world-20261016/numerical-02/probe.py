"""Reproducible MC33/mm-format experiment, not a production terrain engine."""
import ctypes as c
import hashlib
import json
import math
import pathlib
import time
from collections import Counter

HERE = pathlib.Path(__file__).resolve().parent
Vec = c.c_double * 3
Tri = c.c_uint * 3


class Surface(c.Structure):
    _fields_ = [('triangles', c.POINTER(Tri)), ('vertices', c.POINTER(Vec)),
                ('normals', c.c_void_p), ('colors', c.c_void_p),
                ('nv', c.c_uint), ('nt', c.c_uint)]


lib = c.CDLL('/tmp/quod-voxel-mc33-probe-01.so')
lib.probe_mesh.argtypes = [c.POINTER(c.c_double), c.c_uint, c.c_uint, c.c_uint, c.c_double]
lib.probe_mesh.restype = c.POINTER(Surface)
lib.free_surface_memory.argtypes = [c.POINTER(Surface)]


def mesh(values, size, spacing):
    values = [max(-127, min(127, 2 * math.floor(v * 64 / spacing) + 1)) for v in values]
    data = (c.c_double * len(values))(*values)
    start = time.perf_counter_ns()
    result = lib.probe_mesh(data, *size, spacing)
    elapsed = time.perf_counter_ns() - start
    if not result:
        raise RuntimeError('MC33 returned NULL')
    try:
        s = result.contents
        vertices = [tuple(s.vertices[i]) for i in range(s.nv)]
        triangles = [tuple(s.triangles[i]) for i in range(s.nt)]
    finally:
        lib.free_surface_memory(result)
    return vertices, triangles, elapsed


def quantize(vertices):
    return [tuple(math.floor(v + 0.5) if v >= 0 else math.ceil(v - 0.5)
                  for v in point) for point in vertices]


def area(vertices, triangle):
    a, b, d = (vertices[i] for i in triangle)
    u = [b[k] - a[k] for k in range(3)]
    v = [d[k] - a[k] for k in range(3)]
    return sum((u[(k+1) % 3]*v[(k+2) % 3] - u[(k+2) % 3]*v[(k+1) % 3])**2
               for k in range(3))


def metrics(name, values, size, spacing):
    vertices, triangles, elapsed = mesh(values, size, spacing)
    points = quantize(vertices)
    bad = [i for i, t in enumerate(triangles) if area(points, t) == 0]
    distinct_collinear = sum(len({points[j] for j in triangles[i]}) == 3 for i in bad)
    record = dict(name=name, samples=len(values), vertices=len(vertices), triangles=len(triangles),
                  raw_degenerate=sum(area(vertices, t) == 0 for t in triangles),
                  quantized_degenerate=len(bad), distinct_collinear=distinct_collinear,
                  native_mesh_ns=elapsed)
    if bad:
        t = triangles[bad[0]]
        record['first_degenerate'] = dict(indices=t, raw=[vertices[i] for i in t],
                                          rounded=[points[i] for i in t])
    record['geometry_sha256'] = hashlib.sha256(json.dumps([points, triangles], separators=(',', ':')).encode()).hexdigest()
    return record, (points, triangles)


# BBSvx-style value noise/smoothstep in fixed point; this experiment uses SHA256
# over full signed coordinates to avoid inheriting BBSvx's 32-bit coordinate wrap.
Q = 65536


def corner(seed, x, y, z):
    key = f'{seed}:{x}:{y}:{z}'.encode('ascii')
    return int.from_bytes(hashlib.sha256(key).digest()[:2], 'big') * 2 - Q


def smooth(t):
    return (t*t*(3*Q-2*t)) // (Q*Q)


def lerp(a, b, t):
    return a + ((b-a)*t)//Q


def noise(seed, x, y, z, scale):
    cell = [v//scale for v in (x, y, z)]
    t = [smooth((v % scale)*Q//scale) for v in (x, y, z)]
    a, b, d = cell
    rows = [lerp(corner(seed, a, b+j, d+k), corner(seed, a+1, b+j, d+k), t[0])
            for k in range(2) for j in range(2)]
    return lerp(lerp(rows[0], rows[1], t[1]), lerp(rows[2], rows[3], t[1]), t[2])


def sample(fn, n, spacing, origin=(0, 0, 0)):
    return [fn(origin[0]+x*spacing, origin[1]+y*spacing, origin[2]+z*spacing)
            for z in range(n+1) for y in range(n+1) for x in range(n+1)]


def height(seed, amplitude, scale):
    return lambda x, y, z: y - (3500 + amplitude*noise(seed, x, 0, z, scale)//Q)


def boundary_edges(geometry, axis, coordinate, offset):
    vertices, triangles = geometry
    edges = Counter()
    for a, b, d in triangles:
        for i, j in ((a, b), (b, d), (d, a)):
            u, v = vertices[i], vertices[j]
            if u[axis] == coordinate and v[axis] == coordinate and u != v:
                u = tuple(u[k]+offset[k] for k in range(3))
                v = tuple(v[k]+offset[k] for k in range(3))
                edges[tuple(sorted((u, v)))] += 1
    return sorted(edge for edge, count in edges.items() if count == 1)


def main():
    rows = []
    near_node = [-1] + [32767]*7
    first, _ = metrics('one-cell-near-node', near_node, (1, 1, 1), 500)
    rows.append(first)
    n, spacing = 16, 500
    fixtures = [('flat', lambda x, y, z: y-3500),
                ('incline', lambda x, y, z: y-((x+z)//3+1500)),
                ('sphere', lambda x, y, z: math.isqrt((x-4000)**2+(y-4000)**2+(z-4000)**2)-2300),
                ('tunnel', lambda x, y, z: max(y-5000, 1200-math.isqrt((y-3000)**2+(z-4000)**2)))]
    for seed in range(128):
        for amplitude, scale in [(2000, 4000), (6000, 2000)]:
            fixtures.append((f'height-{seed}-{amplitude}-{scale}', height(seed, amplitude, scale)))
    for name, fn in fixtures:
        row, _ = metrics(name, sample(fn, n, spacing), (n, n, n), spacing)
        rows.append(row)
    fn = height(9, 6000, 2000)
    left, lg = metrics('seam-left', sample(fn, n, spacing, (-8000, 0, 0)), (n, n, n), spacing)
    right, rg = metrics('seam-right', sample(fn, n, spacing), (n, n, n), spacing)
    repeat, _ = metrics('seam-right-repeat', sample(fn, n, spacing), (n, n, n), spacing)
    seam_equal = boundary_edges(lg, 0, 8000, (-8000, 0, 0)) == boundary_edges(rg, 0, 0, (0, 0, 0))
    result = dict(experiment='signed odd 8-bit density, saturation +/-127; nearest integer mm; no welding',
                  fixtures=rows, seam_equal=seam_equal,
                  unchanged_repeat_equal=right['geometry_sha256'] == repeat['geometry_sha256'],
                  seam_fixtures=[left, right],
                  chunks_with_quantized_degeneracy=sum(r['quantized_degenerate'] > 0 for r in rows),
                  total_triangles=sum(r['triangles'] for r in rows),
                  quantized_degenerate=sum(r['quantized_degenerate'] for r in rows))
    (HERE/'results.json').write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps({k: v for k, v in result.items() if k not in ['fixtures', 'seam_fixtures']}, indent=2))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
