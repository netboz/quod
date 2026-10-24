//! Translation of the retained simulation frame; no run or body recreation.
use crate::{geometry::{Geometry,Kind},voxel::Point,Body,World};
use rapier3d::prelude::*;

#[derive(Debug,PartialEq,rustler::NifUnitEnum)]
pub(super) enum Error { InvalidShift, CoordinateAllowance }

impl World {
    pub(super) fn validate_origin(&self, shift:Point, definitions:&[Body]) -> Result<(),Error> {
        let delta = Vector::new(shift.0 as f64/1000.0,shift.1 as f64/1000.0,shift.2 as f64/1000.0);
        let limit = self.limits.3;
        let within = |p:Vector| p.is_finite() && p.abs().max_element() <= limit;
        if !delta.is_finite() || delta.abs().max_element() > 2.0*limit { return Err(Error::CoordinateAllowance); }
        // All coordinates and future kinematic targets are checked before
        // changing any retained body, collider, joint or query structure.
        for (row,handle) in self.rows.values() {
            if let Geometry::Terrain(spacing,chunks) = &row.4 {
                let width = *spacing as i64*8;
                if [shift.0,shift.1,shift.2].iter().any(|d| d%width != 0) {
                    return Err(Error::InvalidShift);
                }
                for c in chunks {
                    let p = shifted(c.origin,shift)?;
                    let end = (p.0.checked_add(width),p.1.checked_add(width),p.2.checked_add(width));
                    let (Some(x),Some(y),Some(z)) = end else { return Err(Error::InvalidShift); };
                    let _ = (x,y,z);
                }
            } else if definitions.iter().any(|new| new.0 == row.0 && new.1 == row.1) {
                let body = &self.bodies[*handle];
                if !within(body.translation()-delta) || !within(body.next_position().translation-delta) {
                    return Err(Error::CoordinateAllowance);
                }
            }
        }
        Ok(())
    }

    pub(super) fn translate_origin(&mut self, shift:Point) {
        if shift == (0,0,0) { return; }
        let delta = metres(shift);
        for (row,handle) in self.rows.values_mut() {
            if let Geometry::Terrain(_,chunks) = &mut row.4 {
                for c in chunks { c.origin = shifted(c.origin,shift).unwrap(); }
            } else {
                let body = &mut self.bodies[*handle];
                let mut position = *body.position(); position.translation -= delta;
                let mut next = *body.next_position(); next.translation -= delta;
                body.set_position(position,false);
                if row.2 == Kind::Controlled { body.set_next_kinematic_position(next); }
            }
        }
        for chunks in self.terrain.values_mut() {
            *chunks = std::mem::take(chunks).into_values().map(|mut installed| {
                installed.chunk.origin = shifted(installed.chunk.origin,shift).unwrap();
                if let Some(handle) = installed.collider {
                    self.colliders[handle].set_translation_wrt_parent(metres(installed.chunk.origin));
                }
                (installed.chunk.origin,installed)
            }).collect();
        }
        self.bodies.propagate_modified_body_positions_to_colliders(&mut self.colliders);
        // Fixed terrain parents remain at the local origin. Their constituent
        // offsets changed even when the parent itself was not modified.
        for (_,collider) in self.colliders.iter_mut() {
            if let Some(parent) = collider.parent() {
                let pose = *self.bodies[parent].position()*collider.position_wrt_parent().copied().unwrap_or_default();
                collider.set_position(pose);
            }
        }
        let parameters = IntegrationParameters {dt:self.dt,..Default::default()};
        for (handle,collider) in self.colliders.iter() {
            self.broad.set_aabb(&parameters,handle,collider.compute_aabb());
        }
    }
}

