//! The account server's calls a host makes (docs/hosts.md, "Account server"), and the
//! `login` and `logout` subcommands.

use std::time::Duration;

use serde_json::{json, Value};

use crate::config::{self, Config};

/// A call that the server answered with an error status, or that never reached it (status 0).
#[derive(Debug)]
pub struct Failed {
    pub status: u16,
    pub code: String,
}

impl std::fmt::Display for Failed {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        match self.status {
            0 => write!(f, "could not reach the account server ({})", self.code),
            status => write!(f, "the account server said {status} {}", self.code),
        }
    }
}

fn failed(error: ureq::Error) -> Failed {
    match error {
        ureq::Error::Status(status, reply) => {
            let body: Value = reply.into_json().unwrap_or(Value::Null);
            Failed { status, code: body["error"].as_str().unwrap_or("").to_string() }
        }
        // The transport's kind only: never the request, which carries the token.
        ureq::Error::Transport(transport) => Failed { status: 0, code: transport.kind().to_string() },
    }
}

pub struct Api {
    server: String,
    agent: ureq::Agent,
}

impl Api {
    pub fn new(server: &str) -> Api {
        let agent = ureq::AgentBuilder::new().timeout_connect(Duration::from_secs(15)).timeout(Duration::from_secs(30)).build();
        Api { server: server.to_string(), agent }
    }

    pub fn call(&self, method: &str, path: &str, token: Option<&str>, body: Option<Value>) -> Result<Value, Failed> {
        let mut request = self.agent.request(method, &format!("{}{path}", self.server));
        if let Some(token) = token {
            request = request.set("Authorization", &format!("Bearer {token}"));
        }
        let reply = match body {
            Some(body) => request.send_json(body),
            None => request.call(),
        };
        reply.map(|reply| reply.into_json().unwrap_or(Value::Null)).map_err(failed)
    }

    /// A POST of `body` whose reply is bytes, at most `limit` of them.
    pub fn post_bytes(&self, path: &str, token: &str, body: Value, limit: u64) -> Result<Vec<u8>, Failed> {
        let reply = self.agent.post(&format!("{}{path}", self.server)).set("Authorization", &format!("Bearer {token}")).send_json(body).map_err(failed)?;
        crate::vault::read_limited(reply.into_reader(), limit).map_err(|error| Failed { status: 0, code: error.kind().to_string() })
    }

    /// Registers this host, or refreshes its name, platform and version, and where boards may
    /// reach it directly (none while its daemon isn't running).
    pub fn register(&self, config: &Config, token: &str, addresses: &[String]) -> Result<(), Failed> {
        let body = json!({
            "name": config.name,
            "platform": format!("{}-{}", std::env::consts::OS, std::env::consts::ARCH),
            "version": env!("CARGO_PKG_VERSION"),
            "public_key": config.public_key().map_err(|code| Failed { status: 0, code })?,
            "addresses": addresses,
        });
        self.call("PUT", &format!("/v1/hosts/{}", config.id), Some(token), Some(body)).map(|_| ())
    }
}

/// Runs the device flow to its end: the token and the account's login. `say` shows the user
/// what to do; `wait` sleeps between polls.
/// `host` is this host's id: the session it gets serves this host only.
pub fn device_flow(api: &Api, host: &str, say: &mut dyn FnMut(&str), wait: &mut dyn FnMut(Duration)) -> Result<(String, String), String> {
    let device = api.call("POST", "/v1/login/device", None, None).map_err(|failed| failed.to_string())?;
    let (Some(device_code), Some(user_code), Some(uri)) = (device["device_code"].as_str(), device["user_code"].as_str(), device["verification_uri"].as_str()) else {
        return Err("the account server's reply made no sense".into());
    };
    let mut interval = device["interval"].as_u64().unwrap_or(5).max(1);
    let mut left = device["expires_in"].as_u64().unwrap_or(900);
    say(&format!("To sign in, open this page on any device:\n\n    {uri}\n\nand enter the code:\n\n    {user_code}\n\nWaiting for you to confirm..."));

    while left > 0 {
        wait(Duration::from_secs(interval));
        left = left.saturating_sub(interval);
        let reply = match api.call("POST", "/v1/login/poll", None, Some(json!({ "device_code": device_code, "host": host }))) {
            Ok(reply) => reply,
            // The network blinked: the code is still good, ask again.
            Err(Failed { status: 0, .. }) => continue,
            Err(failed) => return Err(failed.to_string()),
        };
        match reply["status"].as_str() {
            Some("pending") => {}
            // The reply carries no new interval: 5 seconds slower, as GitHub asks.
            Some("slow_down") => interval += 5,
            Some("denied") => return Err("The sign-in was refused.".into()),
            Some("expired") => break,
            _ => match (reply["token"].as_str(), reply["account"]["login"].as_str()) {
                (Some(token), Some(login)) => return Ok((token.to_string(), login.to_string())),
                _ => return Err("the account server's reply made no sense".into()),
            },
        }
    }
    Err("The code expired before it was confirmed. Run `agentboard login` again.".into())
}

