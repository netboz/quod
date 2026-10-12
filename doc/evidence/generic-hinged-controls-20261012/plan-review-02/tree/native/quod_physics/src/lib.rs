//! Mechanical adapter. No ontology, principal, generation or domain decisions.
use rapier3d::prelude::*;
mod geometry;
mod motion;
use geometry::{Geometry, Kind, Transform};
use rustler::{Atom, Env, LocalPid, NifResult, ResourceArc, Term};
use std::collections::{BTreeMap, BTreeSet};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::{Mutex, TryLockError};

mod atoms {
    rustler::atoms! { ok, busy, retired, wrong_owner, native_failure, invalid_body,
    body_allowance, pose_allowance, contact_allowance, invalid_allowance,
    coordinate_allowance, invalid_step, invalid_gravity, non_finite_state, stale_revision, invalid_hinge, geometry_allowance, invalid_checkpoint }
}

// Metres, seconds and kilograms. Names and revisions remain in the Erlang owner.
// id, revision, mechanical kind, baseline pose, authored geometry, density.
type Body = (u64, u64, Kind, Transform, Geometry, f64);
type Limits = (usize, usize, usize, f64, usize, usize, usize);
type Pose = (u64, (f64, f64, f64), (f64, f64, f64, f64), (f64, f64, f64));
type Rest = (u64, u64, (geometry::V3, (f64,f64,f64,f64)), f64, usize);
type Sample = (bool, Vec<Pose>, Vec<(u64, u64)>);
// Millimetres and quaternion millionths; a sleeping body has zero velocity.
type RestSample = ((i64, i64, i64), (i64, i64, i64, i64));

// Vertical revolute cuboid profile. Each leaf has one joint; the existing
// body allowance bounds the joint set too. Restore angles are insertion inputs,
// never part of a structural definition's identity.
type Hinge = (u64, u64, u64, (f64, f64, f64), f64, (f64, f64, f64, f64));
struct InstalledHinge {
    row: Hinge,
    handle: ImpulseJointHandle,
    leaf: RigidBodyHandle,
    frame: RigidBodyHandle,
    driving: bool,
}

struct World {
    pipeline: PhysicsPipeline,
    islands: IslandManager,
    broad: BroadPhaseBvh,
    narrow: NarrowPhase,
    bodies: RigidBodySet,
    colliders: ColliderSet,
    impulse: ImpulseJointSet,
    multibody: MultibodyJointSet,
    ccd: CCDSolver,
    soft: SoftBodySet,
    rows: BTreeMap<u64, (Body, RigidBodyHandle)>,
    hinges: BTreeMap<u64, InstalledHinge>,
    limits: Limits,
    dt: f64,
    gravity: f64,
    changed: bool,
    query_ready: bool,
}

struct WorldResource {
    owner: LocalPid,
    world: Mutex<Option<World>>,
}
#[rustler::resource_impl]
impl rustler::Resource for WorldResource {}

impl World {
    fn new(limits: Limits, dt: f64, gravity: f64) -> Result<Self, Atom> {
        if !limits.3.is_finite() || limits.3 <= 0.0 {
            return Err(atoms::invalid_allowance());
        }
        // These are representation/algorithm requirements, not population budgets.
        if !dt.is_finite() || dt <= 0.0 || !dt.recip().is_finite() {
            return Err(atoms::invalid_step());
        }
        if !gravity.is_finite() {
            return Err(atoms::invalid_gravity());
        }
        Ok(Self {
            pipeline: PhysicsPipeline::new(),
            islands: IslandManager::new(),
            broad: BroadPhaseBvh::new(),
            narrow: NarrowPhase::new(),
            bodies: RigidBodySet::new(),
            colliders: ColliderSet::new(),
            impulse: ImpulseJointSet::new(),
            multibody: MultibodyJointSet::new(),
            ccd: CCDSolver::new(),
            soft: SoftBodySet::new(),
            rows: BTreeMap::new(),
            hinges: BTreeMap::new(),
            limits,
            dt,
            gravity,
            changed: false,
            query_ready: false,
        })
    }

