use crate::{require, terms::binary, Result};
use aes_gcm::{
    aead::{Aead, KeyInit, Payload},
    Aes256Gcm, Nonce,
};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use ed25519_dalek::{Signer, SigningKey};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::Sha256;
use zeroize::Zeroizing;

pub fn b64(bytes: &[u8]) -> String {
    URL_SAFE_NO_PAD.encode(bytes)
}
pub fn decode(s: &str) -> Result<Vec<u8>> {
    URL_SAFE_NO_PAD
        .decode(s)
        .map_err(|_| "invalid base64url".into())
}
pub fn bytes32(s: &str) -> Result<[u8; 32]> {
    decode(s)?
        .try_into()
        .map_err(|_| "expected 32 bytes".into())
}
pub fn text<'a>(v: &'a Value, key: &str) -> Result<&'a str> {
    v[key].as_str().ok_or_else(|| format!("missing {key}"))
}
pub fn integer(v: &Value, key: &str) -> Result<u64> {
    v[key]
        .as_u64()
        .or_else(|| v[key].as_str()?.parse().ok())
        .or_else(|| {
            v[key]
                .as_f64()
                .filter(|n| {
                    n.is_finite() && *n >= 0. && n.fract() == 0. && *n <= 9_007_199_254_740_991.
                })
                .map(|n| n as u64)
        })
        .ok_or_else(|| format!("invalid {key}"))
}
pub fn random32() -> Result<[u8; 32]> {
    let mut out = [0; 32];
    getrandom::getrandom(&mut out).map_err(|_| "random source unavailable")?;
    Ok(out)
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Account {
    pub network: String,
    pub namespace: String,
    pub anchor: String,
    #[serde(rename = "instanceText")]
    pub instance_text: String,
}
impl Account {
    pub fn validate(&self) -> Result<()> {
        bytes32(&self.network)?;
        bytes32(&self.anchor)?;
        require(
            !self.namespace.is_empty() && self.namespace.len() <= 255,
            "invalid account namespace",
        )?;
        require(
            !self.instance_text.is_empty() && self.instance_text.len() <= 131_072,
            "invalid account instance",
        )
    }
}

pub struct Identity {
    key: SigningKey,
    pub accounts: Vec<Account>,
}
impl Identity {
    pub fn import(encoded: &str, passphrase: &str) -> Result<Self> {
        require(encoded.len() <= 16_384, "saved identity is too large")?;
        let bundle: Value = serde_json::from_str(encoded).map_err(|_| "invalid identity JSON")?;
        require(
            bundle["version"] == 1
                && bundle["kdf"] == "PBKDF2-SHA-256"
                && bundle["iterations"] == 600_000
                && bundle["cipher"] == "AES-256-GCM",
            "unsupported identity format",
        )?;
        let salt = decode(text(&bundle, "salt")?)?;
        let iv = decode(text(&bundle, "iv")?)?;
        require(
            iv.len() == 12 && salt.len() == 16,
            "invalid identity salt or IV",
        )?;
        let mut wrapping = Zeroizing::new([0u8; 32]);
        pbkdf2::pbkdf2_hmac::<Sha256>(passphrase.as_bytes(), &salt, 600_000, &mut *wrapping);
        let cipher = Aes256Gcm::new_from_slice(&*wrapping).map_err(|_| "invalid wrapping key")?;
        let ciphertext = decode(text(&bundle, "ciphertext")?)?;
        let plaintext = Zeroizing::new(
            cipher
                .decrypt(
                    Nonce::from_slice(&iv),
                    Payload {
                        msg: &ciphertext,
                        aad: b"quod-client-key-v1",
                    },
                )
                .map_err(|_| "wrong passphrase or damaged identity")?,
        );
        Self::from_payload(&plaintext)
    }
    pub(crate) fn from_payload(plaintext: &[u8]) -> Result<Self> {
        // Typed secrets avoid leaving a second decrypted JWK in a generic JSON tree.
        #[derive(Deserialize)]
        struct Jwk {
            kty: String,
            crv: String,
            d: String,
            x: String,
        }
        impl Drop for Jwk {
            fn drop(&mut self) {
                zeroize::Zeroize::zeroize(&mut self.d);
            }
        }
        #[derive(Deserialize)]
        struct Saved {
            private_jwk: Jwk,
            #[serde(default)]
            accounts: Vec<Account>,
        }
        let mut saved: Saved =
            serde_json::from_slice(plaintext).map_err(|_| "damaged identity payload")?;
        require(
            saved.private_jwk.kty == "OKP" && saved.private_jwk.crv == "Ed25519",
            "unsupported signing key",
        )?;
        let secret = Zeroizing::new(bytes32(&saved.private_jwk.d)?);
        let key = SigningKey::from_bytes(&secret);
        require(
            key.verifying_key().as_bytes() == &bytes32(&saved.private_jwk.x)?,
            "inconsistent signing key",
        )?;
        let mut networks = std::collections::HashSet::new();
        for account in &mut saved.accounts {
            account.namespace = account.namespace.trim().into();
            account.instance_text = account.instance_text.trim().into();
            account.anchor = account.anchor.trim().into();
            account.validate()?;
            require(
                networks.insert(account.network.clone()),
                "duplicate network account",
            )?;
        }
        Ok(Self {
            key,
            accounts: saved.accounts,
        })
    }
    pub fn generate() -> Result<Self> {
        let seed = Zeroizing::new(random32()?);
        Ok(Self {
            key: SigningKey::from_bytes(&seed),
            accounts: Vec::new(),
        })
    }
    pub(crate) fn payload(&self) -> Result<Zeroizing<Vec<u8>>> {
        #[derive(Serialize)]
        struct Jwk {
            kty: &'static str,
            crv: &'static str,
            d: String,
            x: String,
            ext: bool,
            key_ops: [&'static str; 1],
        }
        impl Drop for Jwk {
            fn drop(&mut self) {
                zeroize::Zeroize::zeroize(&mut self.d);
            }
        }
        #[derive(Serialize)]
        struct Saved<'a> {
            private_jwk: Jwk,
            accounts: &'a [Account],
        }
        let seed = Zeroizing::new(self.key.to_bytes());
        let saved = Saved {
            private_jwk: Jwk {
                kty: "OKP",
                crv: "Ed25519",
                d: b64(&*seed),
                x: b64(&self.public_key()),
                ext: true,
                key_ops: ["sign"],
            },
            accounts: &self.accounts,
        };
        serde_json::to_vec(&saved)
            .map(Zeroizing::new)
            .map_err(|_| "Cannot encode identity".into())
    }
    pub fn export(&self, passphrase: &str) -> Result<String> {
        require(
            passphrase.encode_utf16().count() >= 12,
            "Use a passphrase of at least 12 characters",
        )?;
        let salt = random32()?;
        let iv = random32()?;
        let mut wrapping = Zeroizing::new([0u8; 32]);
        pbkdf2::pbkdf2_hmac::<Sha256>(passphrase.as_bytes(), &salt[..16], 600_000, &mut *wrapping);
        let cipher = Aes256Gcm::new_from_slice(&*wrapping).map_err(|_| "invalid wrapping key")?;
        let ciphertext = cipher
            .encrypt(
                Nonce::from_slice(&iv[..12]),
                Payload {
                    msg: &self.payload()?,
                    aad: b"quod-client-key-v1",
                },
            )
            .map_err(|_| "Cannot encrypt backup")?;
        let encoded = json!({"version":1,"kdf":"PBKDF2-SHA-256","iterations":600_000,"salt":b64(&salt[..16]),"cipher":"AES-256-GCM","iv":b64(&iv[..12]),"ciphertext":b64(&ciphertext),"public_key":b64(&self.public_key())}).to_string();
        require(
            encoded.len() <= 16_384,
            "Identity metadata exceeds portable backup size",
        )?;
        Ok(encoded)
    }
    pub fn public_key(&self) -> [u8; 32] {
        *self.key.verifying_key().as_bytes()
    }
    pub fn sign(&self, bytes: &[u8]) -> String {
        b64(&self.key.sign(bytes).to_bytes())
    }
    pub fn challenge_signature(&self, challenge: &Value, nonce: &[u8; 32]) -> Result<String> {
        Ok(self.sign(&challenge_bytes(challenge, &self.public_key(), nonce)?))
    }
}

pub fn challenge_bytes(challenge: &Value, public: &[u8; 32], nonce: &[u8; 32]) -> Result<Vec<u8>> {
    let mut out = b"quod.agent.challenge.v1\0".to_vec();
    for name in ["network_id", "node_key"] {
        out.extend(bytes32(text(challenge, name)?)?);
    }
    let challenge_id = decode(text(challenge, "challenge_id")?)?;
    require(challenge_id.len() == 16, "expected 16-byte challenge ID")?;
    out.extend(challenge_id);
    out.extend(public);
    out.extend(nonce);
    out.extend(bytes32(text(challenge, "server_nonce")?)?);
    out.extend(integer(challenge, "expires_ms")?.to_be_bytes());
    Ok(out)
}

pub fn read_request(
    public: &[u8; 32],
    account: &Account,
    operation: &[u8; 32],
    deadline: u64,
    goal: &str,
) -> Result<Vec<u8>> {
    goal_request(public, account, operation, deadline, goal, 0)
}

pub fn goal_request(
    public: &[u8; 32],
    account: &Account,
    operation: &[u8; 32],
    deadline: u64,
    goal: &str,
    mode: u8,
) -> Result<Vec<u8>> {
    require(mode <= 1, "unsupported native goal mode")?;
    account.validate()?;
    require(
        deadline > 0 && !goal.is_empty() && goal.len() <= 131_072,
        "invalid signed read",
    )?;
    let mut out = b"quod.agent.goal.v1\0".to_vec();
    out.extend(bytes32(&account.network)?);
    out.extend(public);
    out.extend(operation);
    out.extend((account.namespace.len() as u16).to_be_bytes());
    out.extend(account.namespace.as_bytes());
    out.extend(bytes32(&account.anchor)?);
    out.extend((account.instance_text.len() as u32).to_be_bytes());
    out.extend(account.instance_text.as_bytes());
    out.extend([mode, 3]); // frozen parser version
    out.extend(deadline.to_be_bytes());
    out.extend((goal.len() as u32).to_be_bytes());
    out.extend(goal.as_bytes());
    Ok(out)
}

/// Client session state; no domain write entry point is exposed.
pub struct Session {
    pub identity: Identity,
    nonce: Option<[u8; 32]>,
    network: Option<String>,
    session: Option<(String, u64)>,
}
impl Session {
    pub fn new(identity: Identity) -> Self {
        Self {
            identity,
            nonce: None,
            network: None,
            session: None,
        }
    }
    pub fn end(&mut self) {
        self.session = None;
        self.network = None;
        self.nonce = None;
    }
    pub fn begin(&mut self) -> Result<Value> {
        self.end();
        let nonce = random32()?;
        self.nonce = Some(nonce);
        Ok(json!({"public_key":b64(&self.identity.public_key()), "client_nonce":b64(&nonce)}))
    }
    pub fn challenge(&mut self, value: &Value, now: u64) -> Result<Value> {
        let nonce = self.nonce.take().ok_or("no pending challenge")?;
        require(
            integer(value, "expires_ms")? > now,
            "authentication challenge expired",
        )?;
        let signature = self.identity.challenge_signature(value, &nonce)?;
        self.network = Some(text(value, "network_id")?.into());
        Ok(json!({"challenge_id":text(value,"challenge_id")?,"signature":signature}))
    }
    pub fn complete(&mut self, value: &Value, now: u64) -> Result<Vec<Account>> {
        let network = self.network.as_ref().ok_or("no authenticated network")?;
        let expiry = integer(value, "expires_ms")?;
        let id = text(value, "session_id")?;
        require(expiry > now && !id.is_empty(), "invalid or expired session")?;
        self.session = Some((id.into(), expiry));
        Ok(self
            .identity
            .accounts
            .iter()
            .filter(|a| &a.network == network)
            .cloned()
            .collect())
    }
    pub fn network(&self) -> Result<&str> {
        self.network.as_deref().ok_or("Not authenticated".into())
    }
    pub fn session_id(&self) -> Result<&str> {
        self.session
            .as_ref()
            .map(|s| s.0.as_str())
            .ok_or("Not authenticated".into())
    }
    pub fn read(&self, account: &Account, goal: &str, now: u64) -> Result<Value> {
        self.goal(account, goal, now, 0)
    }
    pub(crate) fn goal(&self, account: &Account, goal: &str, now: u64, mode: u8) -> Result<Value> {
        require(
            self.network.as_ref() == Some(&account.network),
            "account belongs to another network",
        )?;
        let (id, expiry) = self.session.as_ref().ok_or("not authenticated")?;
        let deadline = (*expiry).min(now.checked_add(30_000).ok_or("clock overflow")?);
        require(deadline > now, "session expired")?;
        let request = goal_request(
            &self.identity.public_key(),
            account,
            &random32()?,
            deadline,
            goal,
            mode,
        )?;
        Ok(
            json!({"session_id":id,"request":b64(&request),"signature":self.identity.sign(&request),"deadline_ms":deadline.to_string()}),
        )
    }
}

pub fn lobby_goal(binding: &str) -> Result<String> {
    let term = crate::terms::parse(binding)?;
    let a = term.args("ontology_ref", 2)?;
    let ns = a[0].text()?;
    let anchor = a[1].bytes()?;
    require(anchor.len() == 32, "invalid lobby anchor")?;
    Ok(format!("{} :: (current_ontology_identity({},{}), ','(lobby_modes(Modes),lobby_view(playing,Scene))).",
        binary(ns.as_bytes()), binary(ns.as_bytes()), binary(anchor)))
}
