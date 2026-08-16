# Grendel fork — hardened single-binary iSCSI work

This repository is the working integration fork for the Grendel audit and embedded gotgt iSCSI work.

The bootstrap workflow imports the upstream Grendel source and applies the current integration patch. The target command is:

```bash
grendel --serve-iscsi
```

The first implementation is intentionally single-target/file-backed for the Ubuntu 24.04 iSCSI-root POC. Multi-node target reconciliation will follow after the first boot test.
