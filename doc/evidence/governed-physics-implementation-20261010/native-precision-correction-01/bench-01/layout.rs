use rapier3d::{math::Vector, prelude::{RigidBody, Collider}, parry::{partitioning::BvhNode, bounding_volume::Aabb, shape::Triangle}};
fn main() {
    println!("{{\"vertex\":{},\"triangle_indices\":{},\"triangle_value\":{},\"aabb\":{},\"bvh_node\":{},\"rigid_body\":{},\"collider\":{}}}",
        size_of::<Vector>(),size_of::<[u32;3]>(),size_of::<Triangle>(),size_of::<Aabb>(),size_of::<BvhNode>(),size_of::<RigidBody>(),size_of::<Collider>());
}
