#!/usr/bin/env bash
# Full computer engine. Runs on a GitHub Actions runner.
# An XFCE desktop on a virtual screen, streamed fullscreen through a
# Cloudflare quick tunnel. The public link is written to live.json and
# committed back to this repo. The Chrome profile AND the desktop
# state (installed apps, pins, created files, wallpaper, settings)
# are saved (AES-256 encrypted) into the repo every minute and
# restored at the next start, when PROFILE_KEY is set.
# Direct datacenter egress: the lab proved the presentation fixes
# carry the human checks, so no home exit node is used here.

VNC_PASS="${VNC_PASS:-bjvfi-live}"
export BROWSER_REPO_DIR="$(pwd)"
export SAVE_REPO="$HOME/save-repo"
export PUB_REPO="$HOME/pub-repo"
TS_STATUS='datacenter direct'
TS_PEERS=''

sudo apt-get update -qq
sudo apt-get install -y -qq xvfb x11vnc novnc websockify xfce4 xfce4-terminal mousepad dbus-x11 imagemagick rsync fonts-liberation fonts-noto-core > /dev/null
if ! command -v google-chrome > /dev/null; then
  wget -q https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
  sudo apt-get install -y -qq ./google-chrome-stable_current_amd64.deb > /dev/null
fi
curl -sL -o /tmp/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
chmod +x /tmp/cloudflared

git config user.name 'browser-bot'
git config user.email 'browser-bot@users.noreply.github.com'

