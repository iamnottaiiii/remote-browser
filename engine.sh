#!/usr/bin/env bash
# Full computer engine. Runs on a GitHub Actions runner.
# A KDE Plasma desktop on a virtual screen, streamed through a
# Cloudflare quick tunnel. The public link is written to live.json and
# committed back to this repo. The Chrome profile AND the desktop
# state (installed apps, pins, created files, wallpaper, settings)
# are saved (AES-256 encrypted) into the repo every minute and
# restored at the next start, when PROFILE_KEY is set. Plasma is
# the desktop: Dolphin supplies the file manager service that web
# app launching needs, and Plasma's own config carries the
# wallpaper, the dark panel, and the launcher favorites.
# Direct datacenter egress: the lab proved the presentation fixes
# carry the human checks, so no home exit node is used here.

VNC_PASS="${VNC_PASS:-bjvfi-live}"
export BROWSER_REPO_DIR="$(pwd)"
export SAVE_REPO="$HOME/save-repo"
export PUB_REPO="$HOME/pub-repo"
TS_STATUS='datacenter direct'
TS_PEERS=''

sudo apt-get update -qq
sudo apt-get install -y -qq xvfb x11vnc novnc websockify plasma-desktop dolphin konsole systemsettings xdg-desktop-portal-kde kate dbus-x11 imagemagick rsync fonts-liberation fonts-noto-core gvfs qdbus-qt5 > /dev/null 2>&1 || sudo apt-get install -y -qq xvfb x11vnc novnc websockify plasma-desktop dolphin konsole systemsettings kate dbus-x11 imagemagick rsync fonts-liberation fonts-noto-core gvfs > /dev/null 2>&1 || sudo apt-get install -y -qq xvfb x11vnc novnc websockify plasma-desktop konsole systemsettings dbus-x11 imagemagick rsync fonts-liberation fonts-noto-core gvfs > /dev/null
# Preview theming: a clean modern icon theme, when the distro
# offers it. Failure here is not fatal; Breeze icons step in.
sudo apt-get install -y -qq papirus-icon-theme > /dev/null 2>&1 || true
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
rsync -a --exclude='*/Cache/*' --exclude='*/Code Cache/*' $HOME/.config/ /tmp/prof-stage/state/config/ 2>/dev/null
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
# as their own windows with no address bar or tabs. Pins live in
# the Plasma panel configuration (the icon task manager's
# launchers in the appletsrc), regenerated from the saved state.
# All state lives in ~/.store, inside the saved area.
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
APPLETSRC = os.path.join(HOME, '.config',
                         'plasma-org.kde.plasma.desktop-appletsrc')
