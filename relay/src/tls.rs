use std::path::Path;
use crate::config::TlsConfig;
use crate::error::RelayError;
use sha2::{Sha256, Digest};

pub struct TlsState {
    pub cert_pem: String,
    pub key_pem: String,
    pub fingerprint: String,
}

pub fn setup_tls(config: &TlsConfig) -> Result<TlsState, RelayError> {
    let cert_path = Path::new(&config.cert_path);
    let key_path = Path::new(&config.key_path);

    let (cert_pem, key_pem) = if cert_path.exists() && key_path.exists() {
        tracing::info!("Loading existing TLS cert from {}", config.cert_path);
        let cert = std::fs::read_to_string(cert_path)
            .map_err(|e| RelayError::Tls(format!("Failed to read cert: {e}")))?;
        let key = std::fs::read_to_string(key_path)
            .map_err(|e| RelayError::Tls(format!("Failed to read key: {e}")))?;
        (cert, key)
    } else {
        tracing::info!("Generating self-signed TLS cert (validity: {} days)", config.cert_validity_days);

        if let Some(parent) = cert_path.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|e| RelayError::Tls(format!("Failed to create cert dir: {e}")))?;
        }

        let validity_days = config.cert_validity_days;
        let cert = rcgen::generate_simple_self_signed(vec!["localhost".to_string()])
            .map_err(|e| RelayError::Tls(format!("Failed to generate cert: {e}")))?;

        let cert_pem = cert.cert.pem();
        let key_pem = cert.key_pair.serialize_pem();

        std::fs::write(cert_path, &cert_pem)
            .map_err(|e| RelayError::Tls(format!("Failed to write cert: {e}")))?;
        std::fs::write(key_path, &key_pem)
            .map_err(|e| RelayError::Tls(format!("Failed to write key: {e}")))?;

        tracing::info!("TLS cert written to {}", config.cert_path);
        (cert_pem, key_pem)
    };

    // Compute SHA-256 fingerprint from DER-encoded cert
    let fingerprint = compute_fingerprint(&cert_pem)?;
    tracing::info!("TLS cert fingerprint (SHA-256): {}", fingerprint);

    Ok(TlsState { cert_pem, key_pem, fingerprint })
}

fn compute_fingerprint(cert_pem: &str) -> Result<String, RelayError> {
    // Parse PEM to get DER bytes
    let pem_data = pem::parse(cert_pem)
        .map_err(|e| RelayError::Tls(format!("Failed to parse PEM: {e}")))?;
    let der_bytes = pem_data.contents();

    let mut hasher = Sha256::new();
    hasher.update(der_bytes);
    let hash = hasher.finalize();

    let hex_parts: Vec<String> = hash.iter().map(|b| format!("{:02X}", b)).collect();
    Ok(hex_parts.join(":"))
}
