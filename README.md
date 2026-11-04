# SA-DemoKit

This kit configures an uplink for a Nile NSB. A solution architect can bring the NSB up quickly when the uplink changes, using a Protectli or Raspberry Pi.

On Ubuntu it will:

* Put static addresses on 1 to 4 LAN interfaces with netplan. You name those interfaces in `parameters.txt`.
* NAT those LANs out the machine’s existing internet uplink (Ethernet or Wi-Fi).
* Start FRR OSPF, ISC DHCP, and FreeRADIUS in three containers on the host network.

`setup.sh` reads `parameters.txt` and configures the host. `cleanup.sh` reverses what setup added. The scripts take no flags. They ask `y/N` before they change the network.

## Setup the server

In this section we prep the server and check out this kit.

### Prerequisites

* Fresh install of an Ubuntu-based system, with sudo
* `/etc/netplan` already present. Setup will not create it
* WiFi or wired internet on an interface you will **not** use as the NSB uplink. That interface must be UP
* Outbound network for `apt` and for the Docker image pulls (`ubuntu:latest`, `freeradius/freeradius-server`, `frrouting/frr`)

### Install git and openssh-server and checkout the scripts

```
sudo apt-get update
sudo apt-get install -y git openssh-server
git clone https://github.com/soleng2018/SA-DemoKit.git
```

### Make all files executable

```
cd SA-DemoKit
sudo chmod +x *
```

`setup.sh`, `cleanup.sh`, and `parameters.txt` are in this directory. Stay here for the steps below. The scripts find `parameters.txt` next to themselves.

### Install Docker

Install Docker if it is not already installed. `setup.sh` installs `docker.io` and starts the daemon when `docker` is missing or not running. Setup always calls `sudo docker`, so you do not need to be in the `docker` group.

## Setup the uplink

### See the interfaces

```
ip -4 route show default
ip link show
```

The default-route interface must be UP, and it must not be listed as a LAN uplink. A LAN uplink only has to exist. It may be DOWN. If a LAN interface is UP and setup cannot put the address on it, setup fails.

A later lookup of `1.1.1.1` is printed during setup. It does not pass or fail the run.

### Edit parameters.txt

Edit `parameters.txt` before setup. For each uplink you want, set all three fields, in double quotes. To disable an uplink, set all three to `""`. A partial uplink is an error. At least one uplink must be complete.

| Field | What to set |
|---|---|
| `uplinkN_interface` | Name from `ip link` (`"enp4s0"`, `"eth0"`, …). Not the internet uplink. |
| `uplinkN_lan_ip` | Address applied to that interface, `x.x.x.x/prefix`. |
| `uplinkN_lan_subnet` | OSPF network, `x.x.x.x/prefix`. The address part is also the DHCP subnet. |

The file comments say the LAN subnet must match the LAN IP’s mask. The script only checks that each value looks like `x.x.x.x/y`, and that the three fields are all set or all empty. It does not check that the IP is inside the subnet, or that the two prefixes match.

DHCP always writes those uplink subnets as netmask `255.255.255.252` (`/30`) and ignores the prefix on `uplinkN_lan_subnet`. Use `/30` uplink networks unless you change the script.

The header comment says 1, 2, or 4 uplinks. The script accepts 1, 2, 3, or 4.

The file as shipped is a sample, not your machine:

| Uplink | Interface | LAN IP | LAN subnet |
|---|---|---|---|
| 1 | `enp4s0` | `172.16.250.1/30` | `172.16.250.0/30` |
| 2 | `enp5s0` | `192.168.10.9/30` | `192.168.10.0/30` |
| 3, 4 | empty | empty | empty |

Replace the interface names. `192.168.10.9/30` is not inside `192.168.10.0/30`. Do not leave that pair as-is. The comment block’s quad example contains `172.16.20./30`, which is not a valid prefix. Do not copy that line.

### Run setup

```
./setup.sh
```

Setup calls `sudo` itself. It installs missing packages before the final confirm prompt. Answer `y` at `Continue with setup? [y/N]:`. Any other answer stops before netplan, NAT, and containers. Packages already installed stay installed.

If a chosen LAN interface already has an IPv4 address, setup asks `Proceed anyway? [y/N]:` first. `N` makes no network changes. `Y` continues, and netplan may replace that address.

Installed if missing: `python3`, `python3-yaml`, `iproute2`, `iptables`, `netplan.io`. If Docker is missing or not running: `ca-certificates`, `curl`, `docker.io`, then `systemctl enable --now docker`.

