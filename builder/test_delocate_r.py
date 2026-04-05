"""Unit tests for delocate-r.py."""

import hashlib
import os
import subprocess
from pathlib import Path
from unittest import mock

import pytest

# Import the module under test. Since delocate-r.py has a hyphen, use importlib.
import importlib.util

spec = importlib.util.spec_from_file_location(
    "delocate_r",
    Path(__file__).parent / "delocate-r.py",
)
delocate_r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(delocate_r)


# ── is_allowed ───────────────────────────────────────────────────────────────


class TestIsAllowed:
    def test_exact_glibc_prefix(self):
        assert delocate_r.is_allowed("libc.so.6") is True

    def test_versioned_suffix(self):
        assert delocate_r.is_allowed("libz.so.1") is True
        assert delocate_r.is_allowed("libz.so.1.2.13") is True

    def test_r_internal_libs(self):
        assert delocate_r.is_allowed("libR.so") is True
        assert delocate_r.is_allowed("libRblas.so") is True
        assert delocate_r.is_allowed("libRlapack.so") is True

    def test_x11_not_allowed(self):
        """X11 libs are intentionally excluded from the allowlist."""
        assert delocate_r.is_allowed("libX11.so.6") is False
        assert delocate_r.is_allowed("libXext.so.6") is False
        assert delocate_r.is_allowed("libXrender.so.1") is False
        assert delocate_r.is_allowed("libICE.so.6") is False
        assert delocate_r.is_allowed("libSM.so.6") is False

    def test_system_libs_not_allowed(self):
        """Libraries not on the allowlist should be bundled."""
        assert delocate_r.is_allowed("libcurl.so.4") is False
        assert delocate_r.is_allowed("libssl.so.1.1") is False
        assert delocate_r.is_allowed("libreadline.so.7") is False
        assert delocate_r.is_allowed("libtinfo.so.6") is False
        assert delocate_r.is_allowed("libcairo.so.2") is False
        assert delocate_r.is_allowed("libpango-1.0.so.0") is False

    def test_vdso(self):
        assert delocate_r.is_allowed("linux-vdso.so.1") is True

    def test_ld_linux(self):
        assert delocate_r.is_allowed("ld-linux-x86-64.so.2") is True
        assert delocate_r.is_allowed("ld-linux-aarch64.so.1") is True

    def test_compiler_runtime(self):
        assert delocate_r.is_allowed("libgcc_s.so.1") is True
        assert delocate_r.is_allowed("libstdc++.so.6") is True

    def test_glib_not_allowed(self):
        """GLib libs are intentionally excluded from the allowlist."""
        assert delocate_r.is_allowed("libglib-2.0.so.0") is False
        assert delocate_r.is_allowed("libgobject-2.0.so.0") is False
        assert delocate_r.is_allowed("libgthread-2.0.so.0") is False

    def test_empty_string(self):
        assert delocate_r.is_allowed("") is False

    def test_partial_match_not_confused(self):
        """libRfoo.so should not match libR.so prefix — wait, it does.
        This is by design: prefix matching means libR.so matches libR.so.anything,
        but libRfoo.so does NOT start with 'libR.so'."""
        assert delocate_r.is_allowed("libRfoo.so") is False
        # But libR.so.1 does match
        assert delocate_r.is_allowed("libR.so.1") is True


# ── hash_rename ──────────────────────────────────────────────────────────────


class TestHashRename:
    def test_simple_filename(self):
        assert delocate_r.hash_rename("libfoo.so.1", "abcd1234") == "libfoo-abcd1234.so.1"

    def test_full_version(self):
        assert delocate_r.hash_rename("libbar.so.1.2.3", "deadbeef") == "libbar-deadbeef.so.1.2.3"

    def test_no_version(self):
        assert delocate_r.hash_rename("libx.so", "12345678") == "libx-12345678.so"

    def test_complex_name(self):
        assert delocate_r.hash_rename("libpango-1.0.so.0", "aabbccdd") == "libpango-1-aabbccdd.0.so.0"

    def test_preserves_hash(self):
        """Different hashes produce different names."""
        a = delocate_r.hash_rename("libfoo.so.1", "aaaaaaaa")
        b = delocate_r.hash_rename("libfoo.so.1", "bbbbbbbb")
        assert a != b
        assert "aaaaaaaa" in a
        assert "bbbbbbbb" in b


