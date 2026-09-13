import usb.core

dev = usb.core.find(idVendor=0x1b17, idProduct=0x6101)
if not dev:
    print("Device not found")
    exit(1)

def reg_r(index):
    try:
        return dev.ctrl_transfer(0xc0, 0xa1, 1, index, 1)[0]
    except:
        return None

pages = [
    ("Clock/Power (0xb0xx)", 0xb000, 0x10),
    ("Sensor IF (0xb3xx)", 0xb300, 0x60),
    ("Scaling (0xb6xx)", 0xb600, 0x30),
    ("JPEG (0xbcxx)", 0xbc00, 0x20),
    ("FIFO/USB (0xbfxx)", 0xbf00, 0xd0),
]

for title, base, count in pages:
    print(f"\n--- {title} ---")
    line = []
    for i in range(count):
        val = reg_r(base + i)
        val_str = f"{val:02x}" if val is not None else "--"
        line.append(f"{i:02x}:{val_str}")
        if (i + 1) % 8 == 0 or i == count - 1:
            print(" ".join(line))
            line = []