    fn install(&mut self, definitions: Vec<Body>) -> Result<usize, Atom> {
        if definitions.len() > self.limits.0 { return Err(atoms::body_allowance()); }
        let mut budget = geometry::Budget { coordinate: self.limits.3,
            parts: self.limits.4, vertices: self.limits.5, triangles: self.limits.6 };
        let mut seen = BTreeSet::new();
        let mut prepared = Vec::new();
        for row @ (id, revision, kind, pose, shape, density) in &definitions {
            if !seen.insert(*id) || *revision == 0 || *density <= 0.0
                || !density.is_finite() { return Err(atoms::invalid_body()); }
            if let Some((old, _)) = self.rows.get(id) {
                if old == row { shape.charge(&mut budget)?; continue; }
                if old.1 >= *revision { return Err(atoms::stale_revision()); }
            }
            let pose = geometry::transform(*pose,self.limits.3)?;
            let shape = shape.build(*kind,&mut budget)?;
            if *kind != Kind::Fixed {
                let mass = shape.mass_properties(*density).mass();
                if !mass.is_finite() || mass <= 0.0 { return Err(atoms::invalid_body()); }
            }
            prepared.push((row.clone(),pose,shape));
        }
        let removed: Vec<_> = self.rows.keys().filter(|id| !seen.contains(id)).copied().collect();
        let changes = removed.len() + prepared.len();
        for id in removed { self.remove(id); }
        for (row,pose,shape) in prepared {
            let id = row.0;
            self.remove(id);
            let builder = match row.2 {
                Kind::Dynamic => RigidBodyBuilder::dynamic().ccd_enabled(true),
                Kind::Fixed => RigidBodyBuilder::fixed(),
                Kind::Controlled => RigidBodyBuilder::kinematic_position_based(),
            };
            let body = self.bodies.insert(builder.pose(pose));
            self.colliders.insert_with_parent(ColliderBuilder::new(shape)
                .density(row.5).user_data(id as u128),body,&mut self.bodies);
            self.rows.insert(id,(row,body));
        }
        self.changed |= changes != 0;
        self.query_ready &= changes == 0;
        Ok(changes)
    }

    // Rest state is an insertion input only. The Erlang owner sends it only
    // for newly installed body revisions, never on a checkpoint-only update.
    fn restore_rest(&mut self, rows: Vec<Rest>) -> Result<(), Atom> {
        if rows.len() > self.limits.0 { return Err(atoms::body_allowance()); }
        let mut seen = BTreeSet::new();
        for (id, rev, (p, q), tolerance, checks) in &rows {
            let Some((row, handle)) = self.rows.get(id) else { return Err(atoms::invalid_checkpoint()); };
            if row.1 != *rev || row.2 != Kind::Dynamic || !seen.insert(*id)
                || self.hinges.values().any(|h| h.row.0 == *id || h.row.2 == *id)
                || !tolerance.is_finite() || *tolerance < 0.0 || *checks == 0 {
                return Err(atoms::invalid_checkpoint());
            }
            let position = geometry::vector(*p,self.limits.3).map_err(Atom::from)?;
            let rotation = Rotation::from_xyzw(q.0,q.1,q.2,q.3);
            if !rotation.is_finite() || (rotation.length_squared()-1.0).abs() > 0.000004 {
                return Err(atoms::invalid_checkpoint());
            }
            self.bodies[*handle].set_position(rapier3d::math::Pose::from_parts(position,rotation.normalize()),false);
            self.bodies[*handle].sleep();
        }
        // Zero-displacement recovery: admit numerical contact tolerance, but
        // never depenetrate a saved chair through a newer wall or closed door.
        for (id, _, _, tolerance, checks) in &rows {
            let handle = self.rows[id].1;
            let body = &self.bodies[handle];
            let collider = &self.colliders[body.colliders()[0]];
            let mut remaining = *checks;
            for (_, other) in self.colliders.iter() {
                if other.parent() == Some(handle) { continue; }
                remaining = remaining.checked_sub(1).ok_or_else(atoms::invalid_checkpoint)?;
                let other_pose = match other.parent() {
                    Some(h) => *self.bodies[h].position() * other.position_wrt_parent().copied().unwrap_or_default(),
                    None => *other.position(),
                };
                let contact = rapier3d::parry::query::contact(body.position(),collider.shape(),
                    &other_pose,other.shape(),0.0).map_err(|_| atoms::invalid_checkpoint())?;
                if contact.is_some_and(|c| c.dist < -*tolerance) {
                    return Err(atoms::invalid_checkpoint());
                }
            }
        }
        Ok(())
    }