PLASMASHELLRC = os.path.join(HOME, '.config', 'plasmashellrc')
CURATED = ['google-chrome.desktop', 'files.desktop',
           'terminal.desktop', 'store.desktop', 'settings.desktop',
           'work.desktop']
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
h1{font-size:28px;font-weight:normal;margin:0 0 4px}
p.sub{color:#6d6152;margin:0 0 20px}
.bar{background:#fffdf7;border:1px solid #d8cbae;padding:16px;margin-bottom:14px}
.bar input[type=text]{font-size:16px;padding:9px;width:62%;border:1px solid #c9b995}
.bar input[type=text].name{width:22%}
.search{margin-bottom:18px}
.search input{font-size:16px;padding:9px;width:98%;border:1px solid #c9b995;background:#fffdf7}
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
<div class='search'><input type='text' id='q' placeholder='Search the store' oninput='filter()'></div>
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
function filter(){
  var q=document.getElementById('q').value.toLowerCase();
  var rows=document.querySelectorAll('#list .app');
  rows.forEach(function(r){
    r.style.display = r.getAttribute('data-name').indexOf(q)>=0 ? '' : 'none';
  });
}
function render(s){
  var byId={}; s.installed.forEach(function(a){byId[a.id]=a});
  var html='';
  s.catalog.forEach(function(c){ html+=row(c, byId[c.id], s.pinned.indexOf(c.id)>=0) });
  s.installed.forEach(function(a){
    if(!s.catalog.some(function(c){return c.id===a.id})) html+=row(a, a, s.pinned.indexOf(a.id)>=0);
  });
  document.getElementById('list').innerHTML=html;
  filter();
}
function row(c, inst, pinned){
  var icon='/icon/'+(inst?inst.id:c.id);
  var h="<div class='app' data-name='"+(c.name+' '+(c.desc||'')).toLowerCase()+"'><img src='"+icon+"' alt=''><div class='grow'><div class='nm'>"+
    c.name+"</div><div class='ds'>"+(c.desc||c.url)+"</div></div>";
  if(inst){
    h+="<span class='tag'>installed</span>";
    h+=" <button onclick=\"act('/api/open','"+c.id+"')\">Open</button>";
    if(pinned) h+=" <button class='plain' onclick=\"act('/api/unpin','"+c.id+"')\">Unpin</button>";
    else h+=" <button onclick=\"act('/api/pin','"+c.id+"')\">Pin to taskbar</button>";
    h+=" <button class='plain' onclick=\"act('/api/uninstall','"+c.id+"')\">Remove</button>";
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
        trust_launcher(p)


def trust_launcher(path):
    # An untrusted .desktop file opens in a text editor showing its
    # contents instead of launching. Marking it trusted (the gio
    # metadata XFCE checks) plus the executable bit makes a click
    # launch the app.
    env = dict(os.environ)
    env.setdefault('DISPLAY', ':99')
    try:
        subprocess.run(['gio', 'set', path, 'metadata::trusted', 'true'],
                       env=env, timeout=10, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL)
    except Exception:
        pass


def remove_launchers(app_id):
    for d in (APPS_DIR, DESKTOP_DIR):
        try:
            os.remove(os.path.join(d, app_id + '.desktop'))
        except OSError:
            pass


def _panel_groups(state):
    by_id = {a['id']: a for a in state['installed']}
    launcher_ids = list(CURATED)
    for pid in state['pinned']:
        if pid in by_id:
            launcher_ids.append(pid + '.desktop')
    launchers = ','.join('applications:' + i for i in launcher_ids)
    return [
        ('ActionPlugins][0', [
            'RightButton;NoModifier=org.kde.contextmenu',
            'wheel:Vertical;NoModifier=org.kde.switchdesktop']),
        ('ActionPlugins][1', [
            'RightButton;NoModifier=org.kde.contextmenu']),
        ('Containments][2', [
            'activityId=', 'formfactor=2', 'immutability=1',
            'lastScreen=0', 'location=4', 'plugin=org.kde.panel',
            'wallpaperplugin=org.kde.image']),
        ('Containments][2][Applets][3', [
            'immutability=1', 'plugin=org.kde.plasma.kickoff']),
        ('Containments][2][Applets][3][Configuration][General', [
            'favoritesPortedToKAstats=true']),
        ('Containments][2][Applets][3][Configuration][Shortcuts', [
            'global=Alt+F1']),
        ('Containments][2][Applets][3][Shortcuts', [
            'global=Alt+F1']),
        ('Containments][2][Applets][4', [
            'immutability=1', 'plugin=org.kde.plasma.icontasks']),
        ('Containments][2][Applets][4][Configuration][General', [
            'launchers=' + launchers]),
        ('Containments][2][Applets][5', [
            'immutability=1', 'plugin=org.kde.plasma.digitalclock']),
        ('Containments][2][General', ['AppletOrder=3;4;5']),
    ]


def _is_ours(group):
    return (group.startswith('ActionPlugins')
            or group == 'Containments][2'
            or group.startswith('Containments][2]['))


def write_panel_config():
    # Regenerate the Plasma panel (containment 2) inside the
    # appletsrc, preserving every other group the shell wrote
    # (the desktop containment with the wallpaper, the screen
    # mapping). The panel: launcher at the left, an icon task
    # manager whose launchers are the six curated apps plus the
    # pinned web apps, and the clock at the right. Panel
    # thickness lives in plasmashellrc, not the appletsrc.
    state = load_state()
    kept = []
    if os.path.exists(APPLETSRC):
        name = None
        lines = []
        with open(APPLETSRC) as f:
            raw_lines = f.read().splitlines()
        for line in raw_lines + ['[END]']:
            if line.startswith('[') and line.endswith(']'):
                if name is not None and not _is_ours(name):
                    kept.append((name, lines))
                name = line[1:-1]
                lines = []
            elif name is not None and line.strip():
                lines.append(line)
    out = []
    for name, lines in kept + _panel_groups(state):
        out.append('[' + name + ']')
        out.extend(lines)
        out.append('')
    os.makedirs(os.path.dirname(APPLETSRC), exist_ok=True)
    with open(APPLETSRC, 'w') as f:
        f.write('\n'.join(out))
    with open(PLASMASHELLRC, 'w') as f:
        f.write('[PlasmaViews][Panel 2][Defaults]\nthickness=44\n')


def restart_panel():
    # Bounce plasmashell so a pin or unpin lands in the task
    # manager: stop the shell, regenerate the panel config while
    # it is down (a running shell overwrites the file on exit),
    # then start the shell again.
    env = dict(os.environ)
    env.setdefault('DISPLAY', ':99')
    env.setdefault('LIBGL_ALWAYS_SOFTWARE', '1')
    try:
        subprocess.run(['pkill', '-x', 'plasmashell'], timeout=10,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass
    for _ in range(20):
        r = subprocess.run(['pgrep', '-x', 'plasmashell'],
                           stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL)
        if r.returncode != 0:
            break
        time.sleep(0.5)
    write_panel_config()
    try:
        subprocess.Popen(['plasmashell'], env=env,
                         stdout=subprocess.DEVNULL,
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
        if self.path == '/api/open':
            entry = next((a for a in state['installed']
                          if a['id'] == app_id), None)
            if entry:
                env = dict(os.environ)
                env.setdefault('DISPLAY', ':99')
                try:
                    subprocess.Popen(
                        ['google-chrome'] + CHROME_FLAGS.split()
                        + ['--app=' + entry['url']],
                        env=env, stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL, start_new_session=True)
                except Exception:
                    pass
            self._json(public_state(state))
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
         $HOME/.config $HOME/Work $HOME/.store $HOME/Templates $HOME/chrome-profile

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
      [ -d /tmp/restore/state/config ] && rsync -a /tmp/restore/state/config/ $HOME/.config/ 2>/dev/null
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

# Seed the desktop with the curated starter apps. This runs on
# every boot and is idempotent: the six system launchers always
# exist and are always the versions written here, whatever an older
# saved state carried in.
if true; then
  seed_app() {
    local file="$1" name="$2" exec_line="$3" icon="$4" cats="$5"
    for d in $HOME/.local/share/applications $HOME/Desktop; do
      printf '[Desktop Entry]\nType=Application\nVersion=1.0\nName=%s\nExec=%s\nIcon=%s\nTerminal=false\nCategories=%s\n' \
        "$name" "$exec_line" "$icon" "$cats" > "$d/$file"
      chmod +x "$d/$file"
    done
  }
  seed_app google-chrome.desktop 'Chrome' "google-chrome $CHROME_FLAGS" 'google-chrome' 'Network;WebBrowser;'
  seed_app files.desktop 'Files' 'dolphin' 'system-file-manager' 'System;FileTools;FileManager;'
  seed_app terminal.desktop 'Terminal' 'konsole' 'utilities-terminal' 'System;TerminalEmulator;'
  seed_app store.desktop 'Store' "google-chrome $CHROME_FLAGS --app=http://127.0.0.1:8090/" 'system-software-install' 'System;Settings;'
  seed_app settings.desktop 'Settings' 'systemsettings' 'preferences-system' 'Settings;'
  seed_app work.desktop 'Work' "dolphin $HOME/Work" 'folder' 'System;FileTools;FileManager;'
  [ -f $HOME/.store/state.json ] || printf '{"installed": [], "pinned": []}' > $HOME/.store/state.json
fi
[ -L $HOME/Desktop/Work ] && rm -f $HOME/Desktop/Work
[ -f "$HOME/Templates/Text Document.txt" ] || : > "$HOME/Templates/Text Document.txt"

# The Plasma look is written as config BEFORE the session first
# starts, so the first boot already wears it: kdeglobals sets the
# Breeze Dark look (dark charcoal panel and windows) and the
# Papirus-Dark icon theme; kwinrc turns compositing on (software
# GL under the virtual screen, so the panel blur can work, with a
# plain fallback if it cannot); mimeapps makes Dolphin the default
# file manager. Dolphin running inside the Plasma session is also
# what supplies the file manager service, the piece whose absence
# made installed web apps fail to launch on the old desktop.
mkdir -p $HOME/.config
cat > $HOME/.config/kdeglobals << 'KDEG_EOF'
[Icons]
Theme=Papirus-Dark
[KDE]
LookAndFeelPackage=org.kde.breezedark.desktop
KDEG_EOF
cat > $HOME/.config/kwinrc << 'KWIN_EOF'
[Compositing]
Enabled=true
KWIN_EOF
cat > $HOME/.config/mimeapps.list << 'MIME_EOF'
[Default Applications]
inode/directory=org.kde.dolphin.desktop
x-scheme-handler/file=org.kde.dolphin.desktop
MIME_EOF

# Hide the system clutter: NoDisplay override entries for the
# noisy utilities a stock Plasma install ships, and for the stock
# Dolphin, Konsole, and System Settings entries, which the curated
# six replace. Menus and search then show his apps only; the
# system tools stay reachable through the Settings entry.
for sysapp in org.kde.dolphin.desktop org.kde.konsole.desktop org.kde.systemsettings.desktop org.kde.plasma-welcome.desktop org.kde.kfind.desktop org.kde.kdiskfree.desktop org.kde.kruler.desktop org.kde.kcharselect.desktop org.kde.kcolorchooser.desktop org.kde.kamera.desktop org.kde.spectacle.desktop org.kde.kleopatra.desktop org.kde.kmag.desktop org.kde.kmouth.desktop org.kde.kate.desktop htop.desktop vim.desktop; do
  if [ -f "/usr/share/applications/$sysapp" ]; then
    printf '[Desktop Entry]\nType=Application\nName=%s\nNoDisplay=true\n' "$sysapp" > "$HOME/.local/share/applications/$sysapp"
  fi
done

# The panel and desktop configuration (the appletsrc) is
# generated from the saved state before Plasma starts, so the
# launcher favorites, the pinned apps in the task manager, and
# the wallpaper are in place from the first second.
python3 $HOME/store-helper.py --regen-panel > /dev/null 2>&1 || true

# Session bus, then the Plasma session itself: KWin, the desktop,
# and the panel all come up as one real Plasma session, so KDE
# services (the file manager service included) register properly.
eval "$(dbus-launch --sh-syntax)" > /dev/null 2>&1 || true
export DISPLAY=:99
# Launchers must LAUNCH: an untrusted .desktop file opens in a text
# editor showing its code instead of the app. Every launcher on the
# desktop and in the applications dir gets the executable bit and
# the trusted flag XFCE checks, on every boot (a restore brings the
# files back without their trust metadata).
for f in $HOME/Desktop/*.desktop $HOME/.local/share/applications/*.desktop; do
  [ -f "$f" ] || continue
  chmod +x "$f"
  gio set "$f" metadata::trusted true > /dev/null 2>&1 || true
done
# Software rendering: the virtual screen has no GPU, so Mesa
# runs in software (llvmpipe) and KWin compositing works on top.
# If compositing still cannot start, KWin falls back on its own
# and the desktop stays usable; nothing hard-depends on it.
export LIBGL_ALWAYS_SOFTWARE=1
startplasma-x11 > /tmp/plasma.log 2>&1 &
sleep 5

# Wallpaper, applied through Plasma's own scripting channel once
# the shell answers. Writing the desktop containment's config by
# hand does not survive: the shell ties the desktop to an
# activity it creates itself and discards foreign containments
# (verified against a local Plasma 5.27 session). Through the
# script channel the setting lands in the appletsrc under the
# real containment, applies on screen, and is part of the saved
# state from then on.
QDBUS=$(command -v qdbus || command -v qdbus-qt5 || true)
if [ -n "$QDBUS" ]; then
  for i in $(seq 1 10); do
    "$QDBUS" org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript "
var ds = desktops();
for (var i = 0; i < ds.length; i++) {
  var d = ds[i];
  d.wallpaperPlugin = 'org.kde.image';
  d.currentConfigGroup = ['Wallpaper', 'org.kde.image', 'General'];
  d.writeConfig('Image', 'file://$HOME/wallpaper.png');
  d.writeConfig('FillMode', 2);
}" > /dev/null 2>&1 && break
    sleep 4
  done
fi

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
url = os.environ['TUNNEL_URL'] + '/vnc.html?autoconnect=true&password=' + os.environ['VNC_PASS'] + '&resize=scale'
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
