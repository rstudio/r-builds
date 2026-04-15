"""Unit tests for generate_sbom.py."""

import importlib.util
import json
from pathlib import Path
from unittest import mock

import pytest

# Import the module under test.
spec = importlib.util.spec_from_file_location(
    "generate_sbom",
    Path(__file__).parent / "generate_sbom.py",
)
generate_sbom = importlib.util.module_from_spec(spec)
spec.loader.exec_module(generate_sbom)


# ── Helpers ──────────────────────────────────────────────────────────────────


def make_manifest(tmp_path: Path) -> Path:
    """Create a fake delocate manifest and the system files it references."""
    libs_dir = tmp_path / "lib" / "R" / "lib" / ".libs"
    libs_dir.mkdir(parents=True)

    # Create fake system library files that the manifest points to
    sys_lib_dir = tmp_path / "fake_sys_libs"
    sys_lib_dir.mkdir()
    (sys_lib_dir / "libfoo.so.1.2.3").write_bytes(b"fake")
    (sys_lib_dir / "libbar.so.2.0.0").write_bytes(b"fake")

    manifest = {
        "libfoo-abcd1234.so.1.2.3": str(sys_lib_dir / "libfoo.so.1.2.3"),
        "libbar-ef567890.so.2.0.0": str(sys_lib_dir / "libbar.so.2.0.0"),
    }
    manifest_path = libs_dir / "delocate-manifest.json"
    manifest_path.write_text(json.dumps(manifest))
    return tmp_path


def run_generate_sbom(r_path: Path, pkg_results: dict) -> dict:
    """Run generate_sbom.main() with mocked system calls and return the SBOM."""

    def mock_query_rpm(sys_path: str):
        basename = Path(sys_path).name
        return pkg_results.get(basename)

    with (
        mock.patch.object(generate_sbom, "detect_pkg_manager", return_value="rpm"),
        mock.patch.object(generate_sbom, "detect_base_image", return_value="Rocky Linux release 9.5"),
        mock.patch.object(generate_sbom, "query_rpm", side_effect=mock_query_rpm),
        mock.patch("sys.argv", ["generate_sbom.py", str(r_path), "4.5.0", "manylinux_2_34"]),
    ):
        generate_sbom.main()

    sbom_path = r_path / "lib" / "R" / "sbom.cdx.json"
    return json.loads(sbom_path.read_text())


# ── SBOM structure tests ────────────────────────────────────────────────────


class TestSBOMStructure:
    """Tests for the generated SBOM structure."""

    @pytest.fixture
    def sbom(self, tmp_path):
        r_path = make_manifest(tmp_path)
        pkg_results = {
            "libfoo.so.1.2.3": ("foo-libs", "1.2.3-1.el9", "x86_64"),
            "libbar.so.2.0.0": ("bar", "2.0.0-3.el9", "x86_64"),
        }
        return run_generate_sbom(r_path, pkg_results)

    def test_bom_format(self, sbom):
        assert sbom["bomFormat"] == "CycloneDX"

    def test_spec_version(self, sbom):
        assert sbom["specVersion"] == "1.5"

    def test_serial_number_is_urn_uuid(self, sbom):
        assert sbom["serialNumber"].startswith("urn:uuid:")

    def test_version(self, sbom):
        assert sbom["version"] == 1

    def test_metadata_component(self, sbom):
        comp = sbom["metadata"]["component"]
        assert comp["type"] == "application"
        assert comp["name"] == "Posit R"
        assert comp["version"] == "4.5.0"
        assert "manylinux_2_34" in comp["description"]

    def test_metadata_properties(self, sbom):
        props = {p["name"]: p["value"] for p in sbom["metadata"]["properties"]}
        assert props["posit:os-identifier"] == "manylinux_2_34"
        assert props["posit:base-image"] == "Rocky Linux release 9.5"

    def test_metadata_timestamp(self, sbom):
        ts = sbom["metadata"]["timestamp"]
        # Should be ISO 8601 format: YYYY-MM-DDTHH:MM:SSZ
        assert ts.endswith("Z")
        assert "T" in ts

    def test_components_count(self, sbom):
        assert len(sbom["components"]) == 2

    def test_component_fields(self, sbom):
        for comp in sbom["components"]:
            assert comp["type"] == "library"
            assert "name" in comp
            assert "version" in comp
            assert "purl" in comp

    def test_component_purl_format(self, sbom):
        for comp in sbom["components"]:
            assert comp["purl"].startswith("pkg:rpm/")

    def test_component_bundled_files(self, sbom):
        """Each component should list bundled files in properties."""
        for comp in sbom["components"]:
            props = {p["name"]: p["value"] for p in comp["properties"]}
            assert "posit:bundled-files" in props
            assert len(props["posit:bundled-files"]) > 0

    def test_components_sorted_by_name(self, sbom):
        names = [c["name"] for c in sbom["components"]]
        assert names == sorted(names)


