#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."

VERSION="${VERSION_INPUT-}"
if [[ -z "$VERSION" ]]; then
  VERSION="$(awk '/^## Unreleased$/ { active=1; next } active && match($0, /^## \[[0-9][0-9.]*\]/) { value=$0; sub(/^## \[/, "", value); sub(/\].*$/, "", value); print value; exit }' CHANGELOG.md)"
fi

if [[ ! "$VERSION" =~ ^[0-9A-Za-z][0-9A-Za-z.+-]*$ ]]; then
  echo "Invalid version: $VERSION" >&2
  exit 1
fi

export VERSION
export VSCODE_TARGET=alpine-arm64
export MINIFY="${MINIFY-true}"
export ELECTRON_SKIP_BINARY_DOWNLOAD=1
export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
export npm_config_build_from_source=true
export npm_config_cxxflags="${npm_config_cxxflags-} -std=gnu++20"
export CXXFLAGS="${CXXFLAGS-} -std=gnu++20"
export npm_config_audit=false
export npm_config_fund=false

mkdir -p "$HOME/.gyp"
cat > "$HOME/.gyp/include.gypi" <<'EOF'
{
  "target_defaults": {
    "conditions": [
      ["OS=='linux'", {
        "cflags_cc": ["-std=gnu++20"]
      }]
    ]
  }
}
EOF

printf 'Building code-server %s for Alpine ARM64 (musl)\n' "$VERSION"

git config --global --add safe.directory "$PWD"
git config --global --add safe.directory "$PWD/lib/vscode"
git submodule update --init --recursive
quilt push -a

SKIP_SUBMODULE_DEPS=1 npm ci --no-audit --no-fund
npm --prefix lib/vscode ci --no-audit --no-fund
npm run build

node_version="$(node -p 'process.versions.node')"
expected_node_version="$(sed -n 's/^target="\([^"]*\)"$/\1/p' lib/vscode/remote/.npmrc | head -n 1)"
if [[ "$node_version" != "$expected_node_version" ]]; then
  echo "Node version mismatch: running $node_version, VS Code requires $expected_node_version" >&2
  exit 1
fi

node_dir="lib/vscode/.build/node/v${expected_node_version}/alpine-arm64"
mkdir -p "$node_dir"
cp "$(command -v node)" "$node_dir/node"
chmod 755 "$node_dir/node"

npm run build:vscode
KEEP_MODULES=1 npm run release

mkdir -p artifacts

test -x release/bin/code-server
test -x release/lib/node
ldd release/lib/node 2>&1 | grep -q musl

test -n "$(find release -type f -path '*linuxmusl-arm64/runtime.node' -print -quit)"

release/lib/node - "$PWD/release" <<'NODE'
const { createRequire } = require("module")
const path = require("path")

const release = process.argv[2]
const requireFromRelease = createRequire(path.join(release, "lib/vscode/package.json"))
const { spawn } = requireFromRelease("node-pty")
const child = spawn("/bin/sh", ["-c", "printf pty-ok"], {
  name: "xterm",
  cols: 80,
  rows: 24,
  cwd: release,
  env: process.env,
})

let output = ""
const timer = setTimeout(() => {
  child.kill()
  console.error("PTY smoke test timed out")
  process.exit(1)
}, 10000)

child.onData((data) => {
  output += data
})
child.onExit(({ exitCode }) => {
  clearTimeout(timer)
  if (exitCode !== 0 || !output.includes("pty-ok")) {
    console.error(`PTY smoke test failed: exit=${exitCode}, output=${JSON.stringify(output)}`)
    process.exit(1)
  }
  console.log("PTY smoke test passed")
})
NODE

server_log="$PWD/artifacts/server.log"
data_dir="$(mktemp -d "${TMPDIR:-/tmp}/code-server-smoke.XXXXXX")"
server_pid=""
cleanup() {
  if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT

release/bin/code-server \
  --auth none \
  --bind-addr 127.0.0.1:18080 \
  --user-data-dir "$data_dir" \
  --disable-telemetry >"$server_log" 2>&1 &
server_pid=$!

healthy=0
for _ in $(seq 1 60); do
  if curl -fsS http://127.0.0.1:18080/healthz >/dev/null; then
    healthy=1
    break
  fi
  if ! kill -0 "$server_pid" 2>/dev/null; then
    break
  fi
  sleep 2
done

if [[ "$healthy" != 1 ]]; then
  echo "code-server health check failed" >&2
  exit 1
fi

echo "code-server health check passed"

artifact_name="code-server-${VERSION}-postmarketos-arm64-musl"
tar -czf "artifacts/${artifact_name}.tar.gz" \
  --owner=0 --group=0 \
  --transform "s,^release,${artifact_name}," release
sha256sum "artifacts/${artifact_name}.tar.gz" > "artifacts/${artifact_name}.sha256"
cat > "artifacts/${artifact_name}.txt" <<EOF
Target: postmarketOS edge / aarch64 / musl
Node: ${expected_node_version}
Install:
  tar -xzf ${artifact_name}.tar.gz
  ./${artifact_name}/bin/code-server
EOF
printf 'Artifact: artifacts/%s.tar.gz\n' "$artifact_name"
