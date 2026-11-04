# SA-DemoKit

This kit configures an uplink for a Nile NSB (the Nile device this server connects to). An SA can bring the NSB up quickly when the uplink changes, on a Protectli or Raspberry Pi.

An uplink is the network link from this server to the NSB.

In plain words, the kit does three jobs:

* It puts a fixed address on each port that faces the NSB. The program that saves those addresses is called netplan.
* It shares this server’s internet connection with those ports, using the server’s normal way out to the internet (the default route). That sharing is called NAT.
* It starts three lab programs: a route announcer called FRR OSPF, an address hand-out service called ISC DHCP, and a login checker called FreeRADIUS.

You only edit one file, `parameters.txt`. Then you run `setup.sh`. When you are finished, `cleanup.sh` removes what setup added. Both scripts stop and ask you before they change the network.

Work through the steps in order. Paste one command, wait until it finishes, then go to the next step.

## 1. Open a terminal

A terminal is the window where you type commands. You need it for every step below.

Open the application named Terminal. On a desktop that is usually in the menu under Terminal or System.

You should see a blinking cursor and a line that ends with `$`.

If you cannot find it, use the keyboard and screen attached to the Protectli or Pi, or ask the person who installed the server to open Terminal once.

## 2. Refresh the list of software

This updates Ubuntu’s list of installable software so the next step can find what it needs. `sudo` runs a command as the administrator. It may ask for your password. The password stays blank while you type. Press Enter when you are done.

```
sudo apt-get update
```

You should see several lines of text, then a line like `Reading package lists... Done`, then your `$` prompt again.

If it says `Sorry, try again`, retype the password. If it says it cannot connect, or `Temporary failure resolving`, the server has no internet. Plug in Ethernet or join Wi-Fi, then run the command again.

## 3. Install git and OpenSSH

Git is the tool that downloads this kit. OpenSSH lets you log in to this server later from another computer.

```
sudo apt-get install -y git openssh-server
```

You should see packages being unpacked, then the `$` prompt, with no line that starts with `E:`.

If it says the packages are already the newest version, that is success. Continue.

## 4. Download the kit

This copies the kit onto the server.

```
git clone https://github.com/soleng2018/SA-DemoKit.git
```

You should see `Cloning into 'SA-DemoKit'...` and then `done`.

If it says `command not found`, step 3 did not finish. Run that install command again. If it says it cannot resolve the host, the internet connection is down. Fix that and run this command again.

## 5. Go into the kit folder

Every command after this one is typed from inside the kit folder.

```
cd SA-DemoKit
```

You should see no error. Type `ls` and press Enter. You should see `setup.sh`, `cleanup.sh`, `parameters.txt`, and `README.md`.

If it says `No such file or directory`, the download in step 4 did not land in this folder. Run step 4 again, then run `cd SA-DemoKit` again.

## 6. Allow the scripts to run

This marks the kit’s files so the server will run them.

```
sudo chmod +x *
```

You should see no message, then the `$` prompt. No message means it worked.

If it says `No such file or directory`, you are not inside the kit folder. Run step 5 again.

## 7. Let setup install Docker

Docker is a way to run the three lab programs in their own containers, separate from the rest of the server. This kit does not include a separate Docker installer. Do not run one.

When you reach step 10, `setup.sh` installs `docker.io` if Docker is missing, and starts it. If Docker is already installed, `setup.sh` uses that copy.

You should see nothing at this step. That is expected.

## 8. Find the network port names

An interface is the name of one network port, such as a plug on the Protectli or Pi. The setup script only accepts names that exist on this server. This command lists them.

```
ip link show
```

You should see a list. Each entry looks like `2: enp1s0:`. The name is the word before the colon (`enp1s0` in that example). Your names will be different. Write down the ones that face the NSB.

Then see which port is the internet port:

```
ip -4 route show default
```

You should see a line with the word `dev` followed by a name. That name is the internet port. Do not put it in `parameters.txt`. The script refuses to use the internet port as an NSB uplink.

A port can be unplugged and still show up in the list. That is fine.

If either command says `not found`, check the spelling, including the spaces. Both commands come with Ubuntu.

## 9. Set the uplink addresses

This is the only file you edit. For each uplink you want, fill in all three lines: the port name (`interface`), the address (`lan_ip`), and the network (`lan_subnet`). To turn an uplink off, set all three to empty quotes `""`. One filled line and two empty lines is an error. At least one uplink must be filled in. Put every value in double quotes. Use `/30` on both the address and the network. The script’s DHCP always writes those uplink networks with netmask `255.255.255.252`, which is a `/30`, no matter what you type.

```
nano parameters.txt
```

You should see text, including this sample:

```
uplink1_interface="enp4s0"
uplink1_lan_ip="172.16.250.1/30"
uplink1_lan_subnet="172.16.250.0/30"
uplink2_interface="enp5s0"
uplink2_lan_ip="192.168.10.9/30"
uplink2_lan_subnet="192.168.10.0/30"
```

Replace `enp4s0` and `enp5s0` with port names from step 8. Replace the addresses with the ones for this NSB. Uplinks 3 and 4 are already empty. Leave them empty unless you need them.

The shipped uplink 2 pair does not match. `192.168.10.9/30` is not inside `192.168.10.0/30`. Do not leave that pair as-is.

The comment at the bottom of the file has a broken example, `172.16.20./30`. Do not copy that line.

Setup also adds four extra address pools, `192.168.18.0`, `192.168.19.0`, `192.168.20.0`, and `192.168.21.0`. Those pools name `.1` as the gateway. The script never puts those `.1` addresses on any port.

Save and close nano: press Ctrl+O, then Enter, then Ctrl+X.

If `nano` says `command not found`, the file is still `parameters.txt` in this folder. Open it with any text editor, change the same lines, and save.

If a later step says an uplink is incomplete, one of the three lines is empty and another is not. Fill all three, or clear all three.

## 10. Run setup

This puts the fixed addresses on the ports, turns on NAT out the internet port, and starts FRR OSPF, ISC DHCP, and FreeRADIUS.

```
./setup.sh
```

It may ask for your password. That is normal.

If it asks `Proceed anyway? [y/N]:`, a port you named already has an address. Type `y` and Enter only if you mean to replace that address. Type `n` and Enter to stop. `n` makes no network change.

When it asks `Continue with setup? [y/N]:`, type `y` and Enter. Anything else stops before it changes the network. The letter `y` is required. Pressing Enter alone means no.

You should see `Setup complete.` and the names `frr_dyn`, `dhcpd_dyn`, and `radiusd_dyn`.

If you see `ERROR`, read the reason on that line. Setup tries to undo the network changes it already made. Software it installed, including Docker, stays installed. Fix the reason (often a port name or a missing address) and run `./setup.sh` again.

## 11. Remove the lab when you are done

This removes the addresses, the NAT rules, and the three lab programs. Run it while you are connected through the internet port, not through a demo LAN address (an address you set on an NSB-facing port). If your login uses a demo LAN address, this command drops that login.

```
sudo ./cleanup.sh
```

When it asks `Proceed with cleanup? [y/N]:`, type `y` and Enter.

You should see `Cleanup complete.`

Packages and Docker images stay after cleanup. That is expected. The command does not uninstall them.

If your login drops before the end, reconnect on the internet address, `cd SA-DemoKit`, and run `sudo ./cleanup.sh` again.