# ── file_hash ────────────────────────────────────────────────────────────────


class TestFileHash:
    def test_deterministic(self, tmp_path):
        f = tmp_path / "test.so"
        f.write_bytes(b"hello world")
        h1 = delocate_r.file_hash(str(f))
        h2 = delocate_r.file_hash(str(f))
        assert h1 == h2

    def test_default_length(self, tmp_path):
        f = tmp_path / "test.so"
        f.write_bytes(b"test content")
        h = delocate_r.file_hash(str(f))
        assert len(h) == 8
        assert all(c in "0123456789abcdef" for c in h)

    def test_custom_length(self, tmp_path):
        f = tmp_path / "test.so"
        f.write_bytes(b"test")
        h = delocate_r.file_hash(str(f), n=16)
        assert len(h) == 16

    def test_matches_sha256(self, tmp_path):
        f = tmp_path / "test.so"
        content = b"known content for testing"
        f.write_bytes(content)
        expected = hashlib.sha256(content).hexdigest()[:8]
        assert delocate_r.file_hash(str(f)) == expected

    def test_different_files_different_hashes(self, tmp_path):
        f1 = tmp_path / "a.so"
        f2 = tmp_path / "b.so"
        f1.write_bytes(b"content A")
        f2.write_bytes(b"content B")
        assert delocate_r.file_hash(str(f1)) != delocate_r.file_hash(str(f2))


# ── relpath_from ─────────────────────────────────────────────────────────────


class TestRelpathFrom:
    def test_sibling_dirs(self):
        target = Path("/opt/R/4.4.2/libs/.libs")
        base = Path("/opt/R/4.4.2/lib/R/lib")
        result = delocate_r.relpath_from(target, base)
        assert result == "../../../libs/.libs"

    def test_deep_to_top(self):
        target = Path("/opt/R/4.4.2/libs/.libs")
        base = Path("/opt/R/4.4.2/lib/R/bin/exec")
        result = delocate_r.relpath_from(target, base)
        assert result == "../../../../libs/.libs"

    def test_same_dir(self):
        target = Path("/opt/R/libs/.libs")
        base = Path("/opt/R/libs/.libs")
        result = delocate_r.relpath_from(target, base)
        assert result == "."

    def test_child_dir(self):
        target = Path("/opt/R/libs/.libs/sub")
        base = Path("/opt/R/libs/.libs")
        result = delocate_r.relpath_from(target, base)
        assert result == "sub"

    def test_parent_dir(self):
        target = Path("/opt/R/libs")
        base = Path("/opt/R/libs/.libs")
        result = delocate_r.relpath_from(target, base)
        assert result == ".."


# ── ldd output parsing ──────────────────────────────────────────────────────


