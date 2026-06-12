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
