# Himeko•NovaSR 
#### Honkai: Star Rail server emulator (4.5 beta) written in Zig.

![Screenshot](Screenshot.png)

## Requirements
- [Zig 0.14.1 x64](https://ziglang.org/download/0.14.1/zig-x86_64-windows-0.14.1.zip)

## Running

### From source

Windows:
```
git clone https://git.xeondev.com/HonkaiSlopRail/himeko-nova-sr
cd himeko-nova-sr
zig build run-dispatch
zig build run-gameserver
```

### Setup launcher.exe

Copy `launcher.exe` and `hkprg.dll` from launcher folder inside himeko-nova-sr and paste them inside your client folder.
Then open your `launcher.exe` with administrator.

### Using Pre-built Binaries
Navigate to the [Releases](https://git.xeondev.com/HonkaiSlopRail/himeko-nova-sr/releases)
page and download the latest release for your platform.

## Connecting
Get 4.4.5X client: [Gofile](https://gofile.io/d/yOz1V6), [Transfer](https://transfer.it/t/1OsknNwDRZQC)

The game server speaks **KCP over UDP** on port `23301` (the same transport the
retail client uses). Make sure UDP `23301` is not blocked by your firewall.

## Configuration

Your characters, their gear and the test battle come from `freesr-data.json`,
the community/SRTools format also used by RobinSR, March7thHoney and freesr.
One ships with the repo; replace it with your own export, or sync from SRTools.

Reload it in-game with `/sync`.

### SRTools

In SRTools pick the **RobinSR** provider and enter `http://localhost:21000`.
No account or password is involved.

| Route | Purpose |
|---|---|
| `POST /srtools` | What SRTools uploads to: writes `freesr-data.json` and reloads the game server |
| `GET /srtools-export` | Downloads the current config as `freesr-data.json` |

The upload endpoint is wire-compatible with RobinSR's (`{"data": {...}}` in,
`{"message":"OK","status":200}` out). Dispatch writes the file and then asks
the game server to reload it, so the sync applies immediately; run `/sync`
in-game to push the new characters and gear to the client.

## Lua scripts

Scripts live in the `lua/` directory and are read at runtime, so you can edit
them without rebuilding:

- `lua/watermark.lua` is pushed with every heartbeat.
- `/windy <file>` pushes any other script under `lua/`, e.g. `/windy test.lua`.

## Functionality (work in progress)
- Login and player spawn
- Test battle via calyx
- MOC/PF/AS simulator with custom stage sellection
- Anomaly Arbitration (Challenge Peak)
- Starward Mode (Challenge Tierce)
- Gacha simulator 
- Support command for Sillyism
- `freesr-data.json` / SRTools support
- Runtime lua scripts and `/windy`

## Contributing

Pull requests are welcome. For major changes, please open an issue first to discuss
what you would like to change, and why.

## Bug Reports

If you find a bug, please open an issue with as much detail as possible. If you
can, please include steps to reproduce the bug.

Bad issues such as "This doesn't work" will be closed immediately, be _sure_ to
provide exact detailed steps to reproduce your bug. If it's hard to reproduce, try
to explain it and write a reproducer as best as you can.