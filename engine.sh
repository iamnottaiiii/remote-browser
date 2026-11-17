#!/usr/bin/env bash
# Live browser engine. Runs on a GitHub Actions runner.
# Chrome on a virtual screen, streamed through a Cloudflare quick tunnel.
# The public link is written to live.json and committed back to this repo.

VNC_PASS='bjvfi-live'

sudo apt-get update -qq
sudo apt-get install -y -qq xvfb x11vnc novnc websockify openbox > /dev/null
if ! command -v google-chrome > /dev/null; then
  wget -q https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
  sudo apt-get install -y -qq ./google-chrome-stable_current_amd64.deb > /dev/null
fi
curl -sL -o /tmp/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
chmod +x /tmp/cloudflared

Xvfb :99 -screen 0 1280x800x24 > /tmp/xvfb.log 2>&1 &
sleep 2
DISPLAY=:99 openbox > /tmp/openbox.log 2>&1 &
mkdir -p ~/.vnc
x11vnc -storepasswd "$VNC_PASS" ~/.vnc/passwd > /dev/null 2>&1
x11vnc -display :99 -rfbport 5900 -rfbauth ~/.vnc/passwd -forever -shared -bg -o /tmp/x11vnc.log
websockify --web=/usr/share/novnc 6080 localhost:5900 > /tmp/websockify.log 2>&1 &
DISPLAY=:99 google-chrome --no-sandbox --disable-dev-shm-usage --start-maximized --user-data-dir=$HOME/chrome-profile https://duckduckgo.com > /tmp/chrome.log 2>&1 &

/tmp/cloudflared tunnel --url http://localhost:6080 --no-autoupdate > /tmp/tunnel.log 2>&1 &
URL=''
for i in $(seq 1 30); do
  URL=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' /tmp/tunnel.log | head -1)
  if [ -n "$URL" ]; then break; fi
  sleep 2
done
if [ -z "$URL" ]; then
  echo 'Tunnel did not come up'
  cat /tmp/tunnel.log
  exit 1
fi
echo "Tunnel is live: $URL"

git config user.name 'browser-bot'
git config user.email 'browser-bot@users.noreply.github.com'

publish() {
  TUNNEL_URL="$URL" VNC_PASS="$VNC_PASS" python3 -c "
import json, os, datetime
now = datetime.datetime.now(datetime.timezone.utc).isoformat()
url = os.environ['TUNNEL_URL'] + '/vnc.html?autoconnect=true&password=' + os.environ['VNC_PASS'] + '&resize=remote'
try:
    d = json.load(open('live.json'))
except Exception:
    d = {}
d['url'] = url
d.setdefault('started', now)
d['heartbeat'] = now
json.dump(d, open('live.json', 'w'), indent=2)
"
  git add live.json
  git commit -m 'browser live' > /dev/null || true
  git push > /dev/null || true
}

publish

# Keep the session alive, refreshing the heartbeat so the door page
# knows the browser is awake. The job itself is capped by the
# workflow timeout (355 minutes).
for i in $(seq 1 64); do
  sleep 300
  publish
done
