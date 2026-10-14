//! Quod client values and codecs. No renderer, transport, or domain authority.
pub type Result<T> = std::result::Result<T, String>;
pub mod glb;
pub mod identity;
pub mod local;
pub mod scene;
mod storage;
pub mod terms;

pub fn require(ok: bool, reason: &str) -> Result<()> {
    if ok {
        Ok(())
    } else {
        Err(reason.into())
    }
}
