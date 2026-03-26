# CastoricePS
[CN](README_CN.md)
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
Get 4.1.5X client:
[Gofile 1](https://gofile.io/d/gx33Tr), [Gofile 2](https://gofile.io/d/BBWioN),
[MEGA](https://mega.nz/file/rQ9AkTyQ#B3xGf5Jnh0UVIMFkoLlXAPxKq7M1KIgG3sQykEKgpz0), [Filen](https://app.filen.io/#/d/4531a66b-ae21-4101-8ba9-8f4a79d6253f%2377714c6738454c506e4370394f6e744b314e52706844414133774a5055694d79) 

## How-to（Android）
Note: This will generate**Android ELF**

- ARM64：`zig build -Dtarget=aarch64-linux-android -Doptimize=ReleaseSafe`
- ARMv7：`zig build -Dtarget=arm-linux-androideabi -Doptimize=ReleaseSafe`

## Acknowledgments
Thanks to [Reversed Rooms](https://discord.gg/reversedrooms)
[BaseProject](https://git.xeondev.com/HonkaiSlopRail/evanescia-sr)
