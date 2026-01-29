#!/usr/bin/env node
const { execSync } = require('child_process');
const path = require('path');

const repoRoot = path.dirname(__dirname);
try {
    execSync('git push origin HEAD', {
        cwd: repoRoot,
        encoding: 'utf8',
        stdio: 'inherit',
        timeout: 30000
    });
    process.exit(0);
} catch (err) {
    console.error(`Git push failed: ${err.message}`);
    process.exit(1);
}