fn metres(p:Point) -> Vector { Vector::new(p.0 as f64/1000.0,p.1 as f64/1000.0,p.2 as f64/1000.0) }
fn shifted(p:Point,d:Point) -> Result<Point,Error> {
    match (p.0.checked_sub(d.0),p.1.checked_sub(d.1),p.2.checked_sub(d.2)) {
        (Some(x),Some(y),Some(z)) => Ok((x,y,z)),
        _ => Err(Error::InvalidShift),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{geometry::{Primitive,TerrainChunk},voxel::chunk::{Prepared,Shared},motion};
    use std::sync::Arc;
    fn shift(w:&mut World,delta:Point) -> Result<(),Error> {
        let mut rows:Vec<Body> = w.rows.values().map(|(row,_)| row.clone()).collect();
        w.validate_origin(delta,&rows)?;
        for row in &mut rows {
            if let Geometry::Terrain(_,chunks) = &mut row.4 {
                for c in chunks { c.origin = shifted(c.origin,delta)?; }
            }
        }
        w.install(rows,delta).map(|_| ()).map_err(|e| match e {
            crate::InstallError::Frame(e) => e,
            other => panic!("unexpected installation refusal: {other:?}"),
        })
    }
    fn world() -> World { World::new((8,8,128,1000.0,512,100000,100000),1.0/60.0,0.0).unwrap() }
    #[test]
    fn fast_step_requests_a_frame_before_mutation_and_resumes_in_place() {
        let mut w = World::new((8,8,128,10.0,512,100000,100000),0.02,0.0).unwrap();
        w.install(vec![(1,1,Kind::Dynamic,((4.9,0.0,0.0),(0.0,0.0,0.0)),
            Geometry::Solid(Primitive::Ball(0.25)),1.0)],(0,0,0)).unwrap();
        let handle = w.rows[&1].1;
        let collider = w.bodies[handle].colliders()[0];
        w.bodies[handle].set_linvel(Vector::new(100.0,0.0,0.0),true);
        let before = w.sample().unwrap();
        for _ in 0..2 {
            assert!(matches!(w.step(),Ok(crate::Step::Frame(bounds)) if bounds.len() == 1 && bounds[0].1.0 > 10.0));
            assert_eq!(w.sample().unwrap(),before);
        }
        shift(&mut w,(4900,0,0)).unwrap();
        assert!(matches!(w.step(),Ok(crate::Step::Sample(_))));
        assert_eq!(w.rows[&1].1,handle);
        assert_eq!(w.bodies[handle].colliders(),&[collider]);
        assert!((w.bodies[handle].translation().x-2.0).abs() < 1.0e-10);
        assert_eq!(w.bodies[handle].linvel(),Vector::new(100.0,0.0,0.0));
    }
    #[test]
    fn off_centre_compound_includes_its_authored_origin_in_the_envelope() {
        let mut w = World::new((8,8,128,1000.0,512,100000,100000),0.02,0.0).unwrap();
        let shape = Geometry::Parts(vec![(((-999.0,0.0,0.0),(0.0,0.0,0.0)),Primitive::Ball(0.25))]);
        w.install(vec![(1,1,Kind::Dynamic,((999.0,0.0,0.0),(0.0,0.0,0.0)),shape,1.0)],(0,0,0)).unwrap();
        let handle = w.rows[&1].1;
        w.bodies[handle].set_linvel(Vector::new(100.0,0.0,0.0),true);
        let before = w.sample().unwrap();
        assert!(matches!(w.step(),Ok(crate::Step::Frame(_))));
        assert_eq!(w.sample().unwrap(),before);
    }
    fn terrain() -> Geometry {
        let density:Vec<u8> = (0..1331).map(|i| if i/11%11 < 3 {(-63i8) as u8} else {65}).collect();
        let materials:Vec<u8> = (0..1331).flat_map(|_| 9u16.to_be_bytes()).collect();
        let (chunk,_) = Prepared::new(&density,&materials,500,(512,10000,10000,500000),None).unwrap();
        Geometry::Terrain(500,vec![TerrainChunk {origin:(0,0,0),prepared:Shared(Arc::new(chunk))}])
    }
    #[test]
    fn translation_preserves_resources_queries_and_body_motion() {
        let mut w = world();
        let body = (1,1,Kind::Controlled,((2.0,2.0,2.0),(0.0,0.0,0.0)),Geometry::Solid(Primitive::Ball(0.25)),1.0);
        w.install(vec![(0,1,Kind::Fixed,((0.0,0.0,0.0),(0.0,0.0,0.0)),terrain(),1.0),body.clone()],(0,0,0)).unwrap();
        w.step().unwrap();
        let handle = w.rows[&1].1;
        let collider = w.terrain[&0][&(0,0,0)].collider;
        let before = motion::evaluate(&w,1,1,motion::Query::Travel((0.25,0.0,0.0),(0.0,0.0,0.0)),(0.002,0.0,8,128));
        shift(&mut w,(4000,0,0)).unwrap();
        assert_eq!(w.rows[&1].1,handle);
        assert_eq!(w.terrain[&0][&(-4000,0,0)].collider,collider);
        assert_eq!(w.bodies[handle].translation(),Vector::new(-2.0,2.0,2.0));
        let after = motion::evaluate(&w,1,1,motion::Query::Travel((0.25,0.0,0.0),(0.0,0.0,0.0)),(0.002,0.0,8,128));
        match (before,after) {
            (motion::Answer::Clear((a,q),ca),motion::Answer::Clear((b,r),cb)) => {
                assert_eq!((a.0-4.0,a.1,a.2),b); assert_eq!(q,r); assert_eq!(ca,cb);
            },
            x => panic!("queries changed: {x:?}"),
        }
        shift(&mut w,(-4000,0,0)).unwrap();
        assert_eq!(w.bodies[handle].translation(),Vector::new(2.0,2.0,2.0));
        assert_eq!(w.terrain[&0][&(0,0,0)].collider,collider);
        assert_eq!(w.rows[&1].0,body);
        let state = w.bodies[handle].position();
        let position = *state;
        assert_eq!(shift(&mut w,(1,0,0)),Err(Error::InvalidShift));
        assert_eq!(*w.bodies[handle].position(),position);
    }
    #[test]
    fn moving_joint_keeps_velocity_motor_and_handle_across_shift() {
        fn pair() -> World {
            let mut w = world();
            let shape = Geometry::Solid(Primitive::Box(0.1,0.1,0.1));
            w.install(vec![
                (1,1,Kind::Fixed,((0.0,0.0,0.0),(0.0,0.0,0.0)),shape.clone(),1.0),
                (2,1,Kind::Dynamic,((1.0,0.0,0.0),(0.0,0.0,0.0)),shape,1.0)],(0,0,0)).unwrap();
            w.install_hinges(vec![(crate::Hinge {moving:(2,1),revision:1,fixed:(1,1),axis:(0.0,1.0,0.0),
                anchors:((0.0,0.0,0.0),(-1.0,0.0,0.0)),limits:(-1.5,1.5),baseline:0.0},0.0)]).unwrap();
            w.control_hinge(2,1,crate::JointCommand::Position(1.0,(100.0,10.0,1000.0),
                (0.02,crate::StopPolicy::TargetOrContact))).unwrap();
            for _ in 0..4 { w.step().unwrap(); }
            w
        }
        let mut reference = pair(); let mut translated = pair();
        let joint = translated.hinges[&2].handle;
        let handle = translated.rows[&2].1;
        let velocity = translated.bodies[handle].linvel();
        let angular = translated.bodies[handle].angvel();
        shift(&mut translated,(8000,-4000,12000)).unwrap();
        assert_eq!(translated.hinges[&2].handle,joint);
        assert_eq!(translated.hinges[&2].command,reference.hinges[&2].command);
        assert_eq!(translated.bodies[handle].linvel(),velocity);
        assert_eq!(translated.bodies[handle].angvel(),angular);
        for _ in 0..60 {
            reference.step().unwrap(); translated.step().unwrap();
            let a = &reference.bodies[reference.rows[&2].1]; let b = &translated.bodies[handle];
            assert!((a.translation()-Vector::new(8.0,-4.0,12.0)-b.translation()).length() < 1e-9);
            assert!((a.linvel()-b.linvel()).length() < 1e-9);
            assert!((a.angvel()-b.angvel()).length() < 1e-9);
            assert_eq!(reference.hinge_samples().unwrap(),translated.hinge_samples().unwrap());
        }
        assert_eq!(translated.hinges[&2].handle,joint);
    }

}
