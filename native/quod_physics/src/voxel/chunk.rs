//! Immutable numerical output retained by the existing geometry consumers.
//! A resource handle is local storage, never an authored world/chunk identity.
use super::{generate,Error,Generated,CORNERS};
use rapier3d::prelude::*;

pub(crate) struct Prepared {
    collision: std::sync::Arc<Collision>,
}
pub(crate) struct Collision {
    pub generated: Generated,
    pub density: Vec<u8>,
    pub spacing: u32,
    pub shape: Option<SharedShape>,
}
impl std::ops::Deref for Prepared {
    type Target = Collision;
    fn deref(&self) -> &Collision { &self.collision }
}

#[derive(Clone)]
pub(crate) struct Shared(pub std::sync::Arc<Prepared>);
impl std::ops::Deref for Shared {
    type Target = Prepared;
    fn deref(&self) -> &Prepared { &self.0 }
}
#[rustler::resource_impl]
impl rustler::Resource for Shared {}
impl<'a> rustler::Decoder<'a> for Shared {
    fn decode(term: rustler::Term<'a>) -> rustler::NifResult<Self> {
        let resource: rustler::ResourceArc<Self> = term.decode()?;
        Ok((*resource).clone())
    }
}
impl rustler::Encoder for Shared {
    fn encode<'a>(&self,env: rustler::Env<'a>) -> rustler::Term<'a> {
        rustler::ResourceArc::new(self.clone()).encode(env)
    }
}

impl Prepared {
    pub fn new(density: &[u8], materials: &[u8], spacing: u32,
               limits: (u64,u64,u64,u64), previous: Option<&Self>) -> Result<(Self,Vec<u8>),Error> {
        if density.len() != 1331 || materials.len() != 2662 || spacing > u32::MAX/8
            || density.iter().any(|v| v & 1 == 0) {
            return Err(Error::InvalidVoxelField);
        }
        let sites: Vec<_> = (1..=9).flat_map(|z| (1..=9).flat_map(move |y|
            (1..=9).map(move |x| (z*11+y)*11+x))).collect();
        let data: Vec<_> = sites.iter().map(|i| density[*i]).collect();
        let mut collision = match previous.filter(|p| p.spacing == spacing && p.density == data) {
            Some(p) => {
                let vertices = p.generated.mesh.0.len() as u64;
                let triangles = p.generated.mesh.1.len() as u64;
                if vertices > limits.1 { return Err(Error::VoxelVertexAllowance(vertices,limits.1)); }
                if triangles > limits.2 { return Err(Error::VoxelTriangleAllowance(triangles,limits.2)); }
                p.collision.clone()
            },
            None => {
                let generated = generate(&data,(8,8,8),spacing,(limits.0,limits.1,limits.2))?;
                std::sync::Arc::new(Collision { generated,density: data,spacing,shape: None })
            }
        };
        // A complete resource is a 16-byte header plus 38 bytes per triangle:
        // nine u32 local millimetre coordinates and one u16 material identity.
        // Flat face normals are computed by the renderer from these positions.
        let bytes = 16 + 38*collision.generated.mesh.1.len() as u64;
        if bytes > limits.3 { return Err(Error::VoxelByteAllowance(bytes,limits.3)); }
        // Only new collision data is uniquely owned here. Appearance changes
        // share the original cell index and Rapier shape without rebuilding.
        if let Some(new) = std::sync::Arc::get_mut(&mut collision) {
            if !new.generated.mesh.1.is_empty() {
                let points = new.generated.mesh.0.iter().map(|p|
                    Vector::new(p.0 as f64/1000.0,p.1 as f64/1000.0,p.2 as f64/1000.0)).collect();
                let faces = new.generated.mesh.1.iter().map(|t| [t.0,t.1,t.2]).collect();
                new.shape = Some(SharedShape::trimesh(points,faces).map_err(|_| Error::InvalidVoxelSurface)?);
            }
        }
        let generated = &collision.generated;
        let mut payload = Vec::with_capacity(bytes as usize);
        payload.extend_from_slice(b"QVT1");
        payload.extend_from_slice(&spacing.to_be_bytes());
        payload.extend_from_slice(&(generated.mesh.1.len() as u32).to_be_bytes());
        payload.extend_from_slice(&(generated.mesh.0.len() as u32).to_be_bytes());
        for (cell,range) in generated.cells.iter().enumerate() {
            if range.is_empty() { continue; }
            let [x,y,z] = [cell%8,(cell/8)%8,cell/64];
            // Nearest-to-surface solid corner; coordinate order breaks ties.
            // Material ids are categorical, never averaged.
            let material = CORNERS.iter().filter_map(|c| {
                let i = ((z+c[2])*9+y+c[1])*9+x+c[0];
                let d = collision.density[i] as i8;
                (d < 0).then_some((-(d as i16),c,i))
            }).min().map(|(_,_,i)| {
                let site = sites[i]; u16::from_be_bytes([materials[2*site],materials[2*site+1]])
            }).ok_or(Error::InvalidVoxelSurface)?;
            for &(a,b,c) in &generated.mesh.1[range.clone()] {
                for i in [a,b,c] {
                    let p = generated.mesh.0[i as usize];
                    for n in [p.0,p.1,p.2] { payload.extend_from_slice(&(n as u32).to_be_bytes()); }
                }
                payload.extend_from_slice(&material.to_be_bytes());
            }
        }
        Ok((Self { collision },payload))
    }

