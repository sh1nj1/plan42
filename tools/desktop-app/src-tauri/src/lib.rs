//! Collavre Desktop shell.
//!
//! Responsibilities (and nothing else — the UI is the server-rendered Rails app):
//!   1. Pick a free loopback port.
//!   2. Spawn the bundled Rails sidecar (`bin/desktop-server`) pointed at a
//!      writable data dir under the OS app-data location.
//!   3. Health-gate `GET /up` until the server is ready.
//!   4. Show the app in a native webview at `http://127.0.0.1:<port>`.
//!   5. Gracefully stop the sidecar (and its process group) on quit.

use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use serde::{Deserialize, Serialize};
use tauri::{Manager, RunEvent, WebviewUrl, WebviewWindowBuilder};

/// Holds the sidecar child so we can stop it on exit.
struct Sidecar {
    child: Mutex<Option<Child>>,
    port: Mutex<Option<u16>>,
}

/// Holds the optional, user-approved cli-openai-proxy process. It is deliberately
/// separate from the Rails sidecar: a failed or disabled proxy must never stop
/// the local Collavre application from opening.
struct ProxySidecar(Mutex<Option<Child>>);

const PROXY_KEYCHAIN_SERVICE: &str = "net.collavre.desktop.cli-openai-proxy";
const PROXY_ADMIN_KEY_ACCOUNT: &str = "admin-key";
const PROXY_COMPLETION_KEY_ACCOUNT: &str = "completion-key";
const PROXY_IDENTITY_SECRET_ACCOUNT: &str = "identity-secret";

#[derive(Debug, Deserialize)]
struct BundledProxyManifest {
    package: String,
    version: String,
    integrity: String,
    platform: String,
}

#[derive(Debug, Deserialize, Serialize)]
struct ProxyConfig {
    port: u16,
    version: String,
    #[serde(default)]
    registered: bool,
}

#[derive(Debug, Serialize)]
struct ProxyStatus {
    installed: bool,
    running: bool,
    port: Option<u16>,
    version: Option<String>,
    registered: bool,
}

#[derive(Debug, Serialize)]
struct ProxySetupResult {
    status: ProxyStatus,
    adapters: Vec<String>,
}

#[derive(Serialize)]
struct GatewayRegistration<'a> {
    registration_token: &'a str,
    proxy_port: u16,
    admin_key: &'a str,
    completion_key: &'a str,
    identity_secret: &'a str,
    adapters: &'a [String],
}

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

/// Locate the macOS application resource directory from its executable.
///
/// `PathResolver::resource_dir` is normally this directory, but can be absent
/// when the app is launched directly from a copied `.app` during installation.
/// Resolving relative to the executable keeps an installed build independent of
/// the development checkout in that case.
fn packaged_resource_dir() -> Option<PathBuf> {
    let executable_dir = std::env::current_exe().ok()?.parent()?.to_path_buf();
    let resources = executable_dir.parent()?.join("Resources");
    resources.join("app").is_dir().then_some(resources)
}

