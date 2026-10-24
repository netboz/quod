// Corrected MC33 case selection, adapted from David Vega/Javier Abache's
// MC33 5.5 (MIT, see MC33-LICENSE.txt). Unlike the upstream floating-point
// interior test, all decisions here are exact for the signed-byte field.
use super::mc33_table::TABLE;

fn face_test(face: usize, v: &[i64; 8]) -> usize {
    let (a,b,c,d,less,other) = match face {
        0 => (0,5,1,4,0x48,0x84), 1 => (1,6,2,5,0x24,0x42),
        2 => (3,6,2,7,0x21,0x12), 3 => (0,7,3,4,0x18,0x81),
        4 => (0,2,1,3,0x50,0xA0), _ => (4,6,5,7,0x05,0x0A),
    };
    if v[a]*v[b] < v[c]*v[d] { less } else { other }
}

fn faces(index: usize, v: &[i64; 8]) -> [i32; 6] {
    let masks = [0xCC,0x66,0x33,0x99,0xF0,0x0F];
    let positive = [0x84,0x42,0x12,0x81,0xA0,0x0A];
    let negative = [0x48,0x24,0x21,0x18,0x50,0x05];
    std::array::from_fn(|f| {
        let bits = index & masks[f];
        if bits == positive[f] { if face_test(f,v) == negative[f] { -1 } else { 1 } }
        else if bits == negative[f] { if face_test(f,v) == negative[f] { 1 } else { -1 } }
        else { 0 }
    })
}

fn interior(i: usize, flag13: usize, v: &[i64; 8]) -> usize {
    let [a,b,c,d] = std::array::from_fn(|k| v[k+4]-v[k]);
    let determinant = a*c-b*d;
    if determinant == 0 || (determinant < 0) == (i & 1 != 0) { return 0; }
    let mut numerator = v[3]*b-v[2]*a+v[1]*d-v[0]*c;
    let mut denominator = 2*determinant;
    if denominator < 0 { denominator = -denominator; numerator = -numerator; }
    if numerator <= 0 || numerator >= denominator { return 0; }
    let [at,bt,ct,dt] = std::array::from_fn(|k| v[k]*denominator+(v[k+4]-v[k])*numerator);
    // |v| <= 127, |differences| <= 254; these products fit signed i64.
    let ac = at*ct;
    let bd = bt*dt;
    if i & 1 != 0 {
        if ac < bd && bd >= 0 { return usize::from((bt < 0) == (v[i] < 0))+flag13; }
    } else if ac > bd && ac >= 0 {
        return usize::from((at < 0) == (v[i] < 0))+flag13;
    }
    0
}

/// Edge triples, oriented out of negative-density solid. Edge 12 is the cell
/// centre. The case table's continuation nibble terminates each bounded case.
pub(super) fn triangles(density: [i8; 8]) -> Vec<[usize; 3]> {
    let v = density.map(|d| -(d as i64));
    let index = v.iter().enumerate().fold(0, |i,(k,d)| i | (usize::from(*d < 0) << (7-k)));
    if index == 0 || index == 255 { return Vec::new(); }
    let code = TABLE[if index & 128 != 0 { index ^ 255 } else { index }] as usize;
    let m = usize::from(if index & 128 != 0 { code & 0x800 == 0 } else { code & 0x800 != 0 });
    let n = 1-m;
    let k = code & 0x7ff;
    let effective = if m != 0 { index } else { index ^ 255 };
    let mut start = match code >> 12 {
        0 => k,
        1 => if effective & face_test(k >> 2,&v) != 0 { 183+2*k } else { 159+k },
        2 => if interior(k,0,&v) != 0 { 239+6*k } else { 231+2*k },
        3 => if effective & face_test(k%6,&v) != 0 { 575+5*k }
             else if interior(k/6,0,&v) != 0 { 407+7*k } else { 335+3*k },
        4 => {
            let f = faces(effective,&v);
            match f.iter().sum::<i32>() {
                -3 => 695+3*k,
                -1 => (if f[4]+f[5] < 0 { if f[0]+f[2] < 0 { 759 } else { 799 } } else { 719 })+5*k,
                1 => (if f[4]+f[5] < 0 { 983 } else if f[0]+f[2] < 0 { 839 } else { 911 })+9*k,
                _ => if interior(k >> 1,0,&v) != 0 { 1095+9*k } else { 1055+5*k },
            }
        },
        5 => {
            let f = faces(effective,&v);
            match f.iter().sum::<i32>() {
                -2 => if interior(0,0,&v) != 0 || (k != 2 && interior(if k != 0 {1} else {3},0,&v) != 0) {1213+8*k} else {1189+4*k},
                0 => (if f[2+k] < 0 {1261} else {1285})+8*k,
                _ => if (k == 2 && interior(1,0,&v) != 0) ||
                        (k != 2 && (interior(2,0,&v) != 0 || interior(if k != 0 {3} else {1},0,&v) != 0)) {1237+8*k} else {1201+4*k},
            }
        },
        6 => {
            let f = faces(effective,&v);
            match f.iter().sum::<i32>() {
                -2 => if interior((0xDA010C >> (k*2)) & 3,0,&v) != 0 {1453+8*k} else {1357+4*k},
                0 => (if f[k >> 1] < 0 {1645} else {1741})+8*k,
                _ => if interior((0xA7B7E5 >> (k*2)) & 3,0,&v) != 0 {1549+8*k} else {1405+4*k},
            }
        },
        _ => {
            let f = faces(165,&v);
            match f.iter().sum::<i32>().abs() {
                0 => {
                    let j = 2*usize::from(f[1] < 0)+usize::from(f[5] < 0);
                    if f[0]*f[1] == f[5] {2157+12*j} else {
                        let c = interior(j,1,&v);
                        if c == 0 {2285+6*j} else {2285+10*j-40*c}
                    }
                },
                2 => 1917+10*((if f[0] < 0 {usize::from(f[2] > 0)} else {12+usize::from(f[2] < 0)})+
                              (if f[1] < 0 {usize::from(f[3] < 0)} else {6+usize::from(f[3] > 0)}))+
                     if f[4] > 0 {30} else {0},
                4 => {
                    let mut j = 21+11*f[0]+4*f[1]+3*f[2]+2*f[3]+f[4];
                    if j >> 4 != 0 { j -= if j & 32 != 0 {20} else {10}; }
                    1845+3*j as usize
                },
                _ => (1839+2*f[0]) as usize,
            }
        },
    };
    let mut result = Vec::new();
    loop {
        start += 1;
        let word = TABLE[start] as usize;
        let edges = [(word >> 8) & 15,(word >> 4) & 15,word & 15];
        result.push([edges[m],edges[n],edges[2]]);
        if word >> 12 == 0 { break; }
    }
    result
}