class TestSBOMDeduplication:
    """Multiple bundled files from the same package should be grouped."""

    def test_same_package_grouped(self, tmp_path):
        r_path = make_manifest(tmp_path)
        # Both files owned by the same package
        pkg_results = {
            "libfoo.so.1.2.3": ("same-pkg", "1.0-1.el9", "x86_64"),
            "libbar.so.2.0.0": ("same-pkg", "1.0-1.el9", "x86_64"),
        }
        sbom = run_generate_sbom(r_path, pkg_results)
        assert len(sbom["components"]) == 1
        props = {p["name"]: p["value"] for p in sbom["components"][0]["properties"]}
        files = props["posit:bundled-files"].split(", ")
        assert len(files) == 2


class TestSBOMUnknownPaths:
    """Files with unknown system paths should be skipped."""

    def test_unknown_paths_skipped(self, tmp_path):
        libs_dir = tmp_path / "lib" / "R" / "lib" / ".libs"
        libs_dir.mkdir(parents=True)
        manifest = {"libmissing-12345678.so.1": "unknown"}
        (libs_dir / "delocate-manifest.json").write_text(json.dumps(manifest))

        with (
            mock.patch.object(generate_sbom, "detect_pkg_manager", return_value="rpm"),
            mock.patch.object(generate_sbom, "detect_base_image", return_value="test"),
            mock.patch("sys.argv", ["generate_sbom.py", str(tmp_path), "4.5.0", "test"]),
        ):
            generate_sbom.main()

        sbom = json.loads((tmp_path / "lib" / "R" / "sbom.cdx.json").read_text())
        assert len(sbom["components"]) == 0


# ── CycloneDX schema validation ─────────────────────────────────────────────


class TestCycloneDXSchema:
    """Validate the generated SBOM against the CycloneDX 1.5 JSON Schema."""

    SCHEMA_URL = "https://raw.githubusercontent.com/CycloneDX/specification/1.5/schema/bom-1.5.schema.json"

    @pytest.fixture
    def sbom(self, tmp_path):
        r_path = make_manifest(tmp_path)
        pkg_results = {
            "libfoo.so.1.2.3": ("foo-libs", "1.2.3-1.el9", "x86_64"),
            "libbar.so.2.0.0": ("bar", "2.0.0-3.el9", "x86_64"),
        }
        return run_generate_sbom(r_path, pkg_results)

    @pytest.fixture
    def schema(self):
        jsonschema = pytest.importorskip("jsonschema")
        try:
            import urllib.request
            with urllib.request.urlopen(self.SCHEMA_URL, timeout=10) as resp:
                return json.loads(resp.read())
        except Exception:
            pytest.skip("Could not fetch CycloneDX schema")

    def test_validates_against_schema(self, sbom, schema):
        import jsonschema
        jsonschema.validate(instance=sbom, schema=schema)

    def test_empty_components_validates(self, tmp_path, schema):
        """An SBOM with zero components should still be valid."""
        libs_dir = tmp_path / "lib" / "R" / "lib" / ".libs"
        libs_dir.mkdir(parents=True)
        manifest = {"libgone-12345678.so": "unknown"}
        (libs_dir / "delocate-manifest.json").write_text(json.dumps(manifest))

        with (
            mock.patch.object(generate_sbom, "detect_pkg_manager", return_value="rpm"),
            mock.patch.object(generate_sbom, "detect_base_image", return_value="test"),
            mock.patch("sys.argv", ["generate_sbom.py", str(tmp_path), "4.5.0", "test"]),
        ):
            generate_sbom.main()

        sbom = json.loads((tmp_path / "lib" / "R" / "sbom.cdx.json").read_text())
        import jsonschema
        jsonschema.validate(instance=sbom, schema=schema)


# ── APK package parsing ─────────────────────────────────────────────────────


class TestQueryAPKParsing:
    """Test APK package name-version parsing."""

    @pytest.mark.parametrize("pkg_full,expected", [
        ("foo-1.2.3-r0", ("foo", "1.2.3-r0")),
        ("lib-with-hyphens-2.0.1-r5", ("lib-with-hyphens", "2.0.1-r5")),
        ("simple-0.1-r0", ("simple", "0.1-r0")),
    ])
    def test_apk_name_version_split(self, pkg_full, expected):
        import re
        m = re.match(r"^(.+?)-(\d[^-]*(?:-r\d+)?)$", pkg_full)
        assert m is not None
        assert (m.group(1), m.group(2)) == expected


# ── purl format ──────────────────────────────────────────────────────────────


class TestPurlFormat:
    """Test package URL generation."""

    def test_purl_for_rpm(self):
        with mock.patch("builtins.open", mock.mock_open(read_data='ID="rocky"\n')):
            purl = generate_sbom.purl_for_rpm("openssl-libs", "3.0.7-1.el9", "x86_64")
        assert purl == "pkg:rpm/rocky/openssl-libs@3.0.7-1.el9?arch=x86_64"

    def test_purl_for_apk(self):
        with mock.patch("platform.machine", return_value="x86_64"):
            purl = generate_sbom.purl_for_apk("openssl", "3.3.0-r0")
        assert purl == "pkg:apk/alpine/openssl@3.3.0-r0?arch=x86_64"
