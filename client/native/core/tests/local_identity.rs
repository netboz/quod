use quod_client_core::{
    identity::{b64, Identity},
    local::Local,
    terms::binary,
};
use serde_json::{json, Value};
use std::{fs, os::unix::fs::PermissionsExt, path::PathBuf, process::Command};

struct Directory(PathBuf);
impl Directory {
    fn new() -> Self {
        Self(std::env::temp_dir().join(format!(
            "quod-identity-test-{}",
            b64(&quod_client_core::identity::random32().unwrap())
        )))
    }
}
impl Drop for Directory {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
fn corpus() -> Value {
    serde_json::from_str(include_str!(
        "../../../test/fixtures/native-contract/contracts.json"
    ))
    .unwrap()
}
fn authenticate(local: &mut Local) {
    let c = corpus();
    let s = local.session_mut().unwrap();
    s.begin().unwrap();
    s.challenge(&c["challenge"]["value"], 1).unwrap();
    s.complete(
        &json!({"session_id":"fresh-session","expires_ms":100000}),
        1,
    )
    .unwrap();
}
fn catalogue() -> Value {
    json!({"network_id":corpus()["account"]["network"],"ontologies":[{"namespace":"quod:signup","anchor":b64(&[2;32])}]})
}
fn signup() -> Value {
    json!({"result":"ok","bindings":[{"Account":format!("agent_instance_ref(<<\"human:native\">>,{},me)",binary(&[4;32]))}]})
}
fn lobby() -> Value {
    json!({"result":"ok","bindings":[{"Lobby":corpus()["lobbyBinding"]}]})
}
fn terminal(mut result: Value) -> Value {
    result["result"] = json!("operation_outcome");
    result["status"] = json!("committed");
    result["terminal"] = json!(true);
    result
}

#[test]
fn generate_restore_and_browser_backup_interoperate_without_rewriting() {
    let d = Directory::new();
    let local = Local::open(&d.0, false).unwrap();
    assert_eq!(local.summary()["present"], false);
    drop(local);
    let local = Local::open(&d.0, true).unwrap();
    let public = local.summary();
    assert!(
        Local::open(&d.0, true).is_err(),
        "second writer must not replace the key"
    );
    let path = d.0.join("active.json");
    assert_eq!(
        fs::metadata(&path).unwrap().permissions().mode() & 0o777,
        0o600
    );
    let before = fs::metadata(&path).unwrap().modified().unwrap();
    let password = "native portable backup";
    let encrypted = local.session().unwrap().identity.export(password).unwrap();
    assert!(local.session().unwrap().identity.export("short").is_err());
    let backup = d.0.join("backup.quodkey");
    fs::write(&backup, &encrypted).unwrap();
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../..");
    let check=Command::new("node").current_dir(root).args(["--input-type=module","-e", "import {readFileSync} from 'node:fs'; import {importEncryptedKeyProvider,b64url} from './client/src/key-provider.js'; const p=await importEncryptedKeyProvider(readFileSync(process.argv[1],'utf8'),'native portable backup'); if(b64url(p.publicKey)!==process.argv[2]) process.exit(1);", backup.to_str().unwrap(),public["public_key"].as_str().unwrap()]).output().unwrap();
    assert!(
        check.status.success(),
        "browser rejected native backup: {}",
        String::from_utf8_lossy(&check.stderr)
    );
    assert_eq!(
        b64(&Identity::import(&encrypted, password).unwrap().public_key()),
        public["public_key"]
    );
    drop(local);
    let mut restored = Local::open(&d.0, true).unwrap();
    assert_eq!(restored.summary(), public);
    assert_eq!(fs::metadata(&path).unwrap().modified().unwrap(), before);
    assert!(restored.import(&encrypted, "wrong").is_err());
    assert_eq!(restored.summary(), public);
    drop(restored);
    fs::write(&path, b"damaged").unwrap();
    assert!(Local::open(&d.0, true).is_err());
    assert_eq!(fs::read(&path).unwrap(), b"damaged");
}

#[test]
fn interrupted_signup_and_lobby_resolve_original_bytes_after_restart() {
    let d = Directory::new();
    let mut local = Local::open(&d.0, true).unwrap();
    authenticate(&mut local);
    let command = local.enroll(&catalogue(), 2).unwrap();
    assert_eq!(command["path"], "/api/goals/execute");
    assert!(local.enroll(&catalogue(), 2).is_err());
    assert!(local.accept(&json!({"unexpected":true}), false, 3).is_err());
    drop(local);
    let mut local = Local::open(&d.0, false).unwrap();
    authenticate(&mut local);
    let recovery = local.resume().unwrap();
    assert_eq!(recovery["path"], "/api/goals/outcomes");
    assert_eq!(recovery["body"]["request"], command["body"]["request"]);
    assert_eq!(recovery["body"]["signature"], command["body"]["signature"]);
    let pending = json!({"result":"operation_outcome","status":"pending","terminal":false});
    let path = d.0.join("active.json");
    let before = fs::metadata(&path).unwrap().modified().unwrap();
    assert_eq!(local.accept(&pending, true, 3).unwrap()["pending"], true);
    assert_eq!(
        fs::metadata(&path).unwrap().modified().unwrap(),
        before,
        "unchanged outcome check wrote state"
    );
    let child = local.accept(&terminal(signup()), true, 4).unwrap();
    assert_eq!(child["path"], "/api/goals/execute");
    assert_ne!(child["body"]["request"], command["body"]["request"]);
    drop(local);
    let mut local = Local::open(&d.0, false).unwrap();
    authenticate(&mut local);
    assert_eq!(local.accounts().unwrap()[0]["namespace"], "human:native");
    assert_eq!(
        local.resume().unwrap()["body"]["request"],
        child["body"]["request"]
    );
    let completed = local.accept(&terminal(lobby()), true, 5).unwrap();
    assert_eq!(completed["accounts"][0]["namespace"], "human:native");
    assert!(!local
        .resume()
        .unwrap()
        .as_object()
        .unwrap()
        .contains_key("path"));
}

#[test]
fn account_handoff_storage_failure_keeps_parent_recoverable() {
    let d = Directory::new();
    let mut local = Local::open(&d.0, true).unwrap();
    authenticate(&mut local);
    let parent = local.enroll(&catalogue(), 2).unwrap();
    // Deterministic filesystem failure after a server result, before the child can leave.
    let path = d.0.join("active.json");
    let retained = fs::read(&path).unwrap();
    fs::remove_file(&path).unwrap();
    fs::create_dir(&path).unwrap();
    assert!(local.accept(&signup(), false, 3).is_err());
    assert!(local.enroll(&catalogue(), 4).is_err());
    drop(local);
    fs::remove_dir(&path).unwrap();
    fs::write(&path, retained).unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
    let mut local = Local::open(&d.0, false).unwrap();
    authenticate(&mut local);
    assert_eq!(
        local.resume().unwrap()["body"]["request"],
        parent["body"]["request"]
    );
    assert!(local.accounts().unwrap().as_array().unwrap().is_empty());
}
