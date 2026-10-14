//! Admission for the existing gltf2-static-v1 profile, before Godot decodes it.
use crate::{require, Result};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::HashSet;

pub fn verify_digest(bytes: &[u8], expected: &str) -> Result<()> {
    let actual = format!("{:x}", Sha256::digest(bytes));
    require(actual == expected, "asset content digest mismatch")
}
fn number(v: &Value) -> Result<usize> {
    let n = v
        .as_u64()
        .or_else(|| {
            v.as_f64()
                .filter(|n| {
                    n.is_finite() && *n >= 0. && n.fract() == 0. && *n <= 9_007_199_254_740_991.
                })
                .map(|n| n as u64)
        })
        .ok_or("invalid nonnegative integer")?;
    require(n <= 9_007_199_254_740_991, "integer exceeds profile range")?;
    usize::try_from(n).map_err(|_| "integer exceeds address space".into())
}
fn optional(v: &Value, key: &str, default: usize) -> Result<usize> {
    v.get(key).map(number).unwrap_or(Ok(default))
}
fn array<'a>(v: &'a Value, key: &str) -> Result<&'a [Value]> {
    match v.get(key) {
        None => Ok(&[]),
        Some(Value::Array(a)) => Ok(a),
        _ => Err(format!("invalid {key} array")),
    }
}
fn index<'a>(a: &'a [Value], i: &Value) -> Result<&'a Value> {
    a.get(number(i)?).ok_or("invalid GLB index".into())
}
fn range(bytes: &[u8], start: usize, count: usize) -> Result<&[u8]> {
    bytes
        .get(start..start.checked_add(count).ok_or("range overflow")?)
        .ok_or("truncated GLB data".into())
}
fn u32le(b: &[u8], offset: usize) -> Result<u32> {
    Ok(u32::from_le_bytes(range(b, offset, 4)?.try_into().unwrap()))
}
fn width(component: usize) -> Result<usize> {
    match component {
        5120 | 5121 => Ok(1),
        5122 | 5123 => Ok(2),
        5125 | 5126 => Ok(4),
        _ => Err("invalid component type".into()),
    }
}
fn components(t: &Value) -> Result<usize> {
    match t.as_str() {
        Some("SCALAR") => Ok(1),
        Some("VEC2") => Ok(2),
        Some("VEC3") => Ok(3),
        Some("VEC4" | "MAT2") => Ok(4),
        Some("MAT3") => Ok(9),
        Some("MAT4") => Ok(16),
        _ => Err("invalid accessor type".into()),
    }
}
fn no_features(v: &Value, keys: &[&str]) -> Result<()> {
    require(
        keys.iter().all(|k| v.get(k).is_none()),
        "unsupported GLB feature",
    )
}
fn accessor_offset(a: &Value, views: &[Value]) -> Result<usize> {
    let view = index(views, &a["bufferView"])?;
    optional(view, "byteOffset", 0)?
        .checked_add(optional(a, "byteOffset", 0)?)
        .ok_or("offset overflow".into())
}
fn floats<const N: usize>(v: &Value) -> Result<[f64; N]> {
    let a = v.as_array().ok_or("invalid vector")?;
    require(a.len() == N, "invalid vector width")?;
    let mut out = [0.0; N];
    for (i, v) in a.iter().enumerate() {
        out[i] = v
            .as_f64()
            .filter(|n| n.is_finite())
            .ok_or("nonfinite value")?;
    }
    Ok(out)
}
type Matrix = [f64; 16];
const IDENTITY: Matrix = [
    1., 0., 0., 0., 0., 1., 0., 0., 0., 0., 1., 0., 0., 0., 0., 1.,
];
fn multiply(a: Matrix, b: Matrix) -> Matrix {
    let mut out = [0.; 16];
    for c in 0..4 {
        for r in 0..4 {
            for k in 0..4 {
                out[c * 4 + r] += a[k * 4 + r] * b[c * 4 + k];
            }
        }
    }
    out
}
fn local(node: &Value) -> Result<Matrix> {
    if let Some(m) = node.get("matrix") {
        no_features(node, &["translation", "rotation", "scale"])?;
        let m = floats::<16>(m)?;
        require(
            m[3] == 0. && m[7] == 0. && m[11] == 0. && m[15] == 1.,
            "non-affine matrix",
        )?;
        return Ok(m);
    }
    let [x, y, z, w] = node
        .get("rotation")
        .map(floats::<4>)
        .transpose()?
        .unwrap_or([0., 0., 0., 1.]);
    require(
        (x * x + y * y + z * z + w * w - 1.).abs() < 0.001,
        "nonunit quaternion",
    )?;
    let [sx, sy, sz] = node
        .get("scale")
        .map(floats::<3>)
        .transpose()?
        .unwrap_or([1.; 3]);
    let [tx, ty, tz] = node
        .get("translation")
        .map(floats::<3>)
        .transpose()?
        .unwrap_or([0.; 3]);
    Ok([
        (1. - 2. * (y * y + z * z)) * sx,
        2. * (x * y + z * w) * sx,
        2. * (x * z - y * w) * sx,
        0.,
        2. * (x * y - z * w) * sy,
        (1. - 2. * (x * x + z * z)) * sy,
        2. * (y * z + x * w) * sy,
        0.,
        2. * (x * z + y * w) * sz,
        2. * (y * z - x * w) * sz,
        (1. - 2. * (x * x + y * y)) * sz,
        0.,
        tx,
        ty,
        tz,
        1.,
    ])
}
fn pixels(bytes: &[u8], mime: &str) -> Result<u64> {
    let (w, h) = if mime == "image/png" {
        require(
            range(bytes, 0, 8)? == b"\x89PNG\r\n\x1a\n" && range(bytes, 12, 4)? == b"IHDR",
            "invalid PNG header",
        )?;
        (
            u32::from_be_bytes(range(bytes, 16, 4)?.try_into().unwrap()) as u64,
            u32::from_be_bytes(range(bytes, 20, 4)?.try_into().unwrap()) as u64,
        )
    } else {
        require(range(bytes, 0, 2)? == [255, 216], "invalid JPEG header")?;
        let mut at = 2;
        let mut dimensions = None;
        while at + 4 <= bytes.len() {
            require(bytes[at] == 255, "invalid JPEG segment")?;
            at += 1;
            while bytes.get(at) == Some(&255) {
                at += 1;
            }
            let marker = *bytes.get(at).ok_or("truncated JPEG")?;
            at += 1;
            let length = u16::from_be_bytes(range(bytes, at, 2)?.try_into().unwrap()) as usize;
            require(length >= 2, "invalid JPEG segment length")?;
            range(bytes, at, length)?;
            if (0xc0..=0xc3).contains(&marker) {
                require(length >= 7, "invalid JPEG frame")?;
                dimensions = Some((
                    u16::from_be_bytes(range(bytes, at + 5, 2)?.try_into().unwrap()) as u64,
                    u16::from_be_bytes(range(bytes, at + 3, 2)?.try_into().unwrap()) as u64,
                ));
                break;
            }
            at += length;
        }
        dimensions.ok_or("JPEG dimensions missing")?
    };
    require(w > 0 && h > 0, "invalid image dimensions")?;
    w.checked_mul(h).ok_or("image pixel overflow".into())
}

