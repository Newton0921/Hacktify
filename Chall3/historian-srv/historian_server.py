#!/usr/bin/env python3
"""
OPC UA Historian Server — Prabal Urja Pvt Ltd
Builds a deep namespace tree with decoy telemetry and one privileged node.
All configuration sourced from environment variables.
"""
import asyncio
import os
import sys
import random
import hashlib
import time

from asyncua import Server, ua

# ---------------------------------------------------------------------------
# Configuration from environment
# ---------------------------------------------------------------------------
TAG_PREFIX      = os.environ["TAG_NAMESPACE_PREFIX"]
ASDU_ADDR_DESC  = os.environ["ASDU_ADDR_DESC"]
HISTORIAN_IP    = os.environ.get("HISTORIAN_IP", "0.0.0.0")
INSTANCE_SEED   = os.environ["INSTANCE_SEED"]

# Seed the PRNG deterministically so the tree is consistent per instance
random.seed(INSTANCE_SEED)

# ---------------------------------------------------------------------------
# Internal constants — NOT player-facing
# ---------------------------------------------------------------------------
# Control-oriented substrings placed at varying depths (implementation detail)
_CTRL_SUBS = [
    "RemoteAddr", "ProtocolCfg", "CommLink", "AsduConfig",
    "TelecontrolRef", "StationParam", "LinkAddr", "FieldUnit",
    "RemoteTerminal", "CtrlEndpoint", "ctlSelOn", "stVal",
    "stNum", "ctlVal",
]

# Telemetry/decoy substrings for bulk noise
_TELEM_SUBS = [
    "Voltage_kV", "Current_A", "Power_MW", "ReactivePower_MVAR",
    "Frequency_Hz", "Temperature_C", "Pressure_kPa", "FlowRate_m3h",
    "BusbarVoltage", "TransformerTap", "CircuitBreakerSts", "DisconnectorSts",
    "LoadProfile", "EnergyAccum_kWh", "PowerFactor", "HarmonicDistortion",
    "CoolingFanSts", "OilLevel_pct", "AmbientTemp_C", "WindSpeed_ms",
    "SolarIrradiance", "BatterySOC_pct", "InverterOutput_kW", "TurbineRPM",
    "GeneratorMW", "SteamPressure_bar", "FuelConsumption_Lh",
    "ExhaustTemp_C", "StackEmission_ppm", "WaterLevel_m",
    "PumpFlowRate", "ValvePosition_pct", "CompressorSts", "FilterDiffP_kPa",
    "MotorCurrent_A", "MotorTemp_C", "BearingVibration_mms",
    "CapacitorBank_MVAR", "ReactorBank_MVAR", "GroundFaultCurrent_mA",
    "SurgeArresterCnt", "BushingTemp_C", "InsulationResistance_MOhm",
    "TapChangerPos", "GasAnalysis_ppm", "MoistureContent_ppm",
    "DGA_H2_ppm", "DGA_CH4_ppm", "DGA_C2H2_ppm", "DGA_CO_ppm",
    "PartialDischarge_pC", "ContactWear_pct", "OperationCounter",
    "TripCoilCurrent_A", "ClosingTime_ms", "OpeningTime_ms",
    "SpringChargeSts", "GasPressure_bar", "SF6_Density_kgm3",
]

# Bay/feeder names for tree branching
_BAY_NAMES = [
    "Bay01_Feeder", "Bay02_Transformer", "Bay03_BusCoupler",
    "Bay04_LineProtection", "Bay05_CapBank", "Bay06_Auxiliary",
    "Bay07_Generator", "Bay08_MotorControl", "Bay09_BusTie",
    "Bay10_ReactorBank", "Bay11_SolarInverter", "Bay12_BESS",
]

# Sub-equipment groupings for deeper levels
_EQUIPMENT_GROUPS = [
    "Protection", "Measurement", "Control", "Monitoring",
    "Communication", "Diagnostics", "Maintenance", "HistoricalLog",
]


