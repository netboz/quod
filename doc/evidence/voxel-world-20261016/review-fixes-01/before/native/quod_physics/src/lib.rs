//! Mechanical adapter. No ontology, principal, generation or domain decisions.
use rapier3d::prelude::*;
mod geometry;
mod motion;
mod voxel;
mod terrain;
mod origin;
use geometry::{Geometry, Kind, Transform};
use rustler::{Atom, Encoder, Env, LocalPid, NifResult, ResourceArc, Term};
use std::collections::{BTreeMap, BTreeSet};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::{Mutex, TryLockError};

#[rustler::nif(schedule = "DirtyCpu")]
fn voxel_surface(samples: rustler::Binary, dimensions: (u32,u32,u32), spacing: u32,
                 allowances: (u64,u64,u64)) -> Result<voxel::Mesh,voxel::Error> {
    voxel::surface(samples.as_slice(),dimensions,spacing,allowances)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn voxel_prepare<'a>(env: Env<'a>, density: rustler::Binary, materials: rustler::Binary,
                     spacing: u32, allowances: (u64,u64,u64,u64), previous: Vec<voxel::chunk::Shared>)
    -> Result<(Term<'a>,rustler::Binary<'a>),voxel::Error> {
    if previous.len() > 1 { return Err(voxel::Error::InvalidVoxelField); }
    let (prepared,payload) = voxel::chunk::Prepared::new(density.as_slice(),materials.as_slice(),spacing,allowances,
        previous.first().map(|p| &**p))?;
    let mut bytes = rustler::OwnedBinary::new(payload.len()).ok_or(voxel::Error::InvalidVoxelSurface)?;
    bytes.as_mut_slice().copy_from_slice(&payload);
    let shared = voxel::chunk::Shared(std::sync::Arc::new(prepared));
    Ok((shared.encode(env),bytes.release(env)))
}

// Admission measures the same geometry accounting used by installation,
// without creating a world or rebuilding retained shapes.
#[rustler::nif(schedule = "DirtyCpu")]
fn geometry_cost(shapes: Vec<Geometry>, coordinate: f64) -> Result<(usize,usize,usize),Atom> {
    let mut budget = geometry::Budget { parts:usize::MAX,vertices:usize::MAX,
        triangles:usize::MAX,coordinate };
    for shape in shapes {
        if let Geometry::Terrain(spacing,chunks) = &shape {
            terrain::validate(*spacing,chunks,Kind::Fixed,rapier3d::math::Pose::IDENTITY,coordinate)?;
        }
        shape.charge(&mut budget)?;
    }
    Ok((usize::MAX-budget.parts,usize::MAX-budget.vertices,usize::MAX-budget.triangles))
}

mod atoms {
    rustler::atoms! { ok, busy, retired, wrong_owner, native_failure, invalid_body,
    body_allowance, pose_allowance, contact_allowance, invalid_allowance,
    coordinate_allowance, invalid_step, invalid_gravity, non_finite_state, stale_revision, invalid_hinge, geometry_allowance, invalid_checkpoint, unavailable, terrain_coverage }
}

#[derive(Debug,PartialEq)]
enum InstallError { Geometry(Atom), Frame(origin::Error) }
impl From<geometry::Error> for InstallError { fn from(e:geometry::Error) -> Self { Self::Geometry(e.into()) } }
impl From<Atom> for InstallError { fn from(e:Atom) -> Self { Self::Geometry(e) } }
impl From<origin::Error> for InstallError { fn from(e:origin::Error) -> Self { Self::Frame(e) } }

