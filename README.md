# SA-DemoKit

This script helps bring up the NSB with multiple uplinks. Enter the router IP address for each interface in `parameters.txt`; the script does the rest. It assigns the static addresses on those interfaces, NATs them out the IPv4 default route, and starts FRR OSPF, ISC DHCP, and FreeRADIUS. `cleanup.sh` removes that. Both scripts prompt before they change the network. An SA can bring the NSB up quickly when the uplink changes, on a Protectli or Raspberry Pi.

## 1. Update apt

```
sudo apt-get update
```

## 2. Install git and OpenSSH

```
sudo apt-get install -y git openssh-server
```

## 3. Clone the repo

```
git clone https://github.com/soleng2018/SA-DemoKit.git
```

## 4. Enter the repo

```
cd SA-DemoKit
```

`setup.sh`, `cleanup.sh`, and `parameters.txt` are in this directory. Stay here for the rest.

## 5. Mark scripts executable

```
sudo chmod +x *
```

## 6. Identify interfaces

```
ip link show
ip -4 route show default
```

Use the ifname from `ip link` in `parameters.txt`. The `dev` on the default route is the internet uplink. Do not put that interface in `parameters.txt`. The script rejects it.

NSB-facing interfaces only need to exist. They may be DOWN. If one is UP and the address does not apply, setup fails.

## 7. Edit parameters.txt

This file supports dynamic WAN configuration for 1, 2, or 4 uplink interfaces. Configure only the interfaces you need; leave unused ones as empty quotes `""`.

Each uplink needs an interface name in double quotes (`eth0`, `eno1np0`, and so on) and a network subnet for OSPF that matches the IP address subnet mask.

Interface names must match the real interfaces. Always quote them. To disable an uplink, set all three parameters to `""`. The script validates parameters before it changes anything.

Examples: one uplink (`uplink1` only), two uplinks (`uplink1` and `uplink2`), four uplinks (all four).

For each uplink set `uplinkN_interface`, `uplinkN_lan_ip`, and `uplinkN_lan_subnet` together, or set all three to `""`. A partial uplink is an error. At least one uplink must be set. Use `/30`.

DHCP always writes those uplink subnets as netmask `255.255.255.252` and ignores any other prefix on `uplinkN_lan_subnet`.

The file comments say 1, 2, or 4 uplinks. The script accepts 1–4. It checks `x.x.x.x/y` form only. It does not check that the address sits in the subnet or that the two prefixes match.

Replace the sample names and addresses. Shipped values:

```
uplink1_interface="enp4s0"
uplink1_lan_ip="172.16.250.1/30"
uplink1_lan_subnet="172.16.250.0/30"
uplink2_interface="enp5s0"
uplink2_lan_ip="192.168.10.9/30"
uplink2_lan_subnet="192.168.10.0/30"
```

Uplink 2 does not match: `192.168.10.9/30` is not inside `192.168.10.0/30`. Do not leave that pair. The quad example in the comments contains `172.16.20./30`. Do not copy it.

Setup also adds DHCP pools `192.168.18.0/24`–`192.168.21.0/24` and names `.1` as the gateway. It never assigns `192.168.18.1`, `192.168.19.1`, `192.168.20.1`, or `192.168.21.1`.

## 8. Install docker

If you already have docker installed you can skip this step

```
./installdocker.sh
```

## 9. Verify Docker is installed and running

```
docker run hello-world
```

```
Hello from Docker!
This message shows that your installation appears to be working correctly.

To generate this message, Docker took the following steps:
 1. The Docker client contacted the Docker daemon.
 2. The Docker daemon pulled the "hello-world" image from the Docker Hub.
    (amd64)
 3. The Docker daemon created a new container from that image which runs the
    executable that produces the output you are currently reading.
 4. The Docker daemon streamed that output to the Docker client, which sent it
    to your terminal.

To try something more ambitious, you can run an Ubuntu container with:
 $ docker run -it ubuntu bash

Share images, automate workflows, and more with a free Docker ID:
 https://hub.docker.com/

For more examples and ideas, visit:
 https://docs.docker.com/get-started/
```

## 10. Run setup

```
./setup.sh
```

`Proceed anyway? [y/N]:` means a selected interface already has an IPv4 address. `y` replaces it via netplan. `n` exits with no network change.

`Continue with setup? [y/N]:` — answer `y`. Anything else stops before netplan, NAT, and containers. Packages installed during the dependency check stay installed.

Success is `Setup complete.` Containers: `frr_dyn`, `dhcpd_dyn`, `radiusd_dyn`.

Checks `setup.sh` actually runs:

* `parse_parameters` — dies if `parameters.txt` is missing, a quote is unclosed, an uplink is only partly filled, `lan_ip` or `lan_subnet` is not `x.x.x.x/y`, or no uplink is active. It does not check that the address is inside the subnet or that the masks match.
* `check_dependencies` — dies without sudo, if `/etc/netplan` is missing, or if a required command is still absent after install. `ensure_docker` dies if the daemon is not running after it installs `docker.io`.
* `preflight_checks` / `iface_exists` — dies if a named LAN interface does not exist.
* `preflight_checks` / `iface_is_up` — a DOWN LAN interface does not fail the run.
* `prompt_existing_lan_ips` — if a LAN interface already has an IPv4 address, asks `Proceed anyway?`. `n` exits before any network change. That prompt does not roll back; nothing has been applied yet.
* `detect_internet_iface` — picks the lowest-metric IPv4 default route, or else the device from `ip -4 route get 1.1.1.1`. `preflight_checks` dies if that interface is missing, not UP, or is also listed as a LAN uplink.
* `preflight_checks` — the `1.1.1.1` route lookup is advisory and does not fail setup.
* `configure_netplan` — dies if `netplan apply` fails. If the new address is missing and the interface is UP, it dies; if the interface is DOWN, it continues. It then calls `detect_internet_iface` up to 6 times. It dies only when there is still no default route and the previous internet interface is not UP, or if that interface then matches a LAN interface.
* `rollback_changes` — on a failed command after changes have started, removes `frr_dyn`, `dhcpd_dyn`, and `radiusd_dyn`, the NAT unit and script, the netplan drop-in, the runtime LAN addresses it added, and the state file.
* `postflight` — dies if one of those containers is not running, if an UP LAN interface lacks its address, or if `detect_internet_iface` finds no default route.

`netplan apply` can drop the default route briefly. Setup continues if the previous internet interface is still up. It aborts if that interface is down and there is no default route.

On `ERROR` after changes have started, setup rolls back containers, the NAT unit and script, the netplan drop-in, the runtime addresses it added, and the state file. It does not remove packages or images.

## 11. Clean up

Run this from the internet address, not from a demo LAN address. Removing the LAN address drops an SSH session that arrived on it. Reconnect on the internet address and run cleanup again if that happens.

```
sudo ./cleanup.sh
```

Answer `y` at `Proceed with cleanup? [y/N]:`.

Success is `Cleanup complete.` Packages and Docker images stay.
