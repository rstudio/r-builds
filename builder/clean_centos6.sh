#!/bin/bash

# For CentOS 6, we need to clean references to the static library and header paths
# out of the R configuration files
sed -i 's|-Wl,--whole-archive /tmp/extra/lib/libz.a /tmp/extra/lib/libbz2.a /tmp/extra/lib/liblzma.a /tmp/extra/lib/libpcre.a /tmp/extra/lib/libcurl.a -Wl,--no-whole-archive -L/tmp/extra/lib/||g' /opt/R/${R_VERSION}/lib/R/etc/Makeconf
sed -i 's|-Wl,--whole-archive /tmp/extra/lib/libz.a /tmp/extra/lib/libbz2.a /tmp/extra/lib/liblzma.a /tmp/extra/lib/libpcre.a /tmp/extra/lib/libcurl.a -Wl,--no-whole-archive -L/tmp/extra/lib/||g' /opt/R/${R_VERSION}/lib/pkgconfig/libR.pc
sed -i 's|-ldl -lpthread .* -lldap -lz -lrt||g' /opt/R/${R_VERSION}/lib/R/etc/Makeconf
sed -i 's|-ldl -lpthread .* -lldap -lz -lrt||g' /opt/R/${R_VERSION}/lib/pkgconfig/libR.pc
sed -i 's|-I/tmp/extra/include||g' /opt/R/${R_VERSION}/lib/R/etc/Makeconf
sed -i 's|-I/tmp/extra/include||g' /opt/R/${R_VERSION}/lib/R/bin/libtool
sed -i 's|-ldl -lpthread .* -lldap -lz||g' /opt/R/${R_VERSION}/lib/R/etc/Makeconf
sed -i 's|-ldl -lpthread .* -lldap||g' /opt/R/${R_VERSION}/lib/R/etc/Makeconf
sed -i 's|:/tmp/extra/lib||g' /opt/R/${R_VERSION}/lib/R/etc/ldpaths
sed -i 's|/tmp/extra/lib||g' /opt/R/${R_VERSION}/lib/R/etc/ldpaths