// Metres, seconds and kilograms. Names and revisions remain in the Erlang owner.
// id, revision, mechanical kind, baseline pose, authored geometry, density.
type Body = (u64, u64, Kind, Transform, Geometry, f64);
type Limits = (usize, usize, usize, f64, usize, usize, usize);
type Pose = (u64, (f64, f64, f64), (f64, f64, f64, f64), (f64, f64, f64));
type Rest = (u64, u64, (geometry::V3, (f64,f64,f64,f64)), f64, usize);
type Sample = (bool, Vec<Pose>, Vec<(u64, u64)>);
#[derive(Debug,PartialEq)]
enum Step { Sample(Sample), Coverage(Vec<terrain::Requirement>), Frame(Vec<(geometry::V3,geometry::V3)>) }
impl Encoder for Step {
    fn encode<'a>(&self,env:Env<'a>) -> Term<'a> {
        match self {
            Self::Sample(sample) => sample.encode(env),
            Self::Coverage(ranges) => (atoms::unavailable(),(atoms::terrain_coverage(),ranges)).encode(env),
            Self::Frame(bounds) => (atoms::unavailable(),(atoms::coordinate_allowance(),bounds)).encode(env),
        }
    }
}
enum Restore { Ready, Coverage(Vec<terrain::Requirement>) }
impl Encoder for Restore {
    fn encode<'a>(&self,env:Env<'a>) -> Term<'a> {
        match self {
            Self::Ready => ().encode(env),
            Self::Coverage(ranges) => (atoms::unavailable(),(atoms::terrain_coverage(),ranges)).encode(env),
        }
    }
}
// Millimetres and quaternion millionths; a sleeping body has zero velocity.
type RestSample = ((i64, i64, i64), (i64, i64, i64, i64));

// One revolute joint per moving body. Body and joint revisions are independent.
// Restore angles are insertion inputs, never structural identity.
#[derive(Clone, Copy, Debug, PartialEq, rustler::NifTuple)]
struct Hinge {
    moving: (u64, u64),
    revision: u64,
    fixed: (u64, u64),
    axis: geometry::V3,
    anchors: (geometry::V3, geometry::V3),
    limits: (f64, f64),
    baseline: f64,
}

#[derive(Clone, Copy, Debug, PartialEq, rustler::NifUnitEnum)]
enum StopPolicy { TargetOrContact }

#[derive(Clone, Copy, Debug, PartialEq, rustler::NifTaggedEnum)]
enum JointCommand {
    Hold,
    // Target, motor stiffness/damping/torque, tolerance and mechanical stop rule.
    Position(f64, (f64, f64, f64), (f64, StopPolicy)),
}