    fn rest_sample(&self, id: u64, rev: u64) -> Option<RestSample> {
        let (row, handle) = self.rows.get(&id)?;
        let b = &self.bodies[*handle];
        if row.1 != rev || row.2 != Kind::Dynamic || !b.is_sleeping() { return None; }
        let p = b.translation(); let q = b.rotation();
        Some((((p.x*1000.0).round() as i64,(p.y*1000.0).round() as i64,
               (p.z*1000.0).round() as i64),
              ((q.x*1e6).round() as i64,(q.y*1e6).round() as i64,
               (q.z*1e6).round() as i64,(q.w*1e6).round() as i64)))
    }

    fn push_body(&mut self, id:u64, rev:u64, impulse:geometry::V3, max_speed:f64) -> bool {
        let Some((row, handle)) = self.rows.get(&id) else { return false; };
        if row.1 != rev || row.2 != Kind::Dynamic
            || self.hinges.values().any(|h| h.row.0 == id || h.row.2 == id)
            || !max_speed.is_finite() || max_speed <= 0.0 { return false; }
        let Ok(impulse) = geometry::vector(impulse,f64::MAX) else { return false; };
        let b = &mut self.bodies[*handle];
        let velocity = b.linvel() + impulse * b.mass().recip();
        // Policy bounds the resulting speed, so rapid signed packets cannot
        // accumulate an unbounded velocity. A refused push changes nothing.
        if !velocity.is_finite() || velocity.length() > max_speed { return false; }
        b.apply_impulse(impulse,true);
        self.changed = true;
        true
    }

    fn install_hinges(&mut self, inputs: Vec<(Hinge, f64)>) -> Result<usize, Atom> {
        let mut seen = BTreeSet::new();
        for (
            row @ (id, rev, frame, (x, y, z), baseline, (stiffness, damping, force, tolerance)),
            restore,
        ) in &inputs
        {
            let Some((leaf_row, _)) = self.rows.get(id) else {
                return Err(atoms::invalid_hinge());
            };
            let Some((frame_row, _)) = self.rows.get(frame) else {
                return Err(atoms::invalid_hinge());
            };
            if !seen.insert(*id)
                || id == frame
                || leaf_row.2 != Kind::Dynamic
                || frame_row.2 != Kind::Fixed
                || leaf_row.4.box_half_x().is_none()
                || frame_row.4.box_half_x().is_none()
                || leaf_row.3.1 != (0.0, 0.0, 0.0)
                || frame_row.3.1 != (0.0, 0.0, 0.0)
                || *rev != leaf_row.1
                || *rev != frame_row.1
                || [baseline, restore, stiffness, damping, force, tolerance]
                    .iter()
                    .any(|v| !v.is_finite())
                || baseline.abs() >= std::f64::consts::PI
                || restore.abs() >= std::f64::consts::PI
                || *stiffness <= 0.0
                || *damping <= 0.0
                || *force <= 0.0
                || *tolerance <= 0.0
                || *tolerance >= baseline.abs()
            {
                return Err(atoms::invalid_hinge());
            }
            if [x, y, z]
                .iter()
                .any(|v| !v.is_finite() || v.abs() > self.limits.3)
            {
                return Err(atoms::coordinate_allowance());
            }
            if let Some(old) = self.hinges.get(id) {
                if (old.row != *row && old.row.1 >= *rev)
                    || (old.row == *row && self.impulse.get(old.handle).is_none())
                {
                    return Err(atoms::stale_revision());
                }
            }
        }
        let removed: Vec<_> = self
            .hinges
            .keys()
            .filter(|id| !seen.contains(id))
            .copied()
            .collect();
        let mut changes = removed.len();
        for id in removed {
            let old = self.hinges.remove(&id).unwrap();
            self.impulse.remove(old.handle, true);
        }
        for (row @ (id, _, frame_id, (x, y, z), _, _), restore) in inputs {
            if self.hinges.get(&id).is_some_and(|old| old.row == row) {
                continue;
            }
            if let Some(old) = self.hinges.remove(&id) {
                self.impulse.remove(old.handle, true);
            }
            let (leaf_row, leaf) = &self.rows[&id];
            let leaf = *leaf;
            let frame = self.rows[&frame_id].1;
            let pivot = Vector::new(x, y, z);
            let offset = Vector::new(leaf_row.4.box_half_x().ok_or_else(atoms::invalid_hinge)?, 0.0, 0.0);
            let rotation = rapier3d::math::rotation_from_angle(Vector::Y * restore);
            let position = self.bodies[frame].translation() + pivot + rotation * offset;
            self.bodies[leaf].set_translation(position, true);
            self.bodies[leaf].set_rotation(rotation, true);
            self.bodies[leaf].set_linvel(Vector::ZERO, true);
            self.bodies[leaf].set_angvel(Vector::ZERO, true);
            let joint = RevoluteJointBuilder::new(Vector::Y)
                .local_anchor1(pivot)
                .local_anchor2(-offset)
                .contacts_enabled(false)
                .limits([restore, restore]);
            let handle = self.impulse.insert(frame, leaf, joint, true);
            self.hinges.insert(
                id,
                InstalledHinge {
                    row,
                    handle,
                    leaf,
                    frame,
                    driving: false,
                },
            );
            changes += 1;
        }
        self.changed |= changes > 0;
        self.query_ready &= changes == 0;
        Ok(changes)
    }

