# SA-DemoKit

This script sets up an NSB with multiple uplinks, at least 1 and up to 4. An SA can bring the NSB up quickly when the uplink changes, on a Protectli or Raspberry Pi.

`parameters.txt` selects the uplinks. `setup.sh` applies static addresses (netplan), NATs them out the IPv4 default route, and starts FRR OSPF, ISC DHCP, and FreeRADIUS. `cleanup.sh` removes that. Both scripts prompt before they change the network.

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

For each uplink set `uplinkN_interface`, `uplinkN_lan_ip`, and `uplinkN_lan_subnet` together, in double quotes, or set all three to `""`. A partial uplink is an error. At least one uplink must be set. Use `/30`.

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

`netplan apply` can drop the default route briefly. Setup continues if the previous internet interface is still up. It aborts if that interface is down and there is no default route.

On `ERROR` after changes have started, setup rolls back containers, the NAT unit and script, the netplan drop-in, the runtime addresses it added, and the state file. It does not remove packages or images.

## 11. Clean up

Run this from the internet address, not from a demo LAN address. Removing the LAN address drops an SSH session that arrived on it. Reconnect on the internet address and run cleanup again if that happens.

```
sudo ./cleanup.sh
```

Answer `y` at `Proceed with cleanup? [y/N]:`.

Success is `Cleanup complete.` Packages and Docker images stay.