async def build_namespace(server: Server) -> None:
    """
    Build a 4-6 level deep namespace tree.
    Structure:
        ns:TAG_PREFIX/Substation
          └─ Bay/
             └─ <bay_name>/
                └─ <equipment_group>/
                   └─ <tag_node>          (depth 4-5 for decoys)
                   └─ <sub_folder>/
                      └─ <tag_node>       (depth 5-6 for some tags)

    One privileged node carries Description = ASDU_ADDR_DESC and is placed
    at a realistic depth (5-6 levels) within a control-oriented branch.
    """
    ns_uri = f"urn:prabalurja:{TAG_PREFIX}:historian"
    idx = await server.register_namespace(ns_uri)

    # Root: <TAG_PREFIX>
    root_obj = server.get_objects_node()
    prefix_node = await root_obj.add_folder(idx, TAG_PREFIX)

    # Level 1: Substation
    substation = await prefix_node.add_folder(idx, "Substation")

    # Level 2: Bay
    bay_root = await substation.add_folder(idx, "Bay")

    privileged_placed = False
    # Choose a random bay and group for the privileged node
    priv_bay_idx = random.randint(0, len(_BAY_NAMES) - 1)
    priv_grp_idx = random.randint(0, len(_EQUIPMENT_GROUPS) - 1)
    # Ensure it lands in a "Communication" or "Control" style group for realism
    while _EQUIPMENT_GROUPS[priv_grp_idx] not in ("Communication", "Control", "Monitoring"):
        priv_grp_idx = random.randint(0, len(_EQUIPMENT_GROUPS) - 1)

    for bay_i, bay_name in enumerate(_BAY_NAMES):
        bay_node = await bay_root.add_folder(idx, bay_name)

        for grp_i, grp_name in enumerate(_EQUIPMENT_GROUPS):
            grp_node = await bay_node.add_folder(idx, grp_name)

            # Decide how many tags in this group (5-15 for telemetry)
            num_tags = random.randint(5, 15)
            tag_pool = random.sample(
                _TELEM_SUBS, min(num_tags, len(_TELEM_SUBS))
            )

            # Some groups get control-oriented tags mixed in (depth 4)
            if grp_name in ("Control", "Communication", "Monitoring"):
                ctrl_count = random.randint(1, 3)
                ctrl_tags = random.sample(_CTRL_SUBS, ctrl_count)
                tag_pool.extend(ctrl_tags)

            for tag_name in tag_pool:
                qualified = f"{bay_name}_{grp_name}_{tag_name}"
                var = await grp_node.add_variable(
                    idx, qualified,
                    ua.Variant(round(random.uniform(0, 500), 2), ua.VariantType.Double)
                )
                await var.set_writable(False)
                # Set a generic description for decoy nodes
                desc = ua.LocalizedText(f"Telemetry point: {qualified}")
                await var.write_attribute(
                    ua.AttributeIds.Description,
                    ua.DataValue(ua.Variant(desc, ua.VariantType.LocalizedText))
                )

            # Add deeper sub-folders for some groups (depth 5-6)
            if grp_name in ("Communication", "Control", "Diagnostics", "HistoricalLog"):
                sub_folders = ["Archive", "Config", "Runtime", "Parameters"]
                chosen_subs = random.sample(sub_folders, random.randint(1, 3))

                for sub_name in chosen_subs:
                    sub_node = await grp_node.add_folder(idx, sub_name)

                    # Add tags at depth 5
                    deep_count = random.randint(3, 8)
                    deep_tags = random.sample(
                        _TELEM_SUBS + _CTRL_SUBS,
                        min(deep_count, len(_TELEM_SUBS) + len(_CTRL_SUBS))
                    )

                    for dtag in deep_tags:
                        dqualified = f"{bay_name}_{sub_name}_{dtag}"
                        dvar = await sub_node.add_variable(
                            idx, dqualified,
                            ua.Variant(round(random.uniform(0, 1000), 3), ua.VariantType.Double)
                        )
                        await dvar.set_writable(False)
                        ddesc = ua.LocalizedText(f"Deep record: {dqualified}")
                        await dvar.write_attribute(
                            ua.AttributeIds.Description,
                            ua.DataValue(ua.Variant(ddesc, ua.VariantType.LocalizedText))
                        )

                    # === PRIVILEGED NODE PLACEMENT ===
                    # Place at depth 6 inside a nested sub-folder for non-obviousness
                    if (bay_i == priv_bay_idx and grp_i == priv_grp_idx
                            and sub_name == "Config" and not privileged_placed):
                        # One more level deep
                        inner_node = await sub_node.add_folder(idx, "DeviceRegistry")
                        priv_tag_name = f"{bay_name}_DeviceRegistry_RemoteUnit"
                        priv_var = await inner_node.add_variable(
                            idx, priv_tag_name,
                            ua.Variant(float(ASDU_ADDR_DESC), ua.VariantType.Double)
                        )
                        await priv_var.set_writable(False)
                        # Set Description to ASDU_ADDR_DESC VERBATIM
                        priv_desc = ua.LocalizedText(ASDU_ADDR_DESC)
                        await priv_var.write_attribute(
                            ua.AttributeIds.Description,
                            ua.DataValue(ua.Variant(priv_desc, ua.VariantType.LocalizedText))
                        )
                        privileged_placed = True
                        print(f"[SETUP] Privileged node placed: {priv_tag_name} "
                              f"(Description={ASDU_ADDR_DESC})", flush=True)

    # Fallback: if the random path didn't include "Config", place it now
    if not privileged_placed:
        fb_bay = await bay_root.get_children()
        fb_bay_node = fb_bay[priv_bay_idx % len(fb_bay)]
        fb_grps = await fb_bay_node.get_children()
        fb_grp_node = fb_grps[priv_grp_idx % len(fb_grps)]
        fb_config = await fb_grp_node.add_folder(idx, "Config")
        fb_inner = await fb_config.add_folder(idx, "DeviceRegistry")
        fb_name = f"FallbackUnit_DeviceRegistry_RemoteUnit"
        fb_var = await fb_inner.add_variable(
            idx, fb_name,
            ua.Variant(float(ASDU_ADDR_DESC), ua.VariantType.Double)
        )
        await fb_var.set_writable(False)
        fb_desc = ua.LocalizedText(ASDU_ADDR_DESC)
        await fb_var.write_attribute(
            ua.AttributeIds.Description,
            ua.DataValue(ua.Variant(fb_desc, ua.VariantType.LocalizedText))
        )
        print(f"[SETUP] Privileged node placed (fallback): {fb_name} "
              f"(Description={ASDU_ADDR_DESC})", flush=True)

    total_count = 0
    for bay_n in await bay_root.get_children():
        for grp_n in await bay_n.get_children():
            children = await grp_n.get_children()
            total_count += len(children)
            for child in children:
                sub_children = await child.get_children()
                total_count += len(sub_children)
                for sc in sub_children:
                    total_count += len(await sc.get_children())

    print(f"[SETUP] Namespace tree built: ~{total_count} nodes under "
          f"{TAG_PREFIX}/Substation/Bay/", flush=True)