    fn hinge_angle(&self, h: &InstalledHinge) -> Result<f64, Atom> {
        let joint = self
            .impulse
            .get(h.handle)
            .ok_or_else(atoms::invalid_hinge)?;
        let revolute = RevoluteJoint { data: joint.data };
        let angle = revolute.angle(
            self.bodies[h.frame].rotation(),
            self.bodies[h.leaf].rotation(),
        );
        if angle.is_finite() {
            Ok(angle)
        } else {
            Err(atoms::non_finite_state())
        }
    }

    fn drive_hinge(&mut self, id: u64, drive: bool) -> Result<(), Atom> {
        let h = self.hinges.get(&id).ok_or_else(atoms::invalid_hinge)?;
        let angle = self.hinge_angle(h)?;
        let h = self.hinges.get_mut(&id).unwrap();
        let joint = self
            .impulse
            .get_mut(h.handle, true)
            .ok_or_else(atoms::invalid_hinge)?;
        if drive {
            let limit = h.row.4.abs();
            joint.data.set_limits(JointAxis::AngX, [-limit, limit]);
            joint.data.set_motor_position(
                JointAxis::AngX,
                0.0,
                h.row.5 .0,
                h.row.5 .1,
            );
            joint
                .data
                .set_motor_max_force(JointAxis::AngX, h.row.5 .2);
        } else {
            joint.data.set_limits(JointAxis::AngX, [angle, angle]);
            joint.data.set_motor_max_force(JointAxis::AngX, 0.0);
            self.bodies[h.leaf].set_linvel(Vector::ZERO, true);
            self.bodies[h.leaf].set_angvel(Vector::ZERO, true);
        }
        h.driving = drive;
        self.changed = true;
        Ok(())
    }

    // The brake is mechanical. Only Prolog interprets the measured condition
    // as a durable blocked/closed result for an authorized activity.
    fn brake_hinges(&mut self) -> Result<(), Atom> {
        let mut stopped = BTreeSet::new();
        for (id, h) in &self.hinges {
            if h.driving && self.hinge_angle(h)?.abs() <= h.row.5 .3 {
                stopped.insert(*id);
            }
        }
        for pair in self
            .narrow
            .contact_pairs()
            .filter(|p| p.has_any_active_contact())
        {
            let a = self.colliders[pair.collider1].user_data as u64;
            let b = self.colliders[pair.collider2].user_data as u64;
            for (leaf, other) in [(a, b), (b, a)] {
                if let Some(h) = self.hinges.get(&leaf) {
                    if h.driving && other != h.row.2 {
                        stopped.insert(leaf);
                    }
                }
            }
        }
        for id in stopped {
            self.drive_hinge(id, false)?;
        }
        Ok(())
    }

