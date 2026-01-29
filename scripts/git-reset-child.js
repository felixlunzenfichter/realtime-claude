#!/usr/bin/env node
const { execSync } = require('child_process');
const path = require('path');

const repoRoot = path.dirname(__dirname);
try {
    execSync('git reset --hard HEAD~1', {
        cwd: repoRoot,
        encoding: 'utf8',
        stdio: 'inherit',
        timeout: 10000
    });
    process.exit(0);
} catch (err) {
    console.error(`Git reset failed: ${err.message}`);
    process.exit(1);
}
