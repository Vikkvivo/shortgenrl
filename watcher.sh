cat << 'EOF' > /workspace/rl-swarm/watcher.sh
#!/usr/bin/env bash

SWARM_LOG="/workspace/rl-swarm/swarm.log"
CHECK_INTERVAL=30
NO_LOG_TIMEOUT=600   # 10 minutes
STATE_FILE="/tmp/rl_last_log_time"
ERR_PATTERNS="ConnectionRefusedError|PYTORCH_CUDA_ALLOC_CONF|Shutting down trainer"

mkdir -p /tmp
[ ! -f "$STATE_FILE" ] && date +%s > "$STATE_FILE"

log() { echo "$(date +'%Y-%m-%d %H:%M:%S') | $*"; }

run_recovery() {
  log "🚨 Triggering recovery..."

  # ---- KILL PROCESSES ----
  pkill -f swarm || true
  pkill -f rl-swarm || true
  pkill -f 'next start' || true
  pkill -f 'node .*next' || true
  pkill -f swarm_launcher || true
  pkill -f hivemind || true
  pkill -f rgym_exp || true

  sleep 10

  # ---- ENV SETUP ----
  cd /workspace/rl-swarm/ || true
  python3.10 -m venv ~/.venv310 || true
  source ~/.venv310/bin/activate || true

  # ---- NVM + NODE ----
  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.6/install.sh | bash
  export NVM_DIR="$HOME/.nvm"
  [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
  nvm install 20.18.0
  nvm alias default 20.18.0
  nvm use default

  # ---- MODAL LOGIN PATCH ----
  cd /workspace/rl-swarm/modal-login || true

  sed -i "/import { Inter } from \"next\/font\/google\";/d;/const inter = Inter({ subsets: \[\"latin\"\] });/d;s/<body className={inter.className}>/<body>/" app/layout.tsx

  sed -i "1i @import \"@fontsource/inter/index.css\";\n\nhtml, body {\n  font-family: \"Inter\", system-ui, sans-serif;\n}\n" app/globals.css

  sed -i '1i import "@fontsource/inter/400.css";' app/layout.tsx
  sed -i '2i import "@fontsource/inter/700.css";' app/layout.tsx

  yarn add @fontsource/inter encoding pino-pretty || true

  # ---- FINAL START ----
  cd /workspace/rl-swarm/ || true
  cp -i /workspace/login/{userApiKey.json,userData.json} /workspace/rl-swarm/modal-login/temp-data/ || true

  chmod +x /workspace/rl-swarm/start_rl.sh
  log "🚀 Running RL Swarm setup now..."
  bash /workspace/rl-swarm/start_rl.sh || true

  date +%s > "$STATE_FILE"
}

log "✅ Watcher started — monitoring swarm.log"

while true; do
  if [ -f "$SWARM_LOG" ]; then

    # ✅ IMMEDIATE ERROR CHECK
    if tail -n 20 "$SWARM_LOG" | grep -E "$ERR_PATTERNS" >/dev/null; then
      log "❗ Immediate error detected — triggering recovery"
      run_recovery
      sleep "$CHECK_INTERVAL"
      continue
    fi

    last_mtime=$(stat -c %Y "$SWARM_LOG")
    now=$(date +%s)

    # ✅ new log arrived → reset timer
    if [ "$last_mtime" -gt "$(cat $STATE_FILE)" ]; then
      date +%s > "$STATE_FILE"
      sleep "$CHECK_INTERVAL"
      continue
    fi

    # ✅ NO LOG FOR 10 MIN
    last_update=$(cat "$STATE_FILE")
    diff=$(( now - last_update ))

    if [ "$diff" -ge "$NO_LOG_TIMEOUT" ]; then
      log "⏳ No logs for $diff sec — checking last lines"

      if tail -n 10 "$SWARM_LOG" | grep -E "$ERR_PATTERNS" >/dev/null; then
        log "❗ Error found — triggering recovery"
      else
        log "⚠️ No logs for 10 min — triggering recovery anyway"
      fi

      run_recovery
    fi
  fi

  sleep "$CHECK_INTERVAL"
done
EOF

chmod +x /workspace/rl-swarm/watcher.sh
