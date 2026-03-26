mod config;
mod error;
mod fanout;
mod publisher;
mod subscriber;
mod tls;

use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::Mutex;
use wtransport::{Endpoint, ServerConfig, Identity};
use axum::{routing::get, Router, Json};
use serde_json::json;
use tracing_subscriber::EnvFilter;

use crate::config::Config;
use crate::error::RelayError;
use crate::fanout::create_fanout;
use crate::publisher::{handle_publisher, PublisherState};
use crate::subscriber::{handle_subscriber, SubscriberRegistry};

#[tokio::main(flavor = "multi_thread", worker_threads = 4)]
async fn main() {
    rustls::crypto::ring::default_provider()
        .install_default()
        .expect("Failed to install crypto provider");

    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::from_default_env())
        .init();

    let config_path = parse_config_arg();

    let config = match Config::load(&config_path) {
        Ok(c) => c,
        Err(e) => {
            tracing::error!("Failed to load config: {e}");
            std::process::exit(1);
        }
    };

    if let Err(e) = run(config).await {
        tracing::error!("Fatal error: {e}");
        std::process::exit(1);
    }
}

fn parse_config_arg() -> String {
    let args: Vec<String> = std::env::args().collect();
    let mut i = 1;
    while i < args.len() {
        if args[i] == "--config" && i + 1 < args.len() {
            return args[i + 1].clone();
        }
        i += 1;
    }
    "config.toml".to_string()
}

async fn run(config: Config) -> Result<(), RelayError> {
    // Setup TLS
    let _tls = tls::setup_tls(&config.tls)?;

    // Create shared state
    let broadcast_tx = create_fanout();
    let publisher_state = Arc::new(PublisherState::new());
    let subscriber_registry = Arc::new(SubscriberRegistry::new());

    let publisher_connected = publisher_state.connected.clone();
    let sub_registry_health = subscriber_registry.clone();
    let pub_connected_health = publisher_state.connected.clone();

    // Spawn health server
    let health_addr: SocketAddr = format!("0.0.0.0:{}", 4434).parse()
        .map_err(|e: std::net::AddrParseError| RelayError::Config(e.to_string()))?;

    tokio::spawn(async move {
        let app = Router::new().route("/health", get({
            let sub_reg = sub_registry_health.clone();
            let pub_conn = pub_connected_health.clone();
            move || {
                let sub_reg = sub_reg.clone();
                let pub_conn = pub_conn.clone();
                async move {
                    let subscribers = sub_reg.subscriber_count();
                    let publisher_connected = *pub_conn.lock().await;
                    Json(json!({
                        "status": "ok",
                        "subscribers": subscribers,
                        "publisher_connected": publisher_connected
                    }))
                }
            }
        }));

        let listener = tokio::net::TcpListener::bind(health_addr).await
            .expect("Failed to bind health server");
        tracing::info!("Health server listening on {health_addr}");
        axum::serve(listener, app).await
            .expect("Health server failed");
    });

    // Build WebTransport server config
    let identity = Identity::load_pemfiles(&config.tls.cert_path, &config.tls.key_path)
        .await
        .map_err(|e| RelayError::Tls(format!("Failed to load identity: {e}")))?;

    let bind_addr: SocketAddr = config.server.bind.parse()
        .map_err(|e: std::net::AddrParseError| RelayError::Config(e.to_string()))?;

    let server_config = ServerConfig::builder()
        .with_bind_address(bind_addr)
        .with_identity(identity)
        .max_idle_timeout(Some(Duration::from_secs(5)))
        .map_err(|e| RelayError::Config(format!("Invalid idle timeout: {e}")))?
        .keep_alive_interval(Some(Duration::from_secs(1)))
        .build();

    let endpoint = Endpoint::server(server_config)
        .map_err(|e| RelayError::Transport(format!("Failed to create endpoint: {e}")))?;

    tracing::info!("WebTransport relay listening on {}", config.server.bind);

    loop {
        // accept() returns IncomingSession directly (not Option)
        let incoming = endpoint.accept().await;

        let config = config.clone();
        let broadcast_tx = broadcast_tx.clone();
        let publisher_connected = publisher_connected.clone();
        let subscriber_registry = subscriber_registry.clone();

        tokio::spawn(async move {
            let session_request: wtransport::endpoint::SessionRequest = match incoming.await {
                Ok(req) => req,
                Err(e) => {
                    tracing::debug!("Failed to receive session request: {e}");
                    return;
                }
            };

            let path = session_request.path().to_string();
            // headers() returns &HashMap<String, String>
            let auth_header = session_request
                .headers()
                .get("authorization")
                .map(|s| s.as_str())
                .unwrap_or("")
                .to_string();

            tracing::debug!("Incoming session: path={path}, auth_len={}", auth_header.len());

            if path == config.server.publish_path {
                let expected = format!("Bearer {}", config.server.publish_token);
                if auth_header != expected {
                    tracing::warn!("Publisher rejected: invalid token");
                    let _ = session_request.not_found().await;
                    return;
                }

                {
                    let connected = publisher_connected.lock().await;
                    if *connected {
                        tracing::warn!("Publisher rejected: already connected");
                        let _ = session_request.not_found().await;
                        return;
                    }
                }

                let session = match session_request.accept().await {
                    Ok(s) => s,
                    Err(e) => {
                        tracing::warn!("Failed to accept publisher session: {e}");
                        return;
                    }
                };

                if let Err(e) = handle_publisher(
                    session,
                    broadcast_tx,
                    publisher_connected,
                    config.server.publish_token,
                ).await {
                    tracing::warn!("Publisher error: {e}");
                }

            } else if path == config.server.subscribe_path {
                let current = subscriber_registry.subscriber_count();
                if current >= config.server.max_subscribers {
                    tracing::warn!("Subscriber rejected: max reached");
                    let _ = session_request.not_found().await;
                    return;
                }

                let session = match session_request.accept().await {
                    Ok(s) => s,
                    Err(e) => {
                        tracing::warn!("Failed to accept subscriber session: {e}");
                        return;
                    }
                };

                if let Err(e) = handle_subscriber(
                    session,
                    broadcast_tx,
                    subscriber_registry,
                    config.server.max_subscribers,
                ).await {
                    tracing::debug!("Subscriber error: {e}");
                }
            } else {
                tracing::warn!("Unknown path: {path}");
                let _ = session_request.not_found().await;
            }
        });
    }

    Ok(())
}
