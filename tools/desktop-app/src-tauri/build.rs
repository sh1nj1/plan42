fn main() {
    // tauri_build::build() copies the `resources` tree (../staging/app) into
    // target/<profile>/app via std::fs::copy, which clones the SOURCE mode onto
    // each destination. Vendored gems ship many 0444 (read-only) files, so the
    // copies land read-only; on the NEXT build, fs::copy opens the existing
    // read-only destination O_TRUNC and dies with a path-less
    // "Permission denied (os error 13)". cargo never cleans target/<profile>/app,
    // so the stale read-only copies persist across rebuilds. Doing this here (not
    // only in build-macos.sh) covers a direct `cargo tauri build`. u+rwX (capital
    // X) restores the traverse bit so chmod -R can descend into copied dirs.
    let _ = std::process::Command::new("sh")
        .arg("-c")
        .arg("chmod -R u+rwX target/*/app 2>/dev/null || true")
        .status();

    tauri_build::build()
}
