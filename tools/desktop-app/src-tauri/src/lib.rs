//! Collavre Desktop shell.
//!
//! Responsibilities (and nothing else — the UI is the server-rendered Rails app):
//!   1. Pick a free loopback port.
//!   2. Spawn the bundled Rails sidecar (`bin/desktop-server`) pointed at a
//!      writable data dir under the OS app-data location.
//!   3. Health-gate `GET /up` until the server is ready.
//!   4. Show the app in a native webview at `http://127.0.0.1:<port>`.
//!   5. Gracefully stop the sidecar (and its process group) on quit.

use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::PathBuf;
use std::process::{Child, Command};
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

pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .manage(Sidecar(Mutex::new(None)))
        .setup(|app| {
            let handle = app.handle().clone();
            let root = app_root(&handle);
            let data = data_dir(&handle);
            std::fs::create_dir_all(&data).ok();

            // Honor a caller-supplied PORT so open mode gets a stable URL/firewall
            // rule; fall back to an ephemeral loopback port for the default
            // single-user case. The same `port` feeds the sidecar, health check,
            // and webview URL, so reading it here keeps all three consistent.
            let port = std::env::var("PORT")
                .ok()
                .and_then(|p| p.parse::<u16>().ok())
                .unwrap_or_else(free_port);
            let child = spawn_sidecar(&root, &data, port);
            app.state::<Sidecar>().0.lock().unwrap().replace(child);

            // Block the splash on health so the webview never loads a refused
            // connection. 120s covers a cold first-run migration.
            let healthy = wait_until_healthy(port, Duration::from_secs(120));
            let url = if healthy {
                format!("http://127.0.0.1:{port}")
            } else {
                // Surface a readable error instead of a blank webview.
                "data:text/html,<h2>Collavre Desktop failed to start</h2>".to_string()
            };

            WebviewWindowBuilder::new(&handle, "main", WebviewUrl::External(url.parse().unwrap()))
                .title("Collavre Desktop")
                .inner_size(1280.0, 860.0)
                .build()?;

            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("build tauri app")
        .run(|app, event| {
            if let RunEvent::ExitRequested { .. } = event {
                if let Some(mut child) = app.state::<Sidecar>().0.lock().unwrap().take() {
                    stop_sidecar(&mut child);
                }
            }
        });
}
