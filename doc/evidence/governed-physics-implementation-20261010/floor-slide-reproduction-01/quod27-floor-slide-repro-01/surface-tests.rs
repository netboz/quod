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
    fn sliding_keeps_obstacles_in_the_same_surface() {
        for (roll,yaw,offset) in [(0.0,0.0,(0.0,0.0,0.0)),(-0.37,0.83,(13.4,-7.0,12.5))] {
            for desired in [Vector::new(1.0,-0.002725109,0.0),Vector::new(1.0,-0.002725109,1.0)] {
                let (mut world,frame) = surface_world((2.7,0.752,2.7),roll,yaw,offset,true);
                let answer = apply(&mut world,2,1,Query::Travel(tuple(frame.rotation*desired),(0.0,0.0,0.0)),(0.002,0.0,8,128));
                let Answer::Clipped((p,_),_,checks) = answer else {panic!("missed obstacle: {answer:?}")};
                let local = frame.inverse_transform_point(Vector::new(p.0 as f32,p.1 as f32,p.2 as f32));
                eprintln!("wall roll={roll}: {local:?} checks={checks}");
                assert!(local.x > 2.94 && local.x < 2.951,"wall: {local:?}");
                assert!(local.z < 2.951,"corner: {local:?}");
                assert!(checks <= 6,"repeated contact: {checks}");
                assert!(surface_distance(&world) >= 0.0,"surface overlap: {p:?}");
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
            assert!((p.1-0.752).abs() <= 0.002,"height drift at {i}: {p:?}");
            assert!(surface_distance(&world) >= 0.0,"surface overlap at {i}: {p:?}");
            world.step().unwrap();
        }
        let pose = world.bodies[world.rows[&2].1].translation();
        assert!((pose-Vector::new(0.0,0.752,4.0)).length() < 0.02,"walk failed: {pose:?}");
    }