Netplan renderer: the `renderer:` line already in `/etc/netplan/*.yaml`, if one is set. Otherwise NetworkManager when that service is active, otherwise `networkd`.

Setup writes only `/etc/netplan/99-dynamicwan-uplinks.yaml` (`dhcp4: false`, `optional: true`, the `uplinkN_lan_ip` address) and runs `netplan apply`. Other netplan files are left alone. If the address is still missing after apply, which is common when the link is down, it runs `ip addr add`.

`netplan apply` can briefly drop Wi-Fi or the default route. Setup waits and continues if the previous internet interface is still up. It stops if that interface is gone and there is no default route.

On failure after changes have started, setup rolls back the containers, the NAT unit and script, the netplan drop-in, the runtime LAN addresses it added, and the state file. It does not uninstall packages or delete images.

### Clean up

Run cleanup from the **internet** address, not from a demo LAN address. Removing the LAN IP drops an SSH session that came in that way. Cleanup warns when it thinks that is the case. Run it again if a session died halfway.

From this directory:

```
sudo ./cleanup.sh
```

`./cleanup.sh` is the same program. It calls `sudo` itself. Answer `y` at `Proceed with cleanup? [y/N]:`.

Cleanup removes the three containers, the iptables rules marked `dynamicwan`, `/usr/local/bin/setup-nat-dynamicwan.sh`, `setup-nat-dynamicwan.service`, the netplan drop-in, the recorded runtime LAN addresses, the generated files in this directory, and the state file. If setup turned forwarding on, cleanup restores the old value and deletes the `net.ipv4.ip_forward=1` line it added to `/etc/sysctl.conf`. Packages and Docker images stay.

If the state file is missing, cleanup reads interface names and LAN IPs from `parameters.txt` and still deletes the known demo artifacts. It only deletes a netplan file whose path contains `dynamicwan`.

## Day-to-day

Run these from the `SA-DemoKit` directory.

| Task | How |
|---|---|
| Change an uplink address or interface | Edit `parameters.txt`, then `./setup.sh` again. It rewrites its netplan drop-in, NAT unit, and the three containers. |
| Turn an uplink off | Set `uplinkN_interface`, `uplinkN_lan_ip`, and `uplinkN_lan_subnet` all to `""`, then run setup again. |
| Undo the lab | `sudo ./cleanup.sh`, from the internet address. |
| Cleanup stopped halfway | Reconnect on the internet or Wi-Fi address and run `./cleanup.sh` again. |

There is no separate verify command. Setup’s last step checks that `frr_dyn`, `dhcpd_dyn`, and `radiusd_dyn` are running, and that each UP LAN interface has its address.

## Commands

```
./setup.sh
sudo ./cleanup.sh
```

| Command | What it does |
|---|---|
| `./setup.sh` | Parse `parameters.txt`, install missing packages, configure netplan and NAT, build or pull images, start the three containers. Asks before it changes the network. On failure, rolls back its own changes. |
| `sudo ./cleanup.sh` | Stop and remove what `setup.sh` added. Keeps apt packages and Docker images. Asks before it starts. Safe to re-run. |

## What gets created

| Object | Where | Name |
|---|---|---|
| Netplan drop-in | `/etc/netplan/` | `99-dynamicwan-uplinks.yaml` (mode 600) |
| State file | `/etc/` | `dynamicwan_configured_interfaces.conf` |
| NAT script | `/usr/local/bin/` | `setup-nat-dynamicwan.sh` |
| Boot unit | `/etc/systemd/system/` | `setup-nat-dynamicwan.service` |
| IPv4 forwarding | host | `net.ipv4.ip_forward=1` when it was not already 1, including a line in `/etc/sysctl.conf` |
| iptables | host | MASQUERADE out the internet interface, and FORWARD rules for each LAN, comment `dynamicwan` |
| OSPF container | Docker, host network, privileged, `--restart=always` | `frr_dyn` (`docker.io/frrouting/frr`) |
| DHCP container | same | `dhcpd_dyn` (image tag `dhcpd`, from `ubuntu:latest`) |
| RADIUS container | same | `radiusd_dyn` (image tag `radiusd`, from `freeradius/freeradius-server`) |

