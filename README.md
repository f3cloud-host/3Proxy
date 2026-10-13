# 3proxy Manager

A script that installs [3proxy](https://github.com/3proxy/3proxy) on a VPS and manages proxy users from a simple menu. It sets up an HTTP/S proxy, a SOCKS5 proxy or both, with login and password authorization.

Made by [F3 Cloud](https://f3cloud.com). Step-by-step guide: [docs.f3cloud.com](https://docs.f3cloud.com/ru/proxy-guide/proxy-server-configuration).

## Quick start

Run as root:

```bash
cd /root && curl -fsSL -o 3proxy.sh https://raw.githubusercontent.com/f3cloud-host/3Proxy/main/3proxy.sh && chmod +x 3proxy.sh
/root/3proxy.sh
```

Choose `1` to install, answer the questions about ports (press Enter to keep the defaults 3128 and 1080) and create the first user. Installation takes about half a minute.

Run `/root/3proxy.sh` again at any time to manage the proxy:

```
1. Add user
2. Delete user
3. List users
4. Uninstall 3proxy
5. Exit
```

After each new user the script prints ready-to-use connection strings:

```
http://SERVER_IP:3128:user:password
socks5://SERVER_IP:1080:user:password
```

## What the script does

- Builds 3proxy 0.9.9.1 (the LTS branch) from the official release tarball and checks its SHA-256 checksum.
- Runs 3proxy as a systemd service `3proxy` under the unprivileged `proxy3` user, with autostart on boot.
- Opens the chosen ports in ufw or firewalld if one of them is active, and closes them again on uninstall.
- Keeps no access logs.

## Supported systems

Debian 11 and newer, Ubuntu 20.04 and newer, AlmaLinux, Rocky Linux and CentOS Stream 8 and newer. systemd is required.

## Files

| Path | Purpose |
| --- | --- |
| `/usr/local/bin/3proxy` | 3proxy binary |
| `/etc/3proxy/3proxy.cfg` | 3proxy configuration |
| `/etc/3proxy/passwd` | Proxy users |
| `/etc/3proxy/manager.conf` | Ports chosen during installation |
| `/etc/systemd/system/3proxy.service` | systemd service |

Useful commands:

```bash
systemctl status 3proxy     # service status
systemctl restart 3proxy    # restart
journalctl -u 3proxy -n 50  # recent service messages
```

---

# 3proxy Manager (по-русски)

Скрипт ставит [3proxy](https://github.com/3proxy/3proxy) на VPS и управляет пользователями прокси через простое меню. Он настраивает HTTP/S-прокси, SOCKS5-прокси или оба сразу, с входом по логину и паролю.

Подробная инструкция есть в [базе знаний F3 Cloud](https://docs.f3cloud.com/ru/proxy-guide/proxy-server-configuration).

```bash
cd /root && curl -fsSL -o 3proxy.sh https://raw.githubusercontent.com/f3cloud-host/3Proxy/main/3proxy.sh && chmod +x 3proxy.sh
/root/3proxy.sh
```

Выберите `1`, ответьте на вопросы о портах (Enter оставляет 3128 и 1080) и создайте первого пользователя. Для добавления и удаления пользователей просто запустите `/root/3proxy.sh` ещё раз.
