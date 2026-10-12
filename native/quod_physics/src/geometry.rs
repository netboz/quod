//! Authored physical geometry. No visual meshes, inferred hulls, or avatar defaults.
use rapier3d::{math::Pose, prelude::*};
use rustler::{Atom, NifTaggedEnum, NifUnitEnum};
use crate::atoms;

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Error { InvalidBody, CoordinateAllowance, GeometryAllowance }
impl From<Error> for Atom {
    fn from(error: Error) -> Self {
        match error {
            Error::InvalidBody => atoms::invalid_body(),
            Error::CoordinateAllowance => atoms::coordinate_allowance(),
            Error::GeometryAllowance => atoms::geometry_allowance(),
        }
    }
}

pub type V3 = (f64, f64, f64);
pub type Transform = (V3, V3);

#[derive(Clone, Copy, Debug, PartialEq, NifUnitEnum)]
pub enum Kind { Fixed, Dynamic, Controlled }

#[derive(Clone, Debug, PartialEq, NifTaggedEnum)]
pub enum Primitive {
    Box(f64, f64, f64),
    Ball(f64),
    Capsule(f64, f64), // Half segment length along local Y, then radius.
    Convex(Vec<V3>),    // Explicitly authored convex hull semantics.
}

#[derive(Clone, Debug, PartialEq, NifTaggedEnum)]
pub enum Geometry {
    Solid(Primitive),
    Parts(Vec<(Transform, Primitive)>),
    Surface(Vec<V3>, Vec<(u32, u32, u32)>),
}

pub fn vector(v: V3, limit: f64) -> Result<Vector, Error> {
    let a = [v.0, v.1, v.2];
    if a.iter().any(|x| !x.is_finite() || x.abs() > limit) {
        return Err(Error::CoordinateAllowance);
    }
    Ok(Vector::new(v.0, v.1, v.2))
}

pub fn transform((p, r): Transform, limit: f64) -> Result<Pose, Error> {
    let p = vector(p, limit)?;
    let r = vector(r, f64::MAX)?;
    // Same convention as authored rendering transforms: local X, then Y, then Z.
    let q = Rotation::from_rotation_z(r.z) * Rotation::from_rotation_y(r.y)
        * Rotation::from_rotation_x(r.x);
    Ok(Pose::from_parts(p, q))
}

pub struct Budget {
    pub parts: usize,
    pub vertices: usize,
    pub triangles: usize,
    pub coordinate: f64,
}

fn take(left: &mut usize, count: usize) -> Result<(), Error> {
    *left = left.checked_sub(count).ok_or(Error::GeometryAllowance)?;
    Ok(())
}

impl Primitive {
    fn build(&self, budget: &mut Budget) -> Result<SharedShape, Error> {
        take(&mut budget.parts, 1)?;
        let positive = |x: f64| {
            if !x.is_finite() || x > budget.coordinate || x <= 0.0 {
                Err(Error::InvalidBody)
            } else { Ok(x) }
        };
        match self {
            Self::Box(x,y,z) => Ok(SharedShape::cuboid(positive(*x)?,positive(*y)?,positive(*z)?)),
            Self::Ball(r) => Ok(SharedShape::ball(positive(*r)?)),
            Self::Capsule(h,r) => Ok(SharedShape::capsule_y(positive(*h)?,positive(*r)?)),
            Self::Convex(points) => {
                take(&mut budget.vertices, points.len())?;
                let points = points.iter().map(|p| vector(*p,budget.coordinate)).collect::<Result<Vec<_>,_>>()?;
                let hull = SharedShape::convex_hull(&points).ok_or(Error::InvalidBody)?;
                let volume = hull.mass_properties(1.0).mass();
                if !volume.is_finite() || volume <= 0.0 { return Err(Error::InvalidBody); }
                Ok(hull)
            }
        }
    }
}

impl Geometry {
    pub fn charge(&self, budget: &mut Budget) -> Result<(), Error> {
        let mut primitive = |p: &Primitive| {
            take(&mut budget.parts,1)?;
            if let Primitive::Convex(points) = p { take(&mut budget.vertices,points.len())?; }
            Ok(())
        };
        match self {
            Self::Solid(p) => primitive(p),
            Self::Parts(parts) => { for (_,p) in parts { primitive(p)?; } Ok(()) },
            Self::Surface(points,faces) => {
                take(&mut budget.parts,1)?;
                take(&mut budget.vertices,points.len())?;
                take(&mut budget.triangles,faces.len())
            }
        }
    }