async def main():
    server = Server()
    await server.init()

    server.set_endpoint(f"opc.tcp://0.0.0.0:4840/prabalurja/historian")
    server.set_server_name("Prabal Urja Historian Service")

    # Security: anonymous access (lab environment)
    server.set_security_policy([ua.SecurityPolicyType.NoSecurity])

    await build_namespace(server)

    # Write flag file
    os.makedirs("/run/ctf", exist_ok=True)
    flag_msg = f"STAGE3:{ASDU_ADDR_DESC}"
    import hmac as _hmac
    flag_hex = _hmac.new(
        bytes.fromhex(INSTANCE_SEED),
        flag_msg.encode(),
        hashlib.sha256
    ).hexdigest()[:16]
    stage_flag = f"FLAG{{S3-{flag_hex}}}"
    with open("/run/ctf/stage3_flag", "w") as fh:
        fh.write(stage_flag)
    os.chmod("/run/ctf/stage3_flag", 0o644)
    print(f"[SETUP] Stage 3 flag written to /run/ctf/stage3_flag", flush=True)

    print(f"[SETUP] OPC UA server starting on opc.tcp://0.0.0.0:4840/", flush=True)
    async with server:
        while True:
            await asyncio.sleep(1)


if __name__ == "__main__":
    asyncio.run(main())
