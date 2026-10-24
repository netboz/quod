//! Collision queries over the installed world. This module never moves a body
//! or chooses an agent's permissions, speed, gravity, or locomotion mode.
use crate::{geometry::{self, Kind, Transform, V3}, World};
use rapier3d::{math::Pose, parry::{bounding_volume::{Aabb, BoundingVolume},
    query::{self, DefaultQueryDispatcher, NonlinearRigidMotion, ShapeCastOptions}, shape::Shape}, prelude::*};
use rustler::NifTaggedEnum;

#[derive(NifTaggedEnum)]
pub enum Query {
    Place(Transform),
    Travel(V3, V3),
    // Body-origin destination, maximum travel, support search, minimum upward
    // normal. Policy chooses these values; the complete body follows a clear
    // straight path, retains its orientation and lands on declared geometry.
    Land(V3, f64, f64, f64),
    // Sensory clearance around an authored body-local camera mount. This does
    // not add a collider or move the agent when a human moves their head.
    View(V3, f64),
}

// Skin, permitted numerical penetration, slide iterations, narrow-phase tests.
// All allowances are supplied by ontology policy through the owner.
pub type Limits = (f64, f64, usize, usize);
pub type Position = (V3, (f64,f64,f64,f64));

#[derive(Debug, PartialEq, NifTaggedEnum)]
pub enum Answer {
    Clear(Position, usize),
    Clipped(Position, Vec<(u64,V3)>, usize),
    Occupied(u64, usize),
    Blocked(u64, usize),
    NoSupport,
    ViewClearance(f64, usize),
    TerrainCoverage(Vec<crate::terrain::Requirement>),
    Unavailable,
    Unsupported,
    Invalid,
    Exhausted,
}

fn position(p: Pose) -> Position {
    ((p.translation.x,p.translation.y,p.translation.z),
     (p.rotation.x,p.rotation.y,p.rotation.z,p.rotation.w))
}
fn tuple(v: Vector) -> V3 { (v.x,v.y,v.z) }

struct Space<'a> {
    world: &'a World,
    query: QueryPipeline<'a>,
    shape: &'a dyn Shape,
    checks: usize,
    remaining: usize,
    tolerance: f64,
}

impl Space<'_> {
    fn charge(&mut self) -> Result<(),Answer> {
        self.remaining = self.remaining.checked_sub(1).ok_or(Answer::Exhausted)?;
        self.checks += 1;
        Ok(())
    }

    fn occupied(&mut self, pose: Pose) -> Result<Option<u64>,Answer> {
        if let Some(ranges) = self.world.terrain_query_coverage(self.shape.compute_aabb(&pose)) {
            return Err(Answer::TerrainCoverage(ranges));
        }
        let parts = self.shape.as_compound().map_or(1,|c| c.shapes().len());
        for _ in 0..self.world.terrain.len()*parts { self.charge()?; }
        if let Some(id) = self.world.terrain_occupied(self.shape,&pose).map_err(|_| Answer::Unavailable)? {
            return Ok(Some(id));
        }
        let query = self.query;
        for (_,other) in query.intersect_aabb_conservative(self.shape.compute_aabb(&pose)) {
            self.charge()?;
            let contact = query::contact(&pose,self.shape,other.position(),other.shape(),0.0)
                .map_err(|_| Answer::Unsupported)?;
            if contact.is_some_and(|c| c.dist < -self.tolerance) {
                return Ok(Some(other.user_data as u64));
            }
        }
        Ok(None)
    }

    fn cast(&mut self, pose: Pose, travel: Vector, turn: Vector, skin: f64)
        -> Result<Option<(f64,u64,Vector)>,Answer> {
        let motion = NonlinearRigidMotion::new(pose,Vector::ZERO,travel,turn);
        let bounds = if turn == Vector::ZERO {
            self.shape.compute_aabb(&pose).merged(&self.shape.compute_aabb(&motion.position_at_time(1.0)))
        } else {
            // A sphere around the body origin contains every rotated part,
            // including parts whose centres are offset from that origin.
            let local = self.shape.compute_local_aabb();
            let radius = local.mins.abs().max(local.maxs.abs()).length();
            Aabb::from_half_extents(pose.translation,Vector::splat(radius))
                .merged(&Aabb::from_half_extents(pose.translation+travel,Vector::splat(radius)))
        }.loosened(skin);
        if let Some(ranges) = self.world.terrain_query_coverage(bounds) {
            return Err(Answer::TerrainCoverage(ranges));
        }
        let pipeline = self.query;
        let mut earliest: Option<(f64,u64,Vector)> = None;
        for (_,other) in pipeline.intersect_aabb_conservative(bounds) {
            self.charge()?;
            let hit = if turn == Vector::ZERO {
                query::cast_shapes(&pose,travel,self.shape,other.position(),Vector::ZERO,other.shape(),
                    ShapeCastOptions { max_time_of_impact: 1.0, target_distance: skin,
                        stop_at_penetration: false, compute_impact_geometry_on_penetration: true })
            } else {
                query::cast_shapes_nonlinear(&motion,self.shape,
                    &NonlinearRigidMotion::constant_position(*other.position()),other.shape(),0.0,1.0,false)
            }.map_err(|_| Answer::Unsupported)?;
            if let Some(hit) = hit {
                let normal = other.position().rotation * hit.normal2;
                if !hit.time_of_impact.is_finite() || !normal.is_finite() { return Err(Answer::Unavailable); }
                let id = other.user_data as u64;
                if earliest.is_none_or(|(time,old,_)| hit.time_of_impact < time
                    || (hit.time_of_impact == time && id < old)) {
                    earliest = Some((hit.time_of_impact,id,normal));
                }
            }
        }
        Ok(earliest)
    }
}

pub fn evaluate(world: &World, id: u64, revision: u64, input: Query, limits: Limits) -> Answer {
    match solve(world,id,revision,input,limits) { Ok(answer) | Err(answer) => answer }
}

pub fn apply(world: &mut World, id: u64, revision: u64, input: Query, limits: Limits) -> Answer {
    let answer = evaluate(world,id,revision,input,limits);
    if let Answer::Clear((p,q),_) | Answer::Clipped((p,q),_,_) = &answer {
        let handle = world.rows[&id].1;
        let pose = Pose::from_parts(Vector::new(p.0,p.1,p.2),
            Rotation::from_xyzw(q.0,q.1,q.2,q.3));
        if *world.bodies[handle].position() != pose {
            let collider = world.bodies[handle].colliders()[0];
            world.bodies[handle].set_position(pose,true);
            world.bodies[handle].set_linvel(Vector::ZERO,true);
            world.bodies[handle].set_angvel(Vector::ZERO,true);
            // Make the new transform visible to the next controlled body in
            // this same step. Rapier retains pair-change detection for its
            // next integration; no second query index is constructed.
            world.colliders[collider].set_position(pose);
            let bounds = world.colliders[collider].compute_aabb();
            world.broad.set_aabb(&IntegrationParameters {dt: world.dt,..Default::default()},collider,bounds);
            world.changed = true;
        }
    }
    answer
}