    pub fn collision_eq(&self,other: &Self) -> bool {
        std::sync::Arc::ptr_eq(&self.collision,&other.collision) ||
            (self.spacing == other.spacing && self.density == other.density
                && self.generated.mesh == other.generated.mesh)
    }

    /// Classify against the actual quantized triangles, not the curved
    /// interpolant. A lattice corner's known sign anchors segment parity.
    /// Ambiguous edge/coplanar rays try other corners; unresolved cases refuse.
    /// Point coordinates are local millimetres. None is never interpreted as air.
    pub fn contains(&self,point: Vector) -> Option<bool> {
        let s = self.spacing as f64;
        if !point.is_finite() || point.min_element() < 0.0 || point.max_element() > 8.0*s { return None; }
        let cell = (point/s).floor().min(Vector::splat(7.0));
        let [x,y,z] = [cell.x as usize,cell.y as usize,cell.z as usize];
        let index = (z*8+y)*8+x;
        let range = &self.generated.cells[index];
        if range.is_empty() { return Some((self.density[(z*9+y)*9+x] as i8) < 0); }
        'corners: for c in CORNERS {
            let a = Vector::new(((x+c[0]) as u64*self.spacing as u64) as f64,
                                ((y+c[1]) as u64*self.spacing as u64) as f64,
                                ((z+c[2]) as u64*self.spacing as u64) as f64);
            let inside = (self.density[((z+c[2])*9+y+c[1])*9+x+c[0]] as i8) < 0;
            if point == a { return Some(inside); }
            let mut crossings = 0;
            for &(i,j,k) in &self.generated.mesh.1[range.clone()] {
                let vertices = [i,j,k].map(|i| {
                    let v = self.generated.mesh.0[i as usize];
                    Vector::new(v.0 as f64,v.1 as f64,v.2 as f64)
                });
                match segment_triangle(a,point,vertices) {
                    Some(true) => crossings += 1,
                    Some(false) => (),
                    None => continue 'corners,
                }
            }
            return Some(inside ^ (crossings%2 != 0));
        }
        None
    }
}