    fn hinge_samples(&self) -> Result<Vec<(u64, i64, bool)>, Atom> {
        self.hinges
            .iter()
            .map(|(id, h)| {
                Ok((
                    *id,
                    (self.hinge_angle(h)? * 1000.0).round() as i64,
                    h.driving,
                ))
            })
            .collect()
    }

    fn remove(&mut self, id: u64) {
        if let Some((_, handle)) = self.rows.remove(&id) {
            self.bodies.remove(
                handle,
                &mut self.islands,
                &mut self.colliders,
                &mut self.impulse,
                &mut self.multibody,
                &mut self.soft,
                true,
            );
        }
    }

    fn active(&self) -> bool {
        self.changed
            || self
                .bodies
                .iter()
                .any(|(_, b)| b.is_dynamic() && !b.is_sleeping())
    }

    fn step(&mut self) -> Result<Sample, Atom> {
        if !self.active() {
            return Ok((false, vec![], vec![]));
        }
        let parameters = IntegrationParameters {
            dt: self.dt,
            ..Default::default()
        };
        self.pipeline.step(
            Vector::new(0.0, self.gravity, 0.0),
            &parameters,
            &mut self.islands,
            &mut self.broad,
            &mut self.narrow,
            &mut self.bodies,
            &mut self.colliders,
            &mut self.impulse,
            &mut self.multibody,
            &mut self.soft,
            &mut self.ccd,
            &(),
            &(),
        );
        // Rapier repairs/disables non-finite bodies internally. Expose that
        // loss of simulation continuity as failure of this selected world.
        if !self.pipeline.quarantine().is_empty() {
            return Err(atoms::non_finite_state());
        }
        self.changed = false;
        self.query_ready = true;
        self.brake_hinges()?;
        self.sample()
    }

    fn sample(&self) -> Result<Sample, Atom> {
        if self.rows.len() > self.limits.1 {
            return Err(atoms::pose_allowance());
        }
        let mut poses = Vec::with_capacity(self.rows.len());
        for (id, (_, handle)) in &self.rows {
            let b = &self.bodies[*handle];
            let p = b.translation();
            let q = b.rotation();
            let v = b.linvel();
            if !p.is_finite() || !v.is_finite() || !q.is_finite() {
                return Err(atoms::non_finite_state());
            }
            if p.to_array().iter().any(|x| x.abs() > self.limits.3) {
                return Err(atoms::coordinate_allowance());
            }
            poses.push((
                *id,
                (p.x, p.y, p.z),
                (q.x, q.y, q.z, q.w),
                (v.x, v.y, v.z),
            ));
        }
        let mut contacts = Vec::new();
        for pair in self
            .narrow
            .contact_pairs()
            .filter(|p| p.has_any_active_contact())
        {
            if contacts.len() == self.limits.2 {
                return Err(atoms::contact_allowance());
            }
            contacts.push((
                self.colliders[pair.collider1].user_data as u64,
                self.colliders[pair.collider2].user_data as u64,
            ));
        }
        Ok((self.active(), poses, contacts))
    }
}

