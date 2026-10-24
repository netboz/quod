#include <math.h>
#define GRD_TYPE_SIZE 8
#define GRD_ORTHOGONAL
#define USE_MM_RSQRT_SS 0
#include "upstream/source/marching_cubes_33.c"

/* Test harness only: the caller owns a finite z/y/x array of exact integers
 * represented as doubles. Production admission and native integration are
 * deliberately not supplied by this numerical experiment. */
surface *probe_mesh(double *data, unsigned nx, unsigned ny, unsigned nz,
                    double spacing) {
    _GRD grid = {0};
    grid.N[0] = nx; grid.N[1] = ny; grid.N[2] = nz;
    for (unsigned d = 0; d < 3; ++d) grid.d[d] = spacing;
    grid.F = calloc(nz + 1, sizeof(*grid.F));
    if (!grid.F) return NULL;
    for (unsigned z = 0; z <= nz; ++z) {
        grid.F[z] = calloc(ny + 1, sizeof(*grid.F[z]));
        if (!grid.F[z]) {
            for (unsigned k = 0; k < z; ++k) free(grid.F[k]);
            free(grid.F); return NULL;
        }
        for (unsigned y = 0; y <= ny; ++y)
            grid.F[z][y] = data + ((size_t)z * (ny + 1) + y) * (nx + 1);
    }
    MC33 *mc = create_MC33(&grid);
    surface *result = mc ? calculate_isosurface(mc, 0.0) : NULL;
    free_MC33(mc);
    for (unsigned z = 0; z <= nz; ++z) free(grid.F[z]);
    free(grid.F);
    return result;
}
