# CastoricePS

- Discord：`Discord.gg/CastoricePS`
- Srtools：`https://srtools.neonteam.dev/`

## Runtime
```
CastoricePS.exe          # Main Program
freesr-data.json         
misc.json                # Config
hotfix.json              # Hotfix
resources/               # Resources
protocol/                # Proto
```

## How-to（Windows）
1) Install Zig 0.14.1

2) Build and run：
- Run Server`zig build run-program`
- Build`zig build`
- Publish`zig build -Doptimize=ReleaseSafe`

## Get Game Client
[4.1.5X Client here](https://gofile.io/d/whpait)

## How-to（Android）
Note: This will generate**Android ELF**

- ARM64：`zig build -Dtarget=aarch64-linux-android -Doptimize=ReleaseSafe`
- ARMv7：`zig build -Dtarget=arm-linux-androideabi -Doptimize=ReleaseSafe`

## Acknowledgments
Thanks to [Reversed Rooms](https://discord.gg/reversedrooms)
[BaseProject](https://git.xeondev.com/HonkaiSlopRail/evanescia-sr)
