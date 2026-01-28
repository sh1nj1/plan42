const esbuild = require('esbuild');
const glob = require('glob');
const path = require('path');
const { execSync } = require('child_process');
const fs = require('fs');

// ============================================================================
// ENGINE CONFIGURATION
// ============================================================================
// Configure engines that may come from gems (when not in local engines/ folder)
// Format: { name: string, mainEntry?: string }
// - name: gem/engine name (used for `bundle show <name>` and import resolution)
// - mainEntry: main JS file name (default: `${name}.js`)
//
// Environment variables:
// - USE_<NAME>_GEM=true: Force using gem instead of local engines/<name>
// - <NAME>_GEM_PATH=/path: Override gem path directly
// ============================================================================
const GEM_ENGINES = [
    { name: 'collavre', mainEntry: 'collavre.js' },
    // Add more engines here as needed:
    // { name: 'another_engine', mainEntry: 'another_engine.js' },
];

// ============================================================================
// ENGINE PATH RESOLUTION
// ============================================================================

/**
 * Get the path to an engine, preferring local engines/ unless USE_<NAME>_GEM=true
 * @param {string} engineName - The engine/gem name
 * @returns {string|null} - Path to engine or null if not found
 */
function getEnginePath(engineName) {
    const envPrefix = engineName.toUpperCase().replace(/-/g, '_');

    // Explicit path override via env var
    const explicitPath = process.env[`${envPrefix}_GEM_PATH`];
    if (explicitPath) return explicitPath;

    // Check local engines directory first (default for development)
    const localPath = path.join(process.cwd(), 'engines', engineName);
    const useGemFlag = process.env[`USE_${envPrefix}_GEM`] === 'true';

    if (fs.existsSync(localPath) && !useGemFlag) {
        return localPath;
    }

    // Use installed gem when flag is set or no local path
    try {
        const gemPath = execSync(`bundle show ${engineName} 2>/dev/null`, { encoding: 'utf8' }).trim();
        if (gemPath && !gemPath.includes('Could not find')) return gemPath;
    } catch (e) {}

    // Final fallback to local path if it exists
    if (fs.existsSync(localPath)) return localPath;

    return null;
}

/**
 * Check if engine path is from local engines/ directory
 */
function isLocalEngine(engineName, enginePath) {
    return enginePath && enginePath.includes(`engines/${engineName}`);
}

// ============================================================================
// ENTRY POINT DISCOVERY
// ============================================================================

// Find all entry points from app and local engines
const appEntries = glob.sync('app/javascript/*.*');
const localEngineEntries = glob.sync('engines/*/app/javascript/*.*');

// Construct entry points object to flatten output structure
// Format: { "filename_without_ext": "path/to/file" }
const entryPoints = {};

function addEntryPoint(entry, overwrite = false) {
    const name = path.parse(entry).name;
    if (entryPoints[name] && !overwrite) {
        console.error(`[ERROR] Duplicate entry point name detected: '${name}'.`);
        console.error(`  Existing: ${entryPoints[name]}`);
        console.error(`  New:      ${entry}`);
        console.error(`Build failed to prevent asset overwrites. Please rename one of the files.`);
        process.exit(1);
    }
    entryPoints[name] = entry;
}

// Add app and local engine entries (fail on duplicates)
[...appEntries, ...localEngineEntries].forEach(entry => addEntryPoint(entry));

// Resolve gem engines and add their entry points (skip duplicates from local)
const resolvedEngines = {};
for (const engine of GEM_ENGINES) {
    const enginePath = getEnginePath(engine.name);
    if (!enginePath) continue;

    resolvedEngines[engine.name] = {
        ...engine,
        path: enginePath,
        isLocal: isLocalEngine(engine.name, enginePath),
        jsPath: path.join(enginePath, 'app/javascript'),
    };

    // Add entry points only if using gem (local entries already included via glob)
    if (!resolvedEngines[engine.name].isLocal) {
        console.log(`[INFO] Including ${engine.name} assets from gem: ${enginePath}`);
        const gemEntries = glob.sync(path.join(enginePath, 'app/javascript/*.*'));
        gemEntries.forEach(entry => {
            const name = path.parse(entry).name;
            if (!entryPoints[name]) {
                entryPoints[name] = entry;
            }
        });
    }
}

if (Object.keys(entryPoints).length === 0) {
    console.log('No entry points found for esbuild.');
    process.exit(0);
}

// ============================================================================
// ESBUILD PLUGIN FOR ENGINE IMPORTS
// ============================================================================

/**
 * Create an esbuild plugin to resolve engine imports
 * Handles: `import "engineName"` and `import "engineName/subpath"`
 */
function createEngineResolvePlugin(engineName, engineConfig) {
    return {
        name: `${engineName}-resolve`,
        setup(build) {
            if (!engineConfig) return;

            const jsPath = engineConfig.jsPath;
            const mainEntry = engineConfig.mainEntry || `${engineName}.js`;

            // Helper to resolve path with extension and index.js fallbacks
            function resolvePath(subpath) {
                let resolved = path.join(jsPath, subpath);

                // If path exists as-is (file with extension), use it
                if (fs.existsSync(resolved) && fs.statSync(resolved).isFile()) {
                    return resolved;
                }

                // Try common extensions
                for (const ext of ['.js', '.jsx', '.ts', '.tsx']) {
                    if (fs.existsSync(resolved + ext)) {
                        return resolved + ext;
                    }
                }

                // If it's a directory, look for index file
                if (fs.existsSync(resolved) && fs.statSync(resolved).isDirectory()) {
                    for (const indexFile of ['index.js', 'index.jsx', 'index.ts', 'index.tsx']) {
                        const indexPath = path.join(resolved, indexFile);
                        if (fs.existsSync(indexPath)) {
                            return indexPath;
                        }
                    }
                }

                return resolved;
            }

            // Resolve bare engine import to main entry
            const bareImportRegex = new RegExp(`^${engineName}$`);
            build.onResolve({ filter: bareImportRegex }, () => ({
                path: path.join(jsPath, mainEntry),
            }));

            // Resolve subpath imports
            const subpathRegex = new RegExp(`^${engineName}/`);
            build.onResolve({ filter: subpathRegex }, (args) => {
                const subpath = args.path.replace(subpathRegex, '');
                return { path: resolvePath(subpath) };
            });
        },
    };
}

// Create plugins for all resolved engines
const enginePlugins = Object.entries(resolvedEngines)
    .map(([name, config]) => createEngineResolvePlugin(name, config));

// ============================================================================
// ESBUILD CONFIGURATION
// ============================================================================

const config = {
    entryPoints: entryPoints,
    bundle: true,
    sourcemap: true,
    format: 'esm',
    jsx: 'automatic',
    outdir: 'app/assets/builds',
    publicPath: '/assets',
    // Resolve node_modules from host app, not from gem paths
    nodePaths: [path.join(process.cwd(), 'node_modules')],
    plugins: enginePlugins,
};

// ============================================================================
// BUILD EXECUTION
// ============================================================================

const watch = process.argv.includes('--watch');

if (watch) {
    esbuild.context(config)
        .then(ctx => {
            ctx.watch().catch(err => {
                console.error(err);
                process.exit(1);
            });
            console.log('Watching for changes...');
        })
        .catch(err => {
            console.error(err);
            process.exit(1);
        });
} else {
    esbuild.build(config).catch(() => process.exit(1));
}
