use crate::{CloudConfig, CoreError};
use std::time::Duration;
use zeroize::Zeroizing;

/// Ping `{base_url}/models` with the caller's key. Same semantics as the
/// desktop `verify_provider` command has had since M2.
pub(crate) async fn verify_at(cfg: &CloudConfig, base_url: &str) -> Result<(), CoreError> {
    let key = Zeroizing::new(cfg.api_key.clone());
    let unreachable = || CoreError::Network { provider: cfg.provider.id().to_owned() };

    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(10))
        .build()
        .map_err(|_| unreachable())?;

    let resp = client
        .get(format!("{}/models", base_url))
        .bearer_auth(key.as_str())
        .send()
        .await
        .map_err(|_| unreachable())?;

    match CoreError::from_status(resp.status().as_u16()) {
        None => Ok(()),
        Some(e) => Err(e),
    }
}
