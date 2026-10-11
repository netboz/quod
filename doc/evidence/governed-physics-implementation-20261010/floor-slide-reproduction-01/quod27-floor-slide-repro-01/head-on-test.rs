
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