// Adaptive exact orientation signs avoid tolerance-dependent inside/outside
// decisions near thin triangles. Coplanar or edge crossings remain ambiguous.
fn segment_triangle(a: Vector,b: Vector,[p,q,r]: [Vector;3]) -> Option<bool> {
    let coord = |v: Vector| robust::Coord3D { x: v.x,y: v.y,z: v.z };
    let sign = |a,b,c,d| robust::orient3d(coord(a),coord(b),coord(c),coord(d));
    let sa = sign(p,q,r,a); let sb = sign(p,q,r,b);
    if (sa > 0.0 && sb > 0.0) || (sa < 0.0 && sb < 0.0) { return Some(false); }
    let sides = [sign(a,b,p,q),sign(a,b,q,r),sign(a,b,r,p)];
    if sides.iter().any(|s| *s > 0.0) && sides.iter().any(|s| *s < 0.0) { return Some(false); }
    if sa == 0.0 || sb == 0.0 || sides.contains(&0.0) { None } else { Some(true) }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn prepare(f: impl Fn(usize,usize,usize)->i8) -> Prepared {
        let mut d = Vec::new();
        for z in 0..11 { for y in 0..11 { for x in 0..11 { d.push(f(x,y,z) as u8); } } }
        Prepared::new(&d,&[0;2662],500,(512,10000,10000,500000),None).unwrap().0
    }
    #[test]
    fn solid_and_empty_chunks_remain_distinct_without_triangles() {
        for (density,inside) in [(-127,true),(127,false)] {
            let c = prepare(|_,_,_| density);
            assert!(c.shape.is_none());
            assert_eq!(c.contains(Vector::splat(2000.0)),Some(inside));
            assert_eq!(c.contains(Vector::splat(-1.0)),None);
        }
    }
    #[test]
    fn volume_agrees_with_quantized_surface_including_nonplanar_cells() {
        let c = prepare(|_,y,_| if y < 3 { -63 } else { 65 });
        for x in [0.0,32.5,250.0,500.0,2000.0,4000.0] {
            assert_eq!(c.contains(Vector::new(x,745.9,230.5)),Some(true));
            assert_eq!(c.contains(Vector::new(x,746.1,230.5)),Some(false));
            assert_eq!(c.contains(Vector::new(x,746.0,230.5)),None);
        }
        let c = prepare(|x,y,z| if (x+y+z)%2 == 0 {-127} else {127});
        for z in 0..=8 { for y in 0..=8 { for x in 0..=8 {
            assert_eq!(c.contains(Vector::new(x as f64*500.0,y as f64*500.0,z as f64*500.0)),
                Some((x+y+z+3)%2 == 0));
        }}}
    }
    #[test]
    fn complete_payload_has_exact_length_and_admitted_bytes() {
        let d: Vec<_> = (0..1331).map(|i| if (i%11+i/11%11+i/121)%2 == 0 {129} else {127}).collect();
        let (c,p) = Prepared::new(&d,&[0;2662],500,(512,10000,10000,500000),None).unwrap();
        assert_eq!(p.len(),16+38*c.generated.mesh.1.len());
        assert!(p.len() <= 16+38*12*512);
        assert!(matches!(Prepared::new(&d,&[0;2662],500,(512,10000,10000,0),None),
            Err(Error::VoxelByteAllowance(_,0))));
        assert!(matches!(Prepared::new(&d,&[0;2662],u32::MAX,(512,10000,10000,500000),None),
            Err(Error::InvalidVoxelField)));
    }

    #[test]
    fn paint_reuses_collision_data_without_surface_work_and_still_checks_output_limits() {
        let d: Vec<_> = (0..1331).map(|i| if i/11%11 < 3 {193} else {65}).collect();
        let (first,original) = Prepared::new(&d,&[0;2662],500,(512,10000,10000,500000),None).unwrap();
        let (painted,payload) = Prepared::new(&d,&[7;2662],500,(0,10000,10000,500000),Some(&first)).unwrap();
        assert!(std::sync::Arc::ptr_eq(&first.collision,&painted.collision));
        assert!(first.shape.is_some());
        assert_ne!(original,payload);
        assert_eq!(first.contains(Vector::new(230.5,745.9,230.5)),Some(true));
        assert_eq!(painted.contains(Vector::new(230.5,745.9,230.5)),Some(true));
        assert!(matches!(Prepared::new(&d,&[7;2662],500,(0,0,10000,500000),Some(&first)),
            Err(Error::VoxelVertexAllowance(_,0))));
        assert!(matches!(Prepared::new(&d,&[7;2662],500,(0,10000,0,500000),Some(&first)),
            Err(Error::VoxelTriangleAllowance(_,0))));
        assert!(matches!(Prepared::new(&d,&[7;2662],500,(0,10000,10000,0),Some(&first)),
            Err(Error::VoxelByteAllowance(_,0))));
        let mut changed = d.clone(); changed[133] = 127;
        assert!(matches!(Prepared::new(&changed,&[7;2662],500,(0,10000,10000,500000),Some(&first)),
            Err(Error::VoxelCellAllowance(512,0))));
    }
}
