cat << 'EOF' > /workspace/rl-swarm/watcher.sh
#!/usr/bin/env bash
# Robust & safe watcher for run_rl_swarm.sh
# - monitors run_rl_swarm.sh presence
# - watches /workspace/swarm.log for new error patterns
# - triggers recovery if process down, error patterns found, or no log activity for ACTIVITY_TIMEOUT
# - waits if log missing for WAIT_FOR_LOG seconds before forcing recovery
# - recovery only targets run_rl_swarm.sh and start_rl.sh (avoids killing watcher itself)

SWARM_CMD="./run_rl_swarm.sh"
SWARM_DIR="/workspace/rl-swarm"
SWARM_LOG="/workspace/rl-swarm/swarm.log"
CHECK_INTERVAL=30
ACTIVITY_TIMEOUT=300                    # 5 minutes
WAIT_FOR_LOG=120                        # wait for log creation before forcing recovery
COOLDOWN_AFTER_RECOVERY=60
STATE_DIR="/tmp/rl_swarm_watcher_state"
LAST_LINE_FILE="${STATE_DIR}/last_line.num"
ERR_PATTERNS="ConnectionRefusedError|PYTORCH_CUDA_ALLOC_CONF|Shutting down trainer"

# ---------- safer RECOVERY_CMDS (targeted, avoid killing watcher) ----------
RECOVERY_CMDS=(
  # kill processes that run the run script (match exact script name)
  "for p in \$(pgrep -f 'run_rl_swarm.sh' || true); do if [ \"\$p\" != \"\$\$\" ]; then echo \"killing pid \$p\"; kill -9 \$p || true; fi; done"

  # kill processes that run the start script (if present)
  "for p in \$(pgrep -f '/workspace/rl-swarm/start_rl.sh' || true); do if [ \"\$p\" != \"\$\$\" ]; then echo \"killing pid \$p\"; kill -9 \$p || true; fi; done"

  # ADDITIONAL 2 KILL COMMANDS (as requested)
  "pkill -f 'next start' || true"
  "pkill -f 'node .*next' || true"

  "cd /workspace/rl-swarm/ || true"
  # keep venv creation idempotent - won't remove existing venv
  "python3.10 -m venv ~/.venv310 || true"
  # source venv in subshell before running start script
  "source ~/.venv310/bin/activate || true"

  # ✅ ✅ INSERTED COMMANDS START
  "cd /workspace/rl-swarm/modal-login || true"
  "sed -i \"/import { Inter } from \\\"next\\/font\\/google\\\";/d;/const inter = Inter({ subsets: \\[\\\"latin\\\"\\] });/d;s/<body className={inter.className}>/<body>/\" app/layout.tsx"
  "sed -i \"1i @import \\\"@fontsource/inter/index.css\\\";\\n\\nhtml, body {\\n  font-family: \\\"Inter\\\", system-ui, sans-serif;\\n}\\n\" app/globals.css"
  "sed -i '1i import \"@fontsource/inter/400.css\";' /workspace/rl-swarm/modal-login/app/layout.tsx"
  "sed -i '2i import \"@fontsource/inter/700.css\";' /workspace/rl-swarm/modal-login/app/layout.tsx"
  "yarn add @fontsource/inter encoding pino-pretty || true"
  "cd /workspace/rl-swarm/ || true"
  # ✅ ✅ INSERTED COMMANDS END

  "cp -i /workspace/login/{userApiKey.json,userData.json} /workspace/rl-swarm/modal-login/temp-data/ || true"
  "ls -l /workspace/rl-swarm/modal-login/temp-data/ || true"
  "chmod +x /workspace/rl-swarm/start_rl.sh || true"
  "echo '🚀 Running RL Swarm setup now...'"
  "bash /workspace/rl-swarm/start_rl.sh || true"
)
# ------------------------------------------------------------------

mkdir -p "${STATE_DIR}"
touch "${LAST_LINE_FILE}"

log(){ echo "$(date +'%Y-%m-%d %H:%M:%S') | $*"; }

log "Watcher starting. SWARM_LOG=${SWARM_LOG}"

# initialize pointer
if [ -f "${SWARM_LOG}" ]; then
  wc -l < "${SWARM_LOG}" > "${LAST_LINE_FILE}" || echo "0" > "${LAST_LINE_FILE}"
else
  echo "0" > "${LAST_LINE_FILE}"
fi

# trap signals and exit gracefully (won't auto-restart on kill)
trap 'log "Watcher received SIGTERM/SIGINT - exiting"; exit 0' SIGTERM SIGINT