class TestLddParsing:
    """Test ldd output parsing by mocking subprocess.run."""

    def _mock_ldd(self, stdout, returncode=0):
        return mock.patch(
            "subprocess.run",
            return_value=subprocess.CompletedProcess(
                args=["ldd"], returncode=returncode, stdout=stdout, stderr="",
            ),
        )

    def test_normal_output(self):
        output = (
            "\tlinux-vdso.so.1 (0x00007ffd12345000)\n"
            "\tlibreadline.so.7 => /usr/lib64/libreadline.so.7 (0x00007f1234560000)\n"
            "\tlibc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007f1234000000)\n"
            "\t/lib64/ld-linux-x86-64.so.2 (0x00007f1234800000)\n"
        )
        with self._mock_ldd(output):
            result = delocate_r.ldd(Path("/fake/binary"))
        assert ("libreadline.so.7", "/usr/lib64/libreadline.so.7") in result
        assert ("libc.so.6", "/lib/x86_64-linux-gnu/libc.so.6") in result
        # vdso and ld-linux don't have "=>" format
        assert len(result) == 2

    def test_not_found(self):
        output = "\tlibmissing.so.1 => not found\n"  # noqa: E501
        with self._mock_ldd(output):
            result = delocate_r.ldd(Path("/fake/binary"))
        # "not found" entries are filtered out
        assert len(result) == 0

    def test_failure(self):
        with self._mock_ldd("", returncode=1):
            result = delocate_r.ldd(Path("/fake/binary"))
        assert result == []

    def test_multiple_deps(self):
        output = (
            "\tlibcurl.so.4 => /usr/lib64/libcurl.so.4 (0x00007f0001000000)\n"
            "\tlibssl.so.1.1 => /usr/lib64/libssl.so.1.1 (0x00007f0002000000)\n"
            "\tlibcrypto.so.1.1 => /usr/lib64/libcrypto.so.1.1 (0x00007f0003000000)\n"
            "\tlibz.so.1 => /lib/x86_64-linux-gnu/libz.so.1 (0x00007f0004000000)\n"
        )
        with self._mock_ldd(output):
            result = delocate_r.ldd(Path("/fake/binary"))
        assert len(result) == 4
        sonames = [s for s, _ in result]
        assert "libcurl.so.4" in sonames
        assert "libssl.so.1.1" in sonames


# ── discover_external_deps ──────────────────────────────────────────────────


class TestDiscoverExternalDeps:
    """Test dependency discovery with mocked ldd."""

    def test_filters_allowed_and_internal(self):
        r_path = Path("/opt/R/4.4.2")
        elf = Path("/opt/R/4.4.2/lib/R/lib/libR.so")

        ldd_output = [
            ("libreadline.so.7", "/usr/lib64/libreadline.so.7"),
            ("libc.so.6", "/lib/x86_64-linux-gnu/libc.so.6"),
            ("libRblas.so", "/opt/R/4.4.2/lib/R/lib/libRblas.so"),
            ("libcurl.so.4", "/usr/lib64/libcurl.so.4"),
            ("libz.so.1", "/lib/x86_64-linux-gnu/libz.so.1"),
        ]

        with mock.patch.object(delocate_r, "ldd", return_value=ldd_output):
            external, elf_needs = delocate_r.discover_external_deps([elf], r_path)

        # libreadline and libcurl should be external (not allowed, not internal)
        assert "libreadline.so.7" in external
        assert "libcurl.so.4" in external
        # libc is allowed, libRblas is internal, libz is allowed
        assert "libc.so.6" not in external
        assert "libRblas.so" not in external
        assert "libz.so.1" not in external
        # elf_needs should list the non-allowed deps
        assert elf in elf_needs
        assert "libreadline.so.7" in elf_needs[elf]
        assert "libcurl.so.4" in elf_needs[elf]

    def test_no_external_deps(self):
        r_path = Path("/opt/R/4.4.2")
        elf = Path("/opt/R/4.4.2/lib/R/lib/libR.so")

        ldd_output = [
            ("libc.so.6", "/lib/x86_64-linux-gnu/libc.so.6"),
            ("libm.so.6", "/lib/x86_64-linux-gnu/libm.so.6"),
        ]

        with mock.patch.object(delocate_r, "ldd", return_value=ldd_output):
            external, elf_needs = delocate_r.discover_external_deps([elf], r_path)

        assert len(external) == 0
        assert len(elf_needs) == 0

    def test_x11_detected_as_external(self):
        """X11 libs are not on the allowlist and should be bundled."""
        r_path = Path("/opt/R/4.4.2")
        elf = Path("/opt/R/4.4.2/lib/R/modules/R_X11.so")

        ldd_output = [
            ("libX11.so.6", "/usr/lib64/libX11.so.6"),
            ("libICE.so.6", "/usr/lib64/libICE.so.6"),
            ("libc.so.6", "/lib/x86_64-linux-gnu/libc.so.6"),
        ]

        with mock.patch.object(delocate_r, "ldd", return_value=ldd_output):
            external, elf_needs = delocate_r.discover_external_deps([elf], r_path)

        assert "libX11.so.6" in external
        assert "libICE.so.6" in external
        assert "libc.so.6" not in external

    def test_librblas_excluded_even_outside_r_path(self):
        """libRblas.so must not be bundled even when ldd resolves it to a system
        path outside R_PATH (e.g., via LD_LIBRARY_PATH pointing at the build
        system's libopenblasp). The allowlist is the safety net."""
        r_path = Path("/opt/R/4.4.2")
        elf = Path("/opt/R/4.4.2/lib/R/bin/exec/R")

        ldd_output = [
            # libRblas resolved outside R_PATH — e.g., ldd sees it in /usr/lib64
            ("libRblas.so", "/usr/lib64/libopenblasp.so.0"),
            ("libRlapack.so", "/usr/lib64/libRlapack.so"),
            ("libcurl.so.4", "/usr/lib64/libcurl.so.4"),
        ]

        with mock.patch.object(delocate_r, "ldd", return_value=ldd_output):
            external, elf_needs = delocate_r.discover_external_deps([elf], r_path)

        # libRblas and libRlapack on the allowlist — never bundled
        assert "libRblas.so" not in external
        assert "libRlapack.so" not in external
        # libcurl is not on the allowlist — should be bundled
        assert "libcurl.so.4" in external


