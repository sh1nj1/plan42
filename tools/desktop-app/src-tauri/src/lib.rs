//! Collavre Desktop shell.
//!
//! Responsibilities (and nothing else — the UI is the server-rendered Rails app):
//!   1. Pick a free loopback port.
//!   2. Spawn the bundled Rails sidecar (`bin/desktop-server`) pointed at a
//!      writable data dir under the OS app-data location.
//!   3. Health-gate `GET /up` until the server is ready.
//!   4. Show the app in a native webview at `http://127.0.0.1:<port>`.
//!   5. Gracefully stop the sidecar (and its process group) on quit.

use std::fs::{self, File};
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use tauri::{Manager, RunEvent, WebviewUrl, WebviewWindowBuilder};

/// Holds the sidecar child so we can stop it on exit.
struct Sidecar(Mutex<Option<Child>>);

/// Bind to port 0 to let the OS hand us a free port, then release it. There is a
/// tiny TOCTOU window before the sidecar grabs it, acceptable for a loopback
/// single-user app.
fn free_port() -> u16 {
    TcpListener::bind("127.0.0.1:0")
        .expect("bind ephemeral port")
        .local_addr()
        .expect("local addr")
        .port()
}

/// Locate the bundled Rails app root. In a packaged `.app` the launcher and app
/// tree live under `Contents/Resources/app`; in `tauri dev` they're resolved
/// relative to the repo so the shell can be exercised without packaging.
fn app_root(app: &tauri::AppHandle) -> PathBuf {
    if let Ok(res) = app.path().resource_dir() {
        let bundled = res.join("app");
        if bundled.join("bin/desktop-server").exists() {
            return bundled;
        }
    }
    // Dev fallback: tools/desktop-app/src-tauri -> repo root (../../..).
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../..")
        .canonicalize()
        .expect("resolve repo root")
}

/// Per-OS writable data directory for DBs, blobs, secrets, and logs.
fn data_dir(app: &tauri::AppHandle) -> PathBuf {
    app.path()
        .app_data_dir()
        .expect("app data dir")
        .join("Collavre")
}

/// File recording the live sidecar's PID, so a launch that follows a crash can
/// reap the orphan the graceful exit handler never got to stop.
fn pidfile_path(data: &PathBuf) -> PathBuf {
    data.join("desktop-sidecar.pid")
}

/// Kill a sidecar orphaned by a previous run before spawning a fresh one. The
/// graceful path (ExitRequested -> stop_sidecar) clears the pidfile on a clean
/// quit; but if the shell crashed or was SIGKILLed, its sidecar process group
/// survives and keeps the SQLite write locks held (and a fixed PORT bound in
/// open mode), which would wedge this launch. Signal that stale group first.
#[cfg(unix)]
fn reap_orphan_sidecar(data: &PathBuf) {
    let path = pidfile_path(data);
    let Ok(contents) = fs::read_to_string(&path) else {
        return;
    };
    // A negative pid targets the whole process group we created via
    // process_group(0) (pgid == leader pid). Guard pid > 1 so a corrupt file
    // can't turn into kill(-1) (every process we may signal).
    if let Ok(pid) = contents.trim().parse::<i32>() {
        if pid > 1 && unsafe { libc_kill(-pid, 0) } == 0 {
            unsafe {
                libc_kill(-pid, 15); // SIGTERM
            }
            let deadline = Instant::now() + Duration::from_secs(5);
            while Instant::now() < deadline {
                if unsafe { libc_kill(-pid, 0) } != 0 {
                    break; // group gone
                }
                std::thread::sleep(Duration::from_millis(100));
            }
            unsafe {
                libc_kill(-pid, 9); // SIGKILL fallback
            }
        }
    }
    let _ = fs::remove_file(&path);
}

#[cfg(not(unix))]
fn reap_orphan_sidecar(data: &PathBuf) {
    let _ = fs::remove_file(pidfile_path(data));
}

