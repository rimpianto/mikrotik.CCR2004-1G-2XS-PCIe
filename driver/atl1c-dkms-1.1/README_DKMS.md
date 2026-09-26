# atl1c-ccr2004fix

DKMS package fixing a soft-lockup in the `atl1c` driver when a CCR2004 PCIe
card reboots and flaps the link.

You will need a second connection to the host machine through a different
interface.

## Build / install

Change into the directory, then:

```sh
sudo dkms add .
sudo dkms build atl1c-ccr2004fix/1.0
sudo dkms install atl1c-ccr2004fix/1.0
sudo modprobe -r atl1c && sudo modprobe atl1c
```

`dkms status` should show the module built and installed for the running
kernel; it rebuilds automatically on kernel upgrades.

## Recovering interfaces after a manual module reload

Installing the patched driver will solve the soft lockup. However, the virtual
interfaces will still be in a bad state. That needs to be fixed from a 
different connection.

```sh
sudo modprobe -r atl1c
echo 1 | sudo tee /sys/bus/pci/devices/0000:05:00.0/remove
echo 1 | sudo tee /sys/bus/pci/devices/0000:05:00.1/remove
echo 1 | sudo tee /sys/bus/pci/devices/0000:05:00.2/remove
echo 1 | sudo tee /sys/bus/pci/devices/0000:05:00.3/remove
echo 1 | sudo tee /sys/bus/pci/rescan
```
