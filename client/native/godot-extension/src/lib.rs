use godot::prelude::*;
use quod_client_core::{
    identity::{self, Account},
    Result,
};
use serde_json::{json, Value};

struct QuodExtension;

#[gdextension]
unsafe impl ExtensionLibrary for QuodExtension {}

#[derive(GodotClass)]
#[class(base=RefCounted)]
struct QuodBridge {
    client: Option<quod_client_core::local::Local>,
    base: Base<RefCounted>,
}

#[godot_api]
impl IRefCounted for QuodBridge {
    fn init(base: Base<RefCounted>) -> Self {
        Self { client: None, base }
    }
}

fn reply(result: Result<Value>) -> GString {
    GString::from(
        &match result {
            Ok(value) => json!({"ok":true,"value":value}),
            Err(error) => json!({"ok":false,"error":error}),
        }
        .to_string(),
    )
}
fn parse(s: &GString) -> Result<Value> {
    serde_json::from_str(&s.to_string()).map_err(|_| "invalid JSON".into())
}
fn now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

#[godot_api]
impl QuodBridge {
    #[func]
    fn open_identity(
        &mut self,
        directory: GString,
        create: bool,
        bundle: GString,
        password: GString,
    ) -> GString {
        self.client = None;
        reply((|| {
            let mut client = quod_client_core::local::Local::open(
                std::path::Path::new(&directory.to_string()),
                create,
            )?;
            if !bundle.is_empty() {
                client.import(&bundle.to_string(), &password.to_string())?;
            }
            let summary = client.summary();
            self.client = Some(client);
            Ok(summary)
        })())
    }
    #[func]
    fn lock(&mut self) {
        self.client = None;
    }
    #[func]
    fn export_identity(&self, password: GString) -> GString {
        reply(
            self.client
                .as_ref()
                .ok_or("Identity unavailable".into())
                .and_then(|c| {
                    c.session()?
                        .identity
                        .export(&password.to_string())
                        .map(Value::String)
                }),
        )
    }
    #[func]
    fn resume_setup(&self) -> GString {
        reply(
            self.client
                .as_ref()
                .ok_or("Identity unavailable".into())
                .and_then(|c| c.resume()),
        )
    }
    #[func]
    fn refuse_setup(&mut self) -> GString {
        reply(
            self.client
                .as_mut()
                .ok_or("Identity unavailable".into())
                .and_then(|c| c.refuse_submission()),
        )
    }
    #[func]
    fn enroll(&mut self, catalogue: GString) -> GString {
        reply(parse(&catalogue).and_then(|v| {
            self.client
                .as_mut()
                .ok_or("Identity unavailable")?
                .enroll(&v, now())
        }))
    }
    #[func]
    fn accept_setup(&mut self, result: GString, resolving: bool) -> GString {
        reply(parse(&result).and_then(|v| {
            self.client
                .as_mut()
                .ok_or("Identity unavailable")?
                .accept(&v, resolving, now())
        }))
    }
    #[func]
    fn end_auth(&mut self) {
        if let Some(client) = self.client.as_mut() {
            if let Ok(session) = client.session_mut() {
                session.end();
            }
        }
    }
    #[func]
    fn begin_auth(&mut self) -> GString {
        reply(
            self.client
                .as_mut()
                .ok_or("Identity unavailable".into())
                .and_then(|c| c.session_mut()?.begin()),
        )
    }
    #[func]
    fn answer_challenge(&mut self, challenge: GString) -> GString {
        reply(parse(&challenge).and_then(|v| {
            self.client
                .as_mut()
                .ok_or("Identity unavailable")?
                .session_mut()?
                .challenge(&v, now())
        }))
    }
    #[func]
    fn complete_auth(&mut self, session: GString) -> GString {
        reply(parse(&session).and_then(|v| {
            Ok(json!(self
                .client
                .as_mut()
                .ok_or("Identity unavailable")?
                .session_mut()?
                .complete(&v, now())?))
        }))
    }
    #[func]
    fn sign_read(&self, account: GString, goal: GString) -> GString {
        reply((|| {
            let account: Account =
                serde_json::from_str(&account.to_string()).map_err(|_| "invalid account")?;
            self.client
                .as_ref()
                .ok_or("Identity unavailable")?
                .session()?
                .read(&account, &goal.to_string(), now())
        })())
    }
    #[func]
    fn lobby_goal(&self, binding: GString) -> GString {
        reply(identity::lobby_goal(&binding.to_string()).map(Value::String))
    }
    #[func]
    fn decode_marks(&self, binding: GString) -> GString {
        reply(quod_client_core::scene::marks(&binding.to_string()))
    }
    #[func]
    fn verify_asset(&self, bytes: PackedByteArray, digest: GString, model: bool) -> GString {
        reply((|| {
            quod_client_core::glb::verify_digest(bytes.as_slice(), &digest.to_string())?;
            if model {
                quod_client_core::glb::inspect(bytes.as_slice())
            } else {
                Ok(Value::Null)
            }
        })())
    }
    #[func]
    fn check_model(&self, info: GString, allowed: GString, bounds: GString) -> GString {
        reply((|| {
            quod_client_core::glb::check(&parse(&info)?, &parse(&allowed)?, &parse(&bounds)?)?;
            Ok(Value::Null)
        })())
    }
}
