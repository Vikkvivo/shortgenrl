pkill -f launch_hydit_webui.py

# 1️Confirm folder exists and size again
sudo du -sh /root/HunyuanDiT

# 2️Delete the entire folder permanently
sudo rm -rf /root/HunyuanDiT

# 3️Verify deletion
sudo du -sh /root/HunyuanDiT 2>/dev/null || echo "✅ /root/HunyuanDiT deleted successfully"

# 4 Check free disk space
df -h

conda clean -a -y
