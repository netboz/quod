//! Chunk retention and coverage inside the existing physical-world owner.
use crate::{atoms,geometry::{Geometry,Kind,TerrainChunk},voxel::{chunk::Shared,Mesh,Point,Triangle},Body,Step,World};
use rapier3d::{math::Pose,parry::{bounding_volume::{Aabb,BoundingVolume},query},prelude::*};
use rustler::Atom;
use std::collections::{BTreeMap,BTreeSet};

pub(super) struct Installed {
    pub chunk: TerrainChunk,
    pub collider: Option<ColliderHandle>,
    pub admission: Option<Admission>,
}

pub(super) enum Admission {
    Whole,
    Changed { baseline: Shared, surface: Option<SharedShape> },
}

// Compare exact oriented faces, not collider identity. Rebuilding a chunk
// cannot turn its unchanged contact surfaces into new authored obstruction.
// The baseline survives replacements until the next successful integration.
fn triangle_key(mesh:&Mesh,(a,b,c):Triangle) -> [Point;3] {
    let (a,b,c) = (mesh.0[a as usize],mesh.0[b as usize],mesh.0[c as usize]);
    [a,b,c].min([b,c,a]).min([c,a,b])
}

fn admission(old:Option<&Installed>,new:&Shared) -> Result<Admission,Atom> {
    let baseline = old.and_then(|old| match &old.admission {
        Some(Admission::Whole) => None,
        Some(Admission::Changed {baseline,..}) => Some(baseline.clone()),
        None => Some(old.chunk.prepared.clone()),
    });
    let Some(baseline) = baseline else { return Ok(Admission::Whole); };
    let before = &baseline.generated.mesh;
    let after = &new.generated.mesh;
    let kept:BTreeSet<_> = before.1.iter().map(|t| triangle_key(before,*t)).collect();
    let faces:Vec<_> = after.1.iter().filter(|t| !kept.contains(&triangle_key(after,**t)))
        .map(|&(a,b,c)| [a,b,c]).collect();
    let surface = if faces.is_empty() { None } else {
        let points = after.0.iter().map(|&(x,y,z)| Vector::new(x as f64/1000.0,y as f64/1000.0,z as f64/1000.0)).collect();
        Some(SharedShape::trimesh(points,faces).map_err(|_| atoms::invalid_body())?)
    };
    Ok(Admission::Changed {baseline,surface})
}

// Inclusive cell-chunk ranges. The ontology owns enumeration/allocation;
// native coverage reports only the mechanical consumers' required regions.
pub(super) type Requirement = (u64,(i64,i64,i64),(i64,i64,i64));

pub(super) fn validate(spacing:u32,chunks:&[TerrainChunk],kind:Kind,pose:Pose,limit:f64) -> Result<(),Atom> {
    if kind != Kind::Fixed || pose != Pose::IDENTITY || spacing < 256 || !spacing.is_multiple_of(2)
        || spacing > u32::MAX/8 { return Err(atoms::invalid_body()); }
    let width = spacing as i64*8;
    let mut seen = BTreeSet::new();
    for c in chunks {
        if c.prepared.spacing != spacing || !seen.insert(c.origin) { return Err(atoms::invalid_body()); }
        for n in [c.origin.0,c.origin.1,c.origin.2] {
            let end = n.checked_add(width).ok_or_else(atoms::invalid_body)?;
            if n%width != 0 { return Err(atoms::invalid_body()); }
            if (n as f64/1000.0).abs() > limit || (end as f64/1000.0).abs() > limit {
                return Err(atoms::coordinate_allowance());
            }
        }
    }
    Ok(())
}

