from pathlib import Path

import pytest

lupa = pytest.importorskip("lupa")
from lupa import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "@Resources" / "BlackSharkBattery.lua"
FIXTURES = ROOT / "tests" / "fixtures"


@pytest.fixture()
def lua():
    runtime = LuaRuntime(unpack_returned_tuples=True)
    runtime.execute(SCRIPT.read_text(encoding="utf-8"))
    runtime.globals().settings = runtime.table_from(
        {
            "devicePattern": "blackshark v2 pro",
            "tailBytes": 524288,
            "lifecycleTailBytes": 32768,
            "logSource": "synapse4",
            "logFileIsConfigured": True,
            "synapse4ChargingInferenceHours": 12,
            "disconnectDebounceSeconds": 15,
            "manufacturerBatteryLifeHours": 70,
        }
    )
    return runtime


def lua_files(lua, *paths):
    return lua.table_from([str(path) for path in paths])


def test_synapse3_parser_selects_latest_matching_device(lua):
    reading = lua.globals().ReadLatestBatteryV3(
        str(FIXTURES / "synapse3.log"), "blackshark v2 pro", 524288
    )
    assert reading.percent == 72
    assert reading.batteryState == "NotCharging"


def test_synapse4_parser_uses_bounded_tail_and_latest_snapshot(lua, tmp_path):
    log = tmp_path / "systray_systrayv2.log"
    prefix = ("unrelated log data\n" * 100_000).encode()
    fixture = (FIXTURES / "synapse4_connected.log").read_bytes()
    log.write_bytes(prefix + fixture)

    reading = lua.globals().ReadLatestBatteryV4(
        str(log), "blackshark v2 pro", len(fixture) + 128
    )
    assert reading.percent == 64
    assert reading.batteryState == "NotCharging"


def test_synapse4_lifecycle_does_not_recover_disconnect_as_connected(lua):
    path = FIXTURES / "synapse4_disconnected.log"
    settings = lua.globals().settings
    settings.synapse4Files = lua_files(lua, path)
    settings.logFile = str(path)

    event = lua.globals().ReadLatestLifecycleEventV4(
        str(path), "blackshark v2 pro", 32768
    )
    assert event.status == "disconnected"


def test_configured_synapse4_file_wins_over_cached_auto_detected_files(lua):
    configured = FIXTURES / "synapse4_connected.log"
    settings = lua.globals().settings
    settings.logFile = str(configured)
    settings.synapse4Files = lua_files(lua, configured)

    files = lua.globals().GetSynapse4ReadFiles(str(configured))
    assert len(files) == 1
    assert files[1] == str(configured)


def test_latest_synapse4_file_is_selected_by_log_timestamp(lua, tmp_path):
    folder = str(tmp_path) + "\\"
    older = tmp_path / "systray_systrayv21.log"
    newer = tmp_path / "systray_systrayv2.log"
    older.write_text(
        "[2026-07-13T10:00:00.000Z] connectingDeviceData: []\n", encoding="utf-8"
    )
    newer.write_text(
        "[2026-07-14T10:00:00.000Z] connectingDeviceData: []\n", encoding="utf-8"
    )

    assert lua.globals().FindLatestSynapse4LogFile(folder) == str(newer)


def test_auto_detected_path_does_not_become_a_user_override(monkeypatch, tmp_path):
    monkeypatch.setenv("LOCALAPPDATA", str(tmp_path))
    log_folder = tmp_path / "Razer" / "RazerAppEngine" / "User Data" / "Logs"
    log_folder.mkdir(parents=True)
    active = log_folder / "systray_systrayv2.log"
    rotated = log_folder / "systray_systrayv21.log"
    active.write_bytes((FIXTURES / "synapse4_connected.log").read_bytes())
    rotated.write_text(
        "[2026-07-13T10:00:00.000Z] connectingDeviceData: []\n", encoding="utf-8"
    )

    runtime = LuaRuntime(unpack_returned_tuples=True)
    runtime.execute(
        """
        SKIN = { vars = { FillMaxW = "22" } }
        function SKIN:GetVariable(name, fallback) return self.vars[name] or fallback end
        function SKIN:ParseFormula(value) return tonumber(value) or 22 end
        function SKIN:Bang(command, name, value)
            if command == "!SetVariable" then self.vars[name] = tostring(value or "") end
        end
        """
    )
    runtime.execute(SCRIPT.read_text(encoding="utf-8"))

    runtime.globals().RefreshSettings()
    runtime.globals().RefreshSettings()
    settings = runtime.globals().settings
    assert settings.logFileIsConfigured is False
    assert len(settings.synapse4Files) == 2
    assert Path(settings.logFile).name == active.name


def test_manufacturer_baseline_and_local_confidence_progression(lua):
    baseline = lua.globals().GetBaselineEstimate(lua.table_from({"percent": 50}))
    assert baseline.hours == pytest.approx(35)
    assert baseline.localWeight == 0

    sparse = lua.table_from(
        {"rate": 2.0, "totalDrop": 2, "totalHours": 1, "sessionCount": 1}
    )
    mature = lua.table_from(
        {"rate": 2.0, "totalDrop": 20, "totalHours": 20, "sessionCount": 6}
    )
    sparse_estimate = lua.globals().CombineRateEstimate(sparse, None, None)
    mature_estimate = lua.globals().CombineRateEstimate(mature, None, None)

    assert 0 < sparse_estimate.confidence < 1
    assert mature_estimate.confidence == pytest.approx(1)
    assert sparse_estimate.confidence < mature_estimate.confidence


def test_repeated_off_snapshots_do_not_keep_extending_debounce(lua):
    lua.execute(
        """
        TEST_NOW = 100
        local real_os_time = os.time
        os.time = function(value)
            if value then return real_os_time(value) end
            return TEST_NOW
        end
        SKIN = { vars = {} }
        function SKIN:Bang(command, name, value)
            if command == "!SetVariable" then self.vars[name] = tostring(value or "") end
        end
        """
    )
    settings = lua.globals().settings
    settings.devMode = False
    settings.lifecyclePollSeconds = 5
    settings.fillMaxWidth = 22
    settings.staleMinutes = 180
    settings.redThreshold = 10
    settings.orangeThreshold = 20
    settings.yellowThreshold = 30
    settings.logFile = ""
    settings.logSource = "synapse4"

    first = lua.table_from(
        {
            "timestamp": 100,
            "timestampText": "first off",
            "percent": 70,
            "batteryState": "Off",
        }
    )
    repeated = lua.table_from(
        {
            "timestamp": 110,
            "timestampText": "repeated off",
            "percent": 70,
            "batteryState": "Off",
        }
    )
    lua.globals().SKIN.vars.BatteryStatus = "Not charging"
    assert lua.globals().QueuePendingLifecycleReading(first) is True
    assert lua.globals().SKIN.vars.BatteryStatus == "Not charging"

    lua.globals().TEST_NOW = 110
    assert lua.globals().QueuePendingLifecycleReading(repeated) is True
    lua.globals().TEST_NOW = 115
    lua.globals().CheckQuickLifecycle(115)
    assert lua.globals().SKIN.vars.BatteryStatus == "Headset off"
