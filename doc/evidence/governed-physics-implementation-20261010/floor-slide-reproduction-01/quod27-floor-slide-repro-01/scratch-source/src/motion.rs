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
    Unavailable,
    Unsupported,
    Invalid,
    Exhausted,
}

fn position(p: Pose) -> Position {
    ((p.translation.x as f64,p.translation.y as f64,p.translation.z as f64),
     (p.rotation.x as f64,p.rotation.y as f64,p.rotation.z as f64,p.rotation.w as f64))
}
fn tuple(v: Vector) -> V3 { (v.x as f64,v.y as f64,v.z as f64) }

struct Space<'a> {
    query: QueryPipeline<'a>,
    shape: &'a dyn Shape,
    checks: usize,
    remaining: usize,
    tolerance: f32,
}

impl Space<'_> {
    fn charge(&mut self) -> Result<(),Answer> {
        self.remaining = self.remaining.checked_sub(1).ok_or(Answer::Exhausted)?;
        self.checks += 1;
        Ok(())
    }

    fn occupied(&mut self, pose: Pose) -> Result<Option<u64>,Answer> {
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

    fn cast(&mut self, pose: Pose, travel: Vector, turn: Vector, skin: f32)
        -> Result<Option<(f32,u64,Vector)>,Answer> {
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
        let pipeline = self.query;
        let mut earliest: Option<(f32,u64,Vector)> = None;
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
        let pose = Pose::from_parts(Vector::new(p.0 as f32,p.1 as f32,p.2 as f32),
            Rotation::from_xyzw(q.0 as f32,q.1 as f32,q.2 as f32,q.3 as f32));
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
    let mut space = Space { query: world.broad.as_query_pipeline(&DefaultQueryDispatcher,
        &world.bodies,&world.colliders,QueryFilter::default().exclude_rigid_body(body_handle)),
        shape, checks: 0, remaining: checks, tolerance: tolerance as f32 };
    let mut pose = *body.position();
    let (mut travel,mut turn) = match input {
        Query::View(local,radius) => {
            if !radius.is_finite() || radius <= 0.0 || radius > world.limits.3 { return Err(Answer::Invalid); }
            let local = geometry::vector(local,world.limits.3).map_err(|_| Answer::Invalid)?;
            let point = pose.transform_point(local);
            let pipeline = space.query;
            let mut clearance = radius as f32;
            for (_,other) in pipeline.intersect_aabb_conservative(Aabb::from_half_extents(point,Vector::splat(clearance))) {
                space.charge()?;
                let projected = other.shape().project_point(other.position(),point,true);
                let distance = if projected.is_inside { 0.0 } else { (point-projected.point).length() };
                if !distance.is_finite() { return Err(Answer::Unavailable); }
                clearance = clearance.min(distance);
            }
            return Ok(Answer::ViewClearance((clearance-skin as f32).max(0.0) as f64,space.checks));
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
            if delta.length() as f64 > reach { return Err(Answer::Invalid); }
            if let Some(other) = space.occupied(pose)? { return Ok(Answer::Occupied(other,space.checks)); }
            let mut landing = pose;
            landing.translation = target;
            if let Some(other) = space.occupied(landing)? { return Ok(Answer::Occupied(other,space.checks)); }
            if delta != Vector::ZERO {
                if let Some((_,other,_)) = space.cast(pose,delta,Vector::ZERO,skin as f32)? {
                    return Ok(Answer::Blocked(other,space.checks));
                }
            }
            let descent = Vector::new(0.0,-(drop as f32),0.0);
            let Some((fraction,other,normal)) = space.cast(landing,descent,Vector::ZERO,skin as f32)?
                else { return Ok(Answer::NoSupport); };
            if normal.y < up as f32 { return Ok(Answer::NoSupport); }
            landing.translation += descent*fraction;
            if landing.translation.abs().max_element() as f64 > world.limits.3 { return Err(Answer::Invalid); }
            if let Some(other) = space.occupied(landing)? { return Ok(Answer::Occupied(other,space.checks)); }
            return Ok(Answer::Clipped(position(landing),vec![(other,tuple(normal))],space.checks));
        }
        Query::Travel(delta,rotation) => (
            geometry::vector(delta,world.limits.3).map_err(|_| Answer::Invalid)?,
            geometry::vector(rotation,std::f64::consts::PI).map_err(|_| Answer::Invalid)?),
    };
    if let Some(other) = space.occupied(pose)? { return Ok(Answer::Occupied(other,space.checks)); }
    if (pose.translation+travel).abs().max_element() as f64 > world.limits.3 { return Err(Answer::Invalid); }
    let mut contacts = Vec::new();
    for _ in 0..iterations {
        if travel == Vector::ZERO && turn == Vector::ZERO { break; }
        let Some((time,other,normal)) = space.cast(pose,travel,turn,skin as f32)? else {
            pose = NonlinearRigidMotion::new(pose,Vector::ZERO,travel,turn).position_at_time(1.0);
            break;
        };
        let radius = shape.compute_local_aabb().mins.abs().max(shape.compute_local_aabb().maxs.abs()).length();
        let speed_bound = travel.length()+turn.length()*radius;
        let fraction = if turn == Vector::ZERO { time }
            else { (time-(skin as f32)/speed_bound).max(0.0) };
        pose = NonlinearRigidMotion::new(pose,Vector::ZERO,travel,turn).position_at_time(fraction);
        contacts.push((other,tuple(normal)));
        travel *= 1.0-fraction;
        // Rotation stops at contact. Translation may continue along the surface.
        turn = Vector::ZERO;
        travel -= normal*travel.dot(normal).min(0.0);
        travel += normal*(16.0*f32::EPSILON*travel.length());
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
        world.install(rows).unwrap(); world.step().unwrap(); world
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
        world.install(rows.clone()).unwrap(); world.step().unwrap();
        assert!(end(travel(&world,(5.0,0.0,0.0))).0 > 4.99);
        rows.pop(); world.install(rows).unwrap(); world.step().unwrap();
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
        world.install(rows).unwrap(); world.step().unwrap();
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
        world.install(vec![box_at(1,Kind::Controlled,(0.0,3.0,0.0),(0.5,1.0,0.5)),floor]).unwrap();
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
        assert_eq!(world.bodies[world.rows[&1].1].translation().x,first.0 as f32);
        assert_eq!(world.bodies[world.rows[&3].1].translation().x,second.0 as f32);
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

    #[test]
    fn surface_skin_contact_keeps_tangent_motion() {
        let mut world = World::new((16,16,128,1000.0,32,256,256),0.016667,-9.81).unwrap();
        let start = (2.68794584274292,0.7519908547401428,0.36940792202949524);
        let floor = (1,1,Kind::Fixed,((0.0,0.0,0.0),(0.0,0.0,0.0)),Geometry::Surface(vec![(2.2, 0.0, 0.0),(2.125, 0.0, 0.569),(1.905, 0.0, 1.1),(1.555, 0.0, 1.555),(1.1, 0.0, 1.905),(0.569, 0.0, 2.125),(0.0, 0.0, 2.2),(-0.569, 0.0, 2.125),(-1.1, 0.0, 1.905),(-1.555, 0.0, 1.555),(-1.905, 0.0, 1.1),(-2.125, 0.0, 0.569),(-2.2, 0.0, 0.0),(-2.125, 0.0, -0.569),(-1.905, 0.0, -1.1),(-1.555, 0.0, -1.555),(-1.1, 0.0, -1.905),(-0.569, 0.0, -2.125),(0.0, 0.0, -2.2),(0.569, 0.0, -2.125),(1.1, 0.0, -1.905),(1.555, 0.0, -1.555),(1.905, 0.0, -1.1),(2.125, 0.0, -0.569),(9.0, 0.0, 0.0),(8.693, 0.0, 2.329),(7.794, 0.0, 4.5),(6.363, 0.0, 6.363),(4.5, 0.0, 7.794),(2.329, 0.0, 8.693),(0.0, 0.0, 9.0),(-2.329, 0.0, 8.693),(-4.5, 0.0, 7.794),(-6.363, 0.0, 6.363),(-7.794, 0.0, 4.5),(-8.693, 0.0, 2.329),(-9.0, 0.0, 0.0),(-8.693, 0.0, -2.329),(-7.794, 0.0, -4.5),(-6.363, 0.0, -6.363),(-4.5, 0.0, -7.794),(-2.329, 0.0, -8.693),(0.0, 0.0, -9.0),(2.329, 0.0, -8.693),(4.5, 0.0, -7.794),(6.363, 0.0, -6.363),(7.794, 0.0, -4.5),(8.693, 0.0, -2.329)],vec![(0, 25, 24),(0, 1, 25),(1, 26, 25),(1, 2, 26),(2, 27, 26),(2, 3, 27),(3, 28, 27),(3, 4, 28),(4, 29, 28),(4, 5, 29),(5, 30, 29),(5, 6, 30),(6, 31, 30),(6, 7, 31),(7, 32, 31),(7, 8, 32),(8, 33, 32),(8, 9, 33),(9, 34, 33),(9, 10, 34),(10, 35, 34),(10, 11, 35),(11, 36, 35),(11, 12, 36),(12, 37, 36),(12, 13, 37),(13, 38, 37),(13, 14, 38),(14, 39, 38),(14, 15, 39),(15, 40, 39),(15, 16, 40),(16, 41, 40),(16, 17, 41),(17, 42, 41),(17, 18, 42),(18, 43, 42),(18, 19, 43),(19, 44, 43),(19, 20, 44),(20, 45, 44),(20, 21, 45),(21, 46, 45),(21, 22, 46),(22, 47, 46),(22, 23, 47),(23, 24, 47),(23, 0, 24)]),1.0);
        let agent = (2,1,Kind::Controlled,(start,(0.0,0.0,0.0)),Geometry::Solid(Primitive::Capsule(0.5,0.25)),1.0);
        world.install(vec![floor,agent]).unwrap(); world.step().unwrap();
        let separating = evaluate(&world,2,1,Query::Travel((2.0*0.016667,0.0000001,0.0),(0.0,0.0,0.0)),(0.002,0.0,8,128));
        assert!(matches!(separating,Answer::Clear(_,_)), "separating control: {separating:?}");
        let answer = apply(&mut world,2,1,Query::Travel((2.0*0.016667,-9.81*0.016667*0.016667,0.0),(0.0,0.0,0.0)),(0.002,0.0,8,128));
        eprintln!("answer: {answer:?}");
        let p = end(answer);
        assert!(p.0 > start.0 + 0.03, "tangent travel caught on flat surface: {p:?}");
        assert!(p.1 >= 0.75, "overlap: {p:?}");
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
        let position = frame.transform_point(Vector::new(start.0 as f32,start.1 as f32,start.2 as f32));
        world.install(vec![
            (1,1,Kind::Fixed,(offset,(0.0,0.0,roll)),annular_surface(walls),1.0),
            (2,1,Kind::Controlled,(tuple(position),(0.0,yaw,roll)),Geometry::Solid(Primitive::Capsule(0.5,0.25)),1.0),
        ]).unwrap();
        world.step().unwrap();
        (world,frame)
    }

    fn surface_distance(world: &World) -> f32 {
        let collider = |id| &world.colliders[world.bodies[world.rows[&id].1].colliders()[0]];
        let (agent,surface) = (collider(2),collider(1));
        query::contact(agent.position(),agent.shape(),surface.position(),surface.shape(),1.0)
            .unwrap().unwrap().dist
    }

    #[test]
    fn capsule_slides_over_surface_in_rotated_frames() {
        let start = (2.68794584274292,0.7519908547401428,0.36940792202949524);
        for (roll,yaw,offset) in [(0.0,0.0,(0.0,0.0,0.0)),(0.0,0.83,(0.0,0.0,0.0)),
                (-0.37,0.83,(13.4,-7.0,12.5))] {
            let (mut world,frame) = surface_world(start,roll,yaw,offset,false);
            let movement = tuple(frame.rotation*Vector::new(0.033334,-0.002725109,0.0));
            let p = end(apply(&mut world,2,1,Query::Travel(movement,(0.0,0.0,0.0)),(0.002,0.0,8,128)));
            let local = frame.inverse_transform_point(Vector::new(p.0 as f32,p.1 as f32,p.2 as f32));
            assert!(local.x as f64 > start.0+0.03,"roll={roll} yaw={yaw}: {p:?}");
            assert!(surface_distance(&world) >= 0.0,"surface overlap: {p:?}");
        }
    }

    #[test]
    fn diagnostic_obstacles_in_the_same_surface() {
        for (roll,yaw,offset) in [(0.0,0.0,(0.0,0.0,0.0)),(-0.37,0.83,(13.4,-7.0,12.5))] {
            for desired in [Vector::new(1.0,-0.002725109,0.0),Vector::new(1.0,-0.002725109,1.0)] {
                let (mut world,frame) = surface_world((2.7,0.752,2.7),roll,yaw,offset,true);
                let answer = apply(&mut world,2,1,Query::Travel(tuple(frame.rotation*desired),(0.0,0.0,0.0)),(0.002,0.0,8,128));
                let Answer::Clipped((p,_),_,checks) = answer else {panic!("missed obstacle: {answer:?}")};
                let local = frame.inverse_transform_point(Vector::new(p.0 as f32,p.1 as f32,p.2 as f32));
                eprintln!("wall roll={roll}: {local:?} checks={checks}");
                assert!(local.x > 2.94 && local.x < 2.951,"wall: {local:?}");
                assert!(local.z < 2.951,"corner: {local:?}");
                eprintln!("diagnostic cast checks: {checks}");
                assert!(surface_distance(&world) >= 0.0,"surface overlap: {p:?}");
            }
        }
    }

    #[test]
    fn diagnostic_repeated_capsule_travel() {
        let (mut world,_) = surface_world((0.0,0.752,4.0),0.0,0.83,(0.0,0.0,0.0),false);
        let mut min_y = 100.0f64; let mut max_y = -100.0f64;
        for i in 0..2048 {
            let before = std::f64::consts::TAU*i as f64/2048.0;
            let after = std::f64::consts::TAU*(i+1) as f64/2048.0;
            let delta = (4.0*(after.sin()-before.sin()),-0.002725109,4.0*(after.cos()-before.cos()));
            let p = end(apply(&mut world,2,1,Query::Travel(delta,(0.0,0.0,0.0)),(0.002,0.0,8,128)));
            min_y=min_y.min(p.1); max_y=max_y.max(p.1);
            assert!(surface_distance(&world) >= 0.0,"surface overlap at {i}: {p:?}");
            world.step().unwrap();
        }
        let pose = world.bodies[world.rows[&2].1].translation();
        eprintln!("full walk pose={pose:?} y=({min_y},{max_y})");
        assert!((pose-Vector::new(0.0,0.752,4.0)).length() < 0.02,"walk failed: {pose:?}");
    }


    #[test]
    fn head_on_surface_contact_converges() {
        let (mut world,_) = surface_world((2.68794584274292,0.7519908547401428,0.36940792202949524),0.0,0.0,(0.0,0.0,0.0),false);
        let n = Vector::new(2.232311999250669e-5,0.9999999403953552,-3.348468089825474e-5);
        let answer = apply(&mut world,2,1,Query::Travel(tuple(-n),(0.0,0.0,0.0)),(0.002,0.0,8,128));
        eprintln!("head-on {answer:?}");
        let Answer::Clipped(_,_,checks) = answer else {panic!("head-on: {answer:?}")};
        assert!(checks <= 4,"head-on repeats: {checks}");
        assert!(surface_distance(&world) >= 0.0);
    }

}