impl World {
    pub(super) fn install_terrain(&mut self,row:Body) -> Result<bool,Atom> {
        let mut geometry_changed = false;
        let id = row.0;
        if !self.terrain.contains_key(&id) { self.remove(id); }
        let handle = match self.rows.get(&id) {
            Some((_,h)) => *h,
            None => self.bodies.insert(RigidBodyBuilder::fixed()),
        };
        let Geometry::Terrain(_,chunks) = &row.4 else { unreachable!() };
        let mut previous = self.terrain.remove(&id).unwrap_or_default();
        let mut installed = BTreeMap::new();
        for c in chunks {
            if previous.get(&c.origin).is_some_and(|old| old.chunk == *c) {
                installed.insert(c.origin,previous.remove(&c.origin).unwrap());
                continue;
            }
            geometry_changed = true;
            let admission = Some(admission(previous.get(&c.origin),&c.prepared)?);
            let collider = c.prepared.shape.as_ref().map(|shape| {
                let (x,y,z) = c.origin;
                self.colliders.insert_with_parent(ColliderBuilder::new(shape.clone())
                    .translation(Vector::new(x as f64/1000.0,y as f64/1000.0,z as f64/1000.0))
                    .density(row.5).user_data(id as u128),handle,&mut self.bodies)
            });
            installed.insert(c.origin,Installed { chunk:c.clone(),collider,admission });
        }
        geometry_changed |= !previous.is_empty();
        for (_,old) in previous {
            if let Some(c) = old.collider {
                self.colliders.remove(c,&mut self.islands,&mut self.bodies,&mut self.soft,true);
            }
        }
        self.terrain.insert(id,installed);
        self.rows.insert(id,(row,handle));
        Ok(geometry_changed)
    }

    /// A queried/swept box needs every intersected cell chunk, including known
    /// empty chunks. Missing data cannot be inferred from collider absence.
    pub(super) fn terrain_coverage(&self,bounds:Aabb) -> bool {
        self.terrain.iter().all(|(id,chunks)| {
            let Geometry::Terrain(spacing,_) = self.rows[id].0.4 else { return false; };
            let side = spacing as i64*8;
            let Some((low,high)) = range(bounds,side) else { return false; };
            let count = (0..3).try_fold(1u128,|n,k| n.checked_mul((high[k] as i128-low[k] as i128+1) as u128));
            if count.is_none_or(|n| n > chunks.len() as u128) { return false; }
            (low[0]..=high[0]).all(|x| (low[1]..=high[1]).all(|y| (low[2]..=high[2]).all(|z|
                chunks.contains_key(&(x*side,y*side,z*side)))))
        })
    }

    /// A connected solid with a known-air interior point and no triangle
    /// penetration is clear. Compound bodies need one such point per part;
    /// their overall centre alone can lie in a doorway or between solid parts.
    pub(super) fn terrain_occupied(&self,shape:&dyn Shape,pose:&Pose) -> Result<Option<u64>,()> {
        if self.terrain.is_empty() { return Ok(None); }
        if !self.terrain_coverage(shape.compute_aabb(pose)) { return Err(()); }
        if let Some(compound) = shape.as_compound() {
            for (local,part) in compound.shapes() {
                let p = (*pose**local).transform_point(part.mass_properties(1.0).local_com);
                if let Some(id) = self.terrain_point(p)? { return Ok(Some(id)); }
            }
            Ok(None)
        } else {
            self.terrain_point(pose.transform_point(shape.mass_properties(1.0).local_com))
        }
    }

    pub(super) fn terrain_point(&self,p:Vector) -> Result<Option<u64>,()> {
        for (id,chunks) in &self.terrain {
            let Geometry::Terrain(spacing,_) = self.rows[id].0.4 else { return Err(()); };
            let side = spacing as i64*8;
            let (low,_) = range(Aabb::from_half_extents(p,Vector::ZERO),side).ok_or(())?;
            let origin = (low[0]*side,low[1]*side,low[2]*side);
            let c = chunks.get(&origin).ok_or(())?;
            let point = p*1000.0-Vector::new(origin.0 as f64,origin.1 as f64,origin.2 as f64);
            match c.chunk.prepared.contains(point) {
                Some(true) => return Ok(Some(*id)),
                Some(false) => (),
                None => return Err(()),
            }
        }
        Ok(None)
    }

