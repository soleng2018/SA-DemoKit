# SA-DemoKit

This script brings up the NSB with 1, 2, or 4 uplinks. Enter each NSB-facing interface in `parameters.txt`. The script assigns the static addresses, NATs them out the IPv4 default route, and starts FRR OSPF, ISC DHCP, and FreeRADIUS. `cleanup.sh` removes that configuration. Both scripts ask before they change the network.

This script helps bring a Nile NSB up on a Protectli that is already connected to the internet over broadband or Wi-Fi. During a customer or partner demo, or while deploying and activating an NSB, the NSB may stay down because of a firewall rule, a missing path to the internet, or a routing problem. Updating the uplink interfaces to match that customer or demo network brings the NSB up quickly. Matching the uplink also helps narrow down whether the problem is a firewall rule or routing.

## Prerequisites

* Ubuntu system that uses netplan
* Sudo access
* A working internet connection
* One internet uplink, kept out of `parameters.txt`
* 1, 2, or 4 additional interfaces for the NSB

## 1. Install git and OpenSSH, then clone the repo

```
sudo apt-get update
sudo apt-get install -y git openssh-server
git clone https://github.com/soleng2018/SA-DemoKit.git
```

## 2. Enter the repo and mark the scripts executable

```
cd SA-DemoKit
sudo chmod +x *
```

`setup.sh`, `cleanup.sh`, and `parameters.txt` are in this directory. Stay here for the rest of the steps.

## 3. Identify the interfaces

```
ip link show
ip -4 route show default
```

Use the interface name from `ip link show` in `parameters.txt`. The `dev` on the default route is the internet uplink. Leave that interface out of `parameters.txt`. Setup stops if the internet uplink is also listed as an NSB uplink.

An NSB-facing interface only has to exist. It may be DOWN. Setup continues and the address can be applied when the link comes up. If the interface is already UP and the new address does not apply, setup stops.

## 4. Edit parameters.txt

```
nano parameters.txt
```

This file supports 1, 2, or 4 uplink interfaces. Fill only the uplinks you need. Leave every unused uplink as empty quotes `""`.

Each active uplink needs all three values, in double quotes:

* `uplinkN_interface` — the real interface name, such as `eth0` or `eno1np0`
* `uplinkN_lan_ip` — the gateway address on that interface
* `uplinkN_lan_subnet` — the OSPF subnet for that address

Use a `/30`. Put the address inside the subnet, and use the same prefix on both lines. To disable an uplink, set all three values to `""`. A partly filled uplink is an error. At least one uplink must be set.

The file ships with these values. Replace the names and addresses with yours:

```
uplink1_interface="enp4s0"
uplink1_lan_ip="172.16.250.1/30"
uplink1_lan_subnet="172.16.250.0/30"
uplink2_interface="enp5s0"
uplink2_lan_ip="192.168.10.1/30"
uplink2_lan_subnet="192.168.10.0/30"
```

Uplink 3 and uplink 4 ship empty.

**One uplink**

```
uplink1_interface="eth0"
uplink1_lan_ip="172.16.0.1/30"
uplink1_lan_subnet="172.16.0.0/30"
uplink2_interface=""
uplink2_lan_ip=""
uplink2_lan_subnet=""
uplink3_interface=""
uplink3_lan_ip=""
uplink3_lan_subnet=""
uplink4_interface=""
uplink4_lan_ip=""
uplink4_lan_subnet=""
```

**Two uplinks**

```
uplink1_interface="enp2s0"
uplink1_lan_ip="172.16.0.1/30"
uplink1_lan_subnet="172.16.0.0/30"
uplink2_interface="enp5s0"
uplink2_lan_ip="172.16.1.1/30"
uplink2_lan_subnet="172.16.1.0/30"
uplink3_interface=""
uplink3_lan_ip=""
uplink3_lan_subnet=""
uplink4_interface=""
uplink4_lan_ip=""
uplink4_lan_subnet=""
```

**Four uplinks**

```
uplink1_interface="eth0"
uplink1_lan_ip="172.16.0.1/30"
uplink1_lan_subnet="172.16.0.0/30"
uplink2_interface="eth1"
uplink2_lan_ip="172.16.1.1/30"
uplink2_lan_subnet="172.16.1.0/30"
uplink3_interface="eth2"
uplink3_lan_ip="172.16.10.1/30"
uplink3_lan_subnet="172.16.10.0/30"
uplink4_interface="eth3"
uplink4_lan_ip="172.16.20.1/30"
uplink4_lan_subnet="172.16.20.0/30"
```

DHCP writes each uplink subnet with netmask `255.255.255.252`. Setup also adds lab pools `192.168.18.0/24` through `192.168.21.0/24`. Those pools start at `.11` and name `.1` as the gateway, so `.1` is not handed out.

## 5. Check Docker

`./setup.sh` installs `docker.io` and starts the daemon when Docker is missing or not running. If Docker is already installed, confirm it before setup:

```
docker run hello-world
```

The expected output begins with:

```
Hello from Docker!
This message shows that your installation appears to be working correctly.
```

## 6. Run setup

```
./setup.sh
```

The script asks for your sudo password when it needs it.

If a selected interface already has an IPv4 address, it prints the current address and the planned address, then asks:

```
An IP already exists on the LAN interface(s) above. Proceed anyway? [y/N]:
```

Answer `y` to replace that address with netplan. Answer `n` to exit. Nothing on the network has been changed yet.

It then prints the internet uplink and each LAN, and asks:

```
Continue with setup? [y/N]:
```

Answer `y`. Any other answer stops before netplan, NAT, and the containers. Packages installed during the dependency check stay installed.

Success looks like this:

```
Setup complete.
  Internet NAT: <internet-interface>
  Active LANs:  <1, 2, or 4>
  Containers:   frr_dyn, dhcpd_dyn, radiusd_dyn
```

Setup does the following:

* Checks `parameters.txt` before it changes the network
* Installs missing packages, including Docker when the daemon is not running
* Assigns the static address on each NSB interface through a netplan drop-in
* NATs those networks out the IPv4 default route
* Starts `frr_dyn`, `dhcpd_dyn`, and `radiusd_dyn`

Setup stops before it changes the network when `parameters.txt` is missing, a quote is unclosed, an uplink is only partly filled, an address is not `x.x.x.x/y`, no uplink is set, a named interface does not exist, sudo is unavailable, `/etc/netplan` is missing, or the internet uplink is down or listed as an NSB interface. It checks the `x.x.x.x/y` form only. It does not check that the address sits inside the subnet.

`netplan apply` can drop the default route for a moment. Setup continues when the previous internet interface is still up. If setup hits an error after changes have started, it removes the three containers, the NAT unit and script, the netplan drop-in, the addresses it added, and the state file. Installed packages and Docker images stay.

## 7. Clean up

Run cleanup from the internet address. Removing an NSB address drops an SSH session that came in on that address. Reconnect on the internet address and run cleanup again if that happens.

```
sudo ./cleanup.sh
```

Answer `y` at:

```
Proceed with cleanup? [y/N]:
```

Success is `Cleanup complete.` Packages and Docker images stay.

## Troubleshooting

**List interfaces and the default route**

```
ip link show
ip -4 addr show
ip -4 route show default
```

**Confirm the containers**

```
sudo docker ps
```

`frr_dyn`, `dhcpd_dyn`, and `radiusd_dyn` should be running after a successful setup.

**Test the internet path**

```
ping -c 3 8.8.8.8
```

**Bring an NSB interface up**

```
sudo ip link set <interface_name> up
ip -4 addr show <interface_name>
```
