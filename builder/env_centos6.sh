# Test to see if $R_VERSION is <= 3.1.3. If so, append some additional configure options
# to the $CONFIGURE_OPTIONS env var.
NEWLINE=$'\n'
if [[ "$(printf '%s\n' "${R_VERSION}${NEWLINE}3.1.3" | sort -V | head -n 1)" == "$R_VERSION" ]]; then \
  export CONFIGURE_OPTIONS="${CONFIGURE_OPTIONS} \
    --with-system-zlib \
    --with-system-bzlib \
    --with-system-pcre \
    --with-system-xz"
fi

# Get library linking information from CURL. This is then used to populate LDFLAGS
export CURL_LIBS="`/tmp/extra/bin/curl-config --libs`"
export LDFLAGS="-ldl -lpthread -lc -lrt -Wl,--as-needed -Wl,--whole-archive /tmp/extra/lib/libz.a /tmp/extra/lib/libbz2.a /tmp/extra/lib/liblzma.a /tmp/extra/lib/libpcre.a /tmp/extra/lib/libcurl.a -Wl,--no-whole-archive -L/tmp/extra/lib/ ${CURL_LIBS}"
