use nikodesk_wol_agent::{handle, Config};
use std::{env, fs, io, net::TcpListener, path::Path};

fn run() -> io::Result<()> {
    let args: Vec<_> = env::args_os().skip(1).collect();
    if args.len() != 2 || args[0] != "--config" {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "Usage: nikodesk-wol-agent --config <local-config.json>",
        ));
    }
    let path = Path::new(&args[1]);
    if fs::metadata(path)?.len() > 65536 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "Configuration exceeds limit",
        ));
    }
    let config: Config = serde_json::from_slice(&fs::read(path)?).map_err(|_| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            "Invalid wake-agent configuration",
        )
    })?;
    config.validate()?;
    let listener = TcpListener::bind(config.listen)?;
    println!("NikoDesk wake agent listening on {}. Reach it only through an authorized encrypted tunnel.", listener.local_addr()?);
    for incoming in listener.incoming() {
        match incoming {
            Ok(mut stream) => {
                if handle(&mut stream, &config).is_err() {
                    eprintln!("Wake request not confirmed");
                }
            }
            Err(_) => eprintln!("Wake-agent connection failed"),
        }
    }
    Ok(())
}
fn main() {
    if let Err(error) = run() {
        eprintln!("NikoDesk wake agent: {error}");
        std::process::exit(1);
    }
}