fn solve(world: &World, id: u64, revision: u64, input: Query, (skin,tolerance,iterations,checks): Limits)
    -> Result<Answer,Answer> {
    // Installation mutates collider sets before the physics step updates the
    // retained BVH. Never treat that interval as empty collision coverage.
    if !world.query_ready { return Err(Answer::Unavailable); }
    if !skin.is_finite() || skin <= 0.0 || skin > world.limits.3
        || !tolerance.is_finite() || tolerance < 0.0 || tolerance >= skin
        || iterations == 0 || checks == 0 { return Err(Answer::Invalid); }
    let Some((row,body)) = world.rows.get(&id) else { return Err(Answer::Unavailable); };
    if row.1 != revision { return Err(Answer::Unavailable); }
    if row.2 != Kind::Controlled { return Err(Answer::Unsupported); }
    let body_handle = *body;
    let body = &world.bodies[body_handle];
    let shape = world.colliders[body.colliders()[0]].shape();
    let mut space = Space { world, query: world.broad.as_query_pipeline(&DefaultQueryDispatcher,
        &world.bodies,&world.colliders,QueryFilter::default().exclude_rigid_body(body_handle)),
        shape, checks: 0, remaining: checks, tolerance };
    let mut pose = *body.position();
    let (mut travel,mut turn) = match input {
        Query::View(local,radius) => {
            if !radius.is_finite() || radius <= 0.0 || radius > world.limits.3 { return Err(Answer::Invalid); }
            let local = geometry::vector(local,world.limits.3).map_err(|_| Answer::Invalid)?;
            let point = pose.transform_point(local);
            if let Some(ranges) = world.terrain_query_coverage(Aabb::from_half_extents(point,Vector::splat(radius))) {
                return Err(Answer::TerrainCoverage(ranges));
            }
            for _ in 0..world.terrain.len() { space.charge()?; }
            if world.terrain_point(point).map_err(|_| Answer::Unavailable)?.is_some() {
                return Ok(Answer::ViewClearance(0.0,space.checks));
            }
            let pipeline = space.query;
            let mut clearance = radius;
            for (_,other) in pipeline.intersect_aabb_conservative(Aabb::from_half_extents(point,Vector::splat(clearance))) {
                space.charge()?;
                let projected = other.shape().project_point(other.position(),point,true);
                let distance = if projected.is_inside { 0.0 } else { (point-projected.point).length() };
                if !distance.is_finite() { return Err(Answer::Unavailable); }
                clearance = clearance.min(distance);
            }
            return Ok(Answer::ViewClearance((clearance-skin).max(0.0),space.checks));
        }
        Query::Place(target) => {
            let target = geometry::transform(target,world.limits.3).map_err(|_| Answer::Invalid)?;
            return Ok(match space.occupied(target)? {
                Some(other) => Answer::Occupied(other,space.checks),
                None => Answer::Clear(position(target),space.checks),
            });
        }
        Query::Land(target,reach,drop,up) => {
            if !reach.is_finite() || reach <= 0.0 || reach > world.limits.3
                || !drop.is_finite() || drop <= 0.0 || drop > world.limits.3
                || !up.is_finite() || up <= 0.0 || up > 1.0 { return Err(Answer::Invalid); }
            let target = geometry::vector(target,world.limits.3).map_err(|_| Answer::Invalid)?;
            let delta = target-pose.translation;
            if delta.length() > reach { return Err(Answer::Invalid); }
            if let Some(other) = space.occupied(pose)? { return Ok(Answer::Occupied(other,space.checks)); }
            let mut landing = pose;
            landing.translation = target;
            if let Some(other) = space.occupied(landing)? { return Ok(Answer::Occupied(other,space.checks)); }
            if delta != Vector::ZERO {
                // The path tests physical geometry; only the support search uses skin.
                // A clear body already inside the support margin may travel along it.
                if let Some((_,other,_)) = space.cast(pose,delta,Vector::ZERO,0.0)? {
                    return Ok(Answer::Blocked(other,space.checks));
                }
            }
            let descent = Vector::new(0.0,-(drop),0.0);
            let Some((fraction,other,normal)) = space.cast(landing,descent,Vector::ZERO,skin)?
                else { return Ok(Answer::NoSupport); };
            if normal.y < up { return Ok(Answer::NoSupport); }
            landing.translation += descent*fraction;
            if landing.translation.abs().max_element() > world.limits.3 { return Err(Answer::Invalid); }
            if let Some(other) = space.occupied(landing)? { return Ok(Answer::Occupied(other,space.checks)); }
            return Ok(Answer::Clipped(position(landing),vec![(other,tuple(normal))],space.checks));
        }
        Query::Travel(delta,rotation) => (
            geometry::vector(delta,world.limits.3).map_err(|_| Answer::Invalid)?,
            geometry::vector(rotation,std::f64::consts::PI).map_err(|_| Answer::Invalid)?),
    };
    if let Some(other) = space.occupied(pose)? { return Ok(Answer::Occupied(other,space.checks)); }
    if (pose.translation+travel).abs().max_element() > world.limits.3 { return Err(Answer::Invalid); }
    let mut contacts = Vec::new();
    for _ in 0..iterations {
        if travel == Vector::ZERO && turn == Vector::ZERO { break; }
        let Some((time,other,normal)) = space.cast(pose,travel,turn,skin)? else {
            pose = NonlinearRigidMotion::new(pose,Vector::ZERO,travel,turn).position_at_time(1.0);
            break;
        };
        let radius = shape.compute_local_aabb().mins.abs().max(shape.compute_local_aabb().maxs.abs()).length();
        let speed_bound = travel.length()+turn.length()*radius;
        let fraction = if turn == Vector::ZERO { time }
            else { (time-(skin)/speed_bound).max(0.0) };
        pose = NonlinearRigidMotion::new(pose,Vector::ZERO,travel,turn).position_at_time(fraction);
        contacts.push((other,tuple(normal)));
        travel *= 1.0-fraction;
        // Rotation stops at contact. Translation may continue along the surface.
        turn = Vector::ZERO;
        travel -= normal*travel.dot(normal).min(0.0);
        // Separate repeated contacts by the solver's relative geometric tolerance.
        // Subsequent casts still check every collider, including this one.
        travel += normal*(query::gjk::eps_tol().sqrt()*travel.length());
    }
    // The query never returns an overlapping endpoint, including after a
    // conservative cast or exhausted sliding iterations.
    if let Some(other) = space.occupied(pose)? { return Ok(Answer::Occupied(other,space.checks)); }
    Ok(if contacts.is_empty() { Answer::Clear(position(pose),space.checks) }
        else { Answer::Clipped(position(pose),contacts,space.checks) })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::geometry::{Geometry,Primitive};
    const LIMITS: Limits = (0.002,0.00001,8,128);
    fn box_at(id: u64, kind: Kind, p: V3, size: V3) -> crate::Body {
        (id,1,kind,(p,(0.0,0.0,0.0)),Geometry::Solid(Primitive::Box(size.0,size.1,size.2)),1.0)
    }
    fn world(extra: Vec<crate::Body>) -> World {
        let mut world = World::new((32,32,64,100.0,64,128,128),0.016,0.0).unwrap();
        let mut rows = vec![box_at(1,Kind::Controlled,(0.0,1.002,0.0),(0.5,1.0,0.5)),
            box_at(2,Kind::Fixed,(0.0,-0.5,0.0),(20.0,0.5,20.0))];
        rows.extend(extra);
        world.install(rows,(0,0,0)).unwrap(); world.step().unwrap(); world
    }
    fn travel(world: &World, p: V3) -> Answer { evaluate(world,1,1,Query::Travel(p,(0.0,0.0,0.0)),LIMITS) }
    fn end(answer: Answer) -> V3 {
        match answer { Answer::Clear((p,_),_) | Answer::Clipped((p,_),_,_) => p,
            other => panic!("unexpected query answer: {other:?}") }
    }

    #[test]
    fn floor_wall_slide_and_corner_do_not_move_native_body() {
        let world = world(vec![box_at(3,Kind::Fixed,(2.0,2.0,0.0),(0.1,3.0,10.0)),
                              box_at(4,Kind::Fixed,(0.0,2.0,3.0),(10.0,3.0,0.1))]);
        let before = world.sample().unwrap();
        let p = end(travel(&world,(10.0,0.0,2.0)));
        assert!(p.0 > 1.39 && p.0 < 1.4,"{p:?}");
        assert!((p.2-2.0).abs() < 0.001,"sliding: {p:?}");
        let p = end(travel(&world,(10.0,0.0,10.0)));
        assert!(p.0 < 1.4 && p.2 < 2.4,"corner: {p:?}");
        let p = end(travel(&world,(0.0,-20.0,0.0)));
        assert!(p.1 >= 1.0,"floor: {p:?}");
        assert_eq!(before,world.sample().unwrap());
    }

    #[test]
    fn placement_overlap_and_unavailable_are_explicit() {
        let world = world(vec![box_at(3,Kind::Fixed,(2.0,1.0,0.0),(0.5,1.0,0.5))]);
        assert!(matches!(evaluate(&world,1,1,Query::Place(((2.0,1.0,0.0),(0.0,0.0,0.0))),LIMITS),Answer::Occupied(3,_)));
        assert!(matches!(evaluate(&world,1,1,Query::Place(((5.0,1.002,0.0),(0.0,0.0,0.0))),LIMITS),Answer::Clear(_,_)));
        assert_eq!(evaluate(&world,1,0,Query::Travel((1.0,0.0,0.0),(0.0,0.0,0.0)),LIMITS),Answer::Unavailable);
        assert_eq!(evaluate(&world,99,1,Query::Place(((0.0,1.0,0.0),(0.0,0.0,0.0))),LIMITS),Answer::Unavailable);
        assert_eq!(evaluate(&world,1,1,Query::Travel((10.0,0.0,0.0),(0.0,0.0,0.0)),(0.002,0.00001,8,1)),Answer::Exhausted);
    }

    #[test]
    fn installed_move_and_deletion_replace_collision_geometry() {
        let mut world = world(vec![box_at(3,Kind::Fixed,(2.0,1.0,0.0),(0.5,1.0,0.5))]);
        assert!(end(travel(&world,(5.0,0.0,0.0))).0 < 1.0);
        let mut rows: Vec<_> = world.rows.values().map(|(row,_)| row.clone()).collect();
        rows[2].1 = 2; rows[2].3.0 = (10.0,1.0,0.0);
        world.install(rows.clone(),(0,0,0)).unwrap(); world.step().unwrap();
        assert!(end(travel(&world,(5.0,0.0,0.0))).0 > 4.99);
        rows.pop(); world.install(rows,(0,0,0)).unwrap(); world.step().unwrap();
        assert!(end(travel(&world,(15.0,0.0,0.0))).0 > 14.99);
    }

    #[test]
    fn compound_opening_and_rotation_use_all_parts() {
        let mut world = world(vec![box_at(3,Kind::Fixed,(0.0,1.0,4.0),(0.3,0.8,0.3))]);
        let mut rows: Vec<_> = world.rows.values().map(|(row,_)| row.clone()).collect();
        rows[0].1 = 2;
        rows[0].4 = Geometry::Parts(vec![
            (((-1.0,0.0,0.0),(0.0,0.0,0.0)),Primitive::Box(0.2,1.0,0.2)),
            (((1.0,0.0,0.0),(0.0,0.0,0.0)),Primitive::Box(0.2,1.0,0.2)),
        ]);
        world.install(rows,(0,0,0)).unwrap(); world.step().unwrap();
        let p = end(evaluate(&world,1,2,Query::Travel((0.0,0.0,6.0),(0.0,0.0,0.0)),LIMITS));
        assert!(p.2 > 5.99,"opening was incorrectly filled: {p:?}");
        let pose = ((0.0,1.002,3.0),(0.0,std::f64::consts::FRAC_PI_2,0.0));
        assert!(matches!(evaluate(&world,1,2,Query::Place(pose),LIMITS),Answer::Occupied(3,_)));
        // An offset part's arc collides even when the body origin stays still.
        let row = world.rows.get_mut(&1).unwrap();
        world.bodies[row.1].set_position(Pose::translation(0.0,1.002,3.0),true);
        world.changed=true; world.step().unwrap();
        assert!(matches!(evaluate(&world,1,2,Query::Travel((0.0,0.0,0.0),(0.0,std::f64::consts::FRAC_PI_2,0.0)),LIMITS),Answer::Clipped(_,_,_)));
    }

    #[test]
    fn triangular_slope_blocks_downward_sweep() {
        let terrain = (3,1,Kind::Fixed,((0.0,0.0,0.0),(0.0,0.0,0.0)),
            Geometry::Surface(vec![(3.0,0.0,-3.0),(7.0,0.0,-3.0),(5.0,3.0,3.0)],vec![(0,2,1)]),1.0);
        let mut world = world(vec![terrain]);
        let body = world.rows[&1].1;
        world.bodies[body].set_position(Pose::translation(5.0,5.0,0.0),true);
        world.changed=true;world.step().unwrap();
        let p = end(travel(&world,(0.0,-4.0,0.0)));
        assert!(p.1 > 1.01,"slope missed: {p:?}");
    }

    #[test]
    fn explicit_surface_opening_remains_passable_with_solid_rim() {
        let mut world = World::new((32,32,64,100.0,64,128,128),0.016,0.0).unwrap();
        let floor = (2,1,Kind::Fixed,((0.0,0.0,0.0),(0.0,0.0,0.0)),
            Geometry::Surface(
                vec![(-5.0,0.0,-5.0),(5.0,0.0,-5.0),(5.0,0.0,5.0),(-5.0,0.0,5.0),
                     (-1.0,0.0,-1.0),(1.0,0.0,-1.0),(1.0,0.0,1.0),(-1.0,0.0,1.0)],
                vec![(0,4,1),(1,4,5),(1,5,2),(2,5,6),
                     (2,6,3),(3,6,7),(3,7,0),(0,7,4)]),1.0);
        world.install(vec![box_at(1,Kind::Controlled,(0.0,3.0,0.0),(0.5,1.0,0.5)),floor],(0,0,0)).unwrap();
        world.step().unwrap();
        assert!(matches!(travel(&world,(0.0,-6.0,0.0)),Answer::Clear(_,_)));
        let moved = apply(&mut world,1,1,Query::Place(((3.0,3.0,0.0),(0.0,0.0,0.0))),LIMITS);
        assert!(matches!(moved,Answer::Clear(_,_)));
        world.step().unwrap();
        let answer = travel(&world,(0.0,-6.0,0.0));
        assert!(matches!(answer,Answer::Clipped(_,_,_)),"rim missed: {answer:?}");
        let p = end(answer);
        assert!(p.1 >= 1.0 && p.1 < 1.01,"rim contact: {p:?}");
    }

    #[test]
    fn movement_stops_before_dynamic_objects_without_pushing_them() {
        let mut world = world(vec![box_at(3,Kind::Dynamic,(2.0,1.002,0.0),(0.5,1.0,0.5))]);
        let obstacle = *world.bodies[world.rows[&3].1].position();
        let p = end(apply(&mut world,1,1,Query::Travel((10.0,0.0,0.0),(0.0,0.0,0.0)),LIMITS));
        assert!(p.0 > 0.99 && p.0 < 1.0,"{p:?}");
        world.step().unwrap();
        assert_eq!(*world.bodies[world.rows[&3].1].position(),obstacle);
    }

    #[test]
    fn next_agent_queries_the_previous_agents_new_position() {
        let mut world = world(vec![box_at(3,Kind::Controlled,(5.0,1.002,0.0),(0.5,1.0,0.5))]);
        let first = end(apply(&mut world,1,1,Query::Travel((2.5,0.0,0.0),(0.0,0.0,0.0)),LIMITS));
        let second = end(apply(&mut world,3,1,Query::Travel((-2.5,0.0,0.0),(0.0,0.0,0.0)),LIMITS));
        assert!(second.0-first.0 >= 1.0,"{first:?} {second:?}");
        world.step().unwrap();
        assert_eq!(world.bodies[world.rows[&1].1].translation().x,first.0);
        assert_eq!(world.bodies[world.rows[&3].1].translation().x,second.0);
    }

    #[test]
    fn landing_checks_full_path_occupied_target_and_support() {
        let mut world = world(vec![box_at(3,Kind::Fixed,(2.0,2.0,0.0),(0.1,3.0,2.0))]);
        let land = |p| Query::Land(p,10.0,2.0,0.7);
        let initial = world.sample().unwrap();
        assert!(matches!(apply(&mut world,1,1,land((2.0,2.0,0.0)),LIMITS),Answer::Occupied(3,_)));
        assert!(matches!(apply(&mut world,1,1,land((4.0,2.0,0.0)),LIMITS),Answer::Blocked(3,_)));
        assert_eq!(apply(&mut world,1,1,land((0.0,8.0,0.0)),LIMITS),Answer::NoSupport);
        assert_eq!(initial,world.sample().unwrap());
        let p = end(apply(&mut world,1,1,land((0.0,2.0,4.0)),LIMITS));
        assert!(p.1 >= 1.0 && p.1 < 1.003 && p.2 == 4.0,"{p:?}");
    }

    #[test]
    fn authored_camera_clearance_is_sensory_and_excludes_its_own_body() {
        let world = world(vec![box_at(3,Kind::Fixed,(2.0,2.0,0.0),(0.1,3.0,2.0))]);
        let before = world.sample().unwrap();
        let Answer::ViewClearance(distance,_) = evaluate(&world,1,1,Query::View((1.0,0.0,0.0),2.0),LIMITS)
            else { panic!("no view clearance"); };
        assert!(distance > 0.897 && distance < 0.901,"{distance}");
        assert_eq!(evaluate(&world,1,1,Query::View((2.0,0.0,0.0),2.0),LIMITS),Answer::ViewClearance(0.0,2));
        assert_eq!(before,world.sample().unwrap());
        assert_eq!(evaluate(&world,1,1,Query::View((0.0,0.0,0.0),2.0),(0.002,0.0,8,1)),Answer::Exhausted);
    }

    #[test]
    fn occupied_spawn_freezes_travel_until_explicit_clear_reposition() {
        let mut world = world(vec![box_at(3,Kind::Fixed,(0.0,1.0,0.0),(0.2,0.2,0.2))]);
        let before = world.sample().unwrap();
        assert!(matches!(apply(&mut world,1,1,Query::Travel((5.0,0.0,0.0),(0.0,0.0,0.0)),LIMITS),Answer::Occupied(3,_)));
        assert_eq!(before,world.sample().unwrap());
        let corrected = end(apply(&mut world,1,1,Query::Place(((3.0,1.002,0.0),(0.0,0.0,0.0))),LIMITS));
        assert_eq!(corrected.0,3.0);
        assert!(end(travel(&world,(1.0,0.0,0.0))).0 > 3.99);
    }

    #[test]
    fn declared_triangle_wall_blocks_travel_from_both_sides() {
        let sheet = (3,1,Kind::Fixed,((0.0,0.0,0.0),(0.0,0.0,0.0)),
            Geometry::Surface(vec![(2.0,0.0,-5.0),(2.0,4.0,-5.0),(2.0,4.0,5.0),(2.0,0.0,5.0)],
                vec![(0,1,2),(0,2,3)]),1.0);
        let mut world = world(vec![sheet]);
        assert!(end(travel(&world,(5.0,0.0,0.0))).0 < 1.5);
        assert_eq!(end(apply(&mut world,1,1,Query::Place(((4.0,1.002,0.0),(0.0,0.0,0.0))),LIMITS)).0,4.0);
        assert!(end(travel(&world,(-6.0,0.0,0.0))).0 > 2.5);
    }
    fn annular_surface(walls: bool) -> Geometry {
        let mut points = Vec::new();
        for radius in [2200.0,9000.0] {
            for i in 0..24 {
                let angle = std::f64::consts::TAU*i as f64/24.0;
                let x = (radius*(angle.cos()*1000000.0).round()/1000000.0).trunc()/1000.0;
                let z = (radius*(angle.sin()*1000000.0).round()/1000000.0).trunc()/1000.0;
                points.push((x,0.0,z));
            }
        }
        let mut faces = Vec::new();
        for i in 0..24 { faces.extend([(i,24+(i+1)%24,24+i),(i,(i+1)%24,24+(i+1)%24)]); }
        if walls {
            points.extend([(3.2,0.0,-5.0),(3.2,4.0,-5.0),(3.2,4.0,5.0),(3.2,0.0,5.0),
                (-5.0,0.0,3.2),(-5.0,4.0,3.2),(5.0,4.0,3.2),(5.0,0.0,3.2)]);
            faces.extend([(48,49,50),(48,50,51),(52,53,54),(52,54,55)]);
        }
        Geometry::Surface(points,faces)
    }

    fn surface_world(start: V3, roll: f64, yaw: f64, offset: V3, walls: bool) -> (World,Pose) {
        let mut world = World::new((16,16,128,1000.0,32,256,256),0.016667,-9.81).unwrap();
        let frame = geometry::transform((offset,(0.0,0.0,roll)),1000.0).unwrap();
        let position = frame.transform_point(Vector::new(start.0,start.1,start.2));
        world.install(vec![
            (1,1,Kind::Fixed,(offset,(0.0,0.0,roll)),annular_surface(walls),1.0),
            (2,1,Kind::Controlled,(tuple(position),(0.0,yaw,roll)),Geometry::Solid(Primitive::Capsule(0.5,0.25)),1.0),
        ],(0,0,0)).unwrap();
        world.step().unwrap();
        (world,frame)
    }

    fn surface_intersects(world: &World) -> bool {
        let collider = |id| &world.colliders[world.bodies[world.rows[&id].1].colliders()[0]];
        let (agent,surface) = (collider(2),collider(1));
        query::intersection_test(agent.position(),agent.shape(),surface.position(),surface.shape())
            .unwrap().intersecting
    }

    #[test]
    fn capsule_slides_over_surface_in_rotated_frames() {
        let start = (2.68794584274292,0.7519908547401428,0.36940792202949524);
        for (roll,yaw,offset) in [(0.0,0.0,(0.0,0.0,0.0)),(0.0,0.83,(0.0,0.0,0.0)),
                (-0.37,0.83,(13.4,-7.0,12.5)),(0.0,0.0,(990.0,-990.0,990.0)),(-0.37,0.83,(-990.0,990.0,-990.0))] {
            let (mut world,frame) = surface_world(start,roll,yaw,offset,false);
            let movement = tuple(frame.rotation*Vector::new(0.033334,-0.002725109,0.0));
            let p = end(apply(&mut world,2,1,Query::Travel(movement,(0.0,0.0,0.0)),(0.002,0.0,8,128)));
            let local = frame.inverse_transform_point(Vector::new(p.0,p.1,p.2));
            assert!(local.x > start.0+0.03,"roll={roll} yaw={yaw}: {p:?}");
            assert!(!surface_intersects(&world),"surface overlap: {p:?}");
        }
    }

    #[test]
    fn sliding_keeps_obstacles_in_the_same_surface() {
        for (roll,yaw,offset) in [(0.0,0.0,(0.0,0.0,0.0)),(-0.37,0.83,(13.4,-7.0,12.5)),(0.0,0.0,(990.0,-990.0,990.0)),(-0.37,0.83,(-990.0,990.0,-990.0))] {
            for desired in [Vector::new(1.0,-0.002725109,0.0),Vector::new(1.0,-0.002725109,1.0)] {
                let (mut world,frame) = surface_world((2.7,0.752,2.7),roll,yaw,offset,true);
                let answer = apply(&mut world,2,1,Query::Travel(tuple(frame.rotation*desired),(0.0,0.0,0.0)),(0.002,0.0,8,128));
                let Answer::Clipped((p,_),_,checks) = answer else {panic!("missed obstacle: {answer:?}")};
                let local = frame.inverse_transform_point(Vector::new(p.0,p.1,p.2));
                assert!(local.x > 2.94 && local.x < 2.951,"wall: {local:?}");
                assert!(local.z < 2.951,"corner: {local:?}");
                assert!(checks < 10,"slide budget consumed by repeated contact: {checks}");
                assert!(!surface_intersects(&world),"surface overlap: {p:?}");
            }
        }
    }

    #[test]
    fn repeated_capsule_travel_keeps_surface_clearance() {
        let (mut world,_) = surface_world((0.0,0.752,4.0),0.0,0.83,(0.0,0.0,0.0),false);
        for i in 0..2048 {
            let before = std::f64::consts::TAU*i as f64/2048.0;
            let after = std::f64::consts::TAU*(i+1) as f64/2048.0;
            let delta = (4.0*(after.sin()-before.sin()),-0.002725109,4.0*(after.cos()-before.cos()));
            let p = end(apply(&mut world,2,1,Query::Travel(delta,(0.0,0.0,0.0)),(0.002,0.0,8,128)));
            assert!(!surface_intersects(&world),"surface overlap at {i}: {p:?}");
            world.step().unwrap();
        }
        let pose = world.bodies[world.rows[&2].1].translation();
        assert!((pose-Vector::new(0.0,0.752,4.0)).length() < 0.02,"walk failed: {pose:?}");
        assert!((pose.y-0.752).abs() <= 0.002,"accumulated height drift: {pose:?}");
    }


    #[test]
    fn head_on_surface_contact_converges() {
        let (mut world,_) = surface_world((2.68794584274292,0.7519908547401428,0.36940792202949524),0.0,0.0,(0.0,0.0,0.0),false);
        let n = Vector::new(2.232_312e-5,0.999_999_94,-3.348_468e-5);
        let answer = apply(&mut world,2,1,Query::Travel(tuple(-n),(0.0,0.0,0.0)),(0.002,0.0,8,128));
        let Answer::Clipped(_,_,checks) = answer else {panic!("head-on: {answer:?}")};
        assert!(checks <= 4,"head-on repeats: {checks}");
        assert!(!surface_intersects(&world));
    }

    #[test]
    fn captured_clear_floor_travel_makes_progress() {
        let cases = [
            ((5.128269672393799,0.7517002820968628,1.5401973724365234),(-0.423,-1.954)),
            ((5.241491794586182,0.751920759677887,2.8427703380584717),(-1.954,0.423)),
            ((5.593716621398926,0.751710057258606,1.9480516910552979),(0.423,1.954)),
        ];
        let mut failures = Vec::new();
        for (start,(x,z)) in cases {
            let (mut world,_) = surface_world(start,0.0,0.0,(0.0,0.0,0.0),false);
            let delta = (x*0.016667,-9.81*0.016667*0.016667,z*0.016667);
            assert!(!surface_intersects(&world) && start.1 > 0.75,"initial overlap: {start:?}");
            let answer = apply(&mut world,2,1,Query::Travel(delta,(0.0,0.0,0.0)),(0.002,0.0,8,128));
            assert!(!surface_intersects(&world),"surface overlap: {start:?}");
            match answer {
                Answer::Clear((p,_),_) | Answer::Clipped((p,_),_,_) => {
                    if (p.0-start.0).hypot(p.2-start.2) < 0.03 { failures.push(start); }
                }
                _ => failures.push(start),
            }
        }

        assert!(failures.is_empty(),"clear floor failed to advance: {failures:?}");
    }

    #[test]
    fn separating_floor_keeps_close_walls_in_the_same_mesh() {
        for (roll,yaw,offset) in [(0.0,0.0,(0.0,0.0,0.0)),(-0.37,0.83,(13.4,-7.0,12.5))] {
            for (start,delta) in [((2.9485,0.7510,2.7),Vector::new(0.04,0.02,0.0)),
                                  ((2.9485,0.7510,2.9485),Vector::new(0.04,0.02,0.04))] {
                let (mut world,frame)=surface_world(start,roll,yaw,offset,true);
                let answer=apply(&mut world,2,1,Query::Travel(tuple(frame.rotation*delta),(0.0,0.0,0.0)),(0.002,0.0,8,128));
                let p=end(answer);
                let local=frame.inverse_transform_point(Vector::new(p.0,p.1,p.2));
                assert!(local.x<=2.9501 && local.z<=2.9501,"wall missed: {local:?}");
                assert!(local.y>0.77,"separating travel blocked: {local:?}");
                assert!(!surface_intersects(&world));
            }
            let (mut world,frame)=surface_world((2.9485,0.7510,2.9485),roll,yaw,offset,true);
            let start=world.bodies[world.rows[&2].1].translation();
            let result=apply(&mut world,2,1,Query::Travel(tuple(frame.rotation*Vector::new(-0.04,0.02,-0.04)),(0.0,0.0,0.0)),(0.002,0.0,8,128));
            let p=end(result);let local=frame.rotation.inverse()*(Vector::new(p.0,p.1,p.2)-start);
            assert!(local.x < -0.039 && local.z < -0.039 && local.y>0.019,"separating contact blocked: {local:?}");
        }
    }

    #[test]
    fn shape_cast_preserves_authored_hole() {
        let (world,_)=surface_world((0.0,0.8,0.0),0.0,0.0,(0.0,0.0,0.0),false);
        let p=end(evaluate(&world,2,1,Query::Travel((0.0,-1.0,0.0),(0.0,0.0,0.0)),(0.002,0.0,8,128)));
        assert!(p.1 < -0.19,"hole filled: {p:?}");
        assert_eq!(evaluate(&world,2,1,Query::Land((0.0,0.8,0.0),1.0,1.0,0.9),(0.002,0.0,8,128)),Answer::NoSupport);
    }

    #[test]
    fn shape_cast_obeys_the_existing_allowance() {
        let (world,_)=surface_world((5.128269672393799,0.7517002820968628,1.5401973724365234),0.0,0.0,(0.0,0.0,0.0),false);
        let make=||Query::Travel((-0.007050141,-0.002725109001090001,-0.032567318),(0.0,0.0,0.0));
        let full=evaluate(&world,2,1,make(),(0.002,0.0,8,128));
        let Answer::Clipped(_,_,used)=full else {panic!("unexpected {full:?}")};
        assert!(used>0);
        assert_eq!(evaluate(&world,2,1,make(),(0.002,0.0,8,used)),full);
        assert_eq!(evaluate(&world,2,1,make(),(0.002,0.0,8,used-1)),Answer::Exhausted);
    }

    #[test]
    fn long_reciprocal_surface_walk_makes_progress() {
        for (roll,yaw,offset) in [(0.0,0.0,(0.0,0.0,0.0)),(-0.37,0.83,(13.4,-7.0,12.5))] {
            let (mut world,frame)=surface_world((5.2685847,0.751785,1.8875018),roll,yaw,offset,false);
            let mut total=0;
            for cycle in 0..42 {
                for (x,z,ticks) in [(-0.423,-1.954,36),(0.423,1.954,36),(-1.954,0.423,16),(1.954,-0.423,16)] {
                    for _ in 0..ticks {
                        let before=world.bodies[world.rows[&2].1].translation();
                        let delta=frame.rotation*Vector::new(x*0.016667,-0.002725109,z*0.016667);
                        let answer=apply(&mut world,2,1,Query::Travel(tuple(delta),(0.0,0.0,0.0)),(0.002,0.0,8,128));
                        let p=match answer {
                            Answer::Clear((p,_),_) | Answer::Clipped((p,_),_,_) => p,
                            _ => panic!("roll={roll} cycle={cycle} step={total} before={before:?}: {answer:?}"),
                        };
                        let progress=frame.rotation.inverse()*(Vector::new(p.0,p.1,p.2)-before);
                        assert!(progress.x.hypot(progress.z)>0.03,"floor stall roll={roll} step={total}: {progress:?}");
                        assert!(!surface_intersects(&world),"overlap roll={roll} step={total}: {p:?}");
                        world.step().unwrap();total+=1;
                    }
                }
            }
        }

    }

    #[test]
    fn skin_boundary_travel_and_landing_paths_remain_clear() {
        let positions=[(5.1282697,1.5401974),(5.241492,2.8427703),(5.5937166,1.9480517),
            (5.0,0.0),(4.829629,1.294095),(4.330127,2.5),(3.535534,3.535534),
            (0.0,5.0),(-4.0,3.0),(-5.0,0.0),(0.0,-5.0),
            (5.155712127685547,1.3666876554489136),(-2.826486825942993,2.83035945892334)];
        let mut travel_bad=Vec::new();let mut land_bad=Vec::new();let mut path_bad=Vec::new();
        let mut count=0;let mut queries=0;
        for (speed_scale,down) in [(1.0,-0.002725109),(2.0,-0.002725109),(4.0,-0.002725109),(1.0,0.0),(4.0,0.0)] {
        for (roll,yaw,offset) in [(0.0,0.0,(0.0,0.0,0.0)),(-0.37,0.83,(13.4,-7.0,12.5))] {
            for (x,z) in positions {
                for y in (0..=40).map(|gap_step|0.7515+gap_step as f64*0.000025).chain([0.7517002820968628,0.751920759677887,0.751710057258606,0.7522839307785034,0.7521604299545288]) {
                    let start=(x,y,z);
                    for (vx,vz) in [(-0.423,-1.954),(0.423,1.954),(-1.954,0.423),(1.954,-0.423)] {
                        let (mut world,frame)=surface_world(start,roll,yaw,offset,false);
                        let answer=apply(&mut world,2,1,Query::Travel(tuple(frame.rotation*Vector::new(vx*0.016667*speed_scale,down,vz*0.016667*speed_scale)),(0.0,0.0,0.0)),(0.002,0.0,8,128));
                        count+=1;
                        assert!(!surface_intersects(&world),"sweep overlap: {start:?}");
                        match answer {
                            Answer::Clear((p,_),n) | Answer::Clipped((p,_),_,n) => {
                                queries+=n;
                                let v=frame.inverse_transform_point(Vector::new(p.0,p.1,p.2));
                                assert!(v.y>=0.75,"analytic floor penetration: {v:?}");
                                if (v.x-x).hypot(v.z-z)<0.03*speed_scale {travel_bad.push(format!("roll={roll} start={start:?} v=({vx},{vz}) scale={speed_scale} down={down} end={v:?}"));}
                            }
                            _=>travel_bad.push(format!("roll={roll} start={start:?} v=({vx},{vz}) scale={speed_scale} down={down} answer={answer:?}")),
                        }
                    }
                    // Landing descends along world Y, so use identity floor frames.
                    if roll==0.0 {
                        let (world,_)=surface_world(start,roll,yaw,offset,false);
                        let answer=evaluate(&world,2,1,Query::Land(start,1.0,0.1,0.9),(0.002,0.0,8,128));
                        if !matches!(answer,Answer::Clipped(_,_,_)) {land_bad.push(format!("start={start:?} answer={answer:?}"));}
                        let target=(x+0.1,start.1,z);
                        let answer=evaluate(&world,2,1,Query::Land(target,1.0,0.1,0.9),(0.002,0.0,8,128));
                        if !matches!(answer,Answer::Clipped(_,_,_)) {path_bad.push(format!("start={start:?} answer={answer:?}"));}
                    }
                }
            }
        }
        }
        eprintln!("SUMMARY count={count} queries={queries} travel_bad={} land_bad={} path_bad={}",travel_bad.len(),land_bad.len(),path_bad.len());
        for (label,rows) in [("travel",&travel_bad),("land",&land_bad),("path",&path_bad)] {
            for row in rows.iter() {eprintln!("{label}: {row}");}
        }
        assert!(travel_bad.is_empty() && land_bad.is_empty() && path_bad.is_empty());
    }


    #[test]
    fn target_distance_cast_finds_captured_triangle() {
        use rapier3d::parry::shape::{Capsule,Triangle};
        let Geometry::Surface(points,faces)=annular_surface(false) else {unreachable!()};
        let (a,b,c)=faces[2];
        let v=|i: usize| Vector::new(points[i].0,points[i].1,points[i].2);
        let triangle=Triangle::new(v(a as usize),v(b as usize),v(c as usize));
        let capsule=Capsule::new_y(0.5,0.25);
        let pose=Pose::translation(5.1282697,0.7517003,1.5401974);
        let velocity=Vector::new(-0.007050141,-0.002725109,-0.03256732);
        let options=ShapeCastOptions {max_time_of_impact:1.0,target_distance:0.002,
            stop_at_penetration:false,compute_impact_geometry_on_penetration:true};
        let hit=query::cast_shapes(&Pose::IDENTITY,Vector::ZERO,&triangle,&pose,velocity,&capsule,options)
            .unwrap().expect("within-skin approach must find the triangle");
        assert_eq!(hit.time_of_impact,0.0);
        assert!(hit.normal1.x.hypot(hit.normal1.z).atan2(hit.normal1.y) < 0.02,"bad floor normal: {hit:?}");
        assert!(query::cast_shapes(&Pose::IDENTITY,Vector::ZERO,&triangle,&pose,-velocity,&capsule,options).unwrap().is_none(),
            "separation must remain clear");
    }

    #[test]
    fn compound_parts_keep_each_nearby_face() {
        for (roll,yaw,offset) in [(0.0,0.0,(0.0,0.0,0.0)),(-0.37,0.0,(13.4,-7.0,12.5))] {
            for z in [2.7,2.9485] {
                let (mut world,frame)=surface_world((2.5485,0.7515,z),roll,yaw,offset,true);
                let mut rows:Vec<_>=world.rows.values().map(|(row,_)|row.clone()).collect();
                let agent=rows.iter_mut().find(|row|row.0==2).unwrap();
                agent.1=2;
                agent.4=Geometry::Parts(vec![
                    (((-0.4,0.0,0.0),(0.0,0.0,0.0)),Primitive::Capsule(0.5,0.25)),
                    (((0.4,0.0,0.0),(0.0,0.0,0.0)),Primitive::Capsule(0.5,0.25)),
                ]);
                world.install(rows,(0,0,0)).unwrap();world.step().unwrap();
                let delta=frame.rotation*Vector::new(0.04,0.02,0.04);
                let p=end(apply(&mut world,2,2,Query::Travel(tuple(delta),(0.0,0.0,0.0)),(0.002,0.0,8,128)));
                let local=frame.inverse_transform_point(Vector::new(p.0,p.1,p.2));
                assert!(local.x<=2.5501 && local.z<=2.9501,"compound missed wall: {local:?}");
                assert!(local.y>0.77,"compound separating floor blocked: {local:?}");
                assert!(!surface_intersects(&world));
            }
        }
    }

    #[test]
    fn rotation_then_translation_keeps_surface_clearance() {
        let (mut world,_)=surface_world((5.0,0.7517,0.0),0.0,0.0,(0.0,0.0,0.0),false);
        let rotated=end(apply(&mut world,2,1,Query::Travel((0.0,0.0,0.0),(0.0,0.7,0.0)),(0.002,0.0,8,128)));
        assert!(!surface_intersects(&world));
        world.step().unwrap();
        for step in 0..32 {
            let before=world.bodies[world.rows[&2].1].translation();
            let p=end(apply(&mut world,2,1,Query::Travel((0.033334,-0.002725109,0.0),(0.0,0.0,0.0)),(0.002,0.0,8,128)));
            assert!(p.0-before.x>0.03,"rotation left a floor stall at {step}: {rotated:?} {p:?}");
            assert!(!surface_intersects(&world));world.step().unwrap();
        }
    }

    #[test]
    fn resting_landing_path_still_checks_the_complete_body() {
        let (mut world,_)=surface_world((2.8,0.7517,2.7),0.0,0.0,(0.0,0.0,0.0),true);
        let before=world.sample().unwrap();
        assert!(matches!(apply(&mut world,2,1,Query::Land((3.6,0.7517,2.7),2.0,0.1,0.9),(0.002,0.0,8,128)),Answer::Blocked(1,_)));
        assert_eq!(before,world.sample().unwrap());
        assert!(matches!(apply(&mut world,2,1,Query::Land((3.1,0.7517,2.7),2.0,0.1,0.9),(0.002,0.0,8,128)),Answer::Occupied(1,_)));
        assert_eq!(before,world.sample().unwrap());
    }


    #[test]
    fn triangle_face_edge_vertex_normal_accuracy() {
        use rapier3d::parry::shape::{Capsule,Triangle};
        let Geometry::Surface(points,faces)=annular_surface(false) else {unreachable!()};
        let capsule=Capsule::new_y(0.5,0.25);
        let positions=[(5.1282697,1.5401974),(5.241492,2.8427703),(5.5937166,1.9480517),
            (5.0,0.0),(4.829629,1.294095),(4.330127,2.5),(3.535534,3.535534),
            (0.0,5.0),(-4.0,3.0),(-5.0,0.0),(0.0,-5.0),
            (5.155712127685547,1.3666876554489136),(-2.826486825942993,2.83035945892334),
            (9.003,-0.003),(-9.003,0.003),(0.003,9.003)];
        let mut count=0;let mut features=[0_usize;3];let mut within_worst=(0.0,String::new());let mut all_worst=(0.0,String::new());let mut missing=0;
        for (x,z) in positions {
            for y in (0..=40).map(|gap_step|0.7515+gap_step as f64*0.000025).chain([0.7517002820968628,0.751920759677887,0.751710057258606,0.7522839307785034,0.7521604299545288]) {
                let pose=Pose::translation(x,y,z);
                let pos=(pose.translation.x,pose.translation.z);
                for (i,&(a,b,c)) in faces.iter().enumerate() {
                    let v=|k|Vector::new(points[k as usize].0,0.0,points[k as usize].2);
                    let [a,b,c]=[v(a),v(b),v(c)];
                    let cross=|u:Vector,v:Vector| (v.x-u.x)*(pos.1-u.z)-(v.z-u.z)*(pos.0-u.x);
                    let signs=[cross(a,b),cross(b,c),cross(c,a)];
                    let inside=signs.iter().all(|s|*s>=-1.0e-9)||signs.iter().all(|s|*s<=1.0e-9);
                    let (q,feature)=if inside {(pos,0)} else {
                        [(a,b),(b,c),(c,a)].map(|(u,v)| {
                            let (ux,uz,vx,vz)=(u.x,u.z,v.x,v.z);
                            let t=(((pos.0-ux)*(vx-ux)+(pos.1-uz)*(vz-uz))/((vx-ux).powi(2)+(vz-uz).powi(2))).clamp(0.0,1.0);
                            ((ux+t*(vx-ux),uz+t*(vz-uz)),if t==0.0 || t==1.0 {2} else {1})
                        }).into_iter().min_by(|u,v| (pos.0-u.0.0).hypot(pos.1-u.0.1).total_cmp(&(pos.0-v.0.0).hypot(pos.1-v.0.1))).unwrap()
                    };
                    let expected=[pos.0-q.0,pose.translation.y-0.5,pos.1-q.1];
                    let length=expected.iter().map(|x|x*x).sum::<f64>().sqrt();
                    let true_gap=length-0.25;
                    if true_gap>0.0025 {continue;}
                    count+=1;features[feature]+=1;
                    let tri=Triangle::new(a,b,c);
                    let velocity=Vector::new(0.0,-0.002725109,0.0);
                    let options=ShapeCastOptions {max_time_of_impact:1.0,target_distance:0.002,
                        stop_at_penetration:false,compute_impact_geometry_on_penetration:true};
                    if let Some(hit)=query::cast_shapes(&Pose::IDENTITY,Vector::ZERO,&tri,&pose,velocity,&capsule,options).unwrap() {
                        let expected=Vector::new(expected[0],expected[1]+velocity.y*hit.time_of_impact,expected[2]).normalize();
                        let n=hit.normal1;
                        // At time zero, refinement is independent of cast velocity.
                        // Check sign classification for these sampled approaches and
                        // separations; later vertical hits only measure slide quality.
                        if true_gap<=0.002 { for speed in [2.0,4.0,8.0] {
                            for (dx,dz) in [(1.0,1.0),(1.0,-1.0),(-1.0,1.0),(-1.0,-1.0)] {
                                let horizontal=speed*0.016667/2.0_f64.sqrt();
                                let travel=Vector::new(dx*horizontal,-0.002725109,dz*horizontal);
                                let approach=expected.dot(travel);
                                assert!((n-expected).length()*travel.length() < approach.abs(),
                                    "normal error can reverse approach: n={n:?} expected={expected:?} travel={travel:?}");
                                assert_eq!(n.dot(travel).is_sign_negative(),approach.is_sign_negative());
                            }
                        }
                        }
                        let angle=(n.cross(expected).length()).atan2(n.dot(expected));
                        let row=format!("x={x} y={y} z={z} triangle={i} normal={n:?} expected={expected:?} true_gap={true_gap} toi={}",hit.time_of_impact);
                        if angle>all_worst.0 {all_worst=(angle,row.clone());}
                        if true_gap<=0.002 && angle>within_worst.0 {within_worst=(angle,row);}
                    }else{missing+=1;}
                }
            }
        }
        assert_eq!(missing,0);
        assert!(features.iter().all(|n|*n>0),"missing face/edge/vertex coverage: {features:?}");
        assert!(within_worst.0<0.0003,"within-skin normal error: {within_worst:?}");
        eprintln!("ANALYTIC_CONTACT features={features:?} count={count} missing={missing} within={within_worst:?} all={all_worst:?}");
    }


    #[test]
    fn grazing_near_a_single_triangle_edge() {
        for speed in [2.0_f64,4.0,8.0] {
            let start=(-2.826486825942993,0.751575,2.83035945892334);
            let (mut world,_)=surface_world(start,0.0,0.0,(0.0,0.0,0.0),false);
            let mut rows:Vec<_>=world.rows.values().map(|(row,_)|row.clone()).collect();
            let ground=rows.iter_mut().find(|row|row.0==1).unwrap();ground.1=2;
            let Geometry::Surface(points,faces)=annular_surface(false) else {unreachable!()};
            let (a,b,c)=faces[18];ground.4=Geometry::Surface(vec![points[a as usize],points[b as usize],points[c as usize]],vec![(0,1,2)]);
            world.install(rows,(0,0,0)).unwrap();world.step().unwrap();
            let d=speed*0.016667/std::f64::consts::SQRT_2;
            let answer=apply(&mut world,2,1,Query::Travel((d,-0.002725109,-d),(0.0,0.0,0.0)),(0.002,0.0,8,128));
            eprintln!("SINGLE_EDGE speed={speed} answer={answer:?}");
            let p=end(answer);assert!((p.0-start.0).hypot(p.2-start.2)>speed*0.016667*0.9);
            assert!(!surface_intersects(&world));
        }
    }

}
