//! `agentboard <command>`: one binary for everything the board runs outside itself.

mod core;

fn main() {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    match arguments.first().map(String::as_str) {
        Some("core") => core::run(&arguments[1..]),
        Some("host") => core::host(),
        Some("data-folder") => println!("{}", runtime::data_folder::url().display()),
        Some("login") => finish(host::login().and_then(|()| host::install_service()).and_then(|()| host::first_board())),
        Some("logout") => finish(host::logout()),
        Some("setup") => finish(host::setup()),
        Some("status") => finish(host::status()),
        Some("vault") => match arguments.get(1).map(String::as_str) {
            Some("pull") => finish(host::vault_pull()),
            Some("status") => finish(host::vault_status()),
            _ => {
                eprintln!("{}", core::USAGE);
                std::process::exit(2);
            }
        },
        Some("boards") => finish(host::boards()),
        // A fingerprint's groups may come as separate arguments.
        Some("trust") => finish(host::trust(&arguments[1..].concat())),
        Some("untrust") => finish(host::untrust(&arguments[1..].concat())),
        Some("service") if arguments.get(1).map(String::as_str) == Some("remove") => finish(host::uninstall_service()),
        Some("service") => finish(host::install_service()),
        _ => {
            eprintln!("{}", core::USAGE);
            std::process::exit(2);
        }
    }
}

fn finish(result: Result<(), String>) {
    if let Err(message) = result {
        eprintln!("{message}");
        std::process::exit(1);
    }
}
