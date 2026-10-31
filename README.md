# Navidrome Automated Setup Script

`navidrome-install.sh` builds [Navidrome](https://www.navidrome.org), the self-hosted music server, from [source](https://github.com/navidrome/navidrome), installs it to `/opt/navidrome`, and sets it up as a systemd service that starts on boot.

## What it does

- Detects your Linux distro and installs the build tools, including Go 1.27+ and Node 24.
- Clones Navidrome and runs `make setup` and `make build`.
- Installs the binary (default `/opt/navidrome`) and creates a `navidrome` systemd service.

## Supported distros

Not tested, need feedback. The script detects Debian/Ubuntu, Fedora/RHEL, Arch, openSUSE and Alpine, but none of them have been tested yet. If you try it, please open an issue saying whether it worked.

## Install

```bash
bash navidrome-install.sh
```

Then open `http://<your-server-ip>:4533` and create your admin account.

Manage the service:

```bash
sudo systemctl status navidrome
sudo systemctl restart navidrome
```

## Uninstall

```bash
bash navidrome-install.sh uninstall
```

This removes the service and files, and asks before removing packages.
