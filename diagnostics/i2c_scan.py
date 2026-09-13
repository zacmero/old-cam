import usb.core
import usb.util
import time

dev = usb.core.find(idVendor=0x1b17, idProduct=0x6101)
if not dev:
    print("Camera 1b17:6101 not found")
    exit(1)

def reg_r(req, index, length=1):
    return dev.ctrl_transfer(0xc0, req, 1, index, length)

def reg_w(req, value, index):
    dev.ctrl_transfer(0x40, req, value, index, b"")

print("Checking header 0xbfcf:", hex(reg_r(0xa1, 0xbfcf, 1)[0]))

# Try different clock configurations for 0xb300
clock_configs = [
    (0x24, 0x25, 0x01, "standard 1"),
    (0x26, 0x26, 0x05, "standard 2"),
    (0x64, 0x65, 0x01, "alt 1"),
    (0x67, 0x67, 0x01, "alt 2"),
    (0x20, 0x22, 0x05, "alt 3"),
    (0x25, 0x24, 0x05, "alt 4")
]

found = []

for m1, m2, op, desc in clock_configs:
    print(f"\n[*] Scanning I2C addresses with clock config: {desc} (m1={hex(m1)}, m2={hex(m2)}, op={hex(op)})...")
    reg_w(0xa0, 0x02, 0xb334)
    reg_w(0xa0, m1, 0xb300)
    reg_w(0xa0, m2, 0xb300)
    reg_w(0xa0, 0x01, 0xb308)
    reg_w(0xa0, 0x0c, 0xb309)
    reg_w(0xa0, op, 0xb301)
    
    # Common I2C camera sensor addresses (8-bit)
    # 0x20, 0x21, 0x30, 0x40, 0x42, 0x48, 0x56, 0x5c, 0x5d, 0x60, 0x6e, 0x76, 0x78, 0x90, 0x98, 0xa0, 0xba
    candidate_addrs = []
    # Test all even addresses 0x10 to 0xee
    for a in range(0x10, 0xf0, 2):
        candidate_addrs.append(0x80 | a)
        candidate_addrs.append(a)
    
    for i2c_add in candidate_addrs:
        # check bus not busy
        b = reg_r(0xa1, 0xb33f, 1)[0]
        if not (b & 0x02):
            # reset bus
            reg_w(0xa0, 0x01, 0xb301)
            time.sleep(0.01)
            continue
        
        reg_w(0xa0, i2c_add, 0xb335)
        # try reading reg 0x00
        reg_w(0xa0, 0x00, 0xb33a)
        reg_w(0xa0, 0x02, 0xb339)
        
        acked = False
        for _ in range(8):
            status = reg_r(0xa1, 0xb33b, 1)[0]
            if status == 0x00:
                acked = True
                break
            time.sleep(0.005)
        
        if acked:
            h = reg_r(0xa1, 0xb33c, 1)[0]
            m = reg_r(0xa1, 0xb33d, 1)[0]
            l = reg_r(0xa1, 0xb33e, 1)[0]
            chip_id = (h << 8) | m
            print(f"  [+] FOUND RESPONDING I2C ADDR: 0x{i2c_add:02x}! Reg 0x00 data: 0x{chip_id:04x} (h={hex(h)}, m={hex(m)}, l={hex(l)})")
            found.append((i2c_add, chip_id, desc))
            
if not found:
    print("\n[-] No I2C response with tested clocks.")
else:
    print("\n[+] Summary of responding sensors:", found)