/// Locate the bundled Rails app root. In a packaged `.app` the launcher and app
/// tree live under `Contents/Resources/app`; in `tauri dev` they're resolved
/// relative to the repo so the shell can be exercised without packaging.
fn app_root(app: &tauri::AppHandle) -> PathBuf {
    if let Some(resources) = packaged_resource_dir() {
        return resources.join("app");
    }
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

/// The installed proxy has no mutable content. Only a public port and its
/// expected package version are persisted here; credentials live exclusively in
/// Keychain and are never serialized into this directory or a log.
fn proxy_state_dir(data: &Path) -> PathBuf {
    data.join("proxy")
}

fn proxy_config_path(data: &Path) -> PathBuf {
    proxy_state_dir(data).join("config.json")
}

fn proxy_pidfile_path(data: &Path) -> PathBuf {
    proxy_state_dir(data).join("desktop-proxy.pid")
}

fn proxy_root(app: &tauri::AppHandle) -> PathBuf {
    if let Some(resources) = packaged_resource_dir() {
        let bundled = resources.join("app/proxy");
        if bundled.join("manifest.json").exists() {
            return bundled;
        }
    }
    if let Ok(resource_dir) = app.path().resource_dir() {
        let bundled = resource_dir.join("app/proxy");
        if bundled.join("manifest.json").exists() {
            return bundled;
        }
    }
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../vendor/proxy")
}

fn bundled_proxy_manifest(app: &tauri::AppHandle) -> Result<BundledProxyManifest, String> {
    let root = proxy_root(app);
    let manifest = fs::read_to_string(root.join("manifest.json")).map_err(|_| {
        "The bundled cli-openai-proxy runtime is missing. Reinstall Collavre Desktop.".to_string()
    })?;
    parse_bundled_proxy_manifest(&manifest)
}

fn parse_bundled_proxy_manifest(manifest: &str) -> Result<BundledProxyManifest, String> {
    let manifest: BundledProxyManifest = serde_json::from_str(manifest).map_err(|_| {
        "The bundled cli-openai-proxy manifest is invalid. Reinstall Collavre Desktop.".to_string()
    })?;
    if manifest.package != "cli-openai-proxy"
        || manifest.platform != "darwin-arm64"
        || manifest.version.is_empty()
        || !manifest.integrity.starts_with("sha512-")
    {
        return Err(
            "The bundled cli-openai-proxy manifest is invalid. Reinstall Collavre Desktop."
                .to_string(),
        );
    }
    Ok(manifest)
}

fn read_proxy_config(data: &Path) -> Option<ProxyConfig> {
    let json = fs::read_to_string(proxy_config_path(data)).ok()?;
    let config: ProxyConfig = serde_json::from_str(&json).ok()?;
    (config.port > 0 && !config.version.is_empty()).then_some(config)
}

fn normalized_proxy_config(
    existing: Option<ProxyConfig>,
    version: String,
    default_port: u16,
) -> ProxyConfig {
    match existing {
        Some(config) => ProxyConfig { version, ..config },
        None => ProxyConfig {
            port: default_port,
            version,
            registered: false,
        },
    }
}

/// A persisted loopback port can later be claimed by another local process.
/// Replacing it requires gateway re-registration because its URL has changed.
fn replace_occupied_proxy_port(config: &mut ProxyConfig, replacement_port: u16) {
    config.port = replacement_port;
    config.registered = false;
}

fn proxy_port_available(port: u16) -> bool {
    TcpListener::bind(("127.0.0.1", port)).is_ok()
}

/// Update only the proxy version tracked in local state when a new desktop
/// bundle is installed. The port, registration state, and all Keychain-backed
/// credentials remain untouched.
fn migrate_proxy_config(data: &Path, version: String) -> Result<Option<ProxyConfig>, String> {
    let Some(existing) = read_proxy_config(data) else {
        return Ok(None);
    };
    let config = normalized_proxy_config(Some(existing), version, 0);
    write_proxy_config(data, &config)?;
    Ok(Some(config))
}

fn write_proxy_config(data: &Path, config: &ProxyConfig) -> Result<(), String> {
    let state_dir = proxy_state_dir(data);
    fs::create_dir_all(&state_dir)
        .map_err(|_| "Could not create the desktop proxy state directory.".to_string())?;
    let temporary = state_dir.join("config.json.tmp");
    let json = serde_json::to_vec(config)
        .map_err(|_| "Could not write desktop proxy configuration.".to_string())?;
    let mut file = OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .open(&temporary)
        .map_err(|_| "Could not write desktop proxy configuration.".to_string())?;
    file.write_all(&json)
        .and_then(|_| file.sync_all())
        .map_err(|_| "Could not write desktop proxy configuration.".to_string())?;
    fs::rename(temporary, proxy_config_path(data))
        .map_err(|_| "Could not finalize desktop proxy configuration.".to_string())
}

fn generate_proxy_key(prefix: &str) -> Result<String, String> {
    let mut bytes = [0u8; 48];
    getrandom::fill(&mut bytes)
        .map_err(|_| "Could not generate a desktop proxy key.".to_string())?;
    Ok(format!("{prefix}_{}", URL_SAFE_NO_PAD.encode(bytes)))
}

struct ProxyCredentials {
    admin_key: String,
    completion_key: String,
    identity_secret: String,
    regenerated: bool,
}

#[cfg(target_os = "macos")]
fn keychain_proxy_key(account: &str, prefix: &str) -> Result<(String, bool), String> {
    use security_framework::passwords::{get_generic_password, set_generic_password};

    if let Ok(bytes) = get_generic_password(PROXY_KEYCHAIN_SERVICE, account) {
        return String::from_utf8(bytes)
            .map(|key| (key, false))
            .map_err(|_| "The desktop proxy key in Keychain is invalid.".to_string());
    }

    let key = generate_proxy_key(prefix)?;
    set_generic_password(PROXY_KEYCHAIN_SERVICE, account, key.as_bytes()).map_err(|_| {
        "Collavre needs Keychain access to store the desktop proxy key.".to_string()
    })?;
    Ok((key, true))
}

#[cfg(not(target_os = "macos"))]
fn keychain_proxy_key(_account: &str, _prefix: &str) -> Result<(String, bool), String> {
    Err("Desktop proxy installation is currently supported on macOS only.".to_string())
}

fn proxy_credentials() -> Result<ProxyCredentials, String> {
    let (admin_key, admin_key_regenerated) =
        keychain_proxy_key(PROXY_ADMIN_KEY_ACCOUNT, "cop_admin")?;
    let (completion_key, completion_key_regenerated) =
        keychain_proxy_key(PROXY_COMPLETION_KEY_ACCOUNT, "cop_key")?;
    let (identity_secret, identity_secret_regenerated) =
        keychain_proxy_key(PROXY_IDENTITY_SECRET_ACCOUNT, "cop_identity")?;
    Ok(ProxyCredentials {
        admin_key,
        completion_key,
        identity_secret,
        regenerated: admin_key_regenerated
            || completion_key_regenerated
            || identity_secret_regenerated,
    })
}

fn invalidate_proxy_registration_after_key_regeneration(
    data: &Path,
    config: &mut ProxyConfig,
    credentials_regenerated: bool,
) -> Result<(), String> {
    if credentials_regenerated && config.registered {
        config.registered = false;
        write_proxy_config(data, config)?;
    }
    Ok(())
}

/// File recording the live sidecar's PID, so a launch that follows a crash can
/// reap the orphan the graceful exit handler never got to stop.
fn pidfile_path(data: &Path) -> PathBuf {
    data.join("desktop-sidecar.pid")
}

/// Kill a sidecar orphaned by a previous run before spawning a fresh one. The
/// graceful path (ExitRequested -> stop_sidecar) clears the pidfile on a clean
/// quit; but if the shell crashed or was SIGKILLed, its sidecar process group
/// survives and keeps the SQLite write locks held (and a fixed PORT bound in
/// open mode), which would wedge this launch. Signal that stale group first.
#[cfg(unix)]
fn reap_orphan_sidecar(data: &Path) {
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
fn reap_orphan_sidecar(data: &Path) {
    let _ = fs::remove_file(pidfile_path(data));
}

fn spawn_sidecar(root: &Path, data: &Path, port: u16) -> Child {
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

/// A pidfile contains no unforgeable process identity. Never signal a process
/// group from it: even a matching command can exit and have its numeric PID
/// reused before a signal is delivered. Clean shutdown uses the `Child` handle
/// held in memory; after a crash, discard the stale file and let repair select
/// a new port if the abandoned proxy still owns the old one.
fn reap_orphan_proxy(data: &Path) {
    let _ = fs::remove_file(proxy_pidfile_path(data));
}

fn spawn_proxy(
    app: &tauri::AppHandle,
    data: &Path,
    config: &ProxyConfig,
    credentials: ProxyCredentials,
) -> Result<Child, String> {
    let root = proxy_root(app);
    let node = root.join("node/bin/node");
    let entrypoint = root.join("node_modules/cli-openai-proxy/dist/server/standalone.js");
    if !node.is_file() || !entrypoint.is_file() {
        return Err(
            "The bundled cli-openai-proxy runtime is incomplete. Reinstall Collavre Desktop."
                .to_string(),
        );
    }

    let state = proxy_state_dir(data);
    fs::create_dir_all(state.join("provision-state"))
        .map_err(|_| "Could not create the desktop proxy state directory.".to_string())?;

    let log_dir = data.join("log");
    fs::create_dir_all(&log_dir).ok();
    let mut command = Command::new(node);
    command
        .arg(entrypoint)
        .current_dir(&state)
        .env("HOST", "127.0.0.1")
        .env("PORT", config.port.to_string())
        .env("API_KEYS", credentials.completion_key)
        .env("AUTH_ADMIN_KEYS", credentials.admin_key)
        .env("USER_IDENTITY_HMAC_SECRET", credentials.identity_secret)
        .env("PATH", desktop_cli_path())
        .env("PROVISION_STATE_DIR", state.join("provision-state"));

    // The proxy inherits HOME and receives an expanded executable-only PATH:
    // the user's already logged-in Claude/Codex CLIs own their authentication.
    // The proxy-only keys above are captured and removed by cli-openai-proxy
    // before it starts a CLI child.
    if let Ok(log) = File::create(log_dir.join("desktop-proxy.log")) {
        if let Ok(error_log) = log.try_clone() {
            command
                .stdout(Stdio::from(log))
                .stderr(Stdio::from(error_log));
        }
    }
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        command.process_group(0);
    }
    command
        .spawn()
        .map_err(|_| "Could not start cli-openai-proxy.".to_string())
}

fn proxy_status(app: &tauri::AppHandle, data: &Path, sidecar: &ProxySidecar) -> ProxyStatus {
    let config = read_proxy_config(data);
    let manifest = bundled_proxy_manifest(app).ok();
    let installed = config.is_some() && manifest.is_some();
    let running = sidecar
        .0
        .lock()
        .map(|mut child| {
            let exited = child
                .as_mut()
                .and_then(|process| process.try_wait().ok().flatten())
                .is_some();
            if exited {
                child.take();
                let _ = fs::remove_file(proxy_pidfile_path(data));
            }
            child.is_some()
        })
        .unwrap_or(false);
    ProxyStatus {
        installed,
        running,
        port: config.as_ref().map(|item| item.port),
        version: manifest.map(|item| item.version),
        registered: config.map(|item| item.registered).unwrap_or(false),
    }
}

fn start_proxy(app: &tauri::AppHandle, data: &Path, sidecar: &ProxySidecar) -> Result<(), String> {
    let mut child = sidecar
        .0
        .lock()
        .map_err(|_| "The desktop proxy process lock is unavailable.".to_string())?;
    let exited = child
        .as_mut()
        .and_then(|process| process.try_wait().ok().flatten())
        .is_some();
    if exited {
        child.take();
        let _ = fs::remove_file(proxy_pidfile_path(data));
    }
    if child.is_some() {
        return Ok(());
    }
    drop(child);
    let mut config = read_proxy_config(data)
        .ok_or_else(|| "Desktop proxy setup has not been approved.".to_string())?;
    let manifest = bundled_proxy_manifest(app)?;
    if config.version != manifest.version {
        return Err("The desktop proxy version changed. Re-run desktop proxy setup.".to_string());
    }
    let credentials = proxy_credentials()?;
    invalidate_proxy_registration_after_key_regeneration(
        data,
        &mut config,
        credentials.regenerated,
    )?;
    reap_orphan_proxy(data);
    let child = spawn_proxy(app, data, &config, credentials)?;
    fs::write(proxy_pidfile_path(data), child.id().to_string())
        .map_err(|_| "Could not record the desktop proxy process.".to_string())?;
    sidecar
        .0
        .lock()
        .map_err(|_| "The desktop proxy process lock is unavailable.".to_string())?
        .replace(child);
    let healthy = sidecar
        .0
        .lock()
        .ok()
        .and_then(|mut guard| {
            guard
                .as_mut()
                .map(|child| wait_until_proxy_healthy(child, config.port, Duration::from_secs(15)))
        })
        .unwrap_or(false);
    if !healthy {
        if let Some(mut child) = sidecar.0.lock().ok().and_then(|mut guard| guard.take()) {
            stop_sidecar(&mut child);
        }
        let _ = fs::remove_file(proxy_pidfile_path(data));
        return Err(
            "cli-openai-proxy did not pass its health check. See desktop-proxy.log.".to_string(),
        );
    }
    Ok(())
}

fn install_proxy(app: &tauri::AppHandle, sidecar: &ProxySidecar) -> Result<ProxyStatus, String> {
    let data = data_dir(app);
    fs::create_dir_all(&data)
        .map_err(|_| "Could not create the Collavre data directory.".to_string())?;
    let manifest = bundled_proxy_manifest(app)?;
    // A bundled proxy update keeps the existing loopback port, Keychain keys,
    // and completed state, but advances the expected runtime version before the
    // health check. Without this migration an upgrade can never restart or be
    // repaired because start_proxy rejects the stale version first.
    let mut config =
        normalized_proxy_config(read_proxy_config(&data), manifest.version, free_port());
    // Clear a prior crashed proxy before probing its persisted port. If another
    // process owns it, choose a fresh loopback port and require registration so
    // Rails' gateway URL follows the repaired proxy.
    reap_orphan_proxy(&data);
    if !proxy_port_available(config.port) {
        replace_occupied_proxy_port(&mut config, free_port());
    }
    write_proxy_config(&data, &config)?;
    start_proxy(app, &data, sidecar)?;
    Ok(proxy_status(app, &data, sidecar))
}

/// Complete the user-approved setup without exposing Keychain secrets to the
/// webview. The registration grant is short-lived and Rails accepts it only
/// over its loopback socket.
#[tauri::command]
fn desktop_proxy_complete_setup(
    app: tauri::AppHandle,
    sidecar: tauri::State<'_, ProxySidecar>,
    rails_sidecar: tauri::State<'_, Sidecar>,
    registration_token: String,
) -> Result<ProxySetupResult, String> {
    let server_port = rails_sidecar
        .port
        .lock()
        .map_err(|_| "The local Collavre server port is unavailable.".to_string())?
        .ok_or_else(|| "Collavre Desktop could not determine the local server port.".to_string())?;
    // Validate the Rails-issued, short-lived consent grant before creating
    // Keychain credentials, writing proxy state, or starting the proxy. The
    // Tauri command is callable from loopback pages, so an arbitrary string
    // must not be allowed to trigger those side effects.
    validate_registration_grant(server_port, &registration_token)?;
    install_proxy(&app, &sidecar)?;
    let data = data_dir(&app);
    let config = read_proxy_config(&data)
        .ok_or_else(|| "Desktop proxy configuration is missing after installation.".to_string())?;
    let credentials = proxy_credentials()?;
    let adapters = detected_adapters();
    let request = GatewayRegistration {
        registration_token: &registration_token,
        proxy_port: config.port,
        admin_key: &credentials.admin_key,
        completion_key: &credentials.completion_key,
        identity_secret: &credentials.identity_secret,
        adapters: &adapters,
    };
    register_gateway(server_port, &request)?;

    let registered = ProxyConfig {
        registered: true,
        ..config
    };
    write_proxy_config(&data, &registered)?;
    Ok(ProxySetupResult {
        status: proxy_status(&app, &data, &sidecar),
        adapters,
    })
}

#[tauri::command]
fn desktop_proxy_status(
    app: tauri::AppHandle,
    sidecar: tauri::State<'_, ProxySidecar>,
) -> ProxyStatus {
    proxy_status(&app, &data_dir(&app), &sidecar)
}

/// Detect executables only. In particular, do not invoke a CLI or inspect its
/// configuration, credential files, Keychain items, or login state.
fn detected_adapters() -> Vec<String> {
    ["claude", "codex"]
        .into_iter()
        .filter(|binary| executable_on_path(binary))
        .map(str::to_owned)
        .collect()
}

#[cfg(unix)]
fn executable_on_path(binary: &str) -> bool {
    use std::os::unix::fs::PermissionsExt;

    desktop_cli_search_paths()
        .into_iter()
        .map(|directory| directory.join(binary))
        .any(|candidate| {
            candidate
                .metadata()
                .map(|metadata| metadata.is_file() && metadata.permissions().mode() & 0o111 != 0)
                .unwrap_or(false)
        })
}

#[cfg(not(unix))]
fn executable_on_path(binary: &str) -> bool {
    desktop_cli_search_paths()
        .into_iter()
        .map(|directory| directory.join(binary))
        .any(|candidate| candidate.is_file())
}

// Finder launches do not reliably inherit shell PATH additions. Check the
// conventional user-install locations as well, then give the proxy that same
// PATH so a detected CLI is actually executable. This is path discovery only;
// it does not run a CLI or inspect provider configuration.
fn desktop_cli_search_paths() -> Vec<PathBuf> {
    let mut paths = std::env::var_os("PATH")
        .into_iter()
        .flat_map(|path| std::env::split_paths(&path).collect::<Vec<_>>())
        .collect::<Vec<_>>();
    append_unique_paths(
        &mut paths,
        [
            PathBuf::from("/opt/homebrew/bin"),
            PathBuf::from("/usr/local/bin"),
        ],
    );
    if let Some(home) = std::env::var_os("HOME") {
        let home = PathBuf::from(home);
        append_unique_paths(
            &mut paths,
            [
                home.join(".local/bin"),
                home.join(".npm-global/bin"),
                home.join(".volta/bin"),
            ],
        );
        append_unique_paths(&mut paths, nvm_bin_paths(&home));
    }
    paths
}

/// Preserve the inherited PATH order: it selects the CLI and Node version a
/// user already chose in their shell. Appended fallback directories are only
/// used when that PATH does not contain the executable.
fn append_unique_paths(paths: &mut Vec<PathBuf>, candidates: impl IntoIterator<Item = PathBuf>) {
    for candidate in candidates {
        if !paths.contains(&candidate) {
            paths.push(candidate);
        }
    }
}

fn nvm_bin_paths(home: &Path) -> Vec<PathBuf> {
    let versions = home.join(".nvm/versions/node");
    let mut paths = fs::read_dir(versions)
        .into_iter()
        .flatten()
        .filter_map(Result::ok)
        .map(|entry| entry.path().join("bin"))
        .filter(|path| path.is_dir())
        .collect::<Vec<_>>();
    // The inherited PATH, if any, was retained before these fallbacks. Keep
    // the fallback order deterministic without disturbing that precedence.
    paths.sort();
    paths
}

fn desktop_cli_path() -> std::ffi::OsString {
    std::env::join_paths(desktop_cli_search_paths()).unwrap_or_else(|_| std::ffi::OsString::new())
}

fn register_gateway(port: u16, registration: &GatewayRegistration<'_>) -> Result<(), String> {
    if port == 0 {
        return Err("Collavre Desktop could not determine the local server port.".to_string());
    }
    let body = serde_json::to_vec(registration)
        .map_err(|_| "Could not prepare the local gateway registration.".to_string())?;
    let address = format!("127.0.0.1:{port}");
    let mut stream = TcpStream::connect(&address)
        .map_err(|_| "Could not connect to the local Collavre server.".to_string())?;
    stream.set_read_timeout(Some(Duration::from_secs(10))).ok();
    stream.set_write_timeout(Some(Duration::from_secs(10))).ok();
    let request = format!(
        "POST /desktop/setup/register-gateway HTTP/1.1\r\nHost: {address}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        body.len()
    );
    stream
        .write_all(request.as_bytes())
        .and_then(|_| stream.write_all(&body))
        .map_err(|_| "Could not send the local gateway registration.".to_string())?;
    let mut response = String::new();
    stream
        .read_to_string(&mut response)
        .map_err(|_| "Could not read the local gateway registration response.".to_string())?;
    if response.starts_with("HTTP/1.1 201") || response.starts_with("HTTP/1.0 201") {
        Ok(())
    } else {
        Err(
            "Collavre could not register the local gateway. No setup was marked complete."
                .to_string(),
        )
    }
}

/// Ask Rails to validate the signed, short-lived setup consent grant before
/// native installation mutates persistent state. This call deliberately sends
/// no proxy credentials.
fn validate_registration_grant(port: u16, registration_token: &str) -> Result<(), String> {
    let body = serde_json::json!({ "registration_token": registration_token }).to_string();
    let address = format!("127.0.0.1:{port}");
    let mut stream = TcpStream::connect(&address)
        .map_err(|_| "Could not connect to the local Collavre server.".to_string())?;
    stream.set_read_timeout(Some(Duration::from_secs(10))).ok();
    stream.set_write_timeout(Some(Duration::from_secs(10))).ok();
    let request = format!(
        "POST /desktop/setup/validate-registration-grant HTTP/1.1\r\nHost: {address}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    stream
        .write_all(request.as_bytes())
        .map_err(|_| "Could not validate the desktop setup consent.".to_string())?;
    let mut response = String::new();
    stream
        .read_to_string(&mut response)
        .map_err(|_| "Could not read the desktop setup consent response.".to_string())?;
    if response.starts_with("HTTP/1.1 204") || response.starts_with("HTTP/1.0 204") {
        Ok(())
    } else {
        Err(
            "Desktop proxy setup consent is invalid or has expired. Return to setup and try again."
                .to_string(),
        )
    }
}

/// Poll `GET /up` until it answers 200 or we give up.
fn wait_until_healthy(port: u16, timeout: Duration) -> bool {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        if http_ok(port, "/up") {
            return true;
        }
        std::thread::sleep(Duration::from_millis(250));
    }
    false
}

fn wait_until_proxy_healthy(child: &mut Child, port: u16, timeout: Duration) -> bool {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        if child.try_wait().ok().flatten().is_some() {
            return false;
        }
        if http_ok(port, "/health") {
            // A different process can claim the persisted port in the small
            // interval between our availability check and Node binding it. Do
            // not accept that process's generic 200 response: give the child
            // time to report the bind failure, then verify it is still alive.
            std::thread::sleep(Duration::from_millis(500));
            return child.try_wait().ok().flatten().is_none();
        }
        std::thread::sleep(Duration::from_millis(250));
    }
    false
}

/// Minimal dependency-free HTTP GET; true only on a `200` status line.
fn http_ok(port: u16, path: &str) -> bool {
    let addr = format!("127.0.0.1:{port}");
    let Ok(mut stream) = TcpStream::connect(&addr) else {
        return false;
    };
    let _ = stream.set_read_timeout(Some(Duration::from_millis(500)));
    let req = format!("GET {path} HTTP/1.0\r\nHost: {addr}\r\nConnection: close\r\n\r\n");
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
fn apply_desktop_config(data: &Path) {
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
#[allow(clippy::items_after_test_module)]
mod tests {
    use super::{
        append_unique_paths, config_env_overrides, generate_proxy_key,
        invalidate_proxy_registration_after_key_regeneration, migrate_proxy_config,
        normalized_proxy_config, nvm_bin_paths, parse_bundled_proxy_manifest, read_proxy_config,
        reap_orphan_proxy, replace_occupied_proxy_port, wait_until_proxy_healthy,
        write_proxy_config, ProxyConfig,
    };
    use std::{env, fs, path::PathBuf, process, time::Duration};

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

    #[test]
    fn bundled_proxy_manifest_accepts_only_the_expected_package_and_platform() {
        let manifest = parse_bundled_proxy_manifest(
            r#"{"package":"cli-openai-proxy","version":"0.1.0","integrity":"sha512-test","platform":"darwin-arm64"}"#,
        )
        .expect("valid manifest");
        assert_eq!(manifest.version, "0.1.0");

        assert!(parse_bundled_proxy_manifest(
            r#"{"package":"other","version":"0.1.0","integrity":"sha512-test","platform":"darwin-arm64"}"#,
        )
        .is_err());
        assert!(parse_bundled_proxy_manifest(
            r#"{"package":"cli-openai-proxy","version":"0.1.0","integrity":"sha512-test","platform":"darwin-x64"}"#,
        )
        .is_err());
    }

    #[test]
    fn generated_proxy_keys_are_prefixed_and_url_safe() {
        let key = generate_proxy_key("cop_key").expect("random key");
        assert!(key.starts_with("cop_key_"));
        assert!(key
            .chars()
            .all(|character| character.is_ascii_alphanumeric()
                || character == '_'
                || character == '-'));
    }

    #[test]
    fn proxy_upgrade_keeps_the_existing_port_and_completion_state() {
        let config = normalized_proxy_config(
            Some(ProxyConfig {
                port: 34_567,
                version: "0.1.0".to_string(),
                registered: true,
            }),
            "0.2.0".to_string(),
            45_678,
        );

        assert_eq!(34_567, config.port);
        assert_eq!("0.2.0", config.version);
        assert!(config.registered);
    }

    #[test]
    fn occupied_proxy_port_is_replaced_and_requires_reregistration() {
        let mut config = ProxyConfig {
            port: 34_567,
            version: "0.1.0".to_string(),
            registered: true,
        };

        replace_occupied_proxy_port(&mut config, 45_678);

        assert_eq!(45_678, config.port);
        assert!(!config.registered);
    }

    #[test]
    fn nvm_node_bins_are_included_in_desktop_cli_paths() {
        let home = env::temp_dir().join(format!("collavre-nvm-paths-{}", process::id()));
        let nvm_bin = home.join(".nvm/versions/node/v22.0.0/bin");
        let _ = fs::remove_dir_all(&home);
        fs::create_dir_all(&nvm_bin).expect("create NVM node bin");

        let paths = nvm_bin_paths(&home);
        let _ = fs::remove_dir_all(&home);

        assert_eq!(vec![nvm_bin], paths);
    }

    #[test]
    fn fallback_paths_do_not_reorder_the_inherited_path() {
        let inherited = PathBuf::from("/custom/node/bin");
        let fallback = PathBuf::from("/opt/homebrew/bin");
        let mut paths = vec![inherited.clone(), fallback.clone()];

        append_unique_paths(&mut paths, [fallback, PathBuf::from("/usr/local/bin")]);

        assert_eq!(
            paths,
            vec![
                inherited,
                PathBuf::from("/opt/homebrew/bin"),
                PathBuf::from("/usr/local/bin"),
            ]
        );
    }

    #[test]
    fn orphan_proxy_reaping_only_discards_the_untrusted_pidfile() {
        let data = env::temp_dir().join(format!("collavre-proxy-pidfile-{}", process::id()));
        let pidfile = super::proxy_pidfile_path(&data);
        let _ = fs::remove_dir_all(&data);
        fs::create_dir_all(pidfile.parent().expect("pidfile parent")).expect("create state");
        fs::write(&pidfile, "12345").expect("write stale pidfile");

        reap_orphan_proxy(&data);

        assert!(!pidfile.exists());
        let _ = fs::remove_dir_all(&data);
    }

    #[cfg(unix)]
    #[test]
    fn proxy_health_rejects_an_impostor_when_the_spawned_child_exits() {
        use std::io::{Read, Write};
        use std::net::TcpListener;
        use std::process::Command;
        use std::thread;

        let listener = TcpListener::bind("127.0.0.1:0").expect("bind impostor health server");
        let port = listener.local_addr().expect("listener address").port();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept health request");
            let mut request = [0_u8; 256];
            let _ = stream.read(&mut request);
            stream
                .write_all(b"HTTP/1.0 200 OK\r\nContent-Length: 2\r\n\r\nok")
                .expect("respond as impostor");
        });
        let mut child = Command::new("sh")
            .args(["-c", "sleep 0.1; exit 1"])
            .spawn()
            .expect("spawn failed proxy process");

        assert!(!wait_until_proxy_healthy(
            &mut child,
            port,
            Duration::from_secs(2)
        ));
        server.join().expect("health server joined");
    }

    #[test]
    fn startup_proxy_upgrade_persists_the_new_version() {
        let data = env::temp_dir().join(format!("collavre-proxy-upgrade-{}", process::id()));
        let _ = fs::remove_dir_all(&data);
        write_proxy_config(
            &data,
            &ProxyConfig {
                port: 34_567,
                version: "0.1.0".to_string(),
                registered: true,
            },
        )
        .expect("write existing proxy configuration");

        let upgraded = migrate_proxy_config(&data, "0.2.0".to_string())
            .expect("migrate proxy configuration")
            .expect("existing proxy configuration");
        let persisted = read_proxy_config(&data).expect("persisted proxy configuration");
        let _ = fs::remove_dir_all(&data);

        assert_eq!(34_567, upgraded.port);
        assert!(upgraded.registered);
        assert_eq!("0.2.0", persisted.version);
    }

    #[test]
    fn regenerated_keychain_credentials_require_gateway_reregistration() {
        let data = env::temp_dir().join(format!("collavre-proxy-reregister-{}", process::id()));
        let _ = fs::remove_dir_all(&data);
        let mut config = ProxyConfig {
            port: 34_567,
            version: "0.1.0".to_string(),
            registered: true,
        };
        write_proxy_config(&data, &config).expect("write registered proxy configuration");

        invalidate_proxy_registration_after_key_regeneration(&data, &mut config, true)
            .expect("invalidate stale gateway registration");
        let persisted = read_proxy_config(&data).expect("persisted proxy configuration");
        let _ = fs::remove_dir_all(&data);

        assert!(!config.registered);
        assert!(!persisted.registered);
        assert_eq!(34_567, persisted.port);
        assert_eq!("0.1.0", persisted.version);
    }
}

pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .manage(Sidecar {
            child: Mutex::new(None),
            port: Mutex::new(None),
        })
        .manage(ProxySidecar(Mutex::new(None)))
        .invoke_handler(tauri::generate_handler![
            desktop_proxy_complete_setup,
            desktop_proxy_status
        ])
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
            app.state::<Sidecar>().child.lock().unwrap().replace(child);
            app.state::<Sidecar>().port.lock().unwrap().replace(port);

            // Show the branded loading screen (dist/index.html) immediately so the
            // user sees custom UI while the Rails sidecar and any previously
            // configured proxy start. Proxy health checks can take up to 15 seconds
            // after an update or failure, so they must not block window creation.
            WebviewWindowBuilder::new(&handle, "main", WebviewUrl::App("index.html".into()))
                .title("Collavre Desktop")
                .inner_size(1280.0, 860.0)
                .build()?;

            // Health-gate startup off the UI thread so the splash keeps animating.
            // On success, swap it for the live app; on timeout, surface a readable
            // error in place. 120s covers a cold first-run Rails migration.
            std::thread::spawn(move || {
                // A configured proxy means the user previously accepted its first
                // run setup. Migrate its expected bundled version before restarting
                // it: otherwise an app update leaves the old version on disk and the
                // restart is rejected forever. If migration or restart fails, open
                // the setup recovery screen rather than silently navigating to home.
                let first_run_complete = bundled_proxy_manifest(&handle)
                    .and_then(|manifest| migrate_proxy_config(&data, manifest.version))
                    .and_then(|config| match config {
                        Some(_) => {
                            start_proxy(&handle, &data, &handle.state::<ProxySidecar>())?;
                            Ok(read_proxy_config(&data)
                                .map(|config| config.registered)
                                .unwrap_or(false))
                        }
                        None => Ok(false),
                    })
                    .unwrap_or(false);
                let healthy = wait_until_healthy(port, Duration::from_secs(120));
                let Some(window) = handle.get_webview_window("main") else {
                    return;
                };
                if healthy {
                    let path = if first_run_complete {
                        "/"
                    } else {
                        "/desktop/setup"
                    };
                    if let Ok(url) = format!("http://127.0.0.1:{port}{path}").parse::<tauri::Url>()
                    {
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
                if let Some(mut child) = app.state::<Sidecar>().child.lock().unwrap().take() {
                    stop_sidecar(&mut child);
                }
                if let Some(mut child) = app.state::<ProxySidecar>().0.lock().unwrap().take() {
                    stop_sidecar(&mut child);
                }
                // Clear the pidfile so the next launch doesn't try to reap a pid
                // that is gone (or, worse, reused by an unrelated process).
                let _ = fs::remove_file(pidfile_path(&data_dir(app)));
                let _ = fs::remove_file(proxy_pidfile_path(&data_dir(app)));
            }
        });
}