# ── graft_libraries ─────────────────────────────────────────────────────────


class TestGraftLibraries:
    """Test library grafting with real files but mocked patchelf."""

    def test_copies_and_renames(self, tmp_path):
        # Create a fake source lib
        src_dir = tmp_path / "system"
        src_dir.mkdir()
        src_lib = src_dir / "libfoo.so.1"
        src_lib.write_bytes(b"fake ELF content for libfoo")

        dest_dir = tmp_path / "libs" / ".libs"
        external_libs = {"libfoo.so.1": str(src_lib)}

        with mock.patch.object(delocate_r, "patchelf"):
            soname_map, soname_path = delocate_r.graft_libraries(external_libs, dest_dir)

        # Check soname_map has the hash-renamed entry
        assert "libfoo.so.1" in soname_map
        new_soname = soname_map["libfoo.so.1"]
        assert new_soname.startswith("libfoo-")
        assert new_soname.endswith(".so.1")
        assert len(new_soname) > len("libfoo-.so.1")  # has hash

        # Check destination file exists
        assert "libfoo.so.1" in soname_path
        assert soname_path["libfoo.so.1"].exists()
        assert soname_path["libfoo.so.1"].name == new_soname

    def test_patchelf_called_correctly(self, tmp_path):
        src_dir = tmp_path / "system"
        src_dir.mkdir()
        src_lib = src_dir / "libbar.so.2"
        src_lib.write_bytes(b"fake ELF for libbar")

        dest_dir = tmp_path / "libs" / ".libs"
        external_libs = {"libbar.so.2": str(src_lib)}

        with mock.patch.object(delocate_r, "patchelf") as mock_patchelf:
            soname_map, _ = delocate_r.graft_libraries(external_libs, dest_dir)

        new_soname = soname_map["libbar.so.2"]
        dest_path = str(dest_dir / new_soname)

        # Should call --set-soname and --set-rpath
        calls = mock_patchelf.call_args_list
        soname_calls = [c for c in calls if c.args[0] == "--set-soname"]
        rpath_calls = [c for c in calls if c.args[0] == "--set-rpath"]

        assert len(soname_calls) == 1
        assert soname_calls[0].args == ("--set-soname", new_soname, dest_path)

        assert len(rpath_calls) == 1
        assert rpath_calls[0].args == ("--set-rpath", "$ORIGIN", dest_path)

    def test_skips_existing(self, tmp_path):
        """If a grafted lib already exists, don't copy or patchelf again."""
        src_dir = tmp_path / "system"
        src_dir.mkdir()
        src_lib = src_dir / "libfoo.so.1"
        src_lib.write_bytes(b"fake ELF content for libfoo")

        dest_dir = tmp_path / "libs" / ".libs"
        dest_dir.mkdir(parents=True)

        # Pre-create the destination file
        shorthash = delocate_r.file_hash(str(src_lib))
        new_soname = delocate_r.hash_rename("libfoo.so.1", shorthash)
        (dest_dir / new_soname).write_bytes(b"already here")

        external_libs = {"libfoo.so.1": str(src_lib)}

        with mock.patch.object(delocate_r, "patchelf") as mock_patchelf:
            delocate_r.graft_libraries(external_libs, dest_dir)

        # patchelf should not be called (lib already exists)
        mock_patchelf.assert_not_called()

    def test_multiple_libs(self, tmp_path):
        src_dir = tmp_path / "system"
        src_dir.mkdir()
        libs = {}
        for name in ["libfoo.so.1", "libbar.so.2", "libbaz.so.3"]:
            p = src_dir / name
            p.write_bytes(f"content for {name}".encode())
            libs[name] = str(p)

        dest_dir = tmp_path / "libs" / ".libs"

        with mock.patch.object(delocate_r, "patchelf"):
            soname_map, soname_path = delocate_r.graft_libraries(libs, dest_dir)

        assert len(soname_map) == 3
        assert len(soname_path) == 3
        for orig in libs:
            assert orig in soname_map
            assert soname_path[orig].exists()

    def test_uses_actual_filename_not_soname(self, tmp_path):
        """When src file has a longer version (libICE.so.6.3.0) than the
        soname (libICE.so.6), the grafted name should use the actual filename."""
        src_dir = tmp_path / "system"
        src_dir.mkdir()
        # Actual system file with full version suffix
        src_lib = src_dir / "libICE.so.6.3.0"
        src_lib.write_bytes(b"fake ELF content for libICE")

        dest_dir = tmp_path / "libs" / ".libs"
        # ldd reports soname "libICE.so.6" -> resolved path ".../libICE.so.6.3.0"
        external_libs = {"libICE.so.6": str(src_lib)}

        with mock.patch.object(delocate_r, "patchelf"):
            soname_map, soname_path = delocate_r.graft_libraries(external_libs, dest_dir)

        new_name = soname_map["libICE.so.6"]
        # Should use full filename, not soname
        assert new_name.endswith(".so.6.3.0"), f"Expected full version suffix, got: {new_name}"
        assert new_name.startswith("libICE-")


