# CastoricePS
基于 Zig 的某回合制游戏Server实现。

本项目完全免费。仅供学习使用。

- Discord：`Discord.gg/CastoricePS`
- srtools：`https://srtools.neonteam.dev/`

## 功能

- [√] **编队**
- [√] **抽卡** 
- [√] **战斗** 
- [√] **地图** -
- [√] **指令** 
- [√] **活动** 
- [√] **混沌回忆 & 虚构叙事 & 末日幻影 & 异相仲裁** 


## 目录结构（运行时）
建议把以下文件放在同一目录：
```
CastoricePS.exe          # 主程序
freesr-data.json         # 角色配置文件
misc.json                # 杂项配置文件
hotfix.json              # 热修复文件
resources/               # 资源配置
protocol/                # 协议文件
```

## 编译与运行（Windows）
1) 安装 Zig 0.14.1，并把 `zig.exe` 加入 PATH

2) 构建并运行：
- 开发运行：`zig build run-program`
- 仅构建：`zig build`
- 发布构建：`zig build -Doptimize=ReleaseSafe`

## 编译（Android）
说明：这会生成 **Android ELF 可执行文件**（不是 APK）。

- ARM64（推荐，大多数手机）：`zig build -Dtarget=aarch64-linux-android -Doptimize=ReleaseSafe`
- ARMv7：`zig build -Dtarget=arm-linux-androideabi -Doptimize=ReleaseSafe`

产物路径：
- `zig-out/bin/CastoricePS`（在 Android 上运行的 ELF）

在设备上运行（示例）：
- `adb push zig-out/bin/CastoricePS /data/local/tmp/`
- `adb shell chmod +x /data/local/tmp/CastoricePS`
- `adb shell /data/local/tmp/CastoricePS`

## 开发提示
- srtools 网页保存的数据会写入根目录 `freesr-data.json`，服务器侧会在 `/sync` 
- 如果你需要更多的参考，请关注 `resources/` 目录。可以通过修改Resources的方式来修改buff和技能效果。

## 启动游戏
实际上内置代理在新版本不凑效。如果你需要更简单的办法，请参考[CastoriceLauncher](https://github.com/DBKAHHK/CastoriceLauncher)

## 贡献
欢迎提交PR和Issue.
感谢[Reversed Rooms](discord.gg/reversedrooms)，以及[他们的开源服务器](https://git.xeondev.com/HonkaiSlopRail/yaoguang-sr)
感谢Kain开发的[代理服务器](https://git.kain.io.vn/Firefly-Shelter/FireflyGo_Proxy)