    pub fn build(&self, kind: Kind, budget: &mut Budget) -> Result<SharedShape, Error> {
        match self {
            Self::Solid(p) => p.build(budget),
            Self::Parts(parts) => {
                if parts.is_empty() { return Err(Error::InvalidBody); }
                let mut shapes = Vec::new();
                for (pose, primitive) in parts {
                    let pose = transform(*pose,budget.coordinate)?;
                    let shape = primitive.build(budget)?;
                    let bounds = shape.compute_aabb(&pose);
                    if bounds.mins.abs().max_element() > budget.coordinate
                        || bounds.maxs.abs().max_element() > budget.coordinate {
                        return Err(Error::CoordinateAllowance);
                    }
                    shapes.push((pose,shape));
                }
                Ok(SharedShape::compound(shapes))
            }
            Self::Surface(points, faces) => {
                if kind != Kind::Fixed || faces.is_empty() { return Err(Error::InvalidBody); }
                take(&mut budget.parts,1)?;
                take(&mut budget.vertices,points.len())?;
                take(&mut budget.triangles,faces.len())?;
                let points = points.iter().map(|p| vector(*p,budget.coordinate)).collect::<Result<Vec<_>,_>>()?;
                let mut indices = Vec::new();
                for &(a,b,c) in faces {
                    let [Some(pa),Some(pb),Some(pc)] = [points.get(a as usize),points.get(b as usize),points.get(c as usize)] else {
                        return Err(Error::InvalidBody);
                    };
                    let area = (*pb-*pa).cross(*pc-*pa).length_squared();
                    if !area.is_finite() || area <= 0.0 {
                        return Err(Error::InvalidBody);
                    }
                    indices.push([a,b,c]);
                }
                SharedShape::trimesh(points,indices).map_err(|_| Error::InvalidBody)
            }
        }
    }

    pub fn box_half_x(&self) -> Option<f64> {
        match self { Self::Solid(Primitive::Box(x,_,_)) => Some(*x), _ => None }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn budget() -> Budget { Budget { parts: 8, vertices: 32, triangles: 16, coordinate: 100.0 } }

    #[test]
    fn compound_preserves_an_authored_opening_and_rotation() {
        let shape = Geometry::Parts(vec![
            (((-2.0,0.0,0.0),(0.0,0.0,0.0)),Primitive::Box(0.5,1.0,0.5)),
            (((2.0,0.0,0.0),(0.0,0.0,std::f64::consts::FRAC_PI_2)),Primitive::Box(1.0,0.25,0.5)),
        ]);
        let mut b = budget();
        let built = shape.build(Kind::Controlled,&mut b).unwrap();
        assert_eq!(b.parts,6);
        assert!(!built.contains_point(&Pose::IDENTITY,Vector::ZERO));
        assert!(built.contains_point(&Pose::IDENTITY,Vector::new(2.0,0.8,0.0)));
        assert!(!built.contains_point(&Pose::IDENTITY,Vector::new(2.8,0.0,0.0)));
        let mut repeated = budget();
        shape.charge(&mut repeated).unwrap();
        assert_eq!((b.parts,b.vertices,b.triangles),(repeated.parts,repeated.vertices,repeated.triangles));
    }

    #[test]
    fn non_cubic_surface_and_explicit_hull_are_distinct() {
        let vertices = vec![(-2.0,0.0,-2.0),(2.0,0.0,-2.0),(0.0,1.0,2.0)];
        let surface = Geometry::Surface(vertices.clone(),vec![(0,2,1)]);
        assert!(surface.build(Kind::Fixed,&mut budget()).is_ok());
        assert_eq!(surface.build(Kind::Controlled,&mut budget()).err(),Some(Error::InvalidBody));
        assert_eq!(Geometry::Solid(Primitive::Convex(vertices)).build(Kind::Controlled,&mut budget()).err(),Some(Error::InvalidBody));
        let hull = Geometry::Solid(Primitive::Convex(vec![(0.0,0.0,0.0),(1.0,0.0,0.0),(0.0,1.0,0.0),(0.0,0.0,1.0)]));
        assert!(hull.build(Kind::Controlled,&mut budget()).is_ok());
    }

    #[test]
    fn malformed_geometry_and_resource_exhaustion_fail() {
        let mut b = budget(); b.parts = 0;
        assert_eq!(Geometry::Solid(Primitive::Ball(0.5)).build(Kind::Controlled,&mut b).err(),Some(Error::GeometryAllowance));
        let invalid = Geometry::Surface(vec![(0.0,0.0,0.0)],vec![(0,1,2)]);
        assert_eq!(invalid.build(Kind::Fixed,&mut budget()).err(),Some(Error::InvalidBody));
        assert_eq!(Geometry::Parts(vec![]).build(Kind::Controlled,&mut budget()).err(),Some(Error::InvalidBody));
        assert_eq!(Geometry::Solid(Primitive::Ball(f64::NAN)).build(Kind::Controlled,&mut budget()).err(),Some(Error::InvalidBody));
    }
}
