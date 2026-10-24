//! Pure, versioned terrain arithmetic. No world handles, I/O or policy state.
//! V1 samples are odd signed bytes in [-127,127], x fastest, then y, then z.
//! Strictly interior edge crossings and even spacing >=256 mm preserve a
//! margin of at least two millimetres from lattice nodes before rounding.
mod mc33;
mod mc33_table;
pub(crate) mod chunk;
use std::collections::BTreeMap;

pub(crate) type Point = (i64,i64,i64);
pub(crate) type Triangle = (u32,u32,u32);
pub(crate) type Mesh = (Vec<Point>,Vec<Triangle>);

#[derive(Debug,PartialEq,Eq,rustler::NifTaggedEnum)]
pub(crate) enum Error {
    InvalidVoxelField,
    VoxelCellAllowance(u64,u64),
    VoxelVertexAllowance(u64,u64),
    VoxelTriangleAllowance(u64,u64),
    VoxelCoordinateEncoding,
    InvalidVoxelSurface,
    VoxelByteAllowance(u64,u64),
}

const CORNERS: [[usize;3];8] = [[0,0,0],[0,1,0],[0,1,1],[0,0,1],
                                [1,0,0],[1,1,0],[1,1,1],[1,0,1]];
const EDGES: [(usize,usize);12] = [(0,1),(1,2),(2,3),(3,0),(4,5),(5,6),
                                  (6,7),(7,4),(0,4),(1,5),(2,6),(3,7)];

pub(crate) fn surface(data: &[u8], dims: (u32,u32,u32), spacing: u32,
                      limits: (u64,u64,u64)) -> Result<Mesh,Error> {
    Ok(generate(data,dims,spacing,limits)?.mesh)
}

pub(super) struct Generated {
    pub mesh: Mesh,
    pub cells: Vec<std::ops::Range<usize>>,
}