Generated next to the scripts, and deleted by cleanup: `daemons`, `frr_dyn.conf`, `dhcpdContainerfile`, `dhcpdStartup.sh`, `dhcpd.conf`, `clients.conf`, `authorize`, `dictionary.nile`, `radiusdContainerfile`.

**FRR.** Zebra and OSPFd only. Router-id `1.1.1.1`. Each LAN interface is `ip ospf network point-to-point`. Each `uplinkN_lan_subnet` is `network … area 0`. `default-information originate always`.

**DHCP.** Listens on the LAN interfaces you configured. Each of those subnets is declared with netmask `255.255.255.252` and no address pool. It also always adds pools `192.168.18.0/24`, `192.168.19.0/24`, `192.168.20.0/24`, and `192.168.21.0/24` (`.11`–`.254`, DNS `8.8.8.8`, domain `dynamicwan.local`). Those pools name `.1` as the gateway. The script never assigns `192.168.18.1`, `192.168.19.1`, `192.168.20.1`, or `192.168.21.1` on any interface.

**RADIUS.** Clients `127.0.0.1`, `172.16.0.0/16`, `192.168.0.0/16`, and `10.0.0.0/8`, shared secret `nile123`. Users: `bob` / `hello`; `employee` / `nilesecure` (netseg Employee); `contractor` / `nilesecure` (netseg contractor); `sally@nilenetworks.com` / `nilesecure` (netseg corporate); `harry-ext@nilenetworks.com` / `nilesecure` (netseg contractor). Vendor dictionary: Nile, id 58313.

If a container named `frr_dyn`, `dhcpd_dyn`, or `radiusd_dyn` already exists, setup stops it and creates it again.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `sudo privileges required` | Run as a user who can `sudo`. |
| `No active uplinks` / `Uplink N incomplete` | Set interface, `lan_ip`, and `lan_subnet` together, or clear all three. |
| `Malformed line` or `invalid lan_ip` | Keep the value in double quotes, shaped like `x.x.x.x/y`. |
| `interface does not exist` | Use a name from `ip link show`. |
| `No default route` / internet uplink `is not UP` | Connect Ethernet or Wi-Fi first. The internet NIC must be up. |
| Interface `is the server internet uplink` | Pick a different NIC in `parameters.txt`. |
| `netplan apply failed` | Read the debug output setup prints. Other netplan files were not edited. |
| LAN IP missing on an UP interface | NetworkManager may own that NIC. A DOWN interface is allowed to come up later. |
| `Internet uplink lost after netplan apply` | Wi-Fi or NetworkManager dropped the default route and the old NIC is no longer UP. |
| `/etc/netplan does not exist` | This Ubuntu install has no netplan directory. Setup will not create it. |
| `Docker installed but daemon is not running` | `sudo systemctl enable --now docker`, then run setup again. |
| Container `is not running after start` | `sudo docker ps` and `sudo docker logs frr_dyn` (or `dhcpd_dyn`, `radiusd_dyn`). |
| SSH dies during cleanup | You were on a demo LAN address. Reconnect via the internet uplink and run `./cleanup.sh` again. |
| Cleanup left packages or images behind | That is what it does. It does not run `apt remove` or `docker rmi`. |

## Layout

After `cd SA-DemoKit`:

```
setup.sh             configure netplan, NAT, and the three containers
cleanup.sh           reverse setup.sh
parameters.txt       the only file you edit
README.md            this file
```

Setup also writes, and cleanup deletes, these files next to the scripts: `daemons`, `frr_dyn.conf`, `dhcpdContainerfile`, `dhcpdStartup.sh`, `dhcpd.conf`, `clients.conf`, `authorize`, `dictionary.nile`, `radiusdContainerfile`.

Host files outside that directory: `/etc/netplan/99-dynamicwan-uplinks.yaml`, `/etc/dynamicwan_configured_interfaces.conf`, `/usr/local/bin/setup-nat-dynamicwan.sh`, `/etc/systemd/system/setup-nat-dynamicwan.service`.

## Security

* Setup needs sudo. It turns on system-wide IPv4 forwarding when that was off, and it adds NAT and FORWARD rules.
* The three containers are `--privileged` and use `--network=host`.
* RADIUS secrets and user passwords are written in the clear into `clients.conf` and `authorize` (secret `nile123`, passwords `hello` and `nilesecure`). Cleanup deletes those files. It does not rotate anything.
* The netplan drop-in is mode `600`. Cleanup will not delete an unrelated file under `/etc/netplan/`.