struct InstalledHinge {
    row: Hinge,
    handle: ImpulseJointHandle,
    moving: RigidBodyHandle,
    fixed: RigidBodyHandle,
    command: JointCommand,
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
    terrain: BTreeMap<u64,BTreeMap<voxel::Point,terrain::Installed>>,
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
            terrain: BTreeMap::new(),
            hinges: BTreeMap::new(),
            limits,
            dt,
            gravity,
            changed: false,
            query_ready: false,
        })
    }

    fn install(&mut self, definitions: Vec<Body>, shift:voxel::Point) -> Result<usize, InstallError> {
        self.validate_origin(shift,&definitions)?;
        if definitions.len() > self.limits.0 { return Err(atoms::body_allowance().into()); }
        let mut budget = geometry::Budget { coordinate: self.limits.3,
            parts: self.limits.4, vertices: self.limits.5, triangles: self.limits.6 };
        let mut seen = BTreeSet::new();
        let mut prepared = Vec::new();
        for row @ (id, revision, kind, pose, shape, density) in &definitions {
            if !seen.insert(*id) || *revision == 0 || *density <= 0.0
                || !density.is_finite() { return Err(atoms::invalid_body().into()); }
            if let Some((old, _)) = self.rows.get(id) {
                if old == row && (shift == (0,0,0) || !matches!(shape,Geometry::Terrain(..))) {
                    shape.charge(&mut budget)?; continue;
                }
                let resident_change = matches!((&old.4,shape),(Geometry::Terrain(a,_),Geometry::Terrain(b,_)) if a == b)
                    && old.2 == *kind && old.3 == *pose && old.5 == *density;
                if old.1 > *revision || (old.1 == *revision && !resident_change) {
                    return Err(atoms::stale_revision().into());
                }
            }
            let pose = geometry::transform(*pose,self.limits.3)?;
            let built = if let Geometry::Terrain(spacing,chunks) = shape {
                terrain::validate(*spacing,chunks,*kind,pose,self.limits.3)?;
                shape.charge(&mut budget)?;
                None
            } else { Some(shape.build(*kind,&mut budget)?) };
            if *kind != Kind::Fixed {
                let mass = built.as_ref().ok_or_else(atoms::invalid_body)?.mass_properties(*density).mass();
                if !mass.is_finite() || mass <= 0.0 { return Err(atoms::invalid_body().into()); }
            }
            prepared.push((row.clone(),pose,built));
        }
        let removed: Vec<_> = self.rows.keys().filter(|id| !seen.contains(id)).copied().collect();
        let changes = removed.len() + prepared.len() + usize::from(shift != (0,0,0));
        let mut geometry_changed = !removed.is_empty();
        self.translate_origin(shift);
        for id in removed { self.remove(id); }
        for (row,pose,shape) in prepared {
            let id = row.0;
            if shape.is_none() { geometry_changed |= self.install_terrain(row); continue; }
            geometry_changed = true;
            self.remove(id);
            let builder = match row.2 {
                Kind::Dynamic => RigidBodyBuilder::dynamic().ccd_enabled(true),
                Kind::Fixed => RigidBodyBuilder::fixed(),
                Kind::Controlled => RigidBodyBuilder::kinematic_position_based(),
            };
            let body = self.bodies.insert(builder.pose(pose));
            self.colliders.insert_with_parent(ColliderBuilder::new(shape.unwrap())
                .density(row.5).user_data(id as u128),body,&mut self.bodies);
            self.rows.insert(id,(row,body));
        }
        self.changed |= changes != 0;
        self.query_ready &= !geometry_changed;
        Ok(changes)
    }

    // Rest state is an insertion input, retried only when missing coverage
    // arrives. A checkpoint-only update never repositions a retained body.
    fn restore_rest(&mut self, rows: Vec<Rest>) -> Result<Restore, Atom> {
        if rows.len() > self.limits.0 { return Err(atoms::body_allowance()); }
        let mut seen = BTreeSet::new();
        let mut prepared = Vec::new();
        for (id, rev, (p, q), tolerance, checks) in &rows {
            let Some((row, handle)) = self.rows.get(id) else { return Err(atoms::invalid_checkpoint()); };
            if row.1 != *rev || row.2 != Kind::Dynamic || !seen.insert(*id)
                || self.hinges.values().any(|h| h.row.moving.0 == *id || h.row.fixed.0 == *id)
                || !tolerance.is_finite() || *tolerance < 0.0 || *checks == 0 {
                return Err(atoms::invalid_checkpoint());
            }
            let position = geometry::vector(*p,self.limits.3).map_err(Atom::from)?;
            let rotation = Rotation::from_xyzw(q.0,q.1,q.2,q.3);
            if !rotation.is_finite() || (rotation.length_squared()-1.0).abs() > 0.000004 {
                return Err(atoms::invalid_checkpoint());
            }
            prepared.push((*handle,rapier3d::math::Pose::from_parts(position,rotation.normalize())));
        }
        let mut missing = false;
        let mut ranges = Vec::new();
        for (handle,pose) in &prepared {
            let shape = self.colliders[self.bodies[*handle].colliders()[0]].shape();
            if let Some(required) = self.terrain_query_coverage(shape.compute_aabb(pose)) {
                missing = true; ranges.extend(required);
            }
        }
        if missing {
            ranges.sort_unstable(); ranges.dedup();
            return Ok(Restore::Coverage(ranges));
        }
        for (handle,pose) in prepared {
            self.bodies[handle].set_position(pose,false);
            self.bodies[handle].sleep();
        }
        // Zero-displacement recovery: admit numerical contact tolerance, but
        // never depenetrate a saved chair through a newer wall or closed door.
        for (id, _, _, tolerance, checks) in &rows {
            let handle = self.rows[id].1;
            let body = &self.bodies[handle];
            let collider = &self.colliders[body.colliders()[0]];
            if self.terrain_occupied(collider.shape(),body.position()) != Ok(None) {
                return Err(atoms::invalid_checkpoint());
            }
            let mut remaining = *checks;
            let mut supported = self.gravity == 0.0;
            for (_, other) in self.colliders.iter() {
                if other.parent() == Some(handle) { continue; }
                remaining = remaining.checked_sub(1).ok_or_else(atoms::invalid_checkpoint)?;
                let other_pose = match other.parent() {
                    Some(h) => *self.bodies[h].position() * other.position_wrt_parent().copied().unwrap_or_default(),
                    None => *other.position(),
                };
                let contact = rapier3d::parry::query::contact(body.position(),collider.shape(),
                    &other_pose,other.shape(),*tolerance).map_err(|_| atoms::invalid_checkpoint())?;
                if contact.is_some_and(|c| c.dist < -*tolerance) {
                    return Err(atoms::invalid_checkpoint());
                }
                supported |= contact.is_some_and(|c| c.normal1.y*self.gravity > 0.0);
            }
            // Saved zero velocity does not certify that current geometry still
            // supports the body. Normal integration settles an unsupported rest.
            if !supported { self.bodies[handle].wake_up(true); }
        }
        Ok(Restore::Ready)
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
            || self.hinges.values().any(|h| h.row.moving.0 == id || h.row.fixed.0 == id)
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
        let mut prepared = Vec::new();
        for (row, restore) in inputs {
            let id = row.moving.0;
            let Some((moving_row, moving)) = self.rows.get(&id) else {
                return Err(atoms::invalid_hinge());
            };
            let Some((fixed_row, fixed)) = self.rows.get(&row.fixed.0) else {
                return Err(atoms::invalid_hinge());
            };
            let (lower, upper) = row.limits;
            if !seen.insert(id) || id == row.fixed.0 || row.revision == 0
                || moving_row.2 != Kind::Dynamic || fixed_row.2 != Kind::Fixed
                || moving_row.1 != row.moving.1 || fixed_row.1 != row.fixed.1
                || [lower, upper, row.baseline, restore].iter().any(|v| !v.is_finite())
                || lower <= -std::f64::consts::PI || upper >= std::f64::consts::PI
                || lower > upper || upper - lower > std::f64::consts::PI
                || !(lower..=upper).contains(&row.baseline)
                || !(lower..=upper).contains(&restore)
            { return Err(atoms::invalid_hinge()); }
            let axis = geometry::vector(row.axis, f64::MAX).map_err(|_| atoms::invalid_hinge())?;
            let scale = axis.abs().max_element();
            if scale == 0.0 { return Err(atoms::invalid_hinge()); }
            // Scale before normalization so any finite nonzero direction is safe.
            let axis = (axis / scale).normalize();
            let a1 = geometry::vector(row.anchors.0, self.limits.3)?;
            let a2 = geometry::vector(row.anchors.1, self.limits.3)?;
            if let Some(old) = self.hinges.get(&id) {
                if (old.row != row && old.row.revision >= row.revision)
                    || (old.row == row && self.impulse.get(old.handle).is_none())
                { return Err(atoms::stale_revision()); }
                if old.row == row { continue; }
            }
            // Both local frames use the same total, pinned Rapier construction.
            // Angle zero aligns the body frames through their authored anchors.
            let frame = GenericJoint::complete_ang_frame(axis);
            let joint = GenericJointBuilder::new(JointAxesMask::LOCKED_REVOLUTE_AXES)
                .local_frame1(rapier3d::math::Pose::from_parts(a1, frame))
                .local_frame2(rapier3d::math::Pose::from_parts(a2, frame))
                .contacts_enabled(false)
                .limits(JointAxis::AngX, [restore, restore])
                .build();
            let fixed_pose = self.bodies[*fixed].position();
            let rotation = fixed_pose.rotation * frame * Rotation::from_rotation_x(restore) * frame.inverse();
            let position = fixed_pose.translation + fixed_pose.rotation * a1 - rotation * a2;
            geometry::vector((position.x, position.y, position.z), self.limits.3)?;
            if !rotation.is_finite() { return Err(atoms::invalid_hinge()); }
            prepared.push((row, *moving, *fixed, position, rotation, joint));
        }
        let removed: Vec<_> = self.hinges.keys().filter(|id| !seen.contains(id)).copied().collect();
        let changes = removed.len() + prepared.len();
        for id in removed {
            let old = self.hinges.remove(&id).unwrap();
            self.impulse.remove(old.handle, true);
        }
        for (row, moving, fixed, position, rotation, joint) in prepared {
            if let Some(old) = self.hinges.remove(&row.moving.0) {
                self.impulse.remove(old.handle, true);
            }
            self.bodies[moving].set_translation(position, true);
            self.bodies[moving].set_rotation(rotation, true);
            self.bodies[moving].set_linvel(Vector::ZERO, true);
            self.bodies[moving].set_angvel(Vector::ZERO, true);
            let handle = self.impulse.insert(fixed, moving, joint, true);
            self.hinges.insert(row.moving.0, InstalledHinge {
                row, handle, moving, fixed, command: JointCommand::Hold,
            });
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
            self.bodies[h.fixed].rotation(),
            self.bodies[h.moving].rotation(),
        );
        if angle.is_finite() {
            Ok(angle)
        } else {
            Err(atoms::non_finite_state())
        }
    }

    fn control_hinge(&mut self, id: u64, revision: u64, command: JointCommand) -> Result<(), Atom> {
        let h = self.hinges.get(&id).ok_or_else(atoms::invalid_hinge)?;
        if h.row.revision != revision { return Err(atoms::stale_revision()); }
        if let JointCommand::Position(target, (stiffness, damping, force), (tolerance, _)) = command {
            if !target.is_finite() || !(h.row.limits.0..=h.row.limits.1).contains(&target)
                || [stiffness, damping, force, tolerance].iter().any(|v| !v.is_finite() || *v <= 0.0)
            { return Err(atoms::invalid_hinge()); }
        }
        let angle = self.hinge_angle(h)?;
        let h = self.hinges.get_mut(&id).unwrap();
        let joint = self.impulse.get_mut(h.handle, true).ok_or_else(atoms::invalid_hinge)?;
        match command {
            JointCommand::Position(target, (stiffness, damping, force), _) => {
                joint.data.set_limits(JointAxis::AngX, [h.row.limits.0, h.row.limits.1]);
                joint.data.set_motor_position(JointAxis::AngX, target, stiffness, damping);
                joint.data.set_motor_max_force(JointAxis::AngX, force);
            }
            JointCommand::Hold => {
                joint.data.set_limits(JointAxis::AngX, [angle, angle]);
                joint.data.set_motor_max_force(JointAxis::AngX, 0.0);
                self.bodies[h.moving].set_linvel(Vector::ZERO, true);
                self.bodies[h.moving].set_angvel(Vector::ZERO, true);
            }
        }
        h.command = command;
        self.changed = true;
        Ok(())
    }

    // These are mechanical stop conditions; the ontology interprets the result.
    fn brake_hinges(&mut self) -> Result<(), Atom> {
        let mut stopped = BTreeSet::new();
        for (id, h) in &self.hinges {
            if let JointCommand::Position(target, _, (tolerance, _)) = h.command {
                if (self.hinge_angle(h)? - target).abs() <= tolerance { stopped.insert(*id); }
            }
        }
        for pair in self.narrow.contact_pairs().filter(|p| p.has_any_active_contact()) {
            let a = self.colliders[pair.collider1].user_data as u64;
            let b = self.colliders[pair.collider2].user_data as u64;
            for (moving, other) in [(a, b), (b, a)] {
                if let Some(h) = self.hinges.get(&moving) {
                    if matches!(h.command, JointCommand::Position(_, _, (_, StopPolicy::TargetOrContact)))
                        && other != h.row.fixed.0 { stopped.insert(moving); }
                }
            }
        }
        for id in stopped {
            self.control_hinge(id, self.hinges[&id].row.revision, JointCommand::Hold)?;
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
                    matches!(h.command, JointCommand::Position(_, _, _)),
                ))
            })
            .collect()
    }

    fn remove(&mut self, id: u64) {
        self.terrain.remove(&id);
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

    fn step(&mut self) -> Result<Step, Atom> {
        if !self.active() {
            return Ok(Step::Sample((false, vec![], vec![])));
        }
        let parameters = IntegrationParameters {
            dt: self.dt,
            ..Default::default()
        };
        // Use the same conservative envelope for numerical admission and
        // terrain coverage. Refusal precedes integration and preserves motion.
        let regions = self.step_regions(&parameters).map_err(|_| atoms::non_finite_state())?;
        if regions.iter().any(|r| r.mins.abs().max(r.maxs.abs()).max_element() > self.limits.3) {
            return Ok(Step::Frame(regions.iter().map(|r|
                ((r.mins.x,r.mins.y,r.mins.z),(r.maxs.x,r.maxs.y,r.maxs.z))).collect()));
        }
        if let Err(ranges) = self.terrain_step_coverage(&parameters,&regions) { return Ok(Step::Coverage(ranges)); }
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
        self.sample().map(Step::Sample)
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
fn install<'a>(
    env: Env<'a>,
    resource: ResourceArc<WorldResource>,
    shift: voxel::Point,
    definitions: Term<'a>,
) -> Result<Term<'a>, Atom> {
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
        match world.install(rows,shift) {
            Ok(count) => Ok(count.encode(env)),
            Err(InstallError::Geometry(error)) => Err(error),
            Err(InstallError::Frame(error)) => Ok((atoms::unavailable(),error).encode(env)),
        }
    })
}
#[rustler::nif(schedule = "DirtyCpu")]
fn restore_rest(env:Env, resource:ResourceArc<WorldResource>, rows:Vec<Rest>) -> Result<Restore,Atom> {
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
fn control_hinge(
    env: Env,
    resource: ResourceArc<WorldResource>,
    id: u64,
    revision: u64,
    command: JointCommand,
) -> Result<(), Atom> {
    access(env, resource, |world| world.control_hinge(id, revision, command))
}
#[rustler::nif(schedule = "DirtyCpu")]
fn hinge_samples(
    env: Env,
    resource: ResourceArc<WorldResource>,
) -> Result<Vec<(u64, i64, bool)>, Atom> {
    access(env, resource, |world| world.hinge_samples())
}
#[rustler::nif(schedule = "DirtyCpu")]
fn step(env: Env, resource: ResourceArc<WorldResource>, refresh: bool) -> Result<Step, Atom> {
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
fn terrain_requirements(env: Env, resource: ResourceArc<WorldResource>,
                        views:Vec<(u64,u64,geometry::V3,f64)>) -> Result<Vec<terrain::Requirement>, Atom> {
    access(env, resource, |world| world.terrain_requirements(views))
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
    fn position_command(target: f64) -> JointCommand {
        JointCommand::Position(target, (100.0,10.0,1000.0), (0.02,StopPolicy::TargetOrContact))
    }

    #[test]
    fn authored_axes_restore_and_drive_nonzero_targets() {
        for axis in [(1.0,0.0,0.0),(-1.0,0.0,0.0),(0.0,1.0,0.0),(0.0,-1.0,0.0),
                     (0.0,0.0,1.0),(0.0,0.0,-1.0),(1.0,2.0,3.0)] {
            let mut w = World::new((2,2,1,100.0,4,0,0),1.0/60.0,0.0).unwrap();
            let mut fixed = box_body(1,2,false,(3.0,4.0,5.0),(0.1,0.1,0.1),1.0);
            fixed.3.1 = (0.23,-0.41,0.19);
            let mut moving = box_body(2,3,true,(3.0,4.0,5.0),(0.5,0.5,0.5),1.0);
            moving.4 = Geometry::Parts(vec![(((0.0,0.0,0.0),(0.0,0.0,0.0)),
                geometry::Primitive::Ball(0.3)), (((0.4,0.0,0.0),(0.0,0.0,0.0)),
                geometry::Primitive::Box(0.1,0.1,0.1))]);
            w.install(vec![fixed.clone(),moving],(0,0,0)).unwrap();
            let h = Hinge { moving: (2,3), revision: 7, fixed: (1,2), axis,
                anchors: ((0.2,0.3,0.4),(-0.7,0.2,0.1)), limits: (-1.2,1.2), baseline: -0.5 };
            w.install_hinges(vec![(h,-0.5)]).unwrap();
            assert_eq!(w.hinge_samples().unwrap(),vec![(2,-500,false)]);
            let fp = geometry::transform(fixed.3,100.0).unwrap();
            let normalized = Vector::new(axis.0,axis.1,axis.2).normalize();
            let expected = fp.rotation * rapier3d::math::rotation_from_angle(normalized * -0.5);
            let body = &w.bodies[w.rows[&2].1];
            assert!(body.rotation().dot(expected).abs() > 1.0-1e-12, "{axis:?}");
            let joint_point = body.translation() + body.rotation() * Vector::new(-0.7,0.2,0.1);
            assert!((joint_point-(fp.translation+fp.rotation*Vector::new(0.2,0.3,0.4))).length() < 1e-12);
            w.control_hinge(2,7,position_command(0.4)).unwrap();
            w.step().unwrap();
            assert!(w.hinge_samples().unwrap()[0].1 > -500, "positive travel around {axis:?}");
            for _ in 0..600 {
                if !w.hinge_samples().unwrap()[0].2 { break; }
                w.step().unwrap();
            }
            let result = w.hinge_samples().unwrap()[0];
            assert!(!result.2 && (result.1-400).abs() <= 20, "{axis:?}: {result:?}");
            // Starting inside tolerance is valid, including a nonzero target.
            w.control_hinge(2,7,position_command(result.1 as f64/1000.0)).unwrap();
            w.step().unwrap();
            assert!(!w.hinge_samples().unwrap()[0].2);
        }
    }

    #[test]
    fn independent_hinges_brake_restore_and_retain() {
        let mut w = World::new((5, 5, 10, 100.0, 64, 1024, 1024), 1.0 / 60.0, 0.0).unwrap();
        let frame = box_body(1, 1, false, (0.0, 0.0, 0.0), (0.05, 1.0, 0.05), 1.0);
        let door = box_body(2, 1, true, (1.0, 1.0, 0.0), (1.0, 1.0, 0.1), 1.0);
        let obstacle = box_body(3, 1, false, (1.5, 1.0, -0.5), (0.2, 1.0, 0.2), 1.0);
        let frame2 = box_body(4, 1, false, (5.0, 0.0, 0.0), (0.05, 1.0, 0.05), 1.0);
        let door2 = box_body(5, 1, true, (6.0, 1.0, 0.0), (1.0, 1.0, 0.1), 1.0);
        let hinge = Hinge { moving: (2,1), revision: 1, fixed: (1,1), axis: (0.0,1.0,0.0),
            anchors: ((0.0,1.0,0.0),(-1.0,0.0,0.0)), limits: (-1.5,1.5), baseline: 1.5 };
        let hinge2 = Hinge { moving: (5,1), fixed: (4,1), ..hinge };
        w.install(vec![frame.clone(), door.clone(), obstacle.clone(), frame2.clone(), door2.clone()],(0,0,0))
            .unwrap();
        assert_eq!(w.install_hinges(vec![(hinge, 1.5), (hinge2, 1.5)]), Ok(2));
        w.control_hinge(2, 1, position_command(0.0)).unwrap();
        w.control_hinge(5, 1, position_command(0.0)).unwrap();
        let mut contact_seen = false;
        for _ in 0..600 {
            let Step::Sample(sample) = w.step().unwrap() else { panic!("unexpected terrain coverage"); };
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
        w.install(vec![frame.clone(), door.clone(), moved.clone(), frame2.clone(), door2.clone()],(0,0,0)).unwrap();
        w.control_hinge(2, 1, position_command(0.0)).unwrap();
        for _ in 0..600 {
            w.step().unwrap();
            if !w.hinge_samples().unwrap()[0].2 {
                break;
            }
        }
        assert!(w.hinge_samples().unwrap()[0].1.abs() <= 20);
        let checkpoint = samples[0].1 as f64 / 1000.0;
        let mut recovered = World::new((3, 3, 10, 100.0, 64, 1024, 1024), 1.0 / 60.0, 0.0).unwrap();
        recovered.install(vec![frame.clone(), door.clone(), obstacle.clone()],(0,0,0)).unwrap();
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
        w.install(vec![ground.clone(),chair.clone()],(0,0,0)).unwrap();
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
        assert_eq!(w.install(vec![ground.clone(),chair.clone()],(0,0,0)),Ok(0));
        assert_eq!(w.sample().unwrap(),before);
        let mut recovered = World::new((3,3,4,100.0,64,1024,1024),1.0/60.0,-9.81).unwrap();
        recovered.install(vec![ground.clone(),chair.clone()],(0,0,0)).unwrap();
        recovered.restore_rest(vec![cp]).unwrap();
        assert_eq!(recovered.rest_sample(2,1),Some((p,q)));
    }

    #[test]
    fn falling_and_retained_installation() {
        let mut w = World::new((2, 2, 1, 1000.0, 64, 1024, 1024), 1.0 / 60.0, -9.81).unwrap();
        let ground = box_body(1, 1, false, (0.0, -0.5, 0.0), (10.0, 0.5, 10.0), 1.0);
        let body = box_body(2, 1, true, (0.0, 3.0, 0.0), (0.5, 0.5, 0.5), 1.0);
        assert_eq!(w.install(vec![ground.clone(), body.clone()],(0,0,0)), Ok(2));
        for _ in 0..30 {
            w.step().unwrap();
        }
        let before = w.sample().unwrap();
        assert!(before.1[1].1 .1 < 3.0);
        assert_eq!(w.install(vec![ground.clone(), body.clone()],(0,0,0)), Ok(0));
        assert_eq!(w.sample().unwrap(), before);
        let changed = box_body(2, 2, true, (0.0, 5.0, 0.0), (0.5, 0.5, 0.5), 1.0);
        assert_eq!(w.install(vec![ground.clone(), changed.clone()],(0,0,0)), Ok(1));
        assert_eq!(w.sample().unwrap().1[1].1 .1, 5.0);
        for _ in 0..1000 {
            w.step().unwrap();
        }
        assert!(!w.active());
        assert_eq!(w.step().unwrap(), Step::Sample((false, vec![], vec![])));
    }
}
