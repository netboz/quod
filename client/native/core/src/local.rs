//! Active identity and exact enrollment recovery; the server owns all outcomes.
use crate::{
    identity::{self, Account, Identity, Session},
    require,
    storage::Storage,
    terms, Result,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{collections::BTreeMap, path::Path};
use zeroize::{Zeroize, Zeroizing};

#[derive(Clone, Serialize, Deserialize)]
struct Operation {
    account: Account,
    step: String,
    body: Value,
    #[serde(default)]
    outcome_ref: Option<Value>,
}
#[derive(Serialize, Deserialize)]
struct Saved {
    version: u8,
    identity: String,
    pending: BTreeMap<String, Operation>,
}
impl Drop for Saved {
    fn drop(&mut self) {
        self.identity.zeroize();
    }
}

pub struct Local {
    storage: Storage,
    pub session: Option<Session>,
    pending: BTreeMap<String, Operation>,
    writable: bool,
}
impl Local {
    pub fn open(directory: &Path, create: bool) -> Result<Self> {
        let storage = Storage::open(directory)?;
        let mut local = Self {
            storage,
            session: None,
            pending: BTreeMap::new(),
            writable: true,
        };
        if let Some(bytes) = local.storage.read()? {
            let mut saved: Saved = serde_json::from_slice(&bytes)
                .map_err(|_| "Saved identity is damaged; it was not replaced")?;
            require(saved.version == 1, "Unsupported saved identity version")?;
            local.session = Some(Session::new(Identity::from_payload(
                saved.identity.as_bytes(),
            )?));
            local.pending = std::mem::take(&mut saved.pending);
            for (network, operation) in &local.pending {
                require(
                    network == &operation.account.network
                        && ["signup", "lobby"].contains(&operation.step.as_str()),
                    "Invalid saved account recovery record",
                )?;
                operation.account.validate()?;
            }
        } else if create {
            local.session = Some(Session::new(Identity::generate()?));
            local.save()?;
        }
        Ok(local)
    }
    pub fn session(&self) -> Result<&Session> {
        self.session
            .as_ref()
            .ok_or("Create or import an identity first".into())
    }
    pub fn session_mut(&mut self) -> Result<&mut Session> {
        self.session
            .as_mut()
            .ok_or("Create or import an identity first".into())
    }
    fn save(&mut self) -> Result<()> {
        require(
            self.writable,
            "Storage failed; reconnect to reload the retained identity",
        )?;
        let saved = Saved {
            version: 1,
            identity: String::from_utf8(self.session()?.identity.payload()?.to_vec())
                .map_err(|_| "Invalid identity encoding")?,
            pending: self.pending.clone(),
        };
        let bytes =
            Zeroizing::new(serde_json::to_vec(&saved).map_err(|_| "Cannot encode saved identity")?);
        if let Err(error) = self.storage.save(&bytes) {
            self.writable = false;
            return Err(error);
        }
        Ok(())
    }
    pub fn import(&mut self, encoded: &str, password: &str) -> Result<()> {
        require(
            self.pending.is_empty(),
            "Resolve pending account setup before replacing this identity",
        )?;
        let identity = Identity::import(encoded, password)?;
        self.session = Some(Session::new(identity));
        self.save()
    }
    pub fn summary(&self) -> Value {
        self.session
            .as_ref()
            .map(|s| json!({"present":true,"public_key":identity::b64(&s.identity.public_key())}))
            .unwrap_or(json!({"present":false}))
    }
    pub fn accounts(&self) -> Result<Value> {
        let session = self.session()?;
        let network = session.network()?;
        Ok(json!(session
            .identity
            .accounts
            .iter()
            .filter(|a| a.network == network)
            .collect::<Vec<_>>()))
    }
    pub fn resume(&self) -> Result<Value> {
        let session = self.session()?;
        if let Some(operation) = self.pending.get(session.network()?) {
            let mut body = operation.body.clone();
            body["session_id"] = json!(session.session_id()?);
            body.as_object_mut().unwrap().remove("deadline_ms");
            if let Some(reference) = &operation.outcome_ref {
                body["outcome_ref"] = reference.clone();
            }
            Ok(json!({"path":"/api/goals/outcomes","body":body,"resolving":true}))
        } else {
            Ok(json!({"accounts":self.accounts()?}))
        }
    }
    pub fn refuse_submission(&mut self) -> Result<Value> {
        let network = self.session()?.network()?.to_string();
        require(
            self.pending.remove(&network).is_some(),
            "No submitted account operation",
        )?;
        self.save()?;
        Ok(Value::Null)
    }
    pub fn enroll(&mut self, catalogue: &Value, now: u64) -> Result<Value> {
        let session = self.session()?;
        let network = session.network()?.to_string();
        require(
            !self.pending.contains_key(&network),
            "Account setup is awaiting confirmation; check its outcome",
        )?;
        if let Some(account) = session
            .identity
            .accounts
            .iter()
            .find(|a| a.network == network)
            .cloned()
        {
            return self.provision(account, now);
        }
        require(
            catalogue["network_id"] == network,
            "System catalogue belongs to another network",
        )?;
        let services: Vec<_> = catalogue["ontologies"]
            .as_array()
            .ok_or("Invalid system catalogue")?
            .iter()
            .filter(|v| v["namespace"] == "quod:signup")
            .collect();
        require(
            services.len() == 1,
            "Open signup is not available on this network",
        )?;
        let account = Account {
            network,
            namespace: "quod:signup".into(),
            anchor: identity::text(services[0], "anchor")?.into(),
            instance_text: format!("signup({}).", terms::binary(&session.identity.public_key())),
        };
        let token = identity::random32()?;
        let goal = format!(
            "signup({},{},Account).",
            terms::binary(&token),
            terms::binary(format!("human:{}", identity::b64(&token)).as_bytes())
        );
        self.stage(account, "signup", &goal, now)
    }
    fn provision(&mut self, account: Account, now: u64) -> Result<Value> {
        let instance = terms::parse(account.instance_text.trim_end_matches('.'))?;
        require(instance.ground(), "Invalid account instance")?;
        let goal = format!(
            "provision_lobby({}), lobby_reference(Lobby).",
            instance.render()
        );
        self.stage(account, "lobby", &goal, now)
    }
    fn stage(&mut self, account: Account, step: &str, goal: &str, now: u64) -> Result<Value> {
        let body = self.session()?.goal(&account, goal, now, 1)?;
        self.pending.insert(
            account.network.clone(),
            Operation {
                account,
                step: step.into(),
                body: body.clone(),
                outcome_ref: None,
            },
        );
        // The key, learned account and replacement operation become durable together.
        self.save()?;
        Ok(json!({"path":"/api/goals/execute","body":body,"resolving":false}))
    }
    pub fn accept(&mut self, reply: &Value, resolving: bool, now: u64) -> Result<Value> {
        let network = self.session()?.network()?.to_string();
        let operation = self
            .pending
            .get(&network)
            .ok_or("No pending account operation")?
            .clone();
        if reply["result"] == "pending" || (resolving && reply["terminal"] == false) {
            if reply.get("group_id").is_some() {
                let mut reference = json!({"ns":operation.account.namespace});
                require(
                    reply["ns"] == operation.account.namespace,
                    "Pending group namespace mismatch",
                )?;
                for name in ["anchor", "coordinator", "coordinator_admission", "group_id"] {
                    let value = identity::text(reply, name)?;
                    require(
                        value.len() == 64
                            && value
                                .bytes()
                                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)),
                        "Invalid pending group reference",
                    )?;
                    reference[name] = json!(value);
                }
                let anchor = identity::bytes32(&operation.account.anchor)?
                    .iter()
                    .map(|b| format!("{b:02x}"))
                    .collect::<String>();
                require(
                    reference["anchor"] == anchor,
                    "Pending group anchor mismatch",
                )?;
                if operation.outcome_ref.as_ref() != Some(&reference) {
                    self.pending.get_mut(&network).unwrap().outcome_ref = Some(reference);
                    self.save()?;
                }
            }
            return Ok(json!({"pending":true}));
        }
        let committed = if resolving {
            require(
                reply["terminal"] == true
                    && ["operation_outcome", "group_outcome"]
                        .contains(&reply["result"].as_str().unwrap_or("")),
                "Unrecognized outcome; recovery record retained",
            )?;
            require(
                ["committed", "rejected", "aborted"]
                    .contains(&reply["status"].as_str().unwrap_or("")),
                "Unknown outcome status",
            )?;
            reply["status"] == "committed"
        } else {
            require(
                reply["result"] == "ok" || reply["result"] == "fail",
                "Unrecognized write response; recovery record retained",
            )?;
            reply["result"] == "ok"
        };
        if !committed {
            self.pending.remove(&network);
            self.save()?;
            return Err("Account setup was refused; the saved identity remains available".into());
        }
        if operation.step == "signup" {
            let term = terms::parse(binding(reply, "Account")?)?;
            let args = term.args("agent_instance_ref", 3)?;
            require(
                args[1].bytes()?.len() == 32 && args[2].ground(),
                "Invalid account reference",
            )?;
            let account = Account {
                network: network.clone(),
                namespace: args[0].text()?.into(),
                anchor: identity::b64(args[1].bytes()?),
                instance_text: format!("{}.", args[2].render()),
            };
            account.validate()?;
            let accounts = &mut self.session_mut()?.identity.accounts;
            accounts.retain(|a| a.network != network);
            accounts.push(account.clone());
            self.provision(account, now)
        } else {
            identity::lobby_goal(binding(reply, "Lobby")?)?;
            self.pending.remove(&network);
            self.save()?;
            Ok(json!({"accounts":self.accounts()?}))
        }
    }
}
fn binding<'a>(reply: &'a Value, name: &str) -> Result<&'a str> {
    let rows = reply["bindings"]
        .as_array()
        .ok_or("Missing account result bindings")?;
    require(rows.len() == 1, "Expected one account result")?;
    identity::text(&rows[0], name)
}
