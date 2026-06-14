#!/usr/bin/env python3
# Read the PacketWyrm identity registers from an AS02MC04 BAR via VFIO.
#
# Works under kernel lockdown / Secure Boot, where raw sysfs resource
# mmap and setpci are blocked but VFIO (IOMMU-mediated) is permitted.
# The device must already be bound to vfio-pci and sit in its own IOMMU
# group (scripts/bringup-check-vfio.sh handles the bind).
#
#   sudo python3 vfio_read_csr.py 0000:07:00.0 <iommu_group>
#
# Scans the device's mmappable BAR regions for device_id 0xA502BEEF and
# prints the first eight 32-bit identity words from the matching BAR.

import ctypes, mmap, os, struct, sys

VFIO_TYPE1_IOMMU = 1
VFIO_GROUP_FLAGS_VIABLE = 1
VFIO_REGION_INFO_FLAG_MMAP = 4

# _IO(';', n) == (0x3B << 8) | n
def _IO(n): return (0x3B << 8) | n
VFIO_SET_IOMMU              = _IO(102)
VFIO_GROUP_GET_STATUS       = _IO(103)
VFIO_GROUP_SET_CONTAINER    = _IO(104)
VFIO_GROUP_GET_DEVICE_FD    = _IO(106)
VFIO_DEVICE_GET_REGION_INFO = _IO(108)
VFIO_DEVICE_RESET           = _IO(111)

EXPECTED = 0xA502BEEF

libc = ctypes.CDLL(None, use_errno=True)
libc.ioctl.restype = ctypes.c_int

def ioctl(fd, req, arg):
    # arg: int (by value) or ctypes buffer (by pointer)
    ctypes.set_errno(0)
    r = libc.ioctl(ctypes.c_int(fd), ctypes.c_ulong(req), arg)
    if r < 0:
        e = ctypes.get_errno()
        raise OSError(e, os.strerror(e), f"ioctl {req:#x}")
    return r

def main():
    bdf, group = sys.argv[1], sys.argv[2]

    container = os.open("/dev/vfio/vfio", os.O_RDWR)
    grp = os.open(f"/dev/vfio/{group}", os.O_RDWR)

    st = ctypes.create_string_buffer(struct.pack("<II", 8, 0), 8)
    ioctl(grp, VFIO_GROUP_GET_STATUS, st)
    _, flags = struct.unpack("<II", st.raw)
    if not (flags & VFIO_GROUP_FLAGS_VIABLE):
        sys.exit(f"VFIO group {group} not viable (flags={flags:#x}); every "
                 "device in the IOMMU group must be bound to vfio-pci")

    ioctl(grp, VFIO_GROUP_SET_CONTAINER, ctypes.byref(ctypes.c_int(container)))
    ioctl(container, VFIO_SET_IOMMU, VFIO_TYPE1_IOMMU)

    devfd = ioctl(grp, VFIO_GROUP_GET_DEVICE_FD,
                  ctypes.create_string_buffer(bdf.encode() + b"\0"))

    def rd(mm, off):
        return struct.unpack_from("<I", mm, off)[0]

    found = None
    for idx in range(6):  # VFIO_PCI_BAR0..BAR5
        ri = ctypes.create_string_buffer(struct.pack("<IIIIQQ", 32, 0, idx, 0, 0, 0), 32)
        ioctl(devfd, VFIO_DEVICE_GET_REGION_INFO, ri)
        _, flags, _, _, size, offset = struct.unpack("<IIIIQQ", ri.raw)
        if size < 4 or not (flags & VFIO_REGION_INFO_FLAG_MMAP):
            continue
        length = (size + mmap.PAGESIZE - 1) // mmap.PAGESIZE * mmap.PAGESIZE
        mm = mmap.mmap(devfd, length, mmap.MAP_SHARED, mmap.PROT_READ, offset=offset)
        rep = [rd(mm, 0) for _ in range(4)]            # offset 0 read x4
        words = [rd(mm, 4*i) for i in range(8)]        # offsets 0..28
        print(f"   BAR{idx} size={size} off0x0 x4=" +
              " ".join(f"{v:08x}" for v in rep))
        print(f"        words[0..7]=" + " ".join(f"{v:08x}" for v in words))
        if rep[0] == EXPECTED and found is None:
            found = (idx, words, rep)
        mm.close()

    # NOTE: an earlier revision issued VFIO_DEVICE_RESET here as a wedge
    # probe -- on this board that reset cascaded to the PCIe link and
    # rebooted the host. Do NOT reset the function from userspace.

    if found is None:
        sys.exit(f"no BAR carried device_id 0x{EXPECTED:08X}")
    idx, words, rep = found
    names = ["device_id", "version", "build_id", "git_hash",
             "capabilities", "num_ports", "num_flows", "num_ifs"]
    print(f"   -> CSR is on BAR{idx}; device_id read back 0x{rep[0]:08x}")
    if all(r == EXPECTED for r in rep) and words[0] == EXPECTED:
        for n, v in zip(names, words):
            print(f"   {n:<13}= 0x{v:08x}")
        print("OK: identity registers verified via VFIO.")
    else:
        print("WARN: device_id reachable but reads are not stable "
              "(first read OK, repeats return 0x%08x) -- AXI-Lite read-path "
              "issue to chase; the BAR/identity itself is correct."
              % rep[1])

if __name__ == "__main__":
    main()
