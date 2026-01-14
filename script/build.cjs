const esbuild = require('esbuild');
const glob = require('glob');

// Find all entry points
const appEntries = glob.sync('app/javascript/*.*');
const engineEntries = glob.sync('engines/*/app/javascript/*.*');
const entryPoints = [...appEntries, ...engineEntries];

if (entryPoints.length === 0) {
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

esbuild.build(config).catch(() => process.exit(1));