fn spawn_sidecar(root: &PathBuf, data: &PathBuf, port: u16) -> Child {
    let launcher = root.join("bin/desktop-server");
    // Honor a caller-supplied bind host (open mode = 0.0.0.0 for LAN/Tailscale);
    // default to loopback. COLLAVRE_ALLOWED_HOSTS rides along via the inherited
    // env, so open mode set on the shell reaches the sidecar intact.
    let bind_host = std::env::var("COLLAVRE_BIND_HOST").unwrap_or_else(|_| "127.0.0.1".into());
    let mut cmd = Command::new("bash");
    cmd.arg(&launcher)
        .current_dir(root)
        .env("PORT", port.to_string())
        .env("COLLAVRE_DATA_DIR", data)
        .env("COLLAVRE_BIND_HOST", bind_host);

    // Capture the sidecar's stdout/stderr to a boot log. A Finder-launched .app has
    // no terminal, so without this any startup failure (db migrate/seed, Puma) is
    // discarded and the app just "quits unexpectedly" with no trail to debug from.
    // Rails' own request logger writes to log/desktop.log once booted; this catches
    // everything before that.
    let log_dir = data.join("log");
    let _ = fs::create_dir_all(&log_dir);
    if let Ok(out) = File::create(log_dir.join("desktop-boot.log")) {
        if let Ok(err) = out.try_clone() {
            cmd.stdout(Stdio::from(out)).stderr(Stdio::from(err));
        }
    }

    // Run the sidecar in its own process group so we can signal the whole tree
    // (bash launcher -> ruby/puma -> Solid Queue) on quit, not just bash.
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        cmd.process_group(0);
    }

    cmd.spawn().expect("spawn rails sidecar")
}

/// Poll `GET /up` until it answers 200 or we give up.
fn wait_until_healthy(port: u16, timeout: Duration) -> bool {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        if http_up_ok(port) {
            return true;
        }
        std::thread::sleep(Duration::from_millis(250));
    }
    false
}

/// Minimal dependency-free HTTP GET /up; true only on a `200` status line.
fn http_up_ok(port: u16) -> bool {
    let addr = format!("127.0.0.1:{port}");
    let Ok(mut stream) = TcpStream::connect(&addr) else {
        return false;
    };
    let _ = stream.set_read_timeout(Some(Duration::from_millis(500)));
    let req = format!("GET /up HTTP/1.0\r\nHost: {addr}\r\nConnection: close\r\n\r\n");
    if stream.write_all(req.as_bytes()).is_err() {
        return false;
    }
    let mut buf = [0u8; 64];
    let Ok(n) = stream.read(&mut buf) else {
        return false;
    };
    let status = String::from_utf8_lossy(&buf[..n]);
    status.starts_with("HTTP/1.") && status.contains(" 200")
}

fn stop_sidecar(child: &mut Child) {
    #[cfg(unix)]
    {
        // SIGTERM the whole process group, then SIGKILL as a fallback.
        let pgid = child.id() as i32;
        unsafe {
            libc_kill(-pgid, 15); // SIGTERM
        }
        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline {
            match child.try_wait() {
                Ok(Some(_)) => return,
                _ => std::thread::sleep(Duration::from_millis(100)),
            }
        }
        unsafe {
            libc_kill(-pgid, 9); // SIGKILL
        }
    }
    let _ = child.kill();
    let _ = child.wait();
}

// Tiny FFI shim so we don't pull in the `libc` crate just for one call.
#[cfg(unix)]
extern "C" {
    #[link_name = "kill"]
    fn libc_kill(pid: i32, sig: i32) -> i32;
}

/// Normalize an `allowed_hosts` JSON value into a comma-joined host string.
/// Accepts either an array of strings (`["a", "b"]`) or a single comma-separated
/// string (`"a, b"`); trims each entry and drops blanks. Any other JSON type
/// (number, bool, object) returns `None` so the key is skipped, not misread.
fn json_to_host_list(v: &serde_json::Value) -> Option<String> {
    let parts: Vec<String> = match v {
        serde_json::Value::Array(items) => items
            .iter()
            .filter_map(|i| i.as_str())
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_string)
            .collect(),
        serde_json::Value::String(s) => s
            .split(',')
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_string)
            .collect(),
        _ => return None,
    };
    Some(parts.join(","))
}