# ── fix_inter_library_refs ──────────────────────────────────────────────────


class TestFixInterLibraryRefs:
    def test_replaces_needed(self):
        soname_map = {
            "libtinfo.so.6": "libtinfo-abcd1234.so.6",
            "libreadline.so.7": "libreadline-dead1234.so.7",
        }
        soname_path = {
            "libreadline.so.7": Path("/opt/R/libs/.libs/libreadline-dead1234.so.7"),
        }

        with mock.patch.object(delocate_r, "patchelf_try", return_value="libtinfo.so.6\nlibc.so.6") as mock_try, \
             mock.patch.object(delocate_r, "patchelf") as mock_patchelf:
            delocate_r.fix_inter_library_refs(soname_map, soname_path)

        # Should replace libtinfo.so.6 -> libtinfo-abcd1234.so.6
        mock_patchelf.assert_called_once_with(
            "--replace-needed", "libtinfo.so.6", "libtinfo-abcd1234.so.6",
            str(soname_path["libreadline.so.7"]),
        )

    def test_no_replacements_needed(self):
        soname_map = {"libtinfo.so.6": "libtinfo-abcd1234.so.6"}
        soname_path = {
            "libtinfo.so.6": Path("/opt/R/libs/.libs/libtinfo-abcd1234.so.6"),
        }

        # libtinfo only depends on libc (which is not in soname_map)
        with mock.patch.object(delocate_r, "patchelf_try", return_value="libc.so.6") as mock_try, \
             mock.patch.object(delocate_r, "patchelf") as mock_patchelf:
            delocate_r.fix_inter_library_refs(soname_map, soname_path)

        mock_patchelf.assert_not_called()


