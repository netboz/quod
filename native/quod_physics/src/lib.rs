//! Mechanical adapter. No ontology, principal, generation or domain decisions.
use rapier3d::prelude::*;
use rustler::{Atom, Env, LocalPid, NifResult, ResourceArc, Term};
use std::collections::{BTreeMap, BTreeSet};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::{Mutex, TryLockError};

mod atoms {
    rustler::atoms! { ok, busy, retired, wrong_owner, native_failure, invalid_body,
    body_allowance, pose_allowance, contact_allowance, invalid_allowance,
    coordinate_allowance, invalid_step, invalid_gravity, non_finite_state, stale_revision }
}

// Metres, seconds and kilograms. Names and revisions remain in the Erlang owner.
// id, revision, dynamic, position xyz, cuboid half extents xyz, density.
type Body = (u64, u64, bool, (f64, f64, f64), (f64, f64, f64), f64);
type Pose = (u64, (f64, f64, f64), (f64, f64, f64, f64), (f64, f64, f64));
type Sample = (bool, Vec<Pose>, Vec<(u64, u64)>);

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
    limits: (usize, usize, usize, f64),
    dt: f32,
    gravity: f32,
    changed: bool,
}

struct WorldResource {
    owner: LocalPid,
    world: Mutex<Option<World>>,
}
#[rustler::resource_impl]
impl rustler::Resource for WorldResource {}

impl World {
    fn new(limits: (usize, usize, usize, f64), dt: f64, gravity: f64) -> Result<Self, Atom> {
        if !limits.3.is_finite() || limits.3 <= 0.0 || limits.3 > f32::MAX as f64 {
            return Err(atoms::invalid_allowance());
        }
        // These are representation/algorithm requirements, not population budgets.
        if !dt.is_finite() || dt <= 0.0 || !(dt as f32).is_finite() || (dt as f32) == 0.0 {
            return Err(atoms::invalid_step());
        }
        if !gravity.is_finite() || !(gravity as f32).is_finite() {
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
            limits,
            dt: dt as f32,
            gravity: gravity as f32,
            changed: false,
        })
    }

    fn install(&mut self, definitions: Vec<Body>) -> Result<usize, Atom> {
        if definitions.len() > self.limits.0 {
            return Err(atoms::body_allowance());
        }
        let mut seen = BTreeSet::new();
        for row @ (id, revision, _, (x, y, z), (hx, hy, hz), density) in &definitions {
            if !seen.insert(*id)
                || *revision == 0
                || *density <= 0.0
                || (*hx as f32) <= 0.0
                || (*hy as f32) <= 0.0
                || (*hz as f32) <= 0.0
                || (*density as f32) <= 0.0
                || !(*density as f32).is_finite()
            {
                return Err(atoms::invalid_body());
            }
            if [x, y, z, hx, hy, hz]
                .iter()
                .any(|v| !v.is_finite() || v.abs() > self.limits.3)
            {
                return Err(atoms::coordinate_allowance());
            }
            let mass = (8.0 * hx * hy * hz * density) as f32;
            if !mass.is_finite() || mass <= 0.0 {
                return Err(atoms::invalid_body());
            }
            if let Some((old, _)) = self.rows.get(id) {
                if old != row && old.1 >= *revision {
                    return Err(atoms::stale_revision());
                }
            }
        }
        let removed: Vec<_> = self
            .rows
            .keys()
            .filter(|id| !seen.contains(id))
            .copied()
            .collect();
        let mut changes = removed.len();
        for id in removed {
            self.remove(id);
        }
        for row @ (id, _, dynamic, (x, y, z), (hx, hy, hz), density) in definitions {
            if self.rows.get(&id).is_some_and(|(old, _)| old == &row) {
                continue;
            }
            self.remove(id);
            let builder = if dynamic {
                RigidBodyBuilder::dynamic()
            } else {
                RigidBodyBuilder::fixed()
            };
            let body = self
                .bodies
                .insert(builder.translation(Vector::new(x as f32, y as f32, z as f32)));
            self.colliders.insert_with_parent(
                ColliderBuilder::cuboid(hx as f32, hy as f32, hz as f32)
                    .density(density as f32)
                    .user_data(id as u128),
                body,
                &mut self.bodies,
            );
            self.rows.insert(id, (row, body));
            changes += 1;
        }
        self.changed |= changes != 0;
        Ok(changes)
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
            if p.to_array().iter().any(|x| x.abs() as f64 > self.limits.3) {
                return Err(atoms::coordinate_allowance());
            }
            poses.push((
                *id,
                (p.x as f64, p.y as f64, p.z as f64),
                (q.x as f64, q.y as f64, q.z as f64, q.w as f64),
                (v.x as f64, v.y as f64, v.z as f64),
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
    limits: (usize, usize, usize, f64),
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
fn step(env: Env, resource: ResourceArc<WorldResource>) -> Result<Sample, Atom> {
    access(env, resource, World::step)
}
#[rustler::nif(schedule = "DirtyCpu")]
fn sample(env: Env, resource: ResourceArc<WorldResource>) -> Result<Sample, Atom> {
    access(env, resource, |world| world.sample())
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
    #[test]
    fn falling_and_retained_installation() {
        let mut w = World::new((2, 2, 1, 1000.0), 1.0 / 60.0, -9.81).unwrap();
        let ground = (1, 1, false, (0.0, -0.5, 0.0), (10.0, 0.5, 10.0), 1.0);
        let body = (2, 1, true, (0.0, 3.0, 0.0), (0.5, 0.5, 0.5), 1.0);
        assert_eq!(w.install(vec![ground, body]), Ok(2));
        for _ in 0..30 {
            w.step().unwrap();
        }
        let before = w.sample().unwrap();
        assert!(before.1[1].1 .1 < 3.0);
        assert_eq!(w.install(vec![ground, body]), Ok(0));
        assert_eq!(w.sample().unwrap(), before);
        let changed = (2, 2, true, (0.0, 5.0, 0.0), (0.5, 0.5, 0.5), 1.0);
        assert_eq!(w.install(vec![ground, changed]), Ok(1));
        assert_eq!(w.sample().unwrap().1[1].1 .1, 5.0);
        for _ in 0..1000 {
            w.step().unwrap();
        }
        assert!(!w.active());
        assert_eq!(w.step().unwrap(), (false, vec![], vec![]));
    }
}
