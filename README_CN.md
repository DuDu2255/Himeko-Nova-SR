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
[4.1.5X 客户端下载链接](https://gofile.io/d/whpait)

## 使用指南（Android）
注意：此操作将生成 **Android ELF** 可执行文件

- ARM64：`zig build -Dtarget=aarch64-linux-android -Doptimize=ReleaseSafe`
- ARMv7：`zig build -Dtarget=arm-linux-androideabi -Doptimize=ReleaseSafe`

## 致谢
特别感谢 [Reversed Rooms](https://discord.gg/reversedrooms)
[BaseProject](https://git.xeondev.com/HonkaiSlopRail/evanescia-sr)