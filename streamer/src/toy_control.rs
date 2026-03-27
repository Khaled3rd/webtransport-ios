use tokio::net::UnixDatagram;
use tokio::sync::mpsc;
use crate::encoder::Direction;

const TOY_SOCK: &str = "/tmp/toy.sock";

pub async fn run_toy_controller(mut cmd_rx: mpsc::Receiver<(Direction, u64)>) {
    let sock = match UnixDatagram::unbound() {
        Ok(s) => s,
        Err(e) => {
            tracing::error!("toy_control: create socket failed: {e}");
            return;
        }
    };

    tracing::info!("toy_control: ready, sending commands to {TOY_SOCK}");

    while let Some((dir, _sub_id)) = cmd_rx.recv().await {
        let d = match dir {
            Direction::Up    => "u",
            Direction::Down  => "d",
            Direction::Left  => "l",
            Direction::Right => "r",
            Direction::Stop  => "s",
        };
        let json = format!(r#"{{"d":"{d}"}}"#);
        if let Err(e) = sock.send_to(json.as_bytes(), TOY_SOCK).await {
            tracing::debug!("toy_control: send to {TOY_SOCK}: {e}");
        }
    }

    tracing::info!("toy_control: stopped");
}
