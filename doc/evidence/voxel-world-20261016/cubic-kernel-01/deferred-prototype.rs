//! Centered sample cells, with material-preserving greedy face merging.
//! Coordinates are relative to the chunk's lower cell boundary (half a sample
//! before its first owned site). Adjacent chunks use the same integer planes.
use super::{Error,Mesh,Point};
use std::collections::BTreeMap;

pub(super) fn generate(density:&[u8],materials:&[u8],spacing:u32,
                      limits:(u64,u64,u64)) -> Result<(Mesh,Vec<u16>),Error> {
    if density.len() != 1331 || materials.len() != 2662 || spacing < 256
        || spacing%2 != 0 || spacing > u32::MAX/8 || density.iter().any(|d| d&1 == 0) {
        return Err(Error::InvalidVoxelField);
    }
    if limits.0 < 512 { return Err(Error::VoxelCellAllowance(512,limits.0)); }
    let site = |p:[i32;3]| ((p[2]+1)*121+(p[1]+1)*11+p[0]+1) as usize;
    let mut vertices = Vec::new();
    let mut indices = BTreeMap::<Point,u32>::new();
    let mut triangles = Vec::new();
    let mut palette = Vec::new();
    for axis in 0..3 {
        let u = (axis+1)%3; let v = (axis+2)%3;
        for side in [-1,1] {
            for slice in 0..8 {
                let mut faces = [None;64];
                for y in 0..8 { for x in 0..8 {
                    let mut p = [0;3]; p[axis] = slice; p[u] = x; p[v] = y;
                    let i = site(p); p[axis] += side;
                    if (density[i] as i8) < 0 && (density[site(p)] as i8) > 0 {
                        faces[(y*8+x) as usize] = Some(u16::from_be_bytes([materials[2*i],materials[2*i+1]]));
                    }
                } }
                for y in 0..8 { for x in 0..8 {
                    let Some(material) = faces[y*8+x] else { continue; };
                    let mut width = 1;
                    while x+width < 8 && faces[y*8+x+width] == Some(material) { width += 1; }
                    let mut height = 1;
                    while y+height < 8 && (x..x+width).all(|i| faces[(y+height)*8+i] == Some(material)) {
                        height += 1;
                    }
                    let count = triangles.len() as u64+2;
                    if count > limits.2 { return Err(Error::VoxelTriangleAllowance(count,limits.2)); }
                    let mut quad = [0;4];
                    for (k,(a,b)) in [(x,y),(x+width,y),(x+width,y+height),(x,y+height)].into_iter().enumerate() {
                        let mut p = [0i64;3]; p[axis] = (slice+(side+1)/2) as i64;
                        p[u] = a as i64; p[v] = b as i64;
                        let point = (p[0]*spacing as i64,p[1]*spacing as i64,p[2]*spacing as i64);
                        quad[k] = match indices.get(&point) {
                            Some(i) => *i,
                            None => {
                                let count = vertices.len() as u64+1;
                                if count > limits.1 { return Err(Error::VoxelVertexAllowance(count,limits.1)); }
                                let i = vertices.len() as u32;
                                vertices.push(point); indices.insert(point,i); i
                            }
                        };
                    }
                    let [a,b,c,d] = quad;
                    if side > 0 { triangles.extend([(a,b,c),(a,c,d)]); }
                    else { triangles.extend([(a,c,b),(a,d,c)]); }
                    palette.extend([material,material]);
                    for j in y..y+height { for i in x..x+width { faces[j*8+i] = None; } }
                } }
            }
        }
    }
    Ok(((vertices,triangles),palette))
}

#[cfg(test)]
mod tests {
    use super::*;
    fn input(f:impl Fn(i32,i32,i32)->(i8,u16)) -> (Vec<u8>,Vec<u8>) {
        let mut d = Vec::new(); let mut m = Vec::new();
        for z in -1..=9 { for y in -1..=9 { for x in -1..=9 {
            let (density,material) = f(x,y,z); d.push(density as u8); m.extend(material.to_be_bytes());
        } } }
        (d,m)
    }
    fn cross(a:Point,b:Point,c:Point) -> Point {
        let u = (b.0-a.0,b.1-a.1,b.2-a.2); let v = (c.0-a.0,c.1-a.1,c.2-a.2);
        (u.1*v.2-u.2*v.1,u.2*v.0-u.0*v.2,u.0*v.1-u.1*v.0)
    }
    #[test]
    fn closed_cube_merges_to_six_outward_faces() {
        let (d,m) = input(|x,y,z| (if [x,y,z].iter().all(|v| (0..8).contains(v)) {-127} else {127},9));
        let ((points,triangles),materials) = generate(&d,&m,500,(512,8,12)).unwrap();
        assert_eq!(points.len(),8); assert_eq!(triangles.len(),12); assert_eq!(materials,vec![9;12]);
        for (a,b,c) in triangles {
            let (a,b,c) = (points[a as usize],points[b as usize],points[c as usize]);
            let n = cross(a,b,c);
            assert!(n.0*(a.0-2000)+n.1*(a.1-2000)+n.2*(a.2-2000) > 0);
        }
        assert!(matches!(generate(&d,&m,500,(512,8,11)),Err(Error::VoxelTriangleAllowance(12,11))));
        assert!(matches!(generate(&d,&m,500,(512,7,12)),Err(Error::VoxelVertexAllowance(8,7))));
    }
    #[test]
    fn centered_plane_has_exact_shared_edges_and_categorical_materials() {
        let (d,m) = input(|_,y,_| (if y < 2 {-127} else {127},7));
        let (mesh,materials) = generate(&d,&m,500,(512,10000,10000)).unwrap();
        assert_eq!(mesh.1.len(),2); assert_eq!(materials,vec![7;2]);
        assert!(mesh.0.iter().all(|p| p.1-250 == 750));
        let left:Vec<_> = mesh.0.iter().filter(|p| p.0 == 4000).map(|p| (p.0-250,p.1-250,p.2-250)).collect();
        let right:Vec<_> = mesh.0.iter().filter(|p| p.0 == 0).map(|p| (p.0+4000-250,p.1-250,p.2-250)).collect();
        let mut left = left; let mut right = right; left.sort();right.sort();assert_eq!(left,right);
        for &(a,b,c) in &mesh.1 { assert!(cross(mesh.0[a as usize],mesh.0[b as usize],mesh.0[c as usize]).1 > 0); }
        let (d,m) = input(|x,y,_| (if y < 2 {-127} else {127},if x < 4 {7} else {9}));
        let (split,materials) = generate(&d,&m,500,(512,10000,10000)).unwrap();
        assert_eq!(split.1.len(),4); assert_eq!(materials,vec![7,7,9,9]);
        assert_eq!((split,materials),generate(&d,&m,500,(512,10000,10000)).unwrap());
    }
    #[test]
    fn halo_never_generates_duplicate_owned_cells() {
        for density in [-127,127] {
            let (d,m) = input(|_,_,_| (density,0));
            assert_eq!(generate(&d,&m,500,(512,0,0)).unwrap(),((vec![],vec![]),vec![]));
        }
        let (d,m) = input(|x,y,z| (if (x+y+z)%2 == 0 {-127} else {127},1));
        let (mesh,materials) = generate(&d,&m,500,(512,10000,6144)).unwrap();
        assert_eq!(mesh.1.len(),3072); assert_eq!(materials.len(),3072);
        assert!(mesh.0.iter().all(|p| [p.0,p.1,p.2].iter().all(|n| (0..=4000).contains(n))));
    }
}
