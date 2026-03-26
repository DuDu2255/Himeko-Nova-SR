# CastoricePS

- Discord：`Discord.gg/CastoricePS`
- Srtools：`https://srtools.neonteam.dev/`

## 运行时文件
```
CastoricePS.exe          # 主程序
freesr-data.json
misc.json                # 配置文件
hotfix.json              # 热修复文件
resources/               # 资源文件
protocol/                # 协议文件 (Proto)
```

## 使用指南（Windows）
1) 安装 Zig 0.14.1

2) 构建与运行：
- 运行服务器：`zig build run-program`
- 构建：`zig build`
- 发布构建：`zig build -Doptimize=ReleaseSafe`

## 获取游戏客户端
Get 4.1.5X client:
[Gofile 1](https://gofile.io/d/gx33Tr), [Gofile 2](https://gofile.io/d/BBWioN),
[MEGA](https://mega.nz/file/rQ9AkTyQ#B3xGf5Jnh0UVIMFkoLlXAPxKq7M1KIgG3sQykEKgpz0), [Filen](https://app.filen.io/#/d/4531a66b-ae21-4101-8ba9-8f4a79d6253f%2377714c6738454c506e4370394f6e744b314e52706844414133774a5055694d79) 

## 使用指南（Android）
注意：此操作将生成 **Android ELF** 可执行文件

- ARM64：`zig build -Dtarget=aarch64-linux-android -Doptimize=ReleaseSafe`
- ARMv7：`zig build -Dtarget=arm-linux-androideabi -Doptimize=ReleaseSafe`

## 致谢
特别感谢 [Reversed Rooms](https://discord.gg/reversedrooms)
[BaseProject](https://git.xeondev.com/HonkaiSlopRail/evanescia-sr)