    pub(super) fn step_regions(&self,parameters:&IntegrationParameters) -> Result<Vec<Aabb>,()> {
        let mut regions = Vec::new();
        for (_,handle) in self.rows.values().filter(|(row,_)| row.2 != Kind::Fixed) {
            let body = &self.bodies[*handle];
            let shape = self.colliders[body.colliders()[0]].shape();
            let bounds = if body.is_dynamic() {
                let local = shape.compute_local_aabb();
                let centre = body.local_center_of_mass();
                // Include the authored body origin as well as its shape. An
                // off-centre compound can rotate that origin outside the
                // numerical window while its occupied shape stays inside.
                let radius = (local.mins-centre).abs().max((local.maxs-centre).abs()).max(centre.abs()).length()
                    +parameters.max_linear_velocity()*parameters.dt+parameters.prediction_distance();
                if !radius.is_finite() { return Err(()); }
                Aabb::from_half_extents(body.center_of_mass(),Vector::splat(radius))
            } else { shape.compute_aabb(body.position()).merged(&shape.compute_aabb(body.next_position()))
                .loosened(parameters.prediction_distance()) };
            regions.push(bounds);
        }
        Ok(regions)
    }

    fn terrain_requests(&self,regions:&[Aabb]) -> Result<Vec<Requirement>,Atom> {
        let mut requests = Vec::new();
        for id in self.terrain.keys() {
            let Geometry::Terrain(spacing,_) = self.rows[id].0.4 else { return Err(atoms::invalid_body()); };
            for bounds in regions {
                let (low,high) = range(*bounds,spacing as i64*8).ok_or_else(atoms::non_finite_state)?;
                requests.push((*id,(low[0],low[1],low[2]),(high[0],high[1],high[2])));
            }
        }
        requests.sort_unstable(); requests.dedup();
        Ok(requests)
    }

    pub(super) fn terrain_requirements(&self,views:Vec<(u64,u64,crate::geometry::V3,f64)>) -> Result<Vec<Requirement>,Atom> {
        let parameters = IntegrationParameters { dt:self.dt,..Default::default() };
        let mut regions = self.step_regions(&parameters).map_err(|_| atoms::non_finite_state())?;
        for (id,revision,local,radius) in views {
            let Some((row,handle)) = self.rows.get(&id) else { return Err(atoms::invalid_body()); };
            if row.1 != revision || !radius.is_finite() || radius <= 0.0 || radius > self.limits.3 {
                return Err(atoms::invalid_body());
            }
            let point = self.bodies[*handle].position().transform_point(
                crate::geometry::vector(local,self.limits.3).map_err(|_| atoms::invalid_body())?);
            regions.push(Aabb::from_half_extents(point,Vector::splat(radius)));
        }
        self.terrain_requests(&regions)
    }

    pub(super) fn terrain_query_coverage(&self,bounds:Aabb) -> Result<Option<Vec<Requirement>>,Atom> {
        if self.terrain_coverage(bounds) { return Ok(None); }
        let parameters = IntegrationParameters { dt:self.dt,..Default::default() };
        let mut regions = self.step_regions(&parameters).map_err(|_| atoms::non_finite_state())?;
        regions.push(bounds);
        self.terrain_requests(&regions).map(Some)
    }

    pub(super) fn terrain_step(&self,parameters:&IntegrationParameters,regions:&[Aabb]) -> Result<Option<Step>,Atom> {
        if self.terrain.is_empty() { return Ok(None); }
        if regions.iter().any(|bounds| !self.terrain_coverage(*bounds)) {
            return Ok(Some(Step::Coverage(self.terrain_requests(regions)?)));
        }
        for (row,handle) in self.rows.values().filter(|(row,_)| row.2 != Kind::Fixed) {
            let body = &self.bodies[*handle];
            let collider = body.colliders()[0];
            let shape = self.colliders[collider].shape();
            match self.terrain_occupied(shape,body.position()) {
                Ok(Some(id)) => return Ok(Some(Step::Occupied(row.0,id))),
                Err(()) => return Ok(Some(Step::Indeterminate(row.0))),
                Ok(None) => (),
            }
            // Admit authored geometry/pose changes against the surface before
            // integration. Unchanged surfaces are already under the solver: its
            // contact error is a correction target, not a hard penetration cap.
            // Interior classification above remains required on every step.
            let bounds = shape.compute_aabb(body.position());
            for (terrain,chunks) in &self.terrain {
                for chunk in chunks.values() {
                    let Some(handle) = chunk.collider else { continue; };
                    let other = &self.colliders[handle];
                    let surface = if self.body_admission.contains(&collider) { other.shape() } else {
                        match &chunk.admission {
                            Some(Admission::Whole) => other.shape(),
                            Some(Admission::Changed {surface:Some(surface),..}) => surface.as_ref(),
                            _ => continue,
                        }
                    };
                    let parent = other.parent().unwrap();
                    let pose = *self.bodies[parent].position()*other.position_wrt_parent().copied().unwrap_or_default();
                    if !bounds.intersects(&surface.compute_aabb(&pose)) { continue; }
                    match query::contact(body.position(),shape,&pose,surface,0.0) {
                        Ok(Some(contact)) if contact.dist < -parameters.allowed_linear_error() =>
                            return Ok(Some(Step::Occupied(row.0,*terrain))),
                        Err(_) => return Ok(Some(Step::Indeterminate(row.0))),
                        _ => (),
                    }
                }
            }
        }
        Ok(None)
    }
}