/// `agentboard login`: signs this machine in to the account and registers it as a host.
pub fn login() -> Result<(), String> {
    let folder = config::data_folder();
    let mut config = Config::load(&folder)?;
    let api = Api::new(&config::server());
    let (token, login) = device_flow(&api, &config.id.to_string(), &mut |text| println!("{text}"), &mut std::thread::sleep)?;
    config.token = Some(token);
    config.login = Some(login);
    // Saved before registering: a failed registration is retried by the daemon, a lost token isn't.
    config.save(&folder)?;
    println!("Signed in as {}.", config.login.as_deref().unwrap_or(""));
    // A running daemon sees the new login in host.json and registers again, with its addresses.
    api.register(&config, config.token.as_deref().unwrap_or(""), &[]).map_err(|failed| format!("Could not register this host: {failed}"))?;
    println!("This host is registered as \"{}\".", config.name);
    Ok(())
}

/// `agentboard logout`: forgets this host on the account, then the token on both sides, and
/// every board this host trusted, and the vault's key (what the vault wrote stays).
pub fn logout() -> Result<(), String> {
    let folder = config::data_folder();
    crate::boards::clear(&folder)?;
    crate::vault::forget(&folder);
    let mut config = Config::load(&folder)?;
    let Some(token) = config.token.take().map(zeroize::Zeroizing::new) else {
        println!("Not signed in.");
        return Ok(());
    };
    let api = Api::new(&config::server());
    // The host first: forgetting it needs the token that logout then ends.
    let calls = [("DELETE", format!("/v1/hosts/{}", config.id)), ("POST", "/v1/logout".to_string())];
    for (method, path) in calls {
        match api.call(method, &path, Some(&token), None) {
            // Already gone on the server's side.
            Ok(_) | Err(Failed { status: 401 | 404, .. }) => {}
            Err(failed) => eprintln!("warning: {method} {path}: {failed}"),
        }
    }
    config.login = None;
    config.save(&folder)?;
    println!("Signed out.");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::http_stub;

    const DEVICE: &str = r#"{"device_code":"device-1","user_code":"ABCD-1234","verification_uri":"https://github.com/login/device","interval":5,"expires_in":900}"#;

    fn run(replies: &[(u16, &str)]) -> (Result<(String, String), String>, Vec<u64>, String, Vec<String>) {
        let (server, requests) = http_stub(replies.iter().map(|(status, body)| (*status, body.to_string())).collect());
        let (mut waits, mut said) = (Vec::new(), String::new());
        let result = device_flow(&Api::new(&server), "0f8fad5b-d9cb-469f-a165-70867728950e", &mut |text| said.push_str(text), &mut |time| waits.push(time.as_secs()));
        let requests = requests.try_iter().collect();
        (result, waits, said, requests)
    }

    #[test]
    fn polls_through_pending_and_slow_down_to_a_token() {
        let (result, waits, said, requests) = run(&[
            (200, DEVICE),
            (200, r#"{"status":"pending"}"#),
            (200, r#"{"status":"slow_down"}"#),
            (200, r#"{"status":"pending"}"#),
            (200, r#"{"token":"tok","account":{"id":1,"login":"octo","name":null,"avatar_url":null}}"#),
        ]);
        assert_eq!(result, Ok(("tok".to_string(), "octo".to_string())));
        assert_eq!(waits, [5, 5, 10, 10]);
        assert!(said.contains("ABCD-1234") && said.contains("https://github.com/login/device"));
        assert!(requests[0].starts_with("POST /v1/login/device "));
        assert!(requests[1].starts_with("POST /v1/login/poll ") && requests[1].ends_with(r#"{"device_code":"device-1","host":"0f8fad5b-d9cb-469f-a165-70867728950e"}"#));
        assert_eq!(requests.len(), 5);
    }

    #[test]
    fn stops_when_denied() {
        let (result, waits, ..) = run(&[(200, DEVICE), (200, r#"{"status":"pending"}"#), (200, r#"{"status":"denied"}"#), (200, r#"{"token":"never"}"#)]);
        assert!(result.unwrap_err().contains("refused"));
        assert_eq!(waits, [5, 5]);
    }

    #[test]
    fn stops_when_expired_or_out_of_time() {
        let (result, waits, ..) = run(&[(200, DEVICE), (200, r#"{"status":"expired"}"#)]);
        assert!(result.unwrap_err().contains("expired"));
        assert_eq!(waits, [5]);

        let short = DEVICE.replace("900", "12");
        let (result, waits, _, requests) = run(&[(200, &short), (200, r#"{"status":"pending"}"#), (200, r#"{"status":"pending"}"#), (200, r#"{"status":"pending"}"#), (200, r#"{"token":"late"}"#)]);
        assert!(result.unwrap_err().contains("expired"));
        assert_eq!((waits, requests.len()), (vec![5, 5, 5], 4));
    }

    #[test]
    fn stops_on_a_server_error_with_its_code() {
        let (result, ..) = run(&[(429, r#"{"error":"rate_limited"}"#)]);
        assert!(result.unwrap_err().contains("429 rate_limited"));
    }
}