is_swarm_running(){
  pgrep -f "$(basename ${SWARM_CMD})" >/dev/null 2>&1
  return $?
}

log_mtime(){
  if [ -f "${SWARM_LOG}" ]; then
    stat -c %Y "${SWARM_LOG}" 2>/dev/null || echo 0
  else
    echo 0
  fi
}

check_errors_in_log(){
  if [ ! -f "${SWARM_LOG}" ]; then
    return 1
  fi
  last_line=$(cat "${LAST_LINE_FILE}" 2>/dev/null || echo 0)
  total_lines=$(wc -l < "${SWARM_LOG}" 2>/dev/null || echo 0)
  if [ "${total_lines}" -le "${last_line}" ]; then
    echo "${total_lines}" > "${LAST_LINE_FILE}"
    return 1
  fi
  start=$(( last_line + 1 ))
  sed -n "${start},${total_lines}p" "${SWARM_LOG}" > "${STATE_DIR}/new_chunk.log"
  echo "${total_lines}" > "${LAST_LINE_FILE}"
  if grep -E "${ERR_PATTERNS}" "${STATE_DIR}/new_chunk.log" >/dev/null 2>&1; then
    log "ERROR PATTERN MATCH in new lines:"
    grep -nE "${ERR_PATTERNS}" "${STATE_DIR}/new_chunk.log" >&2 || true
    return 0
  fi
  return 1
}

run_recovery(){
  log "Recovery triggered"
  echo "---- Recovery begin ----" >> "${STATE_DIR}/recovery.log"
  (
    set -x
    for cmd in "${RECOVERY_CMDS[@]}"; do
      log "RUN: $cmd"
      bash -c "${cmd}" >> "${STATE_DIR}/recovery.log" 2>&1 || log "Command failed (continue): $cmd"
    done
  )
  echo "---- Recovery end ----" >> "${STATE_DIR}/recovery.log"
  log "Recovery finished. Sleeping ${COOLDOWN_AFTER_RECOVERY}s"
  sleep "${COOLDOWN_AFTER_RECOVERY}"
  if [ -f "${SWARM_LOG}" ]; then
    wc -l < "${SWARM_LOG}" > "${LAST_LINE_FILE}" || echo "0" > "${LAST_LINE_FILE}"
  else
    echo "0" > "${LAST_LINE_FILE}"
  fi
}

# main loop
while true; do
  # 1) process not running -> recovery
  if ! is_swarm_running; then
    log "run process NOT running -> triggering recovery"
    run_recovery
    sleep "${CHECK_INTERVAL}"
    continue
  fi

  # 2) if log missing, wait WAIT_FOR_LOG seconds for creation before declaring stuck
  if [ ! -f "${SWARM_LOG}" ]; then
    log "SWARM_LOG not found at ${SWARM_LOG}. Waiting up to ${WAIT_FOR_LOG}s for file to appear..."
    waited=0
    while [ "${waited}" -lt "${WAIT_FOR_LOG}" ]; do
      sleep 5
      waited=$(( waited + 5 ))
      if [ -f "${SWARM_LOG}" ]; then
        log "SWARM_LOG appeared after ${waited}s"
        wc -l < "${SWARM_LOG}" > "${LAST_LINE_FILE}" || true
        break
      fi
      if ! is_swarm_running; then
        log "run process stopped while waiting for log -> immediate recovery"
        run_recovery
        break
      fi
    done
    if [ ! -f "${SWARM_LOG}" ]; then
      log "No log file after waiting ${WAIT_FOR_LOG}s -> triggering recovery"
      run_recovery
      sleep "${CHECK_INTERVAL}"
      continue
    fi
  fi

  # 3) check activity age
  lm=$(log_mtime)
  if [ "${lm}" -eq 0 ]; then
    log "log mtime returned 0 — will skip activity-check this iteration"
  else
    now=$(date +%s)
    age=$(( now - lm ))
    if [ "${age}" -ge "${ACTIVITY_TIMEOUT}" ]; then
      log "No log activity for ${age}s (threshold ${ACTIVITY_TIMEOUT}s) -> triggering recovery"
      run_recovery
      sleep "${CHECK_INTERVAL}"
      continue
    fi
  fi

  # 4) scan new lines for error patterns
  if check_errors_in_log; then
    log "Error pattern detected in new log lines -> triggering recovery"
    run_recovery
    sleep "${CHECK_INTERVAL}"
    continue
  fi

  sleep "${CHECK_INTERVAL}"
done
EOF

chmod +x /workspace/rl-swarm/watcher.sh