/// Map recognized keys in the desktop `config.json` to the (env var, value)
/// pairs the sidecar already understands. Pure (no env/fs) so the mapping is
/// unit-tested in isolation. The result order is fixed (allowed_hosts, bind_host,
/// port) regardless of key order in the file.
///
/// Recognized keys — all optional, unknown keys and wrong-typed values ignored:
///   "allowed_hosts": ["host", ...] | "host,host"  -> COLLAVRE_ALLOWED_HOSTS
///   "bind_host":      "0.0.0.0"                    -> COLLAVRE_BIND_HOST
///   "port":           4000 | "4000"               -> PORT
///
/// Malformed JSON (or a non-object top level) yields no overrides: a bad config
/// file degrades to the built-in closed-loopback defaults rather than failing
/// the launch.
fn config_env_overrides(json: &str) -> Vec<(&'static str, String)> {
    let mut out = Vec::new();
    let Ok(value) = serde_json::from_str::<serde_json::Value>(json) else {
        return out;
    };
    let Some(obj) = value.as_object() else {
        return out;
    };

    if let Some(hosts) = obj.get("allowed_hosts").and_then(json_to_host_list) {
        if !hosts.is_empty() {
            out.push(("COLLAVRE_ALLOWED_HOSTS", hosts));
        }
    }

    if let Some(host) = obj.get("bind_host").and_then(|v| v.as_str()) {
        let host = host.trim();
        if !host.is_empty() {
            out.push(("COLLAVRE_BIND_HOST", host.to_string()));
        }
    }

    if let Some(port) = obj.get("port").and_then(|v| match v {
        serde_json::Value::Number(n) => n.as_u64().map(|n| n.to_string()),
        serde_json::Value::String(s) => {
            let t = s.trim();
            (!t.is_empty()).then(|| t.to_string())
        }
        _ => None,
    }) {
        out.push(("PORT", port));
    }

    out
}