fn access<T>(
    env: Env,
    resource: ResourceArc<WorldResource>,
    f: impl FnOnce(&mut World) -> Result<T, Atom>,
) -> Result<T, Atom> {
    if env.pid() != resource.owner {
        return Err(atoms::wrong_owner());
    }
    let mut guard = match resource.world.try_lock() {
        Ok(g) => g,
        Err(TryLockError::WouldBlock) => return Err(atoms::busy()),
        Err(TryLockError::Poisoned(_)) => return Err(atoms::native_failure()),
    };
    let Some(world) = guard.as_mut() else {
        return Err(atoms::retired());
    };
    match catch_unwind(AssertUnwindSafe(|| f(world))) {
        Ok(Ok(result)) => Ok(result),
        Ok(Err(reason)) => {
            *guard = None;
            Err(reason)
        }
        Err(_) => {
            *guard = None;
            Err(atoms::native_failure())
        }
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn new_world(
    env: Env,
    limits: Limits,
    dt: f64,
    gravity: f64,
) -> Result<ResourceArc<WorldResource>, Atom> {
    World::new(limits, dt, gravity).map(|world| {
        ResourceArc::new(WorldResource {
            owner: env.pid(),
            world: Mutex::new(Some(world)),
        })
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn install(
    env: Env,
    resource: ResourceArc<WorldResource>,
    definitions: Term,
) -> Result<usize, Atom> {
    access(env, resource, |world| {
        let terms: rustler::types::list::ListIterator =
            definitions.decode().map_err(|_| atoms::invalid_body())?;
        let mut rows = Vec::new();
        for term in terms {
            if rows.len() == world.limits.0 {
                return Err(atoms::body_allowance());
            }
            rows.push(term.decode().map_err(|_| atoms::invalid_body())?);
        }
        world.install(rows)
    })
}
#[rustler::nif(schedule = "DirtyCpu")]
fn restore_rest(env:Env, resource:ResourceArc<WorldResource>, rows:Vec<Rest>) -> Result<(),Atom> {
    access(env,resource,|w| w.restore_rest(rows))
}
#[rustler::nif(schedule = "DirtyCpu")]
fn rest_sample(env:Env, resource:ResourceArc<WorldResource>, id:u64, rev:u64)
    -> Result<Option<RestSample>,Atom> {
    access(env,resource,|w| Ok(w.rest_sample(id,rev)))
}
#[rustler::nif(schedule = "DirtyCpu")]
fn push_body(env:Env, resource:ResourceArc<WorldResource>, id:u64, rev:u64,
             impulse:geometry::V3, max_speed:f64) -> Result<bool,Atom> {
    access(env,resource,|w| Ok(w.push_body(id,rev,impulse,max_speed)))
}
#[rustler::nif(schedule = "DirtyCpu")]
fn install_hinges(
    env: Env,
    resource: ResourceArc<WorldResource>,
    definitions: Term,
) -> Result<usize, Atom> {
    access(env, resource, |world| {
        let terms: rustler::types::list::ListIterator =
            definitions.decode().map_err(|_| atoms::invalid_hinge())?;
        let mut rows = Vec::new();
        for term in terms {
            if rows.len() == world.limits.0 {
                return Err(atoms::body_allowance());
            }
            rows.push(term.decode().map_err(|_| atoms::invalid_hinge())?);
        }
        world.install_hinges(rows)
    })
}
#[rustler::nif(schedule = "DirtyCpu")]
fn drive_hinge(
    env: Env,
    resource: ResourceArc<WorldResource>,
    id: u64,
    drive: bool,
) -> Result<(), Atom> {
    access(env, resource, |world| world.drive_hinge(id, drive))
}
#[rustler::nif(schedule = "DirtyCpu")]
fn hinge_samples(
    env: Env,
    resource: ResourceArc<WorldResource>,
) -> Result<Vec<(u64, i64, bool)>, Atom> {
    access(env, resource, |world| world.hinge_samples())
}
#[rustler::nif(schedule = "DirtyCpu")]
fn step(env: Env, resource: ResourceArc<WorldResource>, refresh: bool) -> Result<Sample, Atom> {
    access(env, resource, |world| {
        // Explicit observation renewal completes a new mechanical step even
        // at rest. Ordinary unchanged checks retain the sleeping sentinel.
        world.changed |= refresh;
        world.step()
    })
}
#[rustler::nif(schedule = "DirtyCpu")]
fn sample(env: Env, resource: ResourceArc<WorldResource>) -> Result<Sample, Atom> {
    access(env, resource, |world| world.sample())
}
#[rustler::nif(schedule = "DirtyCpu")]
fn motion_query(env: Env, resource: ResourceArc<WorldResource>, id: u64, revision: u64,
                query: motion::Query, limits: motion::Limits) -> Result<motion::Answer, Atom> {
    access(env, resource, |world| Ok(motion::evaluate(world,id,revision,query,limits)))
}
#[rustler::nif(schedule = "DirtyCpu")]
fn move_body(env: Env, resource: ResourceArc<WorldResource>, id: u64, revision: u64,
             query: motion::Query, limits: motion::Limits) -> Result<motion::Answer, Atom> {
    access(env, resource, |world| Ok(motion::apply(world,id,revision,query,limits)))
}
#[rustler::nif(schedule = "DirtyCpu")]
fn retire(env: Env, resource: ResourceArc<WorldResource>) -> NifResult<Atom> {
    if env.pid() != resource.owner {
        return Err(rustler::Error::Term(Box::new(atoms::wrong_owner())));
    }
    match resource.world.try_lock() {
        Ok(mut guard) => {
            *guard = None;
            Ok(atoms::ok())
        }
        Err(_) => Err(rustler::Error::Term(Box::new(atoms::busy()))),
    }
}

rustler::init!("quod_physics_native");

#[cfg(test)]
mod tests {
    use super::*;
    fn box_body(id:u64, rev:u64, dynamic:bool, p:geometry::V3, h:geometry::V3, density:f64) -> Body {
        (id,rev,if dynamic {Kind::Dynamic} else {Kind::Fixed},
         (p,(0.0,0.0,0.0)),Geometry::Solid(geometry::Primitive::Box(h.0,h.1,h.2)),density)
    }
    #[test]
    fn independent_hinges_brake_restore_and_retain() {
        let mut w = World::new((5, 5, 10, 100.0, 64, 1024, 1024), 1.0 / 60.0, 0.0).unwrap();
        let frame = box_body(1, 1, false, (0.0, 0.0, 0.0), (0.05, 1.0, 0.05), 1.0);
        let door = box_body(2, 1, true, (1.0, 1.0, 0.0), (1.0, 1.0, 0.1), 1.0);
        let obstacle = box_body(3, 1, false, (1.5, 1.0, -0.5), (0.2, 1.0, 0.2), 1.0);
        let frame2 = box_body(4, 1, false, (5.0, 0.0, 0.0), (0.05, 1.0, 0.05), 1.0);
        let door2 = box_body(5, 1, true, (6.0, 1.0, 0.0), (1.0, 1.0, 0.1), 1.0);
        let hinge = (2, 1, 1, (0.0, 1.0, 0.0), 1.5, (100.0, 10.0, 1000.0, 0.02));
        let hinge2 = (5, 1, 4, (0.0, 1.0, 0.0), 1.5, (100.0, 10.0, 1000.0, 0.02));
        w.install(vec![frame.clone(), door.clone(), obstacle.clone(), frame2.clone(), door2.clone()])
            .unwrap();
        assert_eq!(w.install_hinges(vec![(hinge, 1.5), (hinge2, 1.5)]), Ok(2));
        w.drive_hinge(2, true).unwrap();
        w.drive_hinge(5, true).unwrap();
        let mut contact_seen = false;
        for _ in 0..600 {
            let sample = w.step().unwrap();
            contact_seen |= sample.2.iter().any(|p| *p == (2, 3) || *p == (3, 2));
            if w.hinge_samples().unwrap().iter().all(|s| !s.2) {
                break;
            }
        }
        let samples = w.hinge_samples().unwrap();
        assert!(contact_seen);
        assert!(!samples[0].2 && samples[0].1 > 20, "{samples:?}");
        assert!(!samples[1].2 && samples[1].1.abs() <= 20, "{samples:?}");
        let poses = w.sample().unwrap();
        assert_eq!(w.install_hinges(vec![(hinge, 0.3), (hinge2, 0.0)]), Ok(0));
        assert_eq!(w.sample().unwrap(), poses);
        // A braked sleeping body must wake when an ordinary edit clears its obstacle.
        for _ in 0..600 {
            w.step().unwrap();
        }
        let mut moved = obstacle.clone();
        moved.1 = 2;
        moved.3.0 = (20.0, 1.0, -0.5);
        w.install(vec![frame.clone(), door.clone(), moved.clone(), frame2.clone(), door2.clone()]).unwrap();
        w.drive_hinge(2, true).unwrap();
        for _ in 0..600 {
            w.step().unwrap();
            if !w.hinge_samples().unwrap()[0].2 {
                break;
            }
        }
        assert!(w.hinge_samples().unwrap()[0].1.abs() <= 20);
        let checkpoint = samples[0].1 as f64 / 1000.0;
        let mut recovered = World::new((3, 3, 10, 100.0, 64, 1024, 1024), 1.0 / 60.0, 0.0).unwrap();
        recovered.install(vec![frame.clone(), door.clone(), obstacle.clone()]).unwrap();
        recovered.install_hinges(vec![(hinge, checkpoint)]).unwrap();
        assert_eq!(
            recovered.hinge_samples().unwrap(),
            vec![(2, samples[0].1, false)]
        );
    }

    #[test]
    fn bounded_push_rest_and_recovery() {
        let mut w = World::new((3,3,4,100.0,64,1024,1024),1.0/60.0,-9.81).unwrap();
        let ground = box_body(1,1,false,(0.0,-0.5,0.0),(10.0,0.5,10.0),1.0);
        let chair = box_body(2,1,true,(0.0,0.5,0.0),(0.5,0.5,0.5),1.0);
        w.install(vec![ground.clone(),chair.clone()]).unwrap();
        assert!(!w.push_body(2,0,(1.0,0.0,0.0),5.0));
        assert!(!w.push_body(1,1,(1.0,0.0,0.0),5.0));
        assert!(!w.push_body(2,1,(6.0,0.0,0.0),5.0));
        assert!(w.push_body(2,1,(1.0,0.0,0.0),5.0));
        assert_eq!(w.rest_sample(2,1),None);
        for _ in 0..600 { w.step().unwrap(); }
        let (p,q) = w.rest_sample(2,1).expect("pushed body settles");
        assert!(p.0 > 0);
        let cp = (2,1,((p.0 as f64/1000.0,p.1 as f64/1000.0,p.2 as f64/1000.0),
            (q.0 as f64/1e6,q.1 as f64/1e6,q.2 as f64/1e6,q.3 as f64/1e6)),0.005,128);
        let before = w.sample().unwrap();
        assert_eq!(w.install(vec![ground.clone(),chair.clone()]),Ok(0));
        assert_eq!(w.sample().unwrap(),before);
        let mut recovered = World::new((3,3,4,100.0,64,1024,1024),1.0/60.0,-9.81).unwrap();
        recovered.install(vec![ground.clone(),chair.clone()]).unwrap();
        recovered.restore_rest(vec![cp]).unwrap();
        assert_eq!(recovered.rest_sample(2,1),Some((p,q)));
    }

    #[test]
    fn falling_and_retained_installation() {
        let mut w = World::new((2, 2, 1, 1000.0, 64, 1024, 1024), 1.0 / 60.0, -9.81).unwrap();
        let ground = box_body(1, 1, false, (0.0, -0.5, 0.0), (10.0, 0.5, 10.0), 1.0);
        let body = box_body(2, 1, true, (0.0, 3.0, 0.0), (0.5, 0.5, 0.5), 1.0);
        assert_eq!(w.install(vec![ground.clone(), body.clone()]), Ok(2));
        for _ in 0..30 {
            w.step().unwrap();
        }
        let before = w.sample().unwrap();
        assert!(before.1[1].1 .1 < 3.0);
        assert_eq!(w.install(vec![ground.clone(), body.clone()]), Ok(0));
        assert_eq!(w.sample().unwrap(), before);
        let changed = box_body(2, 2, true, (0.0, 5.0, 0.0), (0.5, 0.5, 0.5), 1.0);
        assert_eq!(w.install(vec![ground.clone(), changed.clone()]), Ok(1));
        assert_eq!(w.sample().unwrap().1[1].1 .1, 5.0);
        for _ in 0..1000 {
            w.step().unwrap();
        }
        assert!(!w.active());
        assert_eq!(w.step().unwrap(), (false, vec![], vec![]));
    }
}
