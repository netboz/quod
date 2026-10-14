use quod_client_core::{glb, identity::*, scene, terms};
use serde_json::Value;
use std::path::Path;

fn corpus() -> Value {
    serde_json::from_str(include_str!(
        "../../../test/fixtures/native-contract/contracts.json"
    ))
    .unwrap()
}

// JavaScript has one numeric type. Renderer values are already constrained to
// its exact range; normalize serde's 0/0.0 representation, not subject integers.
fn render_numbers(v: &mut Value) {
    match v {
        Value::Number(n) => {
            if let Some(f) = n.as_f64() {
                if f.fract() == 0.0 {
                    *v = Value::from(f as i64);
                }
            }
        }
        Value::Array(a) => a.iter_mut().for_each(render_numbers),
        Value::Object(o) => o.values_mut().for_each(render_numbers),
        _ => (),
    }
}

#[test]
fn browser_identity_and_signed_bytes() {
    let c = corpus();
    let identity = Identity::import(
        c["bundle"].as_str().unwrap(),
        c["passphrase"].as_str().unwrap(),
    )
    .unwrap();
    assert_eq!(b64(&identity.public_key()), c["public_key"]);
    for r in c["requests"].as_array().unwrap() {
        let account: Account = serde_json::from_value(r["account"].clone()).unwrap();
        let bytes = read_request(
            &identity.public_key(),
            &account,
            &bytes32(r["operation"].as_str().unwrap()).unwrap(),
            r["deadline"].as_str().unwrap().parse().unwrap(),
            r["goal"].as_str().unwrap(),
        )
        .unwrap();
        assert_eq!(b64(&bytes), r["bytes"]);
        assert_eq!(identity.sign(&bytes), r["signature"]);
    }
    let challenge = &c["challenge"];
    let nonce = bytes32(challenge["nonce"].as_str().unwrap()).unwrap();
    let bytes = challenge_bytes(&challenge["value"], &identity.public_key(), &nonce).unwrap();
    assert_eq!(b64(&bytes), challenge["bytes"]);
    let mut invalid_challenge = challenge["value"].clone();
    invalid_challenge["challenge_id"] = Value::String(b64(&[2; 32]));
    assert!(challenge_bytes(&invalid_challenge, &identity.public_key(), &nonce).is_err());
    assert_eq!(
        identity
            .challenge_signature(&challenge["value"], &nonce)
            .unwrap(),
        challenge["signature"]
    );
    assert_eq!(
        lobby_goal(c["lobbyBinding"].as_str().unwrap()).unwrap(),
        c["lobbyGoal"]
    );
}
#[test]
fn damaged_identity_and_session_boundaries() {
    let c = corpus();
    let bundle = c["bundle"].as_str().unwrap();
    let pass = c["passphrase"].as_str().unwrap();
    assert!(Identity::import(bundle, "wrong").is_err());
    let mut changed: Value = serde_json::from_str(bundle).unwrap();
    changed["public_key"] = Value::String(b64(&[0; 32]));
    assert_eq!(
        b64(&Identity::import(&changed.to_string(), pass)
            .unwrap()
            .public_key()),
        c["public_key"]
    );
    changed["ciphertext"] = Value::String("AA".into());
    assert!(Identity::import(&changed.to_string(), pass).is_err());
    let mut session = Session::new(Identity::import(bundle, pass).unwrap());
    let mut account: Account = serde_json::from_value(c["account"].clone()).unwrap();
    assert!(session.read(&account, "true.", 1).is_err());
    session.begin().unwrap();
    session.challenge(&c["challenge"]["value"], 1).unwrap();
    session
        .complete(
            &serde_json::json!({"session_id":"test","expires_ms":100}),
            1,
        )
        .unwrap();
    assert!(session.read(&account, "true.", 100).is_err());
    let original_key = session.identity.public_key();
    assert!(session.read(&account, "true.", 2).is_ok());
    account.network = b64(&[0; 32]);
    assert!(session.read(&account, "true.", 2).is_err());
    account = serde_json::from_value(c["account"].clone()).unwrap();
    session.end();
    assert_eq!(session.identity.public_key(), original_key);
    assert!(session.network().is_err());
    assert!(session.session_id().is_err());
    assert!(session.read(&account, "true.", 2).is_err());
    session.begin().unwrap();
    session.end();
    assert!(session.challenge(&c["challenge"]["value"], 1).is_err());
}
#[test]
fn renderer_neutral_terms_and_marks() {
    let c = corpus();
    for t in c["terms"].as_array().unwrap() {
        assert_eq!(
            terms::parse(t["text"].as_str().unwrap()).unwrap().render(),
            t["canonical"]
        );
    }
    for t in c["invalidTerms"].as_array().unwrap() {
        assert!(terms::parse(t.as_str().unwrap()).is_err(), "{t}");
    }
    for m in c["marks"].as_array().unwrap() {
        let mut actual = scene::marks(m["text"].as_str().unwrap()).unwrap();
        let mut expected = m["value"].clone();
        render_numbers(&mut actual);
        render_numbers(&mut expected);
        assert_eq!(actual, expected);
    }
    for m in c["invalidMarks"].as_array().unwrap() {
        assert!(scene::marks(m.as_str().unwrap()).is_err(), "{m}");
    }
}
#[test]
fn real_assets_match_browser_admission() {
    let c = corpus();
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..");
    for g in c["glbs"].as_array().unwrap() {
        let bytes = std::fs::read(root.join(g["path"].as_str().unwrap())).unwrap();
        glb::verify_digest(&bytes, g["digest"].as_str().unwrap()).unwrap();
        let info = glb::inspect(&bytes).unwrap();
        assert_eq!(info["costs"], g["costs"]);
        assert_eq!(info["boundsMm"], g["boundsMm"]);
        let limits = Value::Array(
            info["costs"]
                .as_array()
                .unwrap()
                .iter()
                .map(|n| Value::from(n.as_u64().unwrap().max(1)))
                .collect(),
        );
        glb::check(&info, &limits, &info["boundsMm"]).unwrap();
        let mut bad = limits.clone();
        bad[0] = Value::from(1);
        assert!(glb::check(&info, &bad, &info["boundsMm"]).is_err());
        assert!(glb::inspect(&bytes[..bytes.len() - 1]).is_err());
        assert!(glb::verify_digest(&bytes, &"0".repeat(64)).is_err());
    }
}
