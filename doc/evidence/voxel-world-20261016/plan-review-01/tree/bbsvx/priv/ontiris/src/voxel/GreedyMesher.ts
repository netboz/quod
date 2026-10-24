import { CHUNK_PAD } from '../core/constants';
import type { IMesher } from './IMesher';
import type { MeshData, BlockPaletteEntry } from './types';

/**
 * Greedy meshing algorithm (0fps.net) with per-vertex color and ambient occlusion.
 *
 * For each of the 6 face directions, sweeps slices along the axis, builds a 2D
 * mask of exposed faces, greedily merges adjacent same-type faces into maximal
 * rectangles (with matching AO), and emits quads with baked vertex colors.
 */
export class GreedyMesher implements IMesher {
  mesh(
    voxelData: ArrayBuffer,
    chunkSize: number,
    palette: BlockPaletteEntry[]
  ): MeshData | null {
    const data = new Uint16Array(voxelData);
    const padSize = chunkSize + 2 * CHUNK_PAD;

    const positions: number[] = [];
    const normals: number[] = [];
    const indices: number[] = [];
    const colors: number[] = [];
    let vertexCount = 0;

    /** Read voxel from padded buffer. */
    const getVoxel = (px: number, py: number, pz: number): number =>
      data[px * padSize * padSize + py * padSize + pz];

    /**
     * Check if a voxel is solid (non-air, non-transparent).
     * Used for AO sampling.
     */
    const isSolid = (px: number, py: number, pz: number): number => {
      const v = getVoxel(px, py, pz);
      if (v === 0) return 0;
      const entry = palette[v];
      return entry && entry.transparent ? 0 : 1;
    };

    /**
     * Compute AO value (0-3) for a vertex given 3 neighbor samples.
     * side1, side2 are the two edge-adjacent voxels; corner is the diagonal.
     */
    const computeAO = (
      side1: number,
      side2: number,
      corner: number
    ): number => {
      if (side1 && side2) return 0;
      return 3 - (side1 + side2 + corner);
    };

    // Axis definitions: for each axis d, define the two tangent axes (u, v)
    // and iterate slices along d.
    // axes[d] = [u, v] where u, v are the other two axes
    const axesPair: [number, number][] = [
      [1, 2], // d=0 (x-axis): u=y, v=z
      [2, 0], // d=1 (y-axis): u=z, v=x
      [0, 1], // d=2 (z-axis): u=x, v=y
    ];

    for (let axis = 0; axis < 3; axis++) {
      const [uAxis, vAxis] = axesPair[axis];

      for (let dir = -1; dir <= 1; dir += 2) {
        // dir = -1 (negative face) or +1 (positive face)
        const backFace = dir < 0;

        // Normal vector for this face direction
        const normal = [0, 0, 0];
        normal[axis] = dir;

        // Sweep each slice along the axis
        for (let slice = 0; slice < chunkSize; slice++) {
          // Build 2D mask of exposed faces
          // mask stores blockType (0 = no face)
          // aoMask stores the 4 AO values per cell packed
          const mask = new Uint16Array(chunkSize * chunkSize);
          const aoValues = new Uint8Array(chunkSize * chunkSize * 4);

          for (let u = 0; u < chunkSize; u++) {
            for (let v = 0; v < chunkSize; v++) {
              // Convert local (slice, u, v) to padded coordinates
              const pos = [0, 0, 0];
              pos[axis] = slice + CHUNK_PAD;
              pos[uAxis] = u + CHUNK_PAD;
              pos[vAxis] = v + CHUNK_PAD;

              const current = getVoxel(pos[0], pos[1], pos[2]);

              // Neighbor in the face direction
              const nPos = [pos[0], pos[1], pos[2]];
              nPos[axis] += dir;
              const neighbor = getVoxel(nPos[0], nPos[1], nPos[2]);

              // Face is visible at the boundary between current (at slice)
              // and neighbor (at slice+dir).
              // For BOTH directions, the face belongs to whichever side is solid.
              // - Positive dir (+1): face is the +axis face of current
              // - Negative dir (-1): face is the -axis face of current
              // In both cases: visible when current is solid and neighbor is air,
              // OR when current is solid-opaque and neighbor is a different transparent type.
              let blockType = 0;
              if (current !== 0 && neighbor === 0) {
                // Current is solid, neighbor is air => face visible
                const cEntry = palette[current];
                if (!cEntry || !cEntry.transparent) {
                  blockType = current;
                }
              } else if (
                current !== 0 &&
                neighbor !== 0 &&
                current !== neighbor
              ) {
                // Both solid but different types: show face if current is opaque
                // and neighbor is transparent
                const cEntry = palette[current];
                const nEntry = palette[neighbor];
                if (
                  (!cEntry || !cEntry.transparent) &&
                  nEntry &&
                  nEntry.transparent
                ) {
                  blockType = current;
                }
              }

              const idx = u * chunkSize + v;
              mask[idx] = blockType;

              if (blockType !== 0) {
                // Compute AO for the 4 vertices of this face
                // The face is on the boundary between current voxel and neighbor.
                // For positive face: face is at pos + dir*0.5 in axis direction
                // For AO, sample voxels adjacent to the face on the solid side.

                // The solid block's padded position (always current)
                const solidPos = pos;

                // Face sits at solidPos + dir*0.5 along axis.
                // AO samples are in the plane of the face, offset from face center.
                // We sample in the (u, v) directions around each vertex.

                // The 4 vertices are at corners: (u +/- 0.5, v +/- 0.5)
                // relative to the face center.
                // For each vertex, sample 3 neighbors: sideU, sideV, corner.

                // AO sampling position base: one step in the face normal direction
                // from the solid block
                const aoBase = [solidPos[0], solidPos[1], solidPos[2]];
                aoBase[axis] += dir;

                // The 4 corners: (du, dv) in {-1, 0} x {-1, 0} mapped to actual offsets
                const cornerOffsets: [number, number][] = [
                  [0, 0],   // vertex 0: (u, v) corner
                  [1, 0],   // vertex 1: (u+1, v) corner
                  [0, 1],   // vertex 2: (u, v+1) corner
                  [1, 1],   // vertex 3: (u+1, v+1) corner
                ];

                for (let ci = 0; ci < 4; ci++) {
                  const [du, dv] = cornerOffsets[ci];
                  // Side neighbors in u and v directions
                  const sideUPos = [aoBase[0], aoBase[1], aoBase[2]];
                  sideUPos[uAxis] += du === 0 ? -1 : 1;

                  const sideVPos = [aoBase[0], aoBase[1], aoBase[2]];
                  sideVPos[vAxis] += dv === 0 ? -1 : 1;

                  const cornerPos = [aoBase[0], aoBase[1], aoBase[2]];
                  cornerPos[uAxis] += du === 0 ? -1 : 1;
                  cornerPos[vAxis] += dv === 0 ? -1 : 1;

                  const s1 = isSolid(sideUPos[0], sideUPos[1], sideUPos[2]);
                  const s2 = isSolid(sideVPos[0], sideVPos[1], sideVPos[2]);
                  const c = isSolid(cornerPos[0], cornerPos[1], cornerPos[2]);

                  aoValues[idx * 4 + ci] = computeAO(s1, s2, c);
                }
              }
            }
          }

          // Greedy merge the mask into maximal rectangles
          const merged = new Uint8Array(chunkSize * chunkSize);

          for (let u = 0; u < chunkSize; u++) {
            for (let v = 0; v < chunkSize; v++) {
              const idx = u * chunkSize + v;
              if (mask[idx] === 0 || merged[idx]) continue;

              const blockType = mask[idx];
              const ao0 = aoValues[idx * 4 + 0];
              const ao1 = aoValues[idx * 4 + 1];
              const ao2 = aoValues[idx * 4 + 2];
              const ao3 = aoValues[idx * 4 + 3];

              // Expand width (along v)
              let width = 1;
              while (v + width < chunkSize) {
                const nIdx = u * chunkSize + v + width;
                if (
                  mask[nIdx] !== blockType ||
                  merged[nIdx] ||
                  aoValues[nIdx * 4 + 0] !== ao0 ||
                  aoValues[nIdx * 4 + 1] !== ao1 ||
                  aoValues[nIdx * 4 + 2] !== ao2 ||
                  aoValues[nIdx * 4 + 3] !== ao3
                ) {
                  break;
                }
                width++;
              }

              // Expand height (along u)
              let height = 1;
              let canExpand = true;
              while (u + height < chunkSize && canExpand) {
                for (let dv = 0; dv < width; dv++) {
                  const nIdx = (u + height) * chunkSize + v + dv;
                  if (
                    mask[nIdx] !== blockType ||
                    merged[nIdx] ||
                    aoValues[nIdx * 4 + 0] !== ao0 ||
                    aoValues[nIdx * 4 + 1] !== ao1 ||
                    aoValues[nIdx * 4 + 2] !== ao2 ||
                    aoValues[nIdx * 4 + 3] !== ao3
                  ) {
                    canExpand = false;
                    break;
                  }
                }
                if (canExpand) height++;
              }

              // Mark all cells in the rectangle as merged
              for (let du = 0; du < height; du++) {
                for (let dv = 0; dv < width; dv++) {
                  merged[(u + du) * chunkSize + v + dv] = 1;
                }
              }

              // Emit quad: 4 vertices + 2 triangles
              // Vertex positions in local chunk coordinates
              // The face is at slice + (dir > 0 ? 1 : 0) along axis
              const faceOffset = dir > 0 ? 1 : 0;

              // The 4 corners of the quad
              // Corner ordering: we need consistent winding for correct normals.
              // For positive-direction faces (normal pointing +axis):
              //   v0(u, v), v1(u+h, v), v2(u+h, v+w), v3(u, v+w) — CCW from outside
              // For negative-direction faces (normal pointing -axis):
              //   v0(u, v), v1(u, v+w), v2(u+h, v+w), v3(u+h, v) — CCW from outside

              const p = [0, 0, 0];
              const verts: [number, number, number][] = [
                [0, 0, 0],
                [0, 0, 0],
                [0, 0, 0],
                [0, 0, 0],
              ];

              // Base position
              p[axis] = slice + faceOffset;
              p[uAxis] = u;
              p[vAxis] = v;

              if (!backFace) {
                // Positive face: CCW winding from outside
                // v0: (u, v)
                verts[0] = [p[0], p[1], p[2]];
                // v1: (u+height, v)
                const p1 = [p[0], p[1], p[2]];
                p1[uAxis] += height;
                verts[1] = [p1[0], p1[1], p1[2]];
                // v2: (u+height, v+width)
                const p2 = [p[0], p[1], p[2]];
                p2[uAxis] += height;
                p2[vAxis] += width;
                verts[2] = [p2[0], p2[1], p2[2]];
                // v3: (u, v+width)
                const p3 = [p[0], p[1], p[2]];
                p3[vAxis] += width;
                verts[3] = [p3[0], p3[1], p3[2]];
              } else {
                // Negative face: reverse winding for correct CCW from outside
                // v0: (u, v)
                verts[0] = [p[0], p[1], p[2]];
                // v1: (u, v+width)
                const p1 = [p[0], p[1], p[2]];
                p1[vAxis] += width;
                verts[1] = [p1[0], p1[1], p1[2]];
                // v2: (u+height, v+width)
                const p2 = [p[0], p[1], p[2]];
                p2[uAxis] += height;
                p2[vAxis] += width;
                verts[2] = [p2[0], p2[1], p2[2]];
                // v3: (u+height, v)
                const p3 = [p[0], p[1], p[2]];
                p3[uAxis] += height;
                verts[3] = [p3[0], p3[1], p3[2]];
              }

              // Get color from palette
              const entry = palette[blockType];
              const r = entry ? entry.color[0] : 1;
              const g = entry ? entry.color[1] : 0;
              const b = entry ? entry.color[2] : 1;

              // AO values for the 4 vertices of the merged quad
              // Since we only merge faces with identical AO patterns, all cells
              // in the merged rect have the same AO. Use the original cell's AO.
              const aoAlpha = [
                0.4 + ao0 * 0.2,
                0.4 + ao1 * 0.2,
                0.4 + ao2 * 0.2,
                0.4 + ao3 * 0.2,
              ];

              // Map AO corner indices to vertex order.
              // Corner layout: 0=(u,v), 1=(u+1,v), 2=(u,v+1), 3=(u+1,v+1)
              // Positive face verts: v0(u,v), v1(u+h,v), v2(u+h,v+w), v3(u,v+w)
              //   v0->ao0, v1->ao1, v2->ao3, v3->ao2
              // Negative face verts: v0(u,v), v1(u,v+w), v2(u+h,v+w), v3(u+h,v)
              //   v0->ao0, v1->ao2, v2->ao3, v3->ao1
              let vertAO: number[];
              if (!backFace) {
                vertAO = [aoAlpha[0], aoAlpha[1], aoAlpha[3], aoAlpha[2]];
              } else {
                vertAO = [aoAlpha[0], aoAlpha[2], aoAlpha[3], aoAlpha[1]];
              }

              // Emit vertices
              const baseVertex = vertexCount;
              for (let vi = 0; vi < 4; vi++) {
                positions.push(verts[vi][0], verts[vi][1], verts[vi][2]);
                normals.push(normal[0], normal[1], normal[2]);
                const aoFactor = 0.4 + vertAO[vi] * 0.6;
                colors.push(r * aoFactor, g * aoFactor, b * aoFactor, 1.0);
              }
              vertexCount += 4;

              // Emit triangles with correct winding.
              // Use the AO-based flip to avoid the "AO interpolation artifact"
              // (anisotropy fix): flip the quad diagonal based on AO.
              // If ao0 + ao3 > ao1 + ao2, flip the diagonal.
              const rawAO = !backFace
                ? [ao0, ao1, ao3, ao2]
                : [ao0, ao2, ao3, ao1];

              if (rawAO[0] + rawAO[2] > rawAO[1] + rawAO[3]) {
                // Standard diagonal: 0-2-1, 0-3-2 (CW for BabylonJS left-handed)
                indices.push(
                  baseVertex + 0,
                  baseVertex + 2,
                  baseVertex + 1
                );
                indices.push(
                  baseVertex + 0,
                  baseVertex + 3,
                  baseVertex + 2
                );
              } else {
                // Flipped diagonal: 1-3-2, 0-3-1 (CW for BabylonJS left-handed)
                indices.push(
                  baseVertex + 1,
                  baseVertex + 3,
                  baseVertex + 2
                );
                indices.push(
                  baseVertex + 0,
                  baseVertex + 3,
                  baseVertex + 1
                );
              }
            }
          }
        }
      }
    }

    if (vertexCount === 0) return null;

    return {
      positions: new Float32Array(positions),
      normals: new Float32Array(normals),
      indices: new Uint32Array(indices),
      colors: new Float32Array(colors),
      vertexCount,
      indexCount: indices.length,
    };
  }
}