fn generate(data: &[u8], dims: (u32,u32,u32), spacing: u32,
            limits: (u64,u64,u64)) -> Result<Generated,Error> {
    let (nx,ny,nz) = (dims.0 as usize,dims.1 as usize,dims.2 as usize);
    let cells = (dims.0 as u64).checked_mul(dims.1 as u64)
        .and_then(|n| n.checked_mul(dims.2 as u64)).ok_or(Error::InvalidVoxelField)?;
    if cells == 0 || spacing < 256 || !spacing.is_multiple_of(2) { return Err(Error::InvalidVoxelField); }
    if cells > limits.0 { return Err(Error::VoxelCellAllowance(cells,limits.0)); }
    let samples = nx.checked_add(1).and_then(|x| ny.checked_add(1).and_then(|y| x.checked_mul(y)))
        .and_then(|n| nz.checked_add(1).and_then(|z| n.checked_mul(z)))
        .ok_or(Error::InvalidVoxelField)?;
    if data.len() != samples || data.iter().any(|v| v & 1 == 0) { return Err(Error::InvalidVoxelField); }
    for size in [dims.0,dims.1,dims.2] {
        if size as u64 * spacing as u64 > i64::MAX as u64 { return Err(Error::VoxelCoordinateEncoding); }
    }
    let sample = |x: usize,y: usize,z: usize| data[(z*(ny+1)+y)*(nx+1)+x] as i8;
    let mut points = Vec::new();
    let mut triangles = Vec::new();
    let mut ranges = Vec::new();
    // A lattice edge has exactly one key regardless of which cell reaches it.
    let mut vertices = BTreeMap::new();
    for z in 0..nz { for y in 0..ny { for x in 0..nx {
        let density = CORNERS.map(|c| sample(x+c[0],y+c[1],z+c[2]));
        let start = triangles.len();
        for edges in mc33::triangles(density) {
            if triangles.len() as u64 >= limits.2 {
                return Err(Error::VoxelTriangleAllowance(triangles.len() as u64+1,limits.2));
            }
            let mut indices = [0;3];
            for (slot,edge) in edges.into_iter().enumerate() {
                let (key,position) = if edge == 12 {
                    ((x,y,z,3), ((x as i64)*spacing as i64+spacing as i64/2,
                                (y as i64)*spacing as i64+spacing as i64/2,
                                (z as i64)*spacing as i64+spacing as i64/2))
                } else {
                    let (mut a,mut b) = EDGES[edge];
                    if CORNERS[a] > CORNERS[b] { std::mem::swap(&mut a,&mut b); }
                    let ca = CORNERS[a];
                    let cb = CORNERS[b];
                    let axis = (0..3).find(|k| ca[*k] != cb[*k]).unwrap();
                    let da = density[a] as i64;
                    let db = density[b] as i64;
                    if (da < 0) == (db < 0) { return Err(Error::InvalidVoxelSurface); }
                    let denominator = da.abs()+db.abs();
                    // Round the exact positive edge fraction; ties go toward
                    // the larger global coordinate, including negative chunks.
                    let offset = (spacing as i64*da.abs()+denominator/2)/denominator;
                    let mut p = [(x+ca[0]) as i64*spacing as i64,
                                 (y+ca[1]) as i64*spacing as i64,
                                 (z+ca[2]) as i64*spacing as i64];
                    p[axis] += offset;
                    ((x+ca[0],y+ca[1],z+ca[2],axis),(p[0],p[1],p[2]))
                };
                indices[slot] = match vertices.get(&key) {
                    Some(index) => *index,
                    None => {
                        if points.len() as u64 >= limits.1 {
                            return Err(Error::VoxelVertexAllowance(points.len() as u64+1,limits.1));
                        }
                        let index = u32::try_from(points.len()).map_err(|_| Error::VoxelCoordinateEncoding)?;
                        points.push(position); vertices.insert(key,index); index
                    }
                };
            }
            let [a,b,c] = indices.map(|i| points[i as usize]);
            let u = [(b.0-a.0) as i128,(b.1-a.1) as i128,(b.2-a.2) as i128];
            let v = [(c.0-a.0) as i128,(c.1-a.1) as i128,(c.2-a.2) as i128];
            if (0..3).all(|k| u[(k+1)%3]*v[(k+2)%3] == u[(k+2)%3]*v[(k+1)%3]) {
                return Err(Error::InvalidVoxelSurface);
            }
            triangles.push((indices[0],indices[1],indices[2]));
        }
        ranges.push(start..triangles.len());
    }}}
    Ok(Generated { mesh: (points,triangles), cells: ranges })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn corrected_mc33_reference_cases_and_integer_geometry() {
        for (line,row) in include_str!("mc33_reference.txt").lines().enumerate() {
            let (input,expected) = row.split_once('|').unwrap();
            let d: Vec<i8> = input.split_whitespace().map(|s| s.parse().unwrap()).collect();
            let mut actual = mc33::triangles(d.clone().try_into().unwrap());
            for t in &mut actual { t.sort(); }
            actual.sort();
            let expected: Vec<[usize;3]> = expected.split_whitespace().map(|t| {
                t.split(',').map(|s| s.parse().unwrap()).collect::<Vec<_>>().try_into().unwrap()
            }).collect();
            assert_eq!(actual,expected,"reference fixture {line}");
            let input = [0,4,1,5,3,7,2,6].map(|k| d[k] as u8);
            let mesh = surface(&input,(1,1,1),256,(1,13,12)).unwrap();
            assert_eq!(mesh.1.len(),expected.len());
        }
    }

    #[test]
    fn plane_winds_out_of_negative_solid_and_repeats_exactly() {
        let d = [-1i8,-1,1,1,-1,-1,1,1].map(|v| v as u8);
        let mesh = surface(&d,(1,1,1),500,(1,13,12)).unwrap();
        assert_eq!(mesh,surface(&d,(1,1,1),500,(1,13,12)).unwrap());
        assert_eq!(mesh.0.len(),4);
        assert_eq!(mesh.1.len(),2);
        for (a,b,c) in &mesh.1 {
            let (a,b,c) = (mesh.0[*a as usize],mesh.0[*b as usize],mesh.0[*c as usize]);
            assert_eq!((a.1,b.1,c.1),(250,250,250));
            assert!((b.2-a.2)*(c.0-a.0)-(b.0-a.0)*(c.2-a.2)>0);
        }
    }

    #[test]
    fn near_node_crossing_stays_distinct_at_minimum_spacing() {
        let mut d = [127u8;8]; d[0] = (-1i8) as u8;
        let (points,triangles) = surface(&d,(1,1,1),256,(1,13,12)).unwrap();
        assert_eq!(triangles.len(),1);
        let mut points = points; points.sort();
        assert_eq!(points,vec![(0,0,2),(0,2,0),(2,0,0)]);
    }

    #[test]
    fn empty_and_solid_are_valid_meshes_but_invalid_encoding_is_rejected() {
        for sample in [1u8,255] {
            assert_eq!(surface(&[sample;8],(1,1,1),256,(1,0,0)),Ok((vec![],vec![])));
        }
        for sample in [0u8,2,128,254] {
            assert_eq!(surface(&[sample;8],(1,1,1),256,(1,13,12)),Err(Error::InvalidVoxelField));
        }
        assert_eq!(surface(&[1;7],(1,1,1),256,(1,13,12)),Err(Error::InvalidVoxelField));
        for spacing in [0,128,255,257] {
            assert_eq!(surface(&[1;8],(1,1,1),spacing,(1,13,12)),Err(Error::InvalidVoxelField));
        }
    }

    #[test]
    fn explicit_allowances_report_the_resource_that_was_exceeded() {
        let d = [-1i8,-1,1,1,-1,-1,1,1].map(|v| v as u8);
        assert_eq!(surface(&d,(1,1,1),256,(0,13,12)),Err(Error::VoxelCellAllowance(1,0)));
        assert_eq!(surface(&d,(1,1,1),256,(1,0,12)),Err(Error::VoxelVertexAllowance(1,0)));
        assert_eq!(surface(&d,(1,1,1),256,(1,13,1)),Err(Error::VoxelTriangleAllowance(2,1)));
    }

    #[test]
    fn adjacent_cells_share_faces_for_every_binary_sign_configuration() {
        for configuration in 0u16..4096 {
            let data: Vec<u8> = (0..12).map(|k| if configuration & (1 << k) == 0 {255} else {1}).collect();
            let (points,triangles) = surface(&data,(2,1,1),256,(2,26,24)).unwrap();
            let mut edges = BTreeMap::new();
            for (a,b,c) in triangles {
                for (a,b) in [(a,b),(b,c),(c,a)] {
                    let mut pair = [points[a as usize],points[b as usize]]; pair.sort();
                    *edges.entry(pair).or_insert(0) += 1;
                }
            }
            for ([a,b],count) in edges {
                if a.0 == 256 && b.0 == 256 {
                    let outside = (a.1 == b.1 && [0,256].contains(&a.1)) ||
                                  (a.2 == b.2 && [0,256].contains(&a.2));
                    if !outside { assert_eq!(count,2,"seam at configuration {configuration}: {a:?} {b:?}"); }
                }
            }
        }
    }
}
