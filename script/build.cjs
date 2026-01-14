const esbuild = require('esbuild');
const glob = require('glob');
const path = require('path');

// Find all entry points
const appEntries = glob.sync('app/javascript/*.*');
const engineEntries = glob.sync('engines/*/app/javascript/*.*');

// Construct entry points object to flatten output structure
// Format: { "filename_without_ext": "path/to/file" }
const entryPoints = {};

[...appEntries, ...engineEntries].forEach(entry => {
    const name = path.parse(entry).name;
    if (entryPoints[name]) {
        console.error(`[ERROR] Duplicate entry point name detected: '${name}'.`);
        console.error(`  Existing: ${entryPoints[name]}`);
        console.error(`  New:      ${entry}`);
        console.error(`Build failed to prevent asset overwrites. Please rename one of the files.`);
        process.exit(1);
    }
    entryPoints[name] = entry;
});

if (Object.keys(entryPoints).length === 0) {
    console.log('No entry points found for esbuild.');
    process.exit(0);
}

const config = {
    entryPoints: entryPoints,
    bundle: true,
    sourcemap: true,
    format: 'esm',
    jsx: 'automatic',
    outdir: 'app/assets/builds',
    publicPath: '/assets',
};

const watch = process.argv.includes('--watch');

if (watch) {
    esbuild.context(config).then(ctx => {
        ctx.watch();
        console.log('Watching for changes...');
    }).catch(() => process.exit(1));
} else {
    esbuild.build(config).catch(() => process.exit(1));
}
