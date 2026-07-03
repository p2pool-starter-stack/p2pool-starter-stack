import io
from types import SimpleNamespace
from unittest.mock import patch

import mining_dashboard.collector.system as system


def _fake_open(content):
    """Return an open() replacement yielding `content` as a context-managed file."""
    return lambda *a, **k: io.StringIO(content)


class TestDiskUsage:
    def test_normal(self):
        usage = SimpleNamespace(
            total=100 * system.BYTES_IN_GB, used=25 * system.BYTES_IN_GB, free=0
        )
        with patch.object(system.shutil, "disk_usage", return_value=usage):
            d = system.get_disk_usage()
        assert d["total_gb"] == 100
        assert d["used_gb"] == 25
        assert d["percent_str"] == "25.0%"

    def test_error_returns_zeros(self):
        with patch.object(system.shutil, "disk_usage", side_effect=OSError):
            assert system.get_disk_usage()["percent_str"] == "0%"


class TestMemoryUsage:
    def test_parses_meminfo(self):
        meminfo = "MemTotal: 1048576 kB\nMemAvailable: 524288 kB\n"  # 1 GiB total, 0.5 free
        with patch("builtins.open", _fake_open(meminfo)):
            m = system.get_memory_usage()
        assert m["percent_str"] == "50.0%"

    def test_error_returns_zeros(self):
        with patch("builtins.open", side_effect=OSError):
            assert system.get_memory_usage()["percent_str"] == "0%"


class TestLoadAverage:
    def test_formats(self):
        with patch.object(system.os, "getloadavg", return_value=(1.0, 2.0, 3.0)):
            assert system.get_load_average() == "1.00 2.00 3.00"

    def test_error(self):
        with patch.object(system.os, "getloadavg", side_effect=OSError):
            assert system.get_load_average() == "0.00 0.00 0.00"


class TestCpuUsage:
    def test_delta_calculation(self):
        system._last_cpu_times = None
        # first sample seeds state -> 0.0% (total=100, idle=100)
        with patch("builtins.open", _fake_open("cpu 0 0 0 100 0 0 0 0\n")):
            assert system.get_cpu_usage() == "0.0%"
        # second sample: delta_total=400, delta_idle=200 -> 50% busy
        with patch("builtins.open", _fake_open("cpu 100 0 100 300 0 0 0 0\n")):
            assert system.get_cpu_usage() == "50.0%"

    def test_malformed_line(self):
        with patch("builtins.open", _fake_open("cpu 1 2\n")):
            assert system.get_cpu_usage() == "0.0%"


class TestHugepages:
    def test_enabled_when_used(self):
        with patch("builtins.open", _fake_open("HugePages_Total: 3072\nHugePages_Free: 1500\n")):
            label, css, val = system.get_hugepages_status()
        assert label == "Enabled"
        assert val == "1572 / 3072"

    def test_allocated_when_unused(self):
        with patch("builtins.open", _fake_open("HugePages_Total: 3072\nHugePages_Free: 3072\n")):
            label, css, _ = system.get_hugepages_status()
        # Reserved but not yet consumed (boot / sync-hold) is the normal state — green, not red (#175).
        assert (label, css) == ("Allocated", "status-ok")

    def test_unknown_when_missing(self):
        with patch("builtins.open", _fake_open("SomethingElse: 1\n")):
            assert system.get_hugepages_status() == ("Unknown", "status-warn", "0/0")


class TestCpuAvx2:
    def setup_method(self):
        system._avx2_supported = None  # clear the process-lifetime cache between cases

    def test_flag_present(self):
        cpuinfo = "processor\t: 0\nflags\t\t: fpu vme avx avx2 sse4_2\n"
        with patch("builtins.open", _fake_open(cpuinfo)):
            assert system.get_cpu_avx2() is True

    def test_flag_absent(self):
        cpuinfo = "processor\t: 0\nflags\t\t: fpu vme avx sse4_2\n"  # avx but not avx2
        with patch("builtins.open", _fake_open(cpuinfo)):
            assert system.get_cpu_avx2() is False

    def test_unreadable_is_unknown(self):
        with patch("builtins.open", side_effect=OSError):
            assert system.get_cpu_avx2() is None

    def test_result_is_cached(self):
        cpuinfo = "flags\t\t: avx2\n"
        with patch("builtins.open", _fake_open(cpuinfo)):
            assert system.get_cpu_avx2() is True
        # Second call must not re-read (open would now raise) — the cached value stands.
        with patch("builtins.open", side_effect=AssertionError("should not re-read")):
            assert system.get_cpu_avx2() is True