# ── verify_repair ────────────────────────────────────────────────────────────


class TestVerifyRepair:
    def test_passes_on_good_state(self, tmp_path):
        dest_dir = tmp_path / "libs" / ".libs"
        dest_dir.mkdir(parents=True)

        # Create fake grafted lib
        grafted = dest_dir / "libfoo-abcd1234.so.1"
        grafted.write_bytes(b"fake")

        soname_map = {"libfoo.so.1": "libfoo-abcd1234.so.1"}
        soname_path = {"libfoo.so.1": grafted}
        r_path = tmp_path

        def fake_patchelf_try(*args):
            if args[0] == "--print-rpath":
                return "$ORIGIN"
            if args[0] == "--print-soname":
                return "libfoo-abcd1234.so.1"
            if args[0] == "--print-needed":
                return "libc.so.6"
            return ""

        mock_ldd_result = subprocess.CompletedProcess(
            args=["ldd"], returncode=0, stdout="\tlibc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007f00)\n", stderr="",
        )

        with mock.patch.object(delocate_r, "patchelf_try", side_effect=fake_patchelf_try), \
             mock.patch("subprocess.run", return_value=mock_ldd_result):
            # Should not raise / sys.exit
            delocate_r.verify_repair(soname_map, soname_path, {}, dest_dir, r_path)

    def test_fails_on_missing_origin_rpath(self, tmp_path):
        dest_dir = tmp_path / "libs" / ".libs"
        dest_dir.mkdir(parents=True)

        grafted = dest_dir / "libfoo-abcd1234.so.1"
        grafted.write_bytes(b"fake")

        soname_map = {"libfoo.so.1": "libfoo-abcd1234.so.1"}
        soname_path = {"libfoo.so.1": grafted}
        r_path = tmp_path

        def fake_patchelf_try(*args):
            if args[0] == "--print-rpath":
                return ""  # Missing $ORIGIN
            if args[0] == "--print-soname":
                return "libfoo-abcd1234.so.1"
            if args[0] == "--print-needed":
                return "libc.so.6"
            return ""

        with mock.patch.object(delocate_r, "patchelf_try", side_effect=fake_patchelf_try), \
             pytest.raises(SystemExit):
            delocate_r.verify_repair(soname_map, soname_path, {}, dest_dir, r_path)

    def test_fails_on_wrong_soname(self, tmp_path):
        dest_dir = tmp_path / "libs" / ".libs"
        dest_dir.mkdir(parents=True)

        grafted = dest_dir / "libfoo-abcd1234.so.1"
        grafted.write_bytes(b"fake")

        soname_map = {"libfoo.so.1": "libfoo-abcd1234.so.1"}
        soname_path = {"libfoo.so.1": grafted}
        r_path = tmp_path

        def fake_patchelf_try(*args):
            if args[0] == "--print-rpath":
                return "$ORIGIN"
            if args[0] == "--print-soname":
                return "libfoo.so.1"  # Wrong — not hash-renamed
            if args[0] == "--print-needed":
                return "libc.so.6"
            return ""

        with mock.patch.object(delocate_r, "patchelf_try", side_effect=fake_patchelf_try), \
             pytest.raises(SystemExit):
            delocate_r.verify_repair(soname_map, soname_path, {}, dest_dir, r_path)

    def test_fails_on_unresolved_needed(self, tmp_path):
        dest_dir = tmp_path / "libs" / ".libs"
        dest_dir.mkdir(parents=True)

        grafted = dest_dir / "libfoo-abcd1234.so.1"
        grafted.write_bytes(b"fake")

        soname_map = {"libfoo.so.1": "libfoo-abcd1234.so.1"}
        soname_path = {"libfoo.so.1": grafted}
        r_path = tmp_path

        def fake_patchelf_try(*args):
            if args[0] == "--print-rpath":
                return "$ORIGIN"
            if args[0] == "--print-soname":
                return "libfoo-abcd1234.so.1"
            if args[0] == "--print-needed":
                # Needs a hash-renamed lib that doesn't exist in dest_dir
                return "libbar-99999999.so.2"
            return ""

        with mock.patch.object(delocate_r, "patchelf_try", side_effect=fake_patchelf_try), \
             pytest.raises(SystemExit):
            delocate_r.verify_repair(soname_map, soname_path, {}, dest_dir, r_path)