pub fn inspect(bytes: &[u8]) -> Result<Value> {
    require(
        bytes.len() >= 20
            && u32le(bytes, 0)? == 0x46546c67
            && u32le(bytes, 4)? == 2
            && u32le(bytes, 8)? as usize == bytes.len(),
        "invalid GLB header",
    )?;
    let mut at = 12;
    let mut json_bytes = None;
    let mut bin = None;
    while at < bytes.len() {
        let len = u32le(bytes, at)? as usize;
        let tag = u32le(bytes, at + 4)?;
        at += 8;
        require(len.is_multiple_of(4), "unaligned GLB chunk")?;
        let data = range(bytes, at, len)?;
        at += len;
        match tag {
            0x4e4f534a if json_bytes.is_none() && bin.is_none() => json_bytes = Some(data),
            0x004e4942 if json_bytes.is_some() && bin.is_none() => bin = Some(data),
            _ => return Err("unexpected GLB chunk".into()),
        }
    }
    let doc: Value = serde_json::from_slice(json_bytes.ok_or("missing JSON chunk")?)
        .map_err(|_| "invalid GLB JSON")?;
    let bin = bin.ok_or("missing BIN chunk")?;
    require(
        doc["asset"]["version"] == "2.0" && doc["asset"].get("minVersion").is_none(),
        "unsupported glTF version",
    )?;
    require(
        array(&doc, "extensionsUsed")?.is_empty() && array(&doc, "extensionsRequired")?.is_empty(),
        "unsupported GLB extensions",
    )?;
    no_features(&doc, &["animations", "skins", "cameras"])?;
    let mut todo = vec![&doc];
    while let Some(v) = todo.pop() {
        match v {
            Value::Object(o) => {
                require(
                    !o.contains_key("extensions"),
                    "unsupported nested extension",
                )?;
                todo.extend(o.values());
            }
            Value::Array(a) => todo.extend(a),
            _ => (),
        }
    }
    let scenes = array(&doc, "scenes")?;
    let buffers = array(&doc, "buffers")?;
    require(
        scenes.len() == 1 && doc["scene"] == 0 && buffers.len() == 1,
        "one selected scene and buffer required",
    )?;
    no_features(&buffers[0], &["uri"])?;
    let buffer_len = number(&buffers[0]["byteLength"])?;
    require(
        buffer_len <= bin.len() && bin.len() - buffer_len < 4,
        "invalid buffer length",
    )?;
    let views = array(&doc, "bufferViews")?;
    let accessors = array(&doc, "accessors")?;
    let nodes = array(&doc, "nodes")?;
    let meshes = array(&doc, "meshes")?;
    let materials = array(&doc, "materials")?;
    let images = array(&doc, "images")?;
    let textures = array(&doc, "textures")?;
    let samplers = array(&doc, "samplers")?;
    for v in views {
        require(v["buffer"] == 0, "invalid buffer index")?;
        no_features(v, &["byteStride"])?;
        range(
            &bin[..buffer_len],
            optional(v, "byteOffset", 0)?,
            number(&v["byteLength"])?,
        )?;
    }
    for a in accessors {
        no_features(a, &["sparse"])?;
        let v = index(views, &a["bufferView"])?;
        let w = width(number(&a["componentType"])?)?;
        let length = number(&a["count"])?
            .checked_mul(w * components(&a["type"])?)
            .ok_or("accessor size overflow")?;
        require(accessor_offset(a, views)? % w == 0, "unaligned accessor")?;
        let end = optional(a, "byteOffset", 0)?
            .checked_add(length)
            .ok_or("accessor range overflow")?;
        require(
            end <= number(&v["byteLength"])?,
            "accessor exceeds buffer view",
        )?;
    }
    for s in samplers {
        for k in ["wrapS", "wrapT"] {
            if let Some(v) = s.get(k) {
                require(
                    [33071, 33648, 10497].contains(&number(v)?),
                    "unsupported sampler",
                )?;
            }
        }
    }
    for t in textures {
        index(images, &t["source"])?;
        if let Some(s) = t.get("sampler") {
            index(samplers, s)?;
        }
    }
    for m in materials {
        for slot in [
            &m["pbrMetallicRoughness"]["baseColorTexture"],
            &m["pbrMetallicRoughness"]["metallicRoughnessTexture"],
            &m["normalTexture"],
            &m["occlusionTexture"],
            &m["emissiveTexture"],
        ] {
            if !slot.is_null() {
                index(textures, &slot["index"])?;
                require(optional(slot, "texCoord", 0)? == 0, "only UV0 supported")?;
            }
        }
    }
    let mut image_pixels = 0u64;
    for image in images {
        no_features(image, &["uri"])?;
        let mime = image["mimeType"]
            .as_str()
            .ok_or("missing image MIME type")?;
        require(
            ["image/png", "image/jpeg"].contains(&mime),
            "unsupported image type",
        )?;
        let view = index(views, &image["bufferView"])?;
        image_pixels = image_pixels
            .checked_add(pixels(
                range(
                    bin,
                    optional(view, "byteOffset", 0)?,
                    number(&view["byteLength"])?,
                )?,
                mime,
            )?)
            .ok_or("image pixel overflow")?;
    }
    let mut used_views = HashSet::new();
    let mut stats = Vec::new();
    for mesh in meshes {
        no_features(mesh, &["weights"])?;
        let primitives = array(mesh, "primitives")?;
        require(!primitives.is_empty(), "empty mesh")?;
        let mut low = [f64::INFINITY; 3];
        let mut high = [f64::NEG_INFINITY; 3];
        let mut vertices = 0usize;
        let mut triangles = 0usize;
        for p in primitives {
            require(optional(p, "mode", 4)? == 4, "only triangles supported")?;
            no_features(p, &["targets"])?;
            let attrs = p["attributes"]
                .as_object()
                .ok_or("missing vertex attributes")?;
            let pos = index(accessors, &p["attributes"]["POSITION"])?;
            let count = number(&pos["count"])?;
            require(
                count > 0 && pos["type"] == "VEC3" && pos["componentType"] == 5126,
                "positions must be float VEC3",
            )?;
            let offset = accessor_offset(pos, views)?;
            let mut min = [f64::INFINITY; 3];
            let mut max = [f64::NEG_INFINITY; 3];
            for i in 0..count {
                for axis in 0..3 {
                    let n = f32::from_le_bytes(
                        range(bin, offset + i * 12 + axis * 4, 4)?
                            .try_into()
                            .unwrap(),
                    ) as f64;
                    require(n.is_finite(), "nonfinite position")?;
                    min[axis] = min[axis].min(n);
                    max[axis] = max[axis].max(n);
                }
            }
            for (key, actual) in [("min", min), ("max", max)] {
                let declared = floats::<3>(&pos[key])?;
                require(
                    (0..3).all(|i| declared[i] as f32 as f64 == actual[i]),
                    "position bounds differ from data",
                )?;
            }
            for axis in 0..3 {
                low[axis] = low[axis].min(min[axis]);
                high[axis] = high[axis].max(max[axis]);
            }
            for (kind, id) in attrs {
                let a = index(accessors, id)?;
                require(number(&a["count"])? == count, "attribute count mismatch")?;
                let types: &[&str] = match kind.as_str() {
                    "POSITION" | "NORMAL" => &["VEC3"],
                    "TANGENT" => &["VEC4"],
                    "TEXCOORD_0" => &["VEC2"],
                    "COLOR_0" => &["VEC3", "VEC4"],
                    _ => return Err("unsupported attribute".into()),
                };
                require(
                    a["type"].as_str().is_some_and(|t| types.contains(&t)),
                    "invalid attribute type",
                )?;
                let component = number(&a["componentType"])?;
                let normalized = a
                    .get("normalized")
                    .map(|v| v.as_bool().ok_or("invalid normalization"))
                    .transpose()?
                    .unwrap_or(false);
                require(
                    if component == 5126 {
                        !normalized
                    } else if kind == "POSITION" {
                        false
                    } else if kind == "NORMAL" || kind == "TANGENT" {
                        [5120, 5122].contains(&component) && normalized
                    } else {
                        [5121, 5123].contains(&component) && normalized
                    },
                    "invalid attribute components",
                )?;
                used_views.insert(number(&a["bufferView"])?);
            }
            let mut index_count = count;
            if let Some(id) = p.get("indices") {
                let a = index(accessors, id)?;
                let component = number(&a["componentType"])?;
                require(
                    a["type"] == "SCALAR"
                        && a["normalized"] != true
                        && [5121, 5123, 5125].contains(&component),
                    "invalid indices",
                )?;
                index_count = number(&a["count"])?;
                let offset = accessor_offset(a, views)?;
                let w = width(component)?;
                for i in 0..index_count {
                    let b = range(bin, offset + i * w, w)?;
                    let n = match w {
                        1 => b[0] as usize,
                        2 => u16::from_le_bytes(b.try_into().unwrap()) as usize,
                        _ => u32::from_le_bytes(b.try_into().unwrap()) as usize,
                    };
                    require(n < count, "index exceeds vertex count")?;
                }
                used_views.insert(number(&a["bufferView"])?);
            }
            require(index_count % 3 == 0, "incomplete triangles")?;
            if let Some(m) = p.get("material") {
                index(materials, m)?;
            }
            vertices = vertices.checked_add(count).ok_or("vertex count overflow")?;
            triangles = triangles
                .checked_add(index_count / 3)
                .ok_or("triangle count overflow")?;
        }
        stats.push((vertices, triangles, low, high));
    }
    let mut seen = HashSet::new();
    let mut used_meshes = HashSet::new();
    let mut stack = array(&scenes[0], "nodes")?
        .iter()
        .map(|v| Ok((number(v)?, IDENTITY)))
        .collect::<Result<Vec<_>>>()?;
    let mut min = [f64::INFINITY; 3];
    let mut max = [f64::NEG_INFINITY; 3];
    let mut vertices = 0usize;
    let mut triangles = 0usize;
    while let Some((id, parent)) = stack.pop() {
        require(seen.insert(id), "cyclic or reused scene node")?;
        let node = nodes.get(id).ok_or("invalid scene node")?;
        no_features(node, &["camera", "skin", "weights"])?;
        let matrix = multiply(parent, local(node)?);
        if let Some(m) = node.get("mesh") {
            let m = number(m)?;
            let (v, t, low, high) = stats.get(m).ok_or("invalid mesh index")?;
            used_meshes.insert(m);
            vertices = vertices.checked_add(*v).ok_or("vertex count overflow")?;
            triangles = triangles.checked_add(*t).ok_or("triangle count overflow")?;
            for x in [low[0], high[0]] {
                for y in [low[1], high[1]] {
                    for z in [low[2], high[2]] {
                        for axis in 0..3 {
                            let n = matrix[axis] * x
                                + matrix[axis + 4] * y
                                + matrix[axis + 8] * z
                                + matrix[axis + 12];
                            require(n.is_finite(), "nonfinite scene bounds")?;
                            min[axis] = min[axis].min(n);
                            max[axis] = max[axis].max(n);
                        }
                    }
                }
            }
        }
        for c in array(node, "children")? {
            stack.push((number(c)?, matrix));
        }
    }
    require(
        seen.len() == nodes.len()
            && used_meshes.len() == meshes.len()
            && min.iter().all(|v| v.is_finite()),
        "unselected or empty content",
    )?;
    let geometry = used_views
        .iter()
        .try_fold(0usize, |sum, &id| -> Result<usize> {
            sum.checked_add(number(&views[id]["byteLength"])?)
                .ok_or("geometry byte overflow".into())
        })?;
    let costs = [
        bytes.len() as u64,
        geometry as u64,
        vertices as u64,
        triangles as u64,
        nodes.len() as u64,
        materials.len() as u64,
        image_pixels,
    ];
    require(
        costs.iter().all(|&n| n <= 9_007_199_254_740_991),
        "resource count overflow",
    )?;
    let mut bounds = Vec::new();
    for (i, n) in min.into_iter().chain(max).enumerate() {
        let mm = n * 1000.;
        let nearest = mm.round();
        let ulp = if n == 0. {
            0.
        } else {
            2f64.powf(n.abs().log2().floor() - 23.)
        };
        let snapped = if (mm - nearest).abs() <= (4. * ulp * 1000.).clamp(0.0001, 0.25) {
            nearest
        } else {
            mm
        };
        let rounded = if i < 3 {
            snapped.floor()
        } else {
            snapped.ceil()
        };
        require(
            rounded.abs() <= 9_007_199_254_740_991.,
            "scene bounds overflow",
        )?;
        bounds.push(rounded as i64);
    }
    for i in 0..3 {
        if bounds[i] == bounds[i + 3] {
            bounds[i] -= 1;
            bounds[i + 3] += 1;
        }
    }
    Ok(json!({"costs":costs,"boundsMm":bounds}))
}

pub fn check(info: &Value, allowed: &Value, bounds: &Value) -> Result<()> {
    let names = [
        "transfer bytes",
        "geometry bytes",
        "vertices",
        "triangles",
        "nodes",
        "materials",
        "image pixels",
    ];
    let a = allowed.as_array().ok_or("invalid allowances")?;
    require(a.len() == 7, "invalid allowance count")?;
    for i in 0..7 {
        let limit = number(&a[i])?;
        require(limit > 0, "invalid resource allowance")?;
        require(
            number(&info["costs"][i])? <= limit,
            &format!("{} exceeded", names[i]),
        )?;
    }
    require(
        floats::<6>(&info["boundsMm"])? == floats::<6>(bounds)?,
        "declared mesh bounds differ from measured bounds",
    )
}