fn range(bounds:Aabb,side:i64) -> Option<([i64;3],[i64;3])> {
    let low = (bounds.mins*(1000.0/side as f64)).floor();
    let high = (bounds.maxs*(1000.0/side as f64)).floor();
    // Multiplication back to local integer millimetres must remain exact in
    // its integer envelope, independently of the world's allocation policy.
    let bound = (i64::MAX/side-1) as f64;
    if !low.is_finite() || !high.is_finite() || low.abs().max(high.abs()).max_element() > bound {
        return None;
    }
    Some((low.to_array().map(|n| n as i64),high.to_array().map(|n| n as i64)))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{geometry::Primitive,motion::{self,Answer,Query},voxel::chunk::{Prepared,Shared}};
    fn prepared(f:impl Fn(usize)->i8) -> Shared {
        let d:Vec<_> = (0..1331).map(|i| f(i) as u8).collect();
        Shared(std::sync::Arc::new(Prepared::new(&d,&[0;2662],500,(512,10000,10000,500000),None).unwrap().0))
    }
    fn piece(origin:(i64,i64,i64),p:&Shared) -> TerrainChunk { TerrainChunk { origin,prepared:p.clone() } }
    fn terrain(revision:u64,chunks:Vec<TerrainChunk>) -> Body {
        (0,revision,Kind::Fixed,((0.0,0.0,0.0),(0.0,0.0,0.0)),Geometry::Terrain(500,chunks),1.0)
    }
    fn body(kind:Kind,p:(f64,f64,f64)) -> Body {
        (1,1,kind,(p,(0.0,0.0,0.0)),Geometry::Solid(Primitive::Ball(0.25)),1.0)
    }
    fn world() -> World { World::new((8,8,128,1000.0,512,100000,100000),1.0/60.0,-9.81).unwrap() }

    #[test]
    fn residency_and_authored_revisions_retain_unchanged_colliders() {
        let ground = prepared(|i| if i/11%11 < 3 {-63} else {65});
        let lower = prepared(|i| if i/11%11 < 2 {-63} else {65});
        let mut w = world();
        let first = piece((0,0,0),&ground);
        w.install(vec![terrain(1,vec![first.clone()])],(0,0,0)).unwrap();
        let handle = w.rows[&0].1;
        let original = w.terrain[&0][&(0,0,0)].collider.unwrap();
        let second = piece((4000,0,0),&ground);
        w.install(vec![terrain(1,vec![first.clone(),second.clone()])],(0,0,0)).unwrap();
        let retained = w.terrain[&0][&(4000,0,0)].collider.unwrap();
        assert_eq!(w.terrain[&0][&(0,0,0)].collider,Some(original));
        assert_eq!(w.install(vec![terrain(1,vec![first,second.clone()])],(0,0,0)),Ok(0));
        w.install(vec![terrain(2,vec![piece((0,0,0),&lower),second])],(0,0,0)).unwrap();
        assert_eq!(w.rows[&0].1,handle);
        assert_eq!(w.rows.len(),1);
        assert_ne!(w.terrain[&0][&(0,0,0)].collider,Some(original));
        assert_eq!(w.terrain[&0][&(4000,0,0)].collider,Some(retained));
        w.install(vec![terrain(2,vec![])],(0,0,0)).unwrap();
        assert_eq!(w.rows[&0].1,handle);
        assert!(w.bodies[handle].colliders().is_empty());
    }

    #[test]
    fn known_solid_refuses_placement_even_without_any_surface_collider() {
        let solid = prepared(|_| -127); let air = prepared(|_| 127);
        let mut w = world();
        w.install(vec![terrain(1,vec![piece((0,0,0),&solid),piece((0,4000,0),&air)]),
                       body(Kind::Controlled,(2.0,6.0,2.0))],(0,0,0)).unwrap();
        w.step().unwrap();
        let target = Query::Place(((2.0,2.0,2.0),(0.0,0.0,0.0)));
        assert!(matches!(motion::evaluate(&w,1,1,target,(0.002,0.0,8,128)),Answer::Occupied(0,_)));
        let parts = Geometry::Parts(vec![(((0.0,-4.0,0.0),(0.0,0.0,0.0)),Primitive::Ball(0.2)),
                                        (((0.0,0.0,0.0),(0.0,0.0,0.0)),Primitive::Ball(0.2))]);
        let shape = parts.build(Kind::Controlled,&mut crate::geometry::Budget {
            parts:2,vertices:0,triangles:0,coordinate:1000.0 }).unwrap();
        assert_eq!(w.terrain_occupied(shape.as_ref(),&Pose::translation(2.0,6.0,2.0)),Ok(Some(0)));
    }

    #[test]
    fn air_centre_does_not_admit_a_body_intersecting_terrain() {
        let ground = prepared(|i| if i/11%11 < 3 {-127} else {127});
        let mut w = world();
        let mut actor = body(Kind::Controlled,(2.0,1.0,2.0));
        actor.4 = Geometry::Solid(Primitive::Ball(0.5));
        w.install(vec![terrain(1,vec![piece((0,0,0),&ground)]),actor],(0,0,0)).unwrap();
        assert_eq!(w.terrain_point(Vector::new(2.0,1.0,2.0)),Ok(None));
        let handle = w.rows[&1].1;
        let pose = *w.bodies[handle].position();
        assert_eq!(w.step(),Ok(crate::Step::Occupied(1,0)));
        assert_eq!(*w.bodies[handle].position(),pose);
        assert!(!w.query_ready);
    }

    #[test]
    fn surface_clearance_preserves_ordinary_falling_and_resting_contact() {
        let mut w = world();
        let mut chunks = Vec::new();
        for z in -2..=2 { for y in -2..=2 { for x in -2..=2 {
            let field = prepared(|i| if (i/11%11) as i64-1+y*8 < 2 {-127} else {127});
            chunks.push(piece((x*4000,y*4000,z*4000),&field));
        } } }
        w.install(vec![terrain(1,chunks),body(Kind::Dynamic,(2.0,2.0,2.0))],(0,0,0)).unwrap();
        for _ in 0..300 { assert!(matches!(w.step(),Ok(crate::Step::Sample(_)))); }
        let actor = &w.bodies[w.rows[&1].1];
        assert!(actor.translation().y > 0.99 && actor.translation().y < 1.01);
        assert!(actor.is_sleeping());
    }

    #[test]
    fn stacked_dynamic_bodies_keep_stepping_over_terrain() {
        let mut w = world();
        let mut chunks = Vec::new();
        for z in -2..=2 { for y in -2..=2 { for x in -2..=2 {
            let field = prepared(|i| if (i/11%11) as i64-1+y*8 < 2 {-127} else {127});
            chunks.push(piece((x*4000,y*4000,z*4000),&field));
        } } }
        let mut lower = body(Kind::Dynamic,(2.0,1.5,2.0));
        lower.4 = Geometry::Solid(Primitive::Box(0.4,0.4,0.4));
        let mut upper = lower.clone(); upper.0 = 2; upper.3.0.1 = 3.0; upper.5 = 100.0;
        w.install(vec![terrain(1,chunks),lower,upper],(0,0,0)).unwrap();
        for tick in 0..600 {
            if tick == 17 || tick == 400 {
                let field = prepared(|i| if i/11%11 < 3 &&
                    !(i/11%11 == 2 && i/121 == 8 && (i%11 == 8 || tick == 400 && i%11 == 7)) {-127} else {127});
                let mut rows:Vec<Body> = w.rows.values().map(|(r,_)| r.clone()).collect();
                rows[0].1 += 1;
                let Geometry::Terrain(_,chunks) = &mut rows[0].4 else { unreachable!() };
                *chunks.iter_mut().find(|c| c.origin == (0,0,0)).unwrap() = piece((0,0,0),&field);
                w.install(rows,(0,0,0)).unwrap();
                let actor = &w.bodies[w.rows[&1].1];
                let ground = &w.colliders[w.terrain[&0][&(0,0,0)].collider.unwrap()];
                let contact = query::contact(actor.position(),w.colliders[actor.colliders()[0]].shape(),
                    ground.position(),ground.shape(),0.02).unwrap().unwrap();
                eprintln!("same-chunk edit at tick {tick}: penetration {} mm",(-contact.dist*1000.0).max(0.0));
                if tick == 17 { assert!(contact.dist < -IntegrationParameters::default().allowed_linear_error()); }
            }
            if tick == 20 {
                // Residency changing elsewhere must not re-admit established
                // solver contacts as though the bodies had just been inserted.
                let mut rows:Vec<Body> = w.rows.values().map(|(r,_)| r.clone()).collect();
                let Geometry::Terrain(_,chunks) = &mut rows[0].4 else { unreachable!() };
                chunks.push(piece((12000,0,0),&prepared(|i| if i/11%11 < 3 {-127} else {127})));
                w.install(rows,(0,0,0)).unwrap();
            }
            if tick == 200 { assert!(w.push_body(2,1,(1.0,0.0,0.0),10.0)); }
            let result = w.step();
            assert!(matches!(result,Ok(crate::Step::Sample(_))),"tick {tick}: {result:?}; lower {:?}; upper {:?}",
                w.bodies[w.rows[&1].1].translation(),w.bodies[w.rows[&2].1].translation());
        }
        for id in [1,2] {
            let actor = &w.bodies[w.rows[&id].1];
            let bottom = w.colliders[actor.colliders()[0]].shape().compute_aabb(actor.position()).mins.y;
            eprintln!("settled body {id}: centre {:?}, lowest point {bottom}",actor.translation());
            assert!(bottom >= 0.75-IntegrationParameters::default().allowed_linear_error());
            assert!(actor.is_sleeping());
        }
        // Existing contact with this chunk cannot exempt newly added rock.
        let filled = prepared(|i| if i/11%11 < 3 {-127}
            else if i/11%11 == 3 && (3..=7).contains(&(i%11)) && (3..=7).contains(&(i/121)) {1}
            else {127});
        let mut rows:Vec<Body> = w.rows.values().map(|(r,_)| r.clone()).collect();
        rows[0].1 += 1;
        let Geometry::Terrain(_,chunks) = &mut rows[0].4 else { unreachable!() };
        *chunks.iter_mut().find(|c| c.origin == (0,0,0)).unwrap() = piece((0,0,0),&filled);
        let handle = w.rows[&1].1;
        let before = *w.bodies[handle].position();
        w.install(rows,(0,0,0)).unwrap();
        assert_eq!(w.terrain_point(w.bodies[handle].center_of_mass()),Ok(None));
        assert_eq!(w.step(),Ok(crate::Step::Occupied(1,0)));
        assert_eq!(*w.bodies[handle].position(),before);
    }

    #[test]
    fn new_terrain_checks_a_retained_body_before_integration() {
        let air = prepared(|_| 127);
        let ground = prepared(|i| if i/11%11 < 5 {-127} else {127});
        let mut w = world();
        let mut actor = body(Kind::Controlled,(2.0,2.0,2.0));
        actor.4 = Geometry::Solid(Primitive::Ball(0.5));
        w.install(vec![terrain(1,vec![piece((0,0,0),&air)]),actor.clone()],(0,0,0)).unwrap();
        w.step().unwrap();
        let handle = w.rows[&1].1;
        let pose = *w.bodies[handle].position();
        // Centre remains air, but the sphere crosses the newly installed face.
        w.install(vec![terrain(2,vec![piece((0,0,0),&ground)]),actor.clone()],(0,0,0)).unwrap();
        assert_eq!(w.rows[&1].1,handle);
        assert_eq!(w.terrain_point(Vector::new(2.0,2.0,2.0)),Ok(None));
        assert_eq!(w.step(),Ok(crate::Step::Occupied(1,0)));
        assert_eq!(*w.bodies[w.rows[&1].1].position(),pose);
        let edited = prepared(|i| if i/11%11 < 5 && !(i%11 == 8 && i/121 == 8 && i/11%11 == 2) {-127} else {127});
        w.install(vec![terrain(3,vec![piece((0,0,0),&edited)]),actor.clone()],(0,0,0)).unwrap();
        // An unintegrated replacement cannot become the admission baseline.
        assert_eq!(w.step(),Ok(crate::Step::Occupied(1,0)));
        w.install(vec![terrain(4,vec![piece((0,0,0),&air)]),actor.clone()],(0,0,0)).unwrap();
        assert!(matches!(w.step(),Ok(crate::Step::Sample(_))));
        assert_eq!(w.rows[&1].1,handle);
        let floor = terrain(5,vec![piece((0,0,0),&prepared(|i| if i/11%11 < 3 {-127} else {127}))]);
        w.install(vec![floor.clone(),actor.clone()],(0,0,0)).unwrap();
        assert!(matches!(w.step(),Ok(crate::Step::Sample(_))));
        actor.1 = 2; actor.3.0.1 = 1.0;
        w.install(vec![floor,actor],(0,0,0)).unwrap();
        // New bodies/poses still check the complete unchanged terrain surface.
        assert_eq!(w.step(),Ok(crate::Step::Occupied(1,0)));
    }

    #[test]
    fn recovery_waits_for_coverage_then_resumes_unsupported_rest() {
        let air = prepared(|_| 127);
        let mut w = world();
        let actor = body(Kind::Dynamic,(2.0,2.0,2.0));
        w.install(vec![terrain(1,vec![piece((0,0,0),&air)]),actor.clone()],(0,0,0)).unwrap();
        let handle = w.rows[&1].1;
        let checkpoint = (1,1,((6.0,2.0,2.0),(0.0,0.0,0.0,1.0)),0.005,256);
        assert!(matches!(w.restore_rest(vec![checkpoint]),Ok(crate::Restore::Coverage(r)) if !r.is_empty()));
        assert_eq!(w.bodies[handle].translation().x,2.0);
        let mut chunks = Vec::new();
        for z in -2..=2 { for y in -2..=2 { for x in -1..=3 {
            chunks.push(piece((x*4000,y*4000,z*4000),&air));
        } } }
        w.install(vec![terrain(1,chunks),actor],(0,0,0)).unwrap();
        assert!(matches!(w.restore_rest(vec![checkpoint]),Ok(crate::Restore::Ready)));
        assert_eq!(w.rows[&1].1,handle);
        assert_eq!(w.bodies[handle].translation().x,6.0);
        assert!(!w.bodies[handle].is_sleeping());
        assert!(matches!(w.step(),Ok(crate::Step::Sample(_))));
        assert!(w.bodies[handle].translation().y < 2.0);
    }

    #[test]
    fn missing_step_coverage_preserves_motion_until_installed_without_a_new_body() {
        let air = prepared(|_| 127);
        let mut w = world();
        let dynamic = body(Kind::Dynamic,(2.0,2.0,2.0));
        w.install(vec![terrain(1,vec![piece((0,0,0),&air)]),dynamic.clone()],(0,0,0)).unwrap();
        let handle = w.rows[&1].1;
        let pose = *w.bodies[handle].position();
        assert!(matches!(w.step(),Ok(crate::Step::Coverage(ranges)) if ranges == vec![(0,(-2,-2,-2),(2,2,2))]));
        assert_eq!(*w.bodies[handle].position(),pose);
        assert_eq!(w.bodies[handle].linvel(),Vector::ZERO);
        let mut chunks = Vec::new();
        for z in -2..=2 { for y in -2..=2 { for x in -2..=2 { chunks.push(piece((x*4000,y*4000,z*4000),&air)); } } }
        w.install(vec![terrain(1,chunks),dynamic],(0,0,0)).unwrap();
        assert_eq!(w.rows[&1].1,handle);
        w.step().unwrap();
        assert!(w.bodies[handle].translation().y < pose.translation.y);
    }
}
