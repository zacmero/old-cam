import usb.core

dev = usb.core.find(idVendor=0x1b17, idProduct=0x6101)
if not dev:
    print("Device not found")
    exit(1)

print("Scanning vendor IN requests (0xc0)...")
supported_in = []
for req in range(256):
    try:
        ret = dev.ctrl_transfer(0xc0, req, 0, 0, 4, timeout=50)
        supported_in.append((hex(req), [hex(x) for x in ret]))
    except usb.core.USBError:
        pass

for req, data in supported_in:
    print(f"  Req {req}: data = {data}")

print("\nScanning vendor IN requests with value=1 (like 0xa1)...")
supported_in_val1 = []
for req in range(256):
    try:
        ret = dev.ctrl_transfer(0xc0, req, 1, 0xbfcf, 1, timeout=50)
        supported_in_val1.append((hex(req), hex(ret[0])))
    except usb.core.USBError:
        pass

for req, val in supported_in_val1:
    print(f"  Req {req} (val=1, idx=0xbfcf): {val}")
