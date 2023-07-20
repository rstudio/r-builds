# Patches

Patches can be applied for specific R versions and platforms. To add a patch for an R version on
all platforms, create a patch file at `patches/R-${R_VERSION}.patch` (such as
`patches/R-devel.patch`).

To add a patch for an R version on a specific platform create a patch file at
`patches/R-${R_VERSION}-${OS_IDENTIFIER}.patch` (such as
`patches/R-3.3.0-centos-8.patch`).