# The save loop and the publish loop each get their OWN clone of this
# repo. In the old build they shared one checkout and their pushes
# kept colliding, which froze the live.json heartbeat. Separate
# clones, and each cycle starts from a fresh fetch of origin/main.
setup_clone() {
  local src="$BROWSER_REPO_DIR" dst="$1" url eh
  rm -rf "$dst"
  git clone -q "$src" "$dst" 2>/dev/null || return 1
  url=$(git -C "$src" remote get-url origin 2>/dev/null)
  [ -n "$url" ] && git -C "$dst" remote set-url origin "$url"
  eh=$(git -C "$src" config --get http.https://github.com/.extraheader 2>/dev/null || true)
  [ -n "$eh" ] && git -C "$dst" config http.https://github.com/.extraheader "$eh"
  git -C "$dst" config user.name 'browser-bot'
  git -C "$dst" config user.email 'browser-bot@users.noreply.github.com'
  git -C "$dst" fetch -q origin main 2>/dev/null || true
  git -C "$dst" checkout -q -B main FETCH_HEAD 2>/dev/null || git -C "$dst" checkout -q -B main 2>/dev/null || true
}
setup_clone "$SAVE_REPO" || echo 'Save clone setup failed'
setup_clone "$PUB_REPO" || echo 'Publish clone setup failed'

# The save script, shared by the auto-save and the manual Save page.
# It packs the Chrome profile and the whole desktop state into one
# AES-256 encrypted file in its own clone and pushes it.
cat > $HOME/do-save.sh << 'SAVE_EOF'
#!/usr/bin/env bash
exec 9>/tmp/save.lock
if ! flock -n 9; then
  echo 'A save is already running'
  exit 3
fi
if [ -z "$PROFILE_KEY" ] && [ -f "$HOME/.browser-save-key" ]; then
  PROFILE_KEY=$(cat "$HOME/.browser-save-key")
  export PROFILE_KEY
fi
if [ -z "$PROFILE_KEY" ]; then
  echo 'Saving is not switched on'
  exit 2
fi
SAVE_REPO="${SAVE_REPO:-$HOME/save-repo}"
if [ ! -d "$SAVE_REPO/.git" ]; then
  echo 'Save repo missing'
  exit 1
fi
rm -rf /tmp/prof-stage && mkdir -p /tmp/prof-stage/profile /tmp/prof-stage/state
rsync -a \
  --exclude='*/Cache/*' --exclude='*/Code Cache/*' --exclude='*/GPUCache/*' \
  --exclude='*/Service Worker/CacheStorage/*' --exclude='*/blob_storage/*' \
  --exclude='SingletonLock' --exclude='SingletonCookie' --exclude='SingletonSocket' \
  $HOME/chrome-profile/ /tmp/prof-stage/profile/ 2>/dev/null
rsync -a $HOME/Desktop/ /tmp/prof-stage/state/Desktop/ 2>/dev/null
rsync -a $HOME/.local/share/applications/ /tmp/prof-stage/state/applications/ 2>/dev/null
rsync -a $HOME/.local/share/icons/ /tmp/prof-stage/state/icons/ 2>/dev/null
rsync -a $HOME/.config/xfce4/ /tmp/prof-stage/state/xfce4/ 2>/dev/null
rsync -a $HOME/Work/ /tmp/prof-stage/state/Work/ 2>/dev/null
rsync -a $HOME/.store/ /tmp/prof-stage/state/store/ 2>/dev/null
MANIFEST=$(cd /tmp/prof-stage && find . -type f -o -type l | sort | xargs -r sha256sum 2>/dev/null | sha256sum | awk '{print $1}')
if [ -n "$MANIFEST" ] && [ "$MANIFEST" = "$(cat $HOME/.profile-manifest 2>/dev/null)" ]; then
  echo 'Saved'
  exit 0
fi
cd "$SAVE_REPO" || exit 1
git fetch -q origin main 2>/dev/null || true
git reset --hard -q origin/main 2>/dev/null || true
if tar -czf - -C /tmp/prof-stage . 2>/dev/null | openssl enc -aes-256-cbc -salt -pbkdf2 -pass env:PROFILE_KEY -out profile.tar.gz.enc 2>/dev/null; then
  git add profile.tar.gz.enc
  git commit -m 'profile save' > /dev/null 2>&1 || true
  if git push -q origin main > /dev/null 2>&1; then
    printf '%s' "$MANIFEST" > $HOME/.profile-manifest
    echo 'Saved'
    exit 0
  fi
fi
echo 'Save failed'
exit 1
SAVE_EOF
chmod +x $HOME/do-save.sh

# The key lives in a private file inside the session only, so the
# Save page can run saves without the secret in its own hands.
if [ -n "$PROFILE_KEY" ]; then
  printf '%s' "$PROFILE_KEY" > $HOME/.browser-save-key
  chmod 600 $HOME/.browser-save-key
fi

# The Save page: a tiny local web page with one big button.
cat > $HOME/save-server.py << 'PYEOF'
import os
import subprocess
from http.server import BaseHTTPRequestHandler, HTTPServer

PAGE = """<!DOCTYPE html>
<html><head><meta charset='utf-8'><title>Save this computer</title>
<style>body{font-family:monospace;padding:40px 24px;font-size:22px;color:#111}
button{font-size:26px;padding:20px 34px;background:#111;color:#fff;border:0;width:100%}
</style></head><body>
<p>This page saves the whole computer: browser tabs, bookmarks, logins, installed apps, files, and settings.</p>
<form method='POST' action='/save'><button type='submit'>SAVE NOW</button></form>
<p>{note}</p>
</body></html>"""

class Handler(BaseHTTPRequestHandler):
    def _send(self, note):
        body = PAGE.replace('{note}', note).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self._send('Auto-save also runs every minute while the computer is on.')

    def do_POST(self):
        if self.path != '/save':
            self._send('')
            return
        try:
            result = subprocess.run(['bash', os.path.expanduser('~/do-save.sh')],
                                    capture_output=True, text=True, timeout=180)
            out = (result.stdout or '') + (result.stderr or '')
        except Exception:
            out = 'failed'
        if 'Saved' in out:
            note = 'Saved. Everything on this computer is packed away safely.'
        elif 'already running' in out:
            note = 'A save is already running. Give it a few seconds.'
        elif 'not switched on' in out:
            note = 'Saving is not switched on yet. It turns on with the PROFILE_KEY secret.'
        else:
            note = 'The save did not finish. The auto-save will try again soon.'
        self._send(note)

    def log_message(self, *args):
        pass

HTTPServer(('127.0.0.1', 8080), Handler).serve_forever()
PYEOF

# The Store helper: serves the Store page on 127.0.0.1:8090 and does
# the file work a web page cannot do. Installing writes a launcher
# that opens the app with Chrome's --app flag, so installed apps open
# as their own windows with no address bar or tabs. Pins are written
# into the xfce4-panel configuration, which is regenerated from the
# saved state. All state lives in ~/.store, inside the saved area.
cat > $HOME/store-helper.py << 'STORE_EOF'
#!/usr/bin/env python3
import json
import os
import re
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

HOME = os.path.expanduser('~')
STATE_DIR = os.path.join(HOME, '.store')
STATE_FILE = os.path.join(STATE_DIR, 'state.json')
APPS_DIR = os.path.join(HOME, '.local', 'share', 'applications')
DESKTOP_DIR = os.path.join(HOME, 'Desktop')
ICON_DIR = os.path.join(HOME, '.local', 'share', 'icons', 'apps')
PANEL_XML = os.path.join(HOME, '.config', 'xfce4', 'xfconf',
                         'xfce-perchannel-xml', 'xfce4-panel.xml')
CHROME_FLAGS = ('--user-data-dir=%s/chrome-profile --lang=en-US '
                '--force-webrtc-ip-handling-policy=disable_non_proxied_udp '
                '--disable-blink-features=AutomationControlled' % HOME)
ICLOUD = 'https://www.icloud.com'

CATALOG = [
    {'id': 'textnow', 'name': 'TextNow',
     'url': 'https://www.textnow.com/messaging', 'color': '#4a7c59',
     'desc': 'Texting and calling, in its own window'},
    {'id': 'icloud-mail', 'name': 'iCloud Mail',
     'url': ICLOUD + '/mail', 'color': '#8a8f98',
     'desc': 'Apple mail through the web door'},
    {'id': 'icloud-photos', 'name': 'iCloud Photos',
     'url': ICLOUD + '/photos', 'color': '#b08968',
     'desc': 'Apple photos through the web door'},
    {'id': 'icloud-notes', 'name': 'Notes',
     'url': ICLOUD + '/notes', 'color': '#a98f2d',
     'desc': 'iCloud notes through the web door'},
    {'id': 'spotify', 'name': 'Spotify',
     'url': 'https://open.spotify.com', 'color': '#3e7c4f',
     'desc': 'Music in the browser'},
    {'id': 'word', 'name': 'Microsoft Word',
     'url': 'https://www.office.com/launch/word', 'color': '#5b7fa6',
     'desc': 'Word documents on the web'},
    {'id': 'calculator', 'name': 'Calculator',
     'url': 'https://www.calculator.net', 'color': '#777777',
     'desc': 'A plain web calculator'},
    {'id': 'zoom', 'name': 'Zoom',
     'url': 'https://app.zoom.us/wc/home', 'color': '#6a7f9e',
     'desc': 'Zoom meetings in the browser'},
]

PAGE = """<!DOCTYPE html>
<html><head><meta charset='utf-8'><title>Store</title>
<style>
body{font-family:Georgia,serif;background:#f3ead8;color:#2b2620;margin:0;padding:28px}
h1{font-size:26px;font-weight:normal;margin:0 0 4px}
p.sub{color:#6d6152;margin:0 0 20px}
.bar{background:#fffdf7;border:1px solid #d8cbae;padding:16px;margin-bottom:22px}
.bar input[type=text]{font-size:16px;padding:9px;width:62%;border:1px solid #c9b995}
.bar input[type=text].name{width:22%}
button{font-size:15px;padding:9px 16px;background:#2e2a26;color:#f3ead8;border:0;cursor:pointer}
button.plain{background:#e7dcc4;color:#2b2620;border:1px solid #c9b995}
.app{background:#fffdf7;border:1px solid #d8cbae;padding:14px 16px;margin-bottom:10px;
display:flex;align-items:center;gap:14px}
.app img{width:44px;height:44px}
.app .grow{flex:1}
.app .nm{font-size:19px}
.app .ds{color:#6d6152;font-size:14px}
.tag{font-size:12px;color:#8a7a5c}
#msg{color:#4a7c59;min-height:20px}
</style></head><body>
<h1>Store</h1>
<p class='sub'>Install a thing and it lands on the desktop and in the menu, as its own app window.</p>
<div class='bar'>
<input type='text' id='link' placeholder='Paste a link, e.g. https://example.com'>
<input type='text' id='linkname' class='name' placeholder='Name (optional)'>
<button onclick='installLink()'>Install</button>
<p id='msg'></p>
</div>
<div id='list'></div>
<script>
function api(path, data){
  return fetch(path,{method:'POST',headers:{'Content-Type':'application/json'},
    body:JSON.stringify(data||{})}).then(function(r){return r.json()});
}
function msg(t){document.getElementById('msg').textContent=t}
function installLink(){
  var url=document.getElementById('link').value;
  var name=document.getElementById('linkname').value;
  if(!url){msg('Paste a link first.');return}
  api('/api/install',{url:url,name:name}).then(function(s){
    document.getElementById('link').value='';document.getElementById('linkname').value='';
    msg('Installed.');render(s)});
}
function render(s){
  var byId={}; s.installed.forEach(function(a){byId[a.id]=a});
  var html='';
  s.catalog.forEach(function(c){ html+=row(c, byId[c.id], s.pinned.indexOf(c.id)>=0) });
  s.installed.forEach(function(a){
    if(!s.catalog.some(function(c){return c.id===a.id})) html+=row(a, a, s.pinned.indexOf(a.id)>=0);
  });
  document.getElementById('list').innerHTML=html;
}
function row(c, inst, pinned){
  var icon='/icon/'+(inst?inst.id:c.id);
  var h="<div class='app'><img src='"+icon+"' alt=''><div class='grow'><div class='nm'>"+
    c.name+"</div><div class='ds'>"+(c.desc||c.url)+"</div></div>";
  if(inst){
    h+="<span class='tag'>installed</span>";
    h+=" <button class='plain' onclick=\"act('/api/uninstall','"+c.id+"')\">Remove</button>";
    if(pinned) h+=" <button class='plain' onclick=\"act('/api/unpin','"+c.id+"')\">Unpin</button>";
    else h+=" <button onclick=\"act('/api/pin','"+c.id+"')\">Pin to taskbar</button>";
  } else {
    h+=" <button onclick=\"act('/api/install','"+c.id+"')\">Install</button>";
  }
  return h+"</div>";
}
function act(path,id){ api(path,{id:id}).then(render) }
fetch('/api/state').then(function(r){return r.json()}).then(render);
</script>
</body></html>"""


def load_state():
    try:
        with open(STATE_FILE) as f:
            s = json.load(f)
        s.setdefault('installed', [])
        s.setdefault('pinned', [])
        return s
    except Exception:
        return {'installed': [], 'pinned': []}


def save_state(s):
    os.makedirs(STATE_DIR, exist_ok=True)
    tmp = STATE_FILE + '.tmp'
    with open(tmp, 'w') as f:
        json.dump(s, f, indent=2)
    os.replace(tmp, STATE_FILE)


def make_icon(entry):
    os.makedirs(ICON_DIR, exist_ok=True)
    path = os.path.join(ICON_DIR, entry['id'] + '.png')
    if os.path.exists(path):
        return path
    letter = (entry.get('name') or 'A')[:1].upper()
    try:
        subprocess.run(['convert', '-size', '128x128',
                        'xc:' + entry.get('color', '#666666'),
                        '-fill', 'white', '-font', 'Liberation-Sans-Bold',
                        '-pointsize', '72', '-gravity', 'center',
                        '-annotate', '0', letter, path],
                       check=True, timeout=20,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return path
    except Exception:
        return 'web-browser'


def write_launchers(entry):
    icon = make_icon(entry)
    body = ('[Desktop Entry]\nType=Application\nVersion=1.0\n'
            'Name=%s\nExec=google-chrome %s --app=%s\nIcon=%s\n'
            'Terminal=false\nCategories=Network;WebApp;\n'
            % (entry['name'], CHROME_FLAGS,
               entry['url'].replace(' ', ''), icon))
    for d in (APPS_DIR, DESKTOP_DIR):
        os.makedirs(d, exist_ok=True)
        p = os.path.join(d, entry['id'] + '.desktop')
        with open(p, 'w') as f:
            f.write(body)
        os.chmod(p, 0o755)


def remove_launchers(app_id):
    for d in (APPS_DIR, DESKTOP_DIR):
        try:
            os.remove(os.path.join(d, app_id + '.desktop'))
        except OSError:
            pass


def write_panel_config():
    state = load_state()
    by_id = {a['id']: a for a in state['installed']}
    pinned = [by_id[i] for i in state['pinned'] if i in by_id]
    ids = [1]
    launchers = []
    nid = 10
    for app in pinned:
        ids.append(nid)
        launchers.append(
            '    <property name="plugin-%d" type="string" value="launcher">\n'
            '      <property name="items" type="array">\n'
            '        <value type="string" value="%s.desktop"/>\n'
            '      </property>\n'
            '    </property>' % (nid, app['id']))
        nid += 1
    ids += [2, 90, 91]
    plugin_ids = '\n'.join('          <value type="int" value="%d"/>' % i
                           for i in ids)
    xml = ('<?xml version="1.0" encoding="UTF-8"?>\n'
           '<channel name="xfce4-panel" version="1.0">\n'
           '  <property name="panels" type="array">\n'
           '    <value type="int" value="1"/>\n'
           '    <property name="panel-1" type="empty">\n'
           '      <property name="position" type="string" value="p=8;x=0;y=0"/>\n'
           '      <property name="length" type="uint" value="100"/>\n'
           '      <property name="position-locked" type="bool" value="true"/>\n'
           '      <property name="icon-size" type="uint" value="28"/>\n'
           '      <property name="size" type="uint" value="40"/>\n'
           '      <property name="background-style" type="uint" value="1"/>\n'
           '      <property name="background-color" type="array">\n'
           '        <value type="uint" value="9500"/>\n'
           '        <value type="uint" value="9500"/>\n'
           '        <value type="uint" value="9500"/>\n'
           '        <value type="uint" value="65535"/>\n'
           '      </property>\n'
           '      <property name="plugin-ids" type="array">\n'
           + plugin_ids + '\n'
           '      </property>\n'
           '    </property>\n'
           '  </property>\n'
           '  <property name="plugins" type="empty">\n'
           '    <property name="plugin-1" type="string" value="applicationsmenu">\n'
           '      <property name="show-button-title" type="bool" value="false"/>\n'
           '    </property>\n'
           + ('\n'.join(launchers) + '\n' if launchers else '')
           + '    <property name="plugin-2" type="string" value="tasklist">\n'
           '      <property name="grouping" type="uint" value="1"/>\n'
           '    </property>\n'
           '    <property name="plugin-90" type="string" value="separator">\n'
           '      <property name="expand" type="bool" value="true"/>\n'
           '      <property name="style" type="uint" value="0"/>\n'
           '    </property>\n'
           '    <property name="plugin-91" type="string" value="clock">\n'
           '      <property name="mode" type="uint" value="2"/>\n'
           '      <property name="digital-format" type="string" value="%l:%M %p"/>\n'
           '    </property>\n'
           '  </property>\n'
           '</channel>\n')
    os.makedirs(os.path.dirname(PANEL_XML), exist_ok=True)
    with open(PANEL_XML, 'w') as f:
        f.write(xml)


def restart_panel():
    env = dict(os.environ)
    env.setdefault('DISPLAY', ':99')
    try:
        subprocess.run(['xfce4-panel', '-q'], env=env, timeout=10,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass
    try:
        subprocess.run(['pkill', '-9', 'xfconfd'], timeout=10,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass
    time.sleep(1)
    write_panel_config()
    try:
        subprocess.Popen(['xfce4-panel'], env=env, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, start_new_session=True)
    except Exception:
        pass


def slugify(name, taken):
    base = re.sub(r'[^a-z0-9]+', '-', name.lower()).strip('-') or 'app'
    slug = base
    n = 2
    while slug in taken:
        slug = '%s-%d' % (base, n)
        n += 1
    return slug


def name_from_url(url):
    host = (urlparse(url).hostname or 'app').lower()
    if host.startswith('www.'):
        host = host[4:]
    return (host.split('.')[0] or 'app').capitalize()


def do_install(data):
    state = load_state()
    if data.get('id'):
        cat = next((c for c in CATALOG if c['id'] == data['id']), None)
        if not cat:
            return None
        entry = {'id': cat['id'], 'name': cat['name'], 'url': cat['url'],
                 'color': cat['color'], 'desc': cat['desc']}
    else:
        url = (data.get('url') or '').strip()
        if not url:
            return None
        if not url.startswith(('http://', 'https://')):
            url = 'https://' + url
        name = (data.get('name') or '').strip() or name_from_url(url)
        taken = {a['id'] for a in state['installed']} | {c['id'] for c in CATALOG}
        entry = {'id': slugify(name, taken), 'name': name, 'url': url,
                 'color': '#7a6a53', 'desc': url}
    if not any(a['id'] == entry['id'] for a in state['installed']):
        state['installed'].append(entry)
    write_launchers(entry)
    save_state(state)
    return public_state(state)


def public_state(state=None):
    if state is None:
        state = load_state()
    return {'catalog': CATALOG, 'installed': state['installed'],
            'pinned': state['pinned']}


class Handler(BaseHTTPRequestHandler):
    def _json(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == '/api/state':
            self._json(public_state())
            return
        if self.path.startswith('/icon/'):
            app_id = self.path[len('/icon/'):]
            p = os.path.join(ICON_DIR, app_id + '.png')
            if os.path.exists(p):
                with open(p, 'rb') as f:
                    body = f.read()
                self.send_response(200)
                self.send_header('Content-Type', 'image/png')
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            else:
                self.send_response(404)
                self.end_headers()
            return
        body = PAGE.encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        try:
            n = int(self.headers.get('Content-Length') or 0)
            data = json.loads(self.rfile.read(n) or b'{}')
        except Exception:
            data = {}
        state = load_state()
        app_id = data.get('id')
        if self.path == '/api/install':
            out = do_install(data)
            self._json(out if out is not None else public_state(), 200 if out else 400)
            return
        if self.path == '/api/uninstall':
            state['installed'] = [a for a in state['installed'] if a['id'] != app_id]
            was_pinned = app_id in state['pinned']
            state['pinned'] = [i for i in state['pinned'] if i != app_id]
            remove_launchers(app_id)
            save_state(state)
            if was_pinned:
                restart_panel()
            self._json(public_state(state))
            return
        if self.path == '/api/pin':
            if any(a['id'] == app_id for a in state['installed']) and app_id not in state['pinned']:
                state['pinned'].append(app_id)
                save_state(state)
                restart_panel()
            self._json(public_state(state))
            return
        if self.path == '/api/unpin':
            if app_id in state['pinned']:
                state['pinned'] = [i for i in state['pinned'] if i != app_id]
                save_state(state)
                restart_panel()
            self._json(public_state(state))
            return
        self._json(public_state(state))

    def log_message(self, *args):
        pass


if __name__ == '__main__':
    if '--regen-panel' in sys.argv:
        write_panel_config()
    else:
        ThreadingHTTPServer(('127.0.0.1', 8090), Handler).serve_forever()
STORE_EOF

sudo timedatectl set-timezone America/New_York > /dev/null 2>&1 || true
export TZ=America/New_York
Xvfb :99 -screen 0 1280x800x24 > /tmp/xvfb.log 2>&1 &
sleep 2

mkdir -p $HOME/Desktop $HOME/.local/share/applications $HOME/.local/share/icons \
         $HOME/.config/xfce4 $HOME/Work $HOME/.store $HOME/Templates $HOME/chrome-profile

# Restore the saved profile and desktop state, if a save exists and
# the key is set. The save file is AES-256 encrypted; without
# PROFILE_KEY it is opaque. Two layouts are understood: the current
# one (profile/ and state/ folders) and the older browser-only one
# (profile files at the top), so the logins saved by the previous
# build carry over.
RESTORED=0
if [ -n "$PROFILE_KEY" ] && [ -f profile.tar.gz.enc ]; then
  rm -rf /tmp/restore && mkdir -p /tmp/restore
  if openssl enc -d -aes-256-cbc -pbkdf2 -pass env:PROFILE_KEY -in profile.tar.gz.enc 2>/dev/null | tar -xzf - -C /tmp/restore 2>/dev/null; then
    if [ -d /tmp/restore/profile ]; then
      rsync -a /tmp/restore/profile/ $HOME/chrome-profile/ 2>/dev/null
      [ -d /tmp/restore/state/Desktop ] && rsync -a /tmp/restore/state/Desktop/ $HOME/Desktop/ 2>/dev/null
      [ -d /tmp/restore/state/applications ] && rsync -a /tmp/restore/state/applications/ $HOME/.local/share/applications/ 2>/dev/null
      [ -d /tmp/restore/state/icons ] && rsync -a /tmp/restore/state/icons/ $HOME/.local/share/icons/ 2>/dev/null
      [ -d /tmp/restore/state/xfce4 ] && rsync -a /tmp/restore/state/xfce4/ $HOME/.config/xfce4/ 2>/dev/null
      [ -d /tmp/restore/state/Work ] && rsync -a /tmp/restore/state/Work/ $HOME/Work/ 2>/dev/null
      [ -d /tmp/restore/state/store ] && rsync -a /tmp/restore/state/store/ $HOME/.store/ 2>/dev/null
    else
      rsync -a /tmp/restore/ $HOME/chrome-profile/ 2>/dev/null
    fi
    rm -f $HOME/chrome-profile/SingletonLock $HOME/chrome-profile/SingletonCookie $HOME/chrome-profile/SingletonSocket
    RESTORED=1
    echo 'Saved profile and desktop restored'
  else
    echo 'Saved profile could not be opened, starting fresh'
  fi
fi

# Wallpaper: a calm warm tan gradient, generated on the spot.
if [ ! -f $HOME/wallpaper.png ]; then
  convert -size 1280x800 gradient:'#e9dcbc-#c8ad7f' $HOME/wallpaper.png 2>/dev/null \
    || convert -size 1280x800 xc:'#d9c69c' $HOME/wallpaper.png 2>/dev/null || true
fi

CHROME_FLAGS="--user-data-dir=$HOME/chrome-profile --lang=en-US --force-webrtc-ip-handling-policy=disable_non_proxied_udp --disable-blink-features=AutomationControlled"

# First boot only: seed the desktop with the starter apps. After
# that, whatever the saved state holds is what the desktop shows.
if [ "$RESTORED" = '0' ]; then
  seed_app() {
    local file="$1" name="$2" exec_line="$3" icon="$4" cats="$5"
    for d in $HOME/.local/share/applications $HOME/Desktop; do
      printf '[Desktop Entry]\nType=Application\nVersion=1.0\nName=%s\nExec=%s\nIcon=%s\nTerminal=false\nCategories=%s\n' \
        "$name" "$exec_line" "$icon" "$cats" > "$d/$file"
      chmod +x "$d/$file"
    done
  }
  seed_app google-chrome.desktop 'Chrome' "google-chrome $CHROME_FLAGS" 'google-chrome' 'Network;WebBrowser;'
  seed_app files.desktop 'Files' 'thunar' 'system-file-manager' 'System;FileTools;FileManager;'
  seed_app terminal.desktop 'Terminal' 'xfce4-terminal' 'utilities-terminal' 'System;TerminalEmulator;'
  seed_app store.desktop 'Store' "google-chrome $CHROME_FLAGS --app=http://127.0.0.1:8090/" 'system-software-install' 'System;Settings;'
  seed_app settings.desktop 'Settings' 'xfce4-settings-manager' 'preferences-system' 'Settings;'
  printf '{"installed": [], "pinned": []}' > $HOME/.store/state.json
fi
ln -sfn $HOME/Work $HOME/Desktop/Work 2>/dev/null || true
[ -f "$HOME/Templates/Text Document.txt" ] || : > "$HOME/Templates/Text Document.txt"

# The panel configuration is generated from the saved state before
# the panel starts, so pinned apps are in the taskbar from boot.
python3 $HOME/store-helper.py --regen-panel > /dev/null 2>&1 || true

# Session bus, then the desktop itself: settings daemon, window
# manager, desktop, panel.
eval "$(dbus-launch --sh-syntax)" > /dev/null 2>&1 || true
export DISPLAY=:99
xfsettingsd > /tmp/xfsettingsd.log 2>&1 &
xfwm4 > /tmp/xfwm4.log 2>&1 &
xfdesktop > /tmp/xfdesktop.log 2>&1 &
xfce4-panel > /tmp/xfce4-panel.log 2>&1 &
sleep 3

# Point the desktop at the wallpaper and at file icons, using
# whatever monitor name this screen reports.
for i in $(seq 1 10); do
  PROPS=$(xfconf-query -c xfce4-desktop -l 2>/dev/null | grep 'last-image$' || true)
  [ -n "$PROPS" ] && break
  sleep 2
done
for p in $PROPS; do
  xfconf-query -c xfce4-desktop -p "$p" -s "$HOME/wallpaper.png" 2>/dev/null || true
  STYLE_PROP="${p%last-image}image-style"
  xfconf-query -c xfce4-desktop -p "$STYLE_PROP" -n -t int -s 5 2>/dev/null || true
done
xfconf-query -c xfce4-desktop -p /desktop-icons/style -n -t int -s 2 2>/dev/null || true

mkdir -p ~/.vnc
x11vnc -storepasswd "$VNC_PASS" ~/.vnc/passwd > /dev/null 2>&1
x11vnc -display :99 -rfbport 5900 -rfbauth ~/.vnc/passwd -forever -shared -bg -o /tmp/x11vnc.log
websockify --web=/usr/share/novnc 6080 localhost:5900 > /tmp/websockify.log 2>&1 &
python3 $HOME/save-server.py > /tmp/save-server.log 2>&1 &
python3 $HOME/store-helper.py > /tmp/store-helper.log 2>&1 &

DISPLAY=:99 google-chrome --no-sandbox --disable-dev-shm-usage --no-first-run --start-maximized --lang=en-US --force-webrtc-ip-handling-policy=disable_non_proxied_udp --disable-blink-features=AutomationControlled --user-data-dir=$HOME/chrome-profile https://duckduckgo.com http://127.0.0.1:8080/ > /tmp/chrome.log 2>&1 &

# Continuous save: every minute, so nothing done in this session is lost.
( while true; do sleep 60; bash $HOME/do-save.sh > /dev/null 2>&1 || true; done ) > /dev/null 2>&1 &

# Quick tunnel, a fresh random address each run.
export CHAIN_FILE="$HOME/chain-result.txt"
/tmp/cloudflared tunnel --url http://localhost:6080 --no-autoupdate --protocol http2 > /tmp/tunnel.log 2>&1 &
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

# Publishing writes live.json in the publish loop's own clone.
publish() {
  (
    flock -x 200
    cd "$PUB_REPO" 2>/dev/null || exit 0
    git fetch -q origin main 2>/dev/null || true
    git reset --hard -q origin/main 2>/dev/null || true
    TUNNEL_URL="$URL" VNC_PASS="$VNC_PASS" TS_STATUS="$TS_STATUS" TS_PEERS="$TS_PEERS" CHAIN_FILE="$CHAIN_FILE" python3 -c "
import json, os, datetime
now = datetime.datetime.now(datetime.timezone.utc).isoformat()
url = os.environ['TUNNEL_URL'] + '/vnc_lite.html?autoconnect=true&password=' + os.environ['VNC_PASS'] + '&resize=scale'
try:
    d = json.load(open('live.json'))
except Exception:
    d = {}
d['url'] = url
if not d.get('started'):
    d['started'] = now
d['heartbeat'] = now
d['state'] = 'live'
d['build'] = 'full-computer'
d['ts'] = os.environ.get('TS_STATUS', '')
d['peers'] = os.environ.get('TS_PEERS', '')
try:
    with open(os.environ['CHAIN_FILE']) as f:
        d['chain'] = f.read().strip()
except Exception:
    d['chain'] = 'pending: self-dispatch fires at 300 minutes'
try:
    import urllib.request
    d['ip'] = urllib.request.urlopen('https://api.ipify.org', timeout=5).read().decode().strip()
except Exception:
    pass
json.dump(d, open('live.json', 'w'), indent=2)
"
    git add live.json
    git commit -m 'browser live' > /dev/null 2>&1 || true
    git push -q origin main > /dev/null 2>&1 || true
  ) 200>/tmp/publish.lock
}

save_profile() {
  bash $HOME/do-save.sh || true
}

publish

# Always on: at 300 minutes this run calls the next run into being,
# so a fresh session takes over before this one ends. The dispatch
# targets the repo this session is actually running in, read from
# its own git remote, and the attempt plus its HTTP result are
# written to the chain file, which publish() puts into live.json.
(
  sleep 18000
  SLUG=$(git -C "$BROWSER_REPO_DIR" remote get-url origin 2>/dev/null | sed -E 's#.*github.com[:/]##; s#\.git$##')
  AUTH=$(git -C "$BROWSER_REPO_DIR" config --get http.https://github.com/.extraheader 2>/dev/null | awk '{print $NF}')
  TOKEN=$(printf '%s' "$AUTH" | base64 -d 2>/dev/null | sed 's/^x-access-token://')
  CODE='no-token'
  if [ -n "$TOKEN" ] && [ -n "$SLUG" ]; then
    CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" "https://api.github.com/repos/$SLUG/actions/workflows/browser.yml/dispatches" -d '{"ref":"main"}')
  fi
  printf 'dispatch to %s at %s UTC, HTTP %s' "$SLUG" "$(date -u +%FT%TZ)" "$CODE" > "$CHAIN_FILE"
  sleep 10
  publish
) > /dev/null 2>&1 &

# Keep the session alive, refreshing the heartbeat so the door page
# knows the computer is awake. The job itself is capped by the
# workflow timeout (355 minutes). The profile and desktop state are
# saved every minute by their own loop, and once more at the end.
for i in $(seq 1 64); do
  sleep 300
  publish
done
save_profile
