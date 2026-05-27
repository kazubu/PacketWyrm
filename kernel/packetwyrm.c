// SPDX-License-Identifier: GPL-2.0
/*
 * PacketWyrm Phase 11 kernel driver -- skeleton.
 *
 * Today this only proves the kernel can probe an AS02MC04 board,
 * map BAR0, and read the same identity registers the userspace
 * BAR backend reads. Future work (netdev registration, NAPI,
 * DMA, ethtool, devlink) layers on top of this same probe path.
 */

#include <linux/module.h>
#include <linux/pci.h>
#include <linux/io.h>
#include <linux/types.h>

#define PW_VENDOR_ID  0x10EE
#define PW_DEVICE_ID  0xA502

/* CSR offsets - must match sw/libpacketwyrm/include/packetwyrm/csr.h */
#define PW_REG_DEVICE_ID      0x0000
#define PW_REG_VERSION        0x0004
#define PW_REG_BUILD_ID       0x0008
#define PW_REG_GIT_HASH       0x000c
#define PW_REG_CAPABILITIES   0x0010
#define PW_REG_NUM_PORTS      0x0014
#define PW_REG_NUM_FLOWS      0x0018

#define PW_EXPECTED_DEVICE_ID 0xA502BEEFu

static bool force_match;
module_param(force_match, bool, 0644);
MODULE_PARM_DESC(force_match,
	"Skip the device_id register check during probe (dev only).");

struct pw_card {
	struct pci_dev __iomem *pci;
	void __iomem           *bar0;
	resource_size_t         bar0_len;
	u32                     device_id;
	u32                     version;
	u32                     build_id;
	u32                     git_hash;
	u32                     capabilities;
	u32                     num_ports;
	u32                     num_flows;
};

static int pw_probe(struct pci_dev *pdev, const struct pci_device_id *id)
{
	struct pw_card *c;
	int rc;
	u32 dev_id;

	c = devm_kzalloc(&pdev->dev, sizeof(*c), GFP_KERNEL);
	if (!c)
		return -ENOMEM;
	c->pci = (struct pci_dev __iomem *)pdev;

	rc = pcim_enable_device(pdev);
	if (rc) {
		dev_err(&pdev->dev, "pcim_enable_device: %d\n", rc);
		return rc;
	}
	pci_set_master(pdev);

	rc = pcim_iomap_regions(pdev, BIT(0), KBUILD_MODNAME);
	if (rc) {
		dev_err(&pdev->dev, "pcim_iomap_regions BAR0: %d\n", rc);
		return rc;
	}
	c->bar0    = pcim_iomap_table(pdev)[0];
	c->bar0_len = pci_resource_len(pdev, 0);

	dev_id = ioread32(c->bar0 + PW_REG_DEVICE_ID);
	if (!force_match && dev_id != PW_EXPECTED_DEVICE_ID) {
		dev_warn(&pdev->dev,
			"device_id register reads 0x%08x (expected 0x%08x); not claiming\n",
			dev_id, PW_EXPECTED_DEVICE_ID);
		return -ENODEV;
	}

	c->device_id    = dev_id;
	c->version      = ioread32(c->bar0 + PW_REG_VERSION);
	c->build_id     = ioread32(c->bar0 + PW_REG_BUILD_ID);
	c->git_hash     = ioread32(c->bar0 + PW_REG_GIT_HASH);
	c->capabilities = ioread32(c->bar0 + PW_REG_CAPABILITIES);
	c->num_ports    = ioread32(c->bar0 + PW_REG_NUM_PORTS);
	c->num_flows    = ioread32(c->bar0 + PW_REG_NUM_FLOWS);

	pci_set_drvdata(pdev, c);

	pci_info(pdev,
		"PacketWyrm: device_id=0x%08x version=0x%08x build=0x%08x git=0x%08x\n",
		c->device_id, c->version, c->build_id, c->git_hash);
	pci_info(pdev,
		"PacketWyrm: caps=0x%08x ports=%u flows=%u  BAR0=%pa+0x%llx\n",
		c->capabilities, c->num_ports, c->num_flows,
		&pdev->resource[0].start, (u64)c->bar0_len);

	/* Future work: register netdev(s), wire NAPI, allocate DMA
	 * descriptor rings, install MSI-X handlers, expose ethtool /
	 * devlink. See docs/design/kernel-driver.md. */
	return 0;
}

static void pw_remove(struct pci_dev *pdev)
{
	pci_info(pdev, "PacketWyrm: remove\n");
	/* pcim_* helpers handle iomap / regions / device disable on
	 * device-managed teardown. */
}

static const struct pci_device_id pw_pci_ids[] = {
	{ PCI_DEVICE(PW_VENDOR_ID, PW_DEVICE_ID) },
	{ 0, }
};
MODULE_DEVICE_TABLE(pci, pw_pci_ids);

static struct pci_driver pw_pci_driver = {
	.name     = KBUILD_MODNAME,
	.id_table = pw_pci_ids,
	.probe    = pw_probe,
	.remove   = pw_remove,
};

module_pci_driver(pw_pci_driver);

MODULE_AUTHOR("PacketWyrm contributors");
MODULE_DESCRIPTION("PacketWyrm kernel skeleton driver (Phase 11)");
MODULE_LICENSE("GPL");
MODULE_VERSION("0.1.0");
