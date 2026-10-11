fn slide(travel: Vector, normal: Vector) -> Vector {
    let into = travel.dot(normal);
    if into >= 0.0 { return travel; }
    let mut result = travel - normal*(into/normal.length_squared());
    let residual = result.dot(normal);
    if residual < 0.0 {
        let n = normal.abs();
        let axis = if n.x >= n.y && n.x >= n.z { 0 } else if n.y >= n.z { 1 } else { 2 };
        let roundoff = 4.0*f32::EPSILON*result.abs().dot(normal.abs());
        let corrected = result[axis] + (roundoff-residual)/normal[axis];
        result[axis] = if normal[axis] > 0.0 { corrected.next_up() } else { corrected.next_down() };
    }
    result
}

