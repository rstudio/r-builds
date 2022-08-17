# HTTP mirror to support R 3.1
options(repos = c("https://cloud.r-project.org", "http://cloud.r-project.org"))

# Create a temp lib to avoid installing into the system library
temp_lib <- tempdir()
.libPaths(temp_lib)

# Install a package from CRAN
install.packages("R6")
library(R6)

# Install a package with C/C++ and Fortran code, which links against libR, BLAS, LAPACK
curr_dir <- Sys.getenv("DIR", ".")
install.packages(file.path(curr_dir, "testpkg"), repos = NULL, clean = TRUE)
source(file.path(curr_dir, "testpkg/tests/test.R"))

# Check iconv support
if (!capabilities("iconv") || !all(c("ASCII", "LATIN1", "UTF-8") %in% iconvlist())) {
  stop("missing iconv support")
}

# Check that built-in packages can be loaded
for (pkg in rownames(installed.packages(priority = c("base", "recommended")))) {
  if (!require(pkg, character.only = TRUE)) {
    stop(sprintf("failed to load built-in package %s", pkg))
  }
}

# Show capabilities. Warnings are returned on missing libraries.
tryCatch(capabilities(), warning = function(w) {
  print(capabilities())
  stop(sprintf("missing libraries: %s", w$message))
})

# Check graphics devices
# https://stat.ethz.ch/R-manual/R-devel/library/grDevices/html/Devices.html
for (dev_name in c("png", "jpeg", "tiff", "svg", "bmp", "pdf", "postscript",
                   "xfig", "pictex", "cairo_pdf", "cairo_ps")) {
  # Skip unsupported graphics devices (e.g. tiff in R >= 3.3 on CentOS 6)
  if (dev_name %in% names(capabilities()) && capabilities(dev_name) == FALSE) {
    next
  }
  dev <- getFromNamespace(dev_name, "grDevices")
  tryCatch({
    file <- tempfile()
    on.exit(unlink(file))
    if (dev_name == "xfig") {
      # Suppress warning from xfig when onefile = FALSE (the default)
      dev(file, onefile = TRUE)
    } else {
      dev(file)
    }
    plot(1)
    dev.off()
  }, warning = function(w) {
    # Catch errors which manifest as warnings (e.g. "failed to load cairo DLL")
    stop(sprintf("graphics device %s failed: %s", dev_name, w$message))
  })
}

# Check for unexpected output from graphics/text rendering.
# Run externally to capture output from external processes.
# For example, "Pango-WARNING **: failed to choose a font, expect ugly output"
# messages when rendering text without any system fonts installed.
output <- system2(R.home("bin/Rscript"), "-e 'png(tempfile()); plot(1)'", stdout = TRUE, stderr = TRUE)
if (length(output) > 0) {
  stop(sprintf("unexpected output returned from plotting:\n%s", paste(output, collapse = "\n")))
}

# Check download methods: libcurl (supported in R >= 3.2) and internal (based on libxml)
if ("libcurl" %in% names(capabilities())) {
  download.file("https://cloud.r-project.org", tempfile(), "libcurl")
}
tmpfile <- tempfile()
write.csv("test", tmpfile)
download.file(sprintf("file://%s", tmpfile), tempfile(), "internal")

# Check that a pager is configured and help pages work
# https://stat.ethz.ch/R-manual/R-devel/library/base/html/file.show.html
output <- system2(R.home("bin/Rscript"), "-e 'help(stats)'", stdout = TRUE)
if (length(output) == 0) {
  stop("failed to display help pages; check that a pager is configured properly")
}

# Smoke test BLAS/LAPACK functionality. R may start just fine with an incompatible
# BLAS/LAPACK library, and only fail when calling a BLAS or LAPACK routine.
stopifnot(identical(crossprod(matrix(1)), matrix(1)))
stopifnot(identical(chol(matrix(1)), matrix(1)))

# Check that R 3.x depends on PCRE1, and R 4.x depends on PCRE2.
# R 3.5 and 3.6 will link against PCRE2 if present, and take on an unnecessary dependency.
# Some distros do always require PCRE2, however, such as Debian 11.
ld_flags <- system2(R.home("bin/R"), c("CMD", "config", "--ldflags"), stdout = TRUE)
has_pcre1 <- grepl("-lpcre\\b", ld_flags)
has_pcre2 <- grepl("-lpcre2-8\\b", ld_flags)
if (getRversion() >= "3.5.0" && getRversion() < "4.0.0") {
  stopifnot(has_pcre1)
  if (has_pcre2) {
    message(sprintf("Info: %s is linked against PCRE2, which may be unnecessary", R.version.string))
  }
} else if (getRversion() >= "4.0.0") {
  stopifnot(has_pcre2 && !has_pcre1)
}
