# L850GL-Xmodem

A specialized fork of [QModem](https://github.com/FUjr/QModem) trimmed to support **only the Fibocom L850-GL (Intel XMM7360)** modem, in **NCM** and **MBIM** modes, with integrated **eSIM (lpac)** management.

All logic, files and packages for other modems have been removed; the shared XModem framework (dial / scan / LuCI `luci-app-xmodem-next`) is kept intact.

## Highlights

- **L850-GL NCM dial** — `AT+XDATACHANNEL` / `M-RAW_IP` with static IP from `AT+CGCONTRDP` (`arp off`).
- **L850-GL MBIM dial (ModemManager-grade)** — driven by **`mbimcli` via `mbim-proxy`** (libmbim). The dialer mirrors ModemManager's flow: wait device-ready → radio on → wait SIM-ready + registered + packet-attached → connect → verify activated. It then runs a tight monitor with **seamless in-place re-IP (0-loss)** and a **self-healing recovery ladder** (mbimcli disconnect → `AT+CFUN=1,1` → USB re-enumerate) so a dropped/wedged modem recovers automatically.
- **quectel-CM is NOT used / removed** — the XMM firmware's MBIM data plane is incompatible with quectel-CM (even with control-plane patches, no data flows). Full analysis: [`docs/L850-quectel-cm-investigation.md`](docs/L850-quectel-cm-investigation.md).
- **eSIM (removable eUICC)** — patched **lpac** (MBIM backend) + **luci-app-lpac** UI (integrated under *Modem → XModem → eSIM*) + **Telegram bot** (`xmodem_esim_bot`). Profile switching coordinates with the dialer (stop → eUICC refresh → wait SIM → re-dial).
- **Coexistence (ModemManager-style)** — `mbim-proxy` (libmbim) is auto-spawned on demand and shared, so dialing (`mbimcli -p`) and lpac use the same MBIM session on `/dev/cdc-wdm0` without dropping the internet connection.
- **ipq40xx USB re-detect watchdog** — `xmodem-usb-redetect` rebinds the `dwc3` host controller when the modem disappears after a warm reset / hang.
- **L850-GL signal & AT tools** — corrected RSSI (`RSSI = RSRP − RSRQ + 10·log10(N_RB)`), Intel cell info (`GTCAINFO`/`XCESQ`), and AT Debug **Quick Commands** tailored to the L850 (incl. `XACT` band-lock presets).

## Packages in this repo

Only the packages used by the L850-GL build remain:

| Package | Purpose |
|---|---|
| `xmodem` | core dial/scan scripts (`modem_dial.sh`, `generic.sh`, rpcd) |
| `modem_scan` | by-name modem detection (`AT+CGMM`) |
| `tom_modem`, `sms-tool_q`, `ubus-at-daemon` | AT/SMS access used by xmodem |
| `sms_forwarder_next` | SMS forwarding (LuCI dependency) |
| `ndisc6` | IPv6 neighbor/router discovery |
| `lpac` | eSIM/eUICC (patched, MBIM backend) |
| `xmodem_esim_bot` | Telegram eSIM bot |
| `luci-app-xmodem-next` | modern XModem LuCI UI |
| `luci-app-lpac` | eSIM LuCI UI |

All other modems' packages, vendor QMI/MHI kernel drivers, quectel-CM, and unrelated LuCI apps have been removed.

## Detection note

The modem is detected primarily by model name (`AT+CGMM` → `l850-gl`), which works in both NCM and MBIM modes. `modem_support.json` also lists both USB IDs (`2cb7:0007` MBIM, `8087:095a` NCM) as an AT-fallback safety net.

## Credits

- Base: [FUjr/XModem](https://github.com/FUjr/QModem)