/// Read the optional `config.json` from the data dir and export its recognized
/// settings into the process environment — but only for keys not already set, so
/// an explicit env var (dev/test override, or a launcher that already exported
/// the value) always wins.
///
/// This is the fix for the tailscale-serve UX gap: a Finder-launched `.app`
/// inherits an empty environment, so there was no way to hand it
/// COLLAVRE_ALLOWED_HOSTS / COLLAVRE_BIND_HOST and open-mode 403'd. Writing this
/// file once (alongside the DBs, secrets, and logs the app already keeps here)
/// lets every later launch pick the settings up. No file is the normal
/// closed-loopback case and a no-op.
fn apply_desktop_config(data: &PathBuf) {
    let path = data.join("config.json");
    let Ok(json) = fs::read_to_string(&path) else {
        return;
    };
    for (key, value) in config_env_overrides(&json) {
        if std::env::var_os(key).is_none() {
            std::env::set_var(key, value);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::config_env_overrides;

    fn pairs(json: &str) -> Vec<(&'static str, String)> {
        config_env_overrides(json)
    }

    #[test]
    fn allowed_hosts_array_joins_with_commas() {
        let got = pairs(r#"{"allowed_hosts": ["a.ts.net", "b.ts.net"]}"#);
        assert_eq!(
            got,
            vec![("COLLAVRE_ALLOWED_HOSTS", "a.ts.net,b.ts.net".to_string())]
        );
    }

    #[test]
    fn allowed_hosts_comma_string_is_normalized() {
        let got = pairs(r#"{"allowed_hosts": " a.ts.net , b.ts.net "}"#);
        assert_eq!(
            got,
            vec![("COLLAVRE_ALLOWED_HOSTS", "a.ts.net,b.ts.net".to_string())]
        );
    }

    #[test]
    fn bind_host_string_maps_to_env() {
        let got = pairs(r#"{"bind_host": "0.0.0.0"}"#);
        assert_eq!(got, vec![("COLLAVRE_BIND_HOST", "0.0.0.0".to_string())]);
    }

    #[test]
    fn port_number_and_string_both_map() {
        assert_eq!(
            pairs(r#"{"port": 4000}"#),
            vec![("PORT", "4000".to_string())]
        );
        assert_eq!(
            pairs(r#"{"port": "4000"}"#),
            vec![("PORT", "4000".to_string())]
        );
    }

    #[test]
    fn all_three_keys_preserve_a_stable_order() {
        let got = pairs(r#"{"port": 4000, "bind_host": "0.0.0.0", "allowed_hosts": ["h"]}"#);
        assert_eq!(
            got,
            vec![
                ("COLLAVRE_ALLOWED_HOSTS", "h".to_string()),
                ("COLLAVRE_BIND_HOST", "0.0.0.0".to_string()),
                ("PORT", "4000".to_string()),
            ]
        );
    }

    #[test]
    fn empty_and_blank_values_are_dropped() {
        assert!(pairs(r#"{"allowed_hosts": []}"#).is_empty());
        assert!(pairs(r#"{"allowed_hosts": "  ,  "}"#).is_empty());
        assert!(pairs(r#"{"bind_host": "   "}"#).is_empty());
        assert!(pairs(r#"{"port": ""}"#).is_empty());
    }

    #[test]
    fn unknown_keys_and_wrong_types_are_ignored() {
        assert!(pairs(r#"{"nope": 1, "bind_host": 123, "allowed_hosts": 5}"#).is_empty());
    }

    #[test]
    fn malformed_json_yields_no_overrides() {
        assert!(pairs("not json at all").is_empty());
        assert!(pairs("").is_empty());
        assert!(pairs("[1,2,3]").is_empty());
    }
}

pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .manage(Sidecar(Mutex::new(None)))
        .setup(|app| {
            let handle = app.handle().clone();
            let root = app_root(&handle);
            let data = data_dir(&handle);
            std::fs::create_dir_all(&data).ok();

            // Load persisted open-mode settings from the data dir's config.json
            // into the env before anything reads it. A Finder-launched .app has
            // no way to receive COLLAVRE_ALLOWED_HOSTS / COLLAVRE_BIND_HOST / PORT
            // otherwise; explicit env vars still win (see apply_desktop_config).
            // Must precede the PORT read and spawn_sidecar's COLLAVRE_BIND_HOST
            // read below so the values actually take effect this launch.
            apply_desktop_config(&data);

            // Honor a caller-supplied PORT so open mode gets a stable URL/firewall
            // rule; fall back to an ephemeral loopback port for the default
            // single-user case. The same `port` feeds the sidecar, health check,
            // and webview URL, so reading it here keeps all three consistent.
            let port = std::env::var("PORT")
                .ok()
                .and_then(|p| p.parse::<u16>().ok())
                .unwrap_or_else(free_port);
            // Reap any sidecar orphaned by a prior crash before we spawn — it
            // still holds this data dir's SQLite write locks.
            reap_orphan_sidecar(&data);
            let child = spawn_sidecar(&root, &data, port);
            let _ = fs::write(pidfile_path(&data), child.id().to_string());
            app.state::<Sidecar>().0.lock().unwrap().replace(child);

            // Show the branded loading screen (dist/index.html) immediately so the
            // user sees custom UI while the sidecar boots, instead of a blank or
            // absent window. We used to block setup on the health check and only
            // then create the window pointed at the Rails URL — meaning nothing was
            // on screen during a cold first-run migration. Now we create the window
            // first and health-gate on a background thread (below).
            WebviewWindowBuilder::new(&handle, "main", WebviewUrl::App("index.html".into()))
                .title("Collavre Desktop")
                .inner_size(1280.0, 860.0)
                .build()?;

            // Health-gate the sidecar OFF the UI thread so the splash keeps
            // animating. On success, swap the splash for the live app; on timeout,
            // surface a readable error in the splash instead of a frozen bar. 120s
            // covers a cold first-run migration.
            std::thread::spawn(move || {
                let healthy = wait_until_healthy(port, Duration::from_secs(120));
                let Some(window) = handle.get_webview_window("main") else {
                    return;
                };
                if healthy {
                    if let Ok(url) = format!("http://127.0.0.1:{port}").parse::<tauri::Url>() {
                        let _ = window.navigate(url);
                    }
                } else {
                    // Update the splash DOM in place (same-origin) rather than
                    // navigating away, so the Collavre branding stays put. No
                    // message is passed: the splash supplies its own locale-aware
                    // (EN/KO) default, keeping user-facing copy out of Rust.
                    let _ = window.eval("window.__collavreSetError && window.__collavreSetError()");
                }
            });

            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("build tauri app")
        .run(|app, event| {
            if let RunEvent::ExitRequested { .. } = event {
                if let Some(mut child) = app.state::<Sidecar>().0.lock().unwrap().take() {
                    stop_sidecar(&mut child);
                }
                // Clear the pidfile so the next launch doesn't try to reap a pid
                // that is gone (or, worse, reused by an unrelated process).
                let _ = fs::remove_file(pidfile_path(&data_dir(app)));
            }
        });
}
