
cat <<'EOF' > fullsetup.sh
#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "=== START: $(date) ==="

# --- STEP 1.1: FIX APT (fixapt.sh) ---
curl -fsSL https://raw.githubusercontent.com/Vikkvivo/utils/refs/heads/main/fixapt.sh | bash

# --- STEP 1.2: CLEAR VPS (cleandisk.sh) ---
curl -fsSL https://raw.githubusercontent.com/Vikkvivo/shortgenrl/refs/heads/main/cleandisk.sh | bash

# --- STEP 2: SET DNS ---
echo "nameserver 8.8.8.8
nameserver 1.1.1.1" > /etc/resolv.conf

# --- STEP 3: SETUP GENSYN (newgenrl installer) ---
curl -fsSL https://raw.githubusercontent.com/Vikkvivo/shortgenrl/refs/heads/main/newgenrl | bash

# --- STEP 4: SET CUDA COMMAND ---
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True

# --- STEP 5: PASTE SYSTEM UTILS FILE (setup.sh) ---
curl -fsSL https://raw.githubusercontent.com/Vikkvivo/utils/refs/heads/main/setup.sh | bash

# --- STEP 5.1: Replace manager.py using manager.sh ---
sudo rm -f rgym_exp/src/manager.py || true
curl -fsSL https://raw.githubusercontent.com/Vikkvivo/utils/refs/heads/main/manager.sh | bash

echo "=== FINISHED: $(date) ==="
# keep shell open for convenience
exec bash
EOF

chmod +x fullsetup.sh

./fullsetup.sh
