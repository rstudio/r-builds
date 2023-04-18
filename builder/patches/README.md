# Patches

Patches can be applied for specific R versions and platforms. To add a patch, create a patch file
at `patches/R-${R_VERSION}.patch` (such as `patches/R-devel.patch`), and add the following line
to the platform Dockerfile:

```dockerfile
COPY patches /patches
```