# ── discover_elf_files ───────────────────────────────────────────────────────


class TestDiscoverElfFiles:
    def test_finds_so_files(self, tmp_path):
        # Create fake .so file
        so_file = tmp_path / "lib" / "R" / "lib" / "libR.so"
        so_file.parent.mkdir(parents=True)
        so_file.write_bytes(b"fake")

        with mock.patch.object(delocate_r, "is_elf", return_value=True):
            result = delocate_r.discover_elf_files(tmp_path)

        assert so_file in result

    def test_finds_versioned_so(self, tmp_path):
        so_file = tmp_path / "libs" / ".libs" / "libfoo.so.1"
        so_file.parent.mkdir(parents=True)
        so_file.write_bytes(b"fake")

        with mock.patch.object(delocate_r, "is_elf", return_value=True):
            result = delocate_r.discover_elf_files(tmp_path)

        assert so_file in result

    def test_finds_R_binary(self, tmp_path):
        r_bin = tmp_path / "lib" / "R" / "bin" / "exec" / "R"
        r_bin.parent.mkdir(parents=True)
        r_bin.write_bytes(b"fake")

        with mock.patch.object(delocate_r, "is_elf", return_value=True):
            result = delocate_r.discover_elf_files(tmp_path)

        assert r_bin in result

    def test_skips_non_elf(self, tmp_path):
        txt_file = tmp_path / "README"
        txt_file.write_text("not ELF")
        so_file = tmp_path / "lib.so"
        so_file.write_bytes(b"fake")

        with mock.patch.object(delocate_r, "is_elf", side_effect=lambda p: p.suffix == ".so"):
            result = delocate_r.discover_elf_files(tmp_path)

        assert so_file in result
        assert txt_file not in result

    def test_skips_directories(self, tmp_path):
        d = tmp_path / "something.so"
        d.mkdir()  # directory, not a file

        with mock.patch.object(delocate_r, "is_elf", return_value=True):
            result = delocate_r.discover_elf_files(tmp_path)

        assert len(result) == 0


# ── patch_elf_binaries (RPATH computation) ──────────────────────────────────


class TestPatchElfBinaries:
    def test_rpath_computation(self, tmp_path):
        """Verify the RPATH is correctly computed for different ELF locations."""
        r_path = tmp_path
        dest_dir = tmp_path / "libs" / ".libs"
        dest_dir.mkdir(parents=True)

        # Create fake ELF at lib/R/lib/libR.so
        elf = tmp_path / "lib" / "R" / "lib" / "libR.so"
        elf.parent.mkdir(parents=True)
        elf.write_bytes(b"fake")

        elf_needs = {elf: ["libfoo.so.1"]}
        soname_map = {"libfoo.so.1": "libfoo-abcd1234.so.1"}

        calls = []

        def capture_patchelf_try(*args):
            calls.append(args)
            if args[0] == "--print-rpath":
                return ""
            return ""

        mock_run = mock.MagicMock(return_value=subprocess.CompletedProcess(
            args=["patchelf"], returncode=0, stdout="", stderr="",
        ))

        with mock.patch.object(delocate_r, "patchelf_try", side_effect=capture_patchelf_try), \
             mock.patch("subprocess.run", mock_run):
            delocate_r.patch_elf_binaries(elf_needs, soname_map, dest_dir, r_path)

        # Check the --set-rpath call
        rpath_calls = [c for c in mock_run.call_args_list
                       if c.args[0][1] == "--set-rpath"]
        assert len(rpath_calls) == 1
        rpath_value = rpath_calls[0].args[0][2]
        assert rpath_value == "$ORIGIN/../../../libs/.libs"
