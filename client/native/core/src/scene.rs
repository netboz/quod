//! Renderer-neutral, validated values. Integers identifying subjects stay term text.
use crate::{
    require,
    terms::{parse, Term},
    Result,
};
use serde_json::{json, Map, Value};
use std::collections::HashSet;

pub fn marks(input: &str) -> Result<Value> {
    let parsed = parse(input)?;
    require(parsed.ground(), "scene must be ground with proper lists")?;
    let mut seen = HashSet::new();
    let mut out = Vec::new();
    for term in parsed.list()? {
        let a = term.args("mark", 7)?;
        let id = a[0].text()?;
        require(!seen.contains(id), "duplicate mark identity")?;
        let kind = a[1].text()?;
        let fields: &[&str] = match kind {
            "box" => &["width", "height", "depth"],
            "sphere" | "sky_sphere" => &["diameter"],
            "plane" => &["width", "height"],
            "cylinder" | "capsule" => &["diameter", "height"],
            "torus" => &["diameter", "thickness"],
            "group" | "mesh" => &[],
            _ => return Err(format!("unsupported mark kind: {kind}")),
        };
        let size = if kind == "mesh" {
            mesh(&a[2])?
        } else {
            let dimensions = a[2].list()?;
            require(dimensions.len() == fields.len(), "wrong dimension count")?;
            let mut size = Map::new();
            for (term, field) in dimensions.iter().zip(fields) {
                let f = term.args("f", 2)?;
                require(f[0].text()? == *field, "wrong dimension name/order")?;
                size.insert((*field).into(), json!(positive(&f[1])?));
            }
            if kind == "capsule" {
                require(
                    size["height"].as_i64() >= size["diameter"].as_i64(),
                    "capsule height excludes ends",
                )?;
            }
            if kind == "torus" {
                require(
                    size["thickness"].as_i64() < size["diameter"].as_i64(),
                    "invalid torus thickness",
                )?;
            }
            Value::Object(size)
        };
        let (parent, transform) = if let Term::Call(n, _) = &a[3] {
            if n == "relative" {
                let r = a[3].args("relative", 2)?;
                (Some(r[0].text()?), &r[1])
            } else {
                (None, &a[3])
            }
        } else {
            (None, &a[3])
        };
        if let Some(p) = parent {
            require(seen.contains(p), "parent must precede child")?;
        }
        // The first viewer cannot invent a physical pose when no simulation view is open.
        if matches!(transform, Term::Call(n, _) if n == "body_pose") {
            return Err("body-driven marks require a simulation view".into());
        }
        let t = transform.args("transform", 6)?;
        let transform: Map<String, Value> = ["x", "y", "z", "rx", "ry", "rz"]
            .iter()
            .zip(t)
            .map(|(k, v)| Ok(((*k).into(), json!(whole(v)?))))
            .collect::<Result<_>>()?;
        let material = match kind {
            "group" => {
                require(a[4].atom("no_surface"), "group must have no surface")?;
                Value::Null
            }
            "mesh" => {
                require(a[4].atom("asset_surfaces"), "mesh must use asset surfaces")?;
                Value::Null
            }
            _ => surface(&a[4])?,
        };
        let label = if a[5].atom("unlabelled") {
            Value::Null
        } else {
            let l = a[5].args("label", 2)?;
            json!({"text":l[0].text()?, "placement":choice(&l[1], &["above","centre","below"])?})
        };
        let depicts = if a[6].atom("depicts_nothing") {
            Value::Null
        } else {
            let count = match &a[6] {
                Term::Call(_, a) => a.len(),
                _ => 0,
            };
            require(count == 2 || count == 3, "invalid depicted subject")?;
            let d = a[6].args("depicts", count)?;
            let anchor = if count == 3 {
                require(d[1].bytes()?.len() == 32, "invalid subject anchor")?;
                Some(crate::identity::b64(d[1].bytes()?))
            } else {
                None
            };
            json!({"ontology":d[0].text()?,"anchor":anchor,"entityText":d[count-1].render()})
        };
        out.push(json!({"id":id,"kind":kind,"size":size,"parent":parent,"transform":transform,"material":material,"label":label,"depicts":depicts}));
        seen.insert(id.to_owned());
    }
    Ok(Value::Array(out))
}
fn whole(t: &Term) -> Result<i64> {
    let n = t.integer()?;
    require(
        n.unsigned_abs() <= 9_007_199_254_740_991,
        "render value exceeds exact numeric range",
    )?;
    Ok(n)
}
fn positive(t: &Term) -> Result<i64> {
    let n = whole(t)?;
    require(n > 0, "expected positive dimension/allowance")?;
    Ok(n)
}
fn choice<'a>(t: &'a Term, choices: &[&str]) -> Result<&'a str> {
    let v = t.text()?;
    require(choices.contains(&v), "unsupported descriptor value")?;
    Ok(v)
}
fn digest(t: &Term) -> Result<&str> {
    let d = t.text()?;
    require(
        d.len() == 64
            && d.bytes()
                .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c)),
        "invalid SHA-256 digest",
    )?;
    Ok(d)
}
fn fraction(t: &Term) -> Result<f64> {
    let n = whole(t)?;
    require((0..=1000).contains(&n), "invalid material factor")?;
    Ok(n as f64 / 1000.0)
}
fn surface(t: &Term) -> Result<Value> {
    let a = t.args("surface", 6)?;
    let colour = a[0].text()?;
    require(
        colour.len() == 7
            && colour.starts_with('#')
            && colour[1..]
                .bytes()
                .all(|c| c.is_ascii_digit() || (b'A'..=b'F').contains(&c)),
        "invalid colour",
    )?;
    let mut slots = HashSet::new();
    let textures = a[5].list()?.iter().map(|t| {
        let b = t.args("texture", 3)?;
        let slot = choice(&b[0], &["base_colour", "normal", "orm"])?;
        require(slots.insert(slot), "duplicate texture slot")?;
        let asset = b[1].args("asset", 2)?;
        choice(&asset[1], &["image/jpeg"])?;
        let repeat = b[2].args("repeat", 2)?;
        Ok(json!({"slot":slot,"digest":digest(&asset[0])?,"repeat":[positive(&repeat[0])? as f64/1000.0,positive(&repeat[1])? as f64/1000.0]}))
    }).collect::<Result<Vec<_>>>()?;
    Ok(
        json!({"colour":colour,"metallic":fraction(&a[1])?,"roughness":fraction(&a[2])?,"emission":fraction(&a[3])?,"opacity":fraction(&a[4])?,"textures":textures}),
    )
}
fn mesh(t: &Term) -> Result<Value> {
    let a = t.args("mesh_asset", 5)?;
    let asset = a[0].args("asset", 2)?;
    choice(&asset[1], &["model/gltf-binary"])?;
    let profile = choice(&a[1], &["gltf2-static-v1"])?;
    let scale = positive(&a[2].args("scale", 1)?[0])? as f64 / 1000.0;
    let frame = a[3].args("frame", 3)?;
    let bounds = frame[0]
        .args("aabb", 6)?
        .iter()
        .map(whole)
        .collect::<Result<Vec<_>>>()?;
    require(
        (0..3).all(|i| bounds[i] < bounds[i + 3]),
        "invalid mesh bounds",
    )?;
    let pivot = frame[1]
        .args("pivot", 3)?
        .iter()
        .map(whole)
        .collect::<Result<Vec<_>>>()?;
    let front = choice(&frame[2].args("front", 1)?[0], &["-z", "+z", "+x", "-x"])?;
    let allowed = a[4]
        .args("resources", 7)?
        .iter()
        .map(positive)
        .collect::<Result<Vec<_>>>()?;
    Ok(
        json!({"digest":digest(&asset[0])?,"profile":profile,"scale":scale,"bounds":bounds,"pivot":pivot,"front":front,"allowed":allowed}),
    )
}
