# Remote Browser

A real Chrome running in the cloud (GitHub Codespaces), streamed into a tab in
any browser. Open the link, you get a full desktop browser: tabs, address bar,
the works. It runs on GitHub's machines, so it works from anywhere.

## Use it

1. Open https://codespaces.new/iamnottaiiii/remote-browser and create the
   Codespace. First build takes a few minutes.
2. When it starts, the terminal prints **YOUR REMOTE BROWSER LINK** (also saved
   in `LINK.txt` in this repo inside the Codespace).
3. Open that link in any browser. That tab is now the remote browser.

## Notes

- The Codespace stops itself after about 30 idle minutes. Restart it from
  https://github.com/codespaces and the browser comes back with its tabs and
  logins intact (the Chrome profile lives in this workspace).
- Free GitHub accounts include 120 core-hours of Codespaces per month, which
  is about 60 hours of this 2-core browser.
- The VNC password is generated on first start and stored in `vnc-pass.txt`
  inside the Codespace. The link above already carries it.
- If the link ever asks for GitHub sign-in, set port 6080 to Public in the
  Codespace's Ports tab.

## How it works

Xvfb makes a virtual screen, Chrome runs on it, x11vnc shares the screen, and
noVNC turns that into a web page on port 6080. Codespaces forwards the port as
the public link.
