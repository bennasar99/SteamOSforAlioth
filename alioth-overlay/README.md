# `alioth-overlay/`

Xiaomi Redmi K40 / POCO F3（alioth，SM8250-AC）特有的用户空间配置，装到
Valve Frame rootfs 上。

## 为什么独立于 `sm8250-overlay/`

alioth 和那些机器同为 SM8250，但 `sm8250-overlay/` 里的 44 个文件全是掌机的
**物理摇杆与按键** InputPlumber 配置（AYANEO Pocket MICRO 2、Retroid Pocket 5 /
Flip 2 / Mini、MANGMI Air Y Pro / Pocket Max、AYN Thor Lite），与 alioth 的
「触摸 + 蓝牙手柄 + 两个音量键」没有交集。

分开放的真正理由是 merge 面：每次 `git merge upstream/main` 都要分得清哪些
文件是上游的、哪些是我们的（spec §4）。

**但两个 overlay 不是按目录互斥的。** `scripts/apply-alioth-overlay.sh` 在
`apply-overlays.sh` 之后跑，只做加法，一个 `sm8250-overlay/` 的文件都不删：

- 掌机的 5 个 InputPlumber profile 全都 gate 在各自的 DT model 上
  （`Retroid Pocket 5`、`AYN Thor Lite`、`MANGMI …`、`AYANEO …`），对
  `Xiaomi Poco F3` 一个都匹配不上，本来就是惰性的；
- 而 `sm8250-overlay/etc/systemd/user/steamos-powerbuttond.service` 恰恰是
  **我们要用的** —— 下面那个 drop-in 只写了 `Wants=`，把它当掌机文件删掉
  `Wants=` 就悬空了，systemd 对此一声不吭，表现为电源键在 Game Mode 里没反应。

互斥因此按 profile 粒度断言（没有第二个 profile 认领我们的 model），不按目录
粒度删除 —— 见 `scripts/assert-alioth-overlay-applied.sh`。

## 内容

| 路径 | 作用 |
|---|---|
| `etc/inputplumber/devices.d/02-xiaomi-alioth.yaml` | 把两个音量键组成一个虚拟 Deck 手柄 |
| `etc/inputplumber/capability_maps.d/alioth_keys.yaml` | 音量上 → Steam 键，音量下 → 快捷菜单 |
| `etc/systemd/user/gamescope-session.target.d/99-zz-alioth-powerbuttond.conf` | 电源键交给 `steamos-powerbuttond`（Frame 自带的 unit 依赖 SteamVR） |
| `usr/lib/udev/rules.d/70-alioth.rules` | FT8756 触摸屏标记为 seat0 的指针设备 |
| `usr/lib/modules-load.d/alioth.conf` | 开机加载 PCIe pwrctrl、WiFi、蓝牙、音频模块 |
| `usr/share/alsa/ucm2/Xiaomi/Alioth/` | 扬声器 UCM（本机只有扬声器，无 3.5 mm 口） |
| `usr/share/alsa/ucm2/conf.d/sm8250/xiaomi-alioth.conf` | UCM 入口，文件名 = 声卡名 |
| `usr/lib/steamos-arm/alioth-firstboot` | 首次开机把根文件系统扩展到 106 GiB，然后标记 A/B successful |
| `usr/lib/systemd/system/alioth-firstboot.service` | 上面那个脚本的 unit（+ `sysinit.target.wants/` 里的 enable 链接） |
| `usr/lib/steamos-arm/steamos-arm-power` | Steam TDP / Manual GPU Clock 的 D-Bus 后端；alioth 没有 konkrd/odin3d，直接调用 `power_limits.apply()` |
| `usr/lib/steamos-arm/power_limits.py` | TDP → CPU/GPU 频率的共享模型（sm8250 范围 3–10 W） |
| `usr/lib/systemd/system/steamos-arm-power.service` | 上面那个服务的 unit（+ `multi-user.target.wants/` 的 enable 链接） |
| `usr/share/steamos-manager/remotes.d/50-steamos-arm.toml` | 把 TdpLimit / GpuPerformanceLevel 转给 Steam 的 Quick Access |
| `usr/share/steamos-manager/devices/xiaomi-alioth.toml` | 让 handheld Steam 客户端把 alioth 认成 SM8250 掌机，显示 Performance 页 |
| `usr/share/dbus-1/system.d/org.steamos_arm.Power.conf` | 允许 root 在 system bus 上 own `org.steamos_arm.Power` |
| `usr/lib/steamos-arm/alioth-swapfile-setup` | 创建 2 GiB `/swapfile`；迁移后 `/swapfile` 指向新分区，挂载缺失时 fail closed |
| `usr/lib/systemd/system/swapfile.swap` | 2 GiB swapfile，priority 50（zram 是 100）；`RequiresMountsFor` 迁移目录 |
| `usr/lib/systemd/system/alioth-swapfile-setup.service` | 在 swapfile.swap 之前建文件 |
| `usr/lib/steamos-arm/alioth-super-migrate` | 可选：把运行期只读的系统文件搬到 Android 系统分区，并把 swap 也放过去 |
| `usr/lib/systemd/system/alioth-super-migrate.service` | 只在 `alioth.supermigrate=1` 的 boot 镜像下运行一次（+ `basic.target.wants/`） |
| `etc/systemd/logind.conf.d/99-alioth-suspend.conf` | 电源键直接 suspend；覆盖 Frame 的 `HandlePowerKey=ignore` |
| `etc/systemd/system/alioth-wifi-recover.service` | 热重启后若 `NetworkManager`/`iwd` 没起来，在 `steamos-manager` 之后补启动（+ `multi-user.target.wants/`） |
| `usr/lib/steamos-arm/tablet-charger-hold` | 充电器插入开机时保持黑屏充电，短按显示大号电量，长按 1.5 s 启动 SteamOS |
| `usr/lib/systemd/system/steamos-arm-tablet-charger.service` | 充电保持 unit，`xiaomi,alioth` 条件，display-manager 之前运行（+ `multi-user.target.wants/` enable 链接） |
| `etc/systemd/user/gamescope-session.service.d/99-orientation.conf` | Razer Kishi 专用：180° 画面翻转。可选；`make-steamos-alioth.sh --install` 会询问，`ALIOTH_ORIENTATION_FLIP=0` 可跳过 |
| `usr/lib/udev/rules.d/71-alioth-flip.rules` | Razer Kishi 专用：与 99 成对启用的触摸矩阵；两者由同一个 `ALIOTH_ORIENTATION_FLIP` 开关控制 |

### 电源 UI

`steamos-arm-power` 实现 Steam 的 TDP 滑条和 Manual GPU Clock。TDP 是唯一的
功耗控制（3–10 W），Manual GPU Clock 优先于 TDP 对 GPU 的上限。真机确认：
换成 handheld `RUNSTEAM.sh` 后 UI 显示 TDP 限流生效；此前 Frame
`RUNSTEAM.sh`（`-deckard -vrgamepadui`）只显示 GPU clock，是因为 Steam
客户端把这个设备当成 Frame。

**Performance Profiles 已移除**：Silent/Balanced/Turbo 预设会和 TDP 滑条
互相覆盖，所以 service 和 remotes 都不再暴露 `PerformanceProfile1`。

Refresh Rate 选项已移除：alioth 是固定 60 Hz 面板，`gamescope-session` 走
60-only 分支并 `unset STEAM_DISPLAY_REFRESH_LIMITS`；`gamescope-onready` 还会
清掉 user manager 里遗留的旧值。这样 Performance 页不再显示一个改不了任何
东西的刷新率滑条。FPS 限流器本身仍未解决。

`alioth-game-tune` 仍然只在游戏运行时切 `performance` governor，和这里的频率
上限不冲突。电池充电上限/Bypass 没有暴露：`qcom_pm8150b_charger` 只暴露
`current_max`，没有 `charge_control_end_threshold`，这部分留给
`alioth-charge-guard`。

### Swap

3.5 GiB zram（lzo-rle，priority 100）先于磁盘；另有一个 2 GiB `/swapfile`
（priority 50），由 `alioth-swapfile-setup` 在第一次启动时创建。zram 压力
到上限后才落到 UFS 上的 swapfile。如果安装时选择了可选的 extra-storage
迁移，`/swapfile` 是指向 Android 系统分区上同名文件的符号链接；迁移失败或
该分区没挂上时，创建脚本会拒绝退回根文件系统。zram 的 lzo-rle/lz4/zstd 实测见
`AGENS_new.md`：lzo-rle 和 LZ4 基本持平，zstd 压缩比更高但明显更慢。

### 电源键

`99-alioth-suspend.conf` 排在 Frame 的 `10-logind-no-powerbutton.conf` 之后，
把 `HandlePowerKey` 从 `ignore` 改成 `suspend`。真机确认：按电源键立即
s2idle，再按一次唤醒；不需要等空闲超时。`steamos-powerbuttond` 仍会尝试发
`steam://powerpress`，但 logind 也能收到键；如果以后被它 grab，mask 该
user service 即可。插着 USB 时 gadget/ttyGS0 是唤醒源，可能在充电状态下立刻
醒来；确认的那次是电池供电。

### 屏幕翻转（Razer Kishi 专用）

`99-orientation.conf` + `71-alioth-flip.rules` 是给 **Razer Kishi** 用的：
Kishi 的 USB-C 接头把手机的 USB-C 边固定在手柄一侧，默认 `right` 方向下
画面是倒的。`GAMESCOPE_ORIENTATION=left` 做 180° 翻转，`71` 把触摸矩阵
改成配套的 `0 -1 1 1 0 0`。

这两个文件必须成对安装或删除。它们不是通用默认值：本 fork 默认启用，是因为
维护者使用 Razer Kishi。使用蓝牙手柄、其他 USB-C 手柄或不接手柄时，请跳过
这一对，保留未修改的 `right` 方向和 `70-alioth.rules` 的
`0 1 0 -1 0 1`；否则画面或触摸会单独转 180°。
从源码构建时，`make-steamos-alioth.sh --install` 会询问
`Apply the Razer Kishi 180-degree render+touch flip? [Y/n]`；回答 `n`
（或设 `ALIOTH_ORIENTATION_FLIP=0`）即成对跳过。已安装系统则删除
`/usr/lib/systemd/user/gamescope-session.service.d/99-orientation.conf` 和
`/usr/lib/udev/rules.d/71-alioth-flip.rules` 后重启。

这是启动期参数：切换方向要重启 gamescope 或整机，让 libinput 重新打开触摸
设备。没有运行时的 Steam UI 开关；要加 UI 需要 Decky 插件或一个非 Steam
快捷方式 + root helper。

## 这台机器上「没有按键」意味着什么

alioth 一个物理游戏按键都没有。触摸由 Deck UI 原生处理，蓝牙手柄由
InputPlumber 自带的 Xbox / DualSense / 8BitDo profile 处理（它们本来就
target `deck-uhid`，我们不去覆盖）。真正需要我们做的只有一件事：Deck UI 的
**Steam 键**和**快捷菜单**在纯触摸下没有可靠入口，游戏全屏捕获触摸时尤其如此。
那两个音量键就是为此而来，代价是失去硬件音量调节 —— 快捷菜单里有音量滑条，
所以是两次按键而不是一次，不是失去。

按键归属（阶段 1 在真机 `/proc/bus/input/devices` 实测）：

```
gpio-keys       音量上    pm8150 gpio6，DTS 里的 vol_up_n
pm8941_resin    音量下    power-key block，上报 KEY_VOLUMEDOWN
pm8941_pwrkey   电源      不归 InputPlumber，归 steamos-powerbuttond
```

## 音频

声卡是 `qcom,sm8250-sndcard`，唯一的 codec 链路接 i2c3 上两颗 Cirrus
**CS35L41** 功放（`sound-name-prefix` 分别是 `RCV` 和 `LCV`），由
`TERTIARY_TDM_RX_0` 喂。没有 WCD938x，没有 WSA881x，没有 3.5 mm 口 ——
耳机走蓝牙，不经过 ALSA。

两件容易踩的事：

1. ROCKNIX 没开 `CONFIG_SND_SOC_CS35L41_I2C`（它的掌机都不用这颗）。少了
   功放驱动，codec 组件不注册，DAI link 配不齐，**整张声卡都不出现** ——
   不是「没声音」，是 `/dev/snd/controlC0` 都没有。已在
   `external-and-mods/kernel-sm8250/steamos.config` 里补成 `=m`。
2. UCM 按**声卡名**查找，而声卡名来自 `&sound` 节点的 `model`
   （`xiaomi-alioth`），不是根节点的 `model`（`Xiaomi Poco F3`）。所以入口
   文件叫 `conf.d/sm8250/xiaomi-alioth.conf`。
   `scripts/assert-alioth-modules.py` 直接从 DTS 读这个值来比对，防止两边漂移。

两颗功放钉在固定的 −12 dB，音量由 PipeWire 在软件里做：它们是两个独立
codec，`PlaybackMixerElem` 只能指到其中一个；而且
`nasaarmas/pmaports-alioth` 报告这对扬声器推大了声音发散。

2026-10-23 真机实测结论（原「待真机核实」已结）：

- 控件名对了。`amixer -c0 controls` 里 `RCV/LCV Digital PCM Volume` 的
  `dBminmax` 是 `-102.00dB .. 12.00dB`，和注释里「721 = −12 dB」的推导一致；
  `alsaucm -c xiaomi-alioth set _verb HiFi set _enadev Speaker` 干净通过，
  路由控件读回 `on`。
- **后端是 TDM，而且绕不过去。** `TERTIARY_TDM_RX_0` 一开始带着 0 槽 0 槽宽
  到 q6afe，ADSP 直接拒收（`AFE enable for port 0x9020 failed -22`，
  `DSP returned error[2]`），表现不是「没声音」而是 **`snd_pcm_open` 返
  EINVAL** —— ACP 一个 profile 都探测不出来（`spa-acp-tool`:
  `profiles:2 ports:0`），PipeWire 只给一个 Dummy Output。真因是
  `qcom,sm8250-sndcard`（`sound/soc/qcom/sm8250.c`）**从不调用
  `snd_soc_dai_set_tdm_slot()`**。

  换成 `TERTIARY_MI2S_RX` 绕开它是走反了方向，而且代价很隐蔽：两颗功放的
  `ASP_SDIN` 接在 `mi2s2_data1`（gpio137）上，而 `sm8250.dtsi` 的
  `tert_mi2s_active` 只有 gpio133/134/135，`qcom,sd-lines = <0>` 驱动的
  gpio134 是功放把 VI sense 送回 SoC 的方向。时钟脚两种模式共用，所以功放
  照样锁 PLL、照样 `PUP_DONE`、照样零故障 —— 得到的是一张**每一项都查得过、
  完全不出声**的声卡，连功率都不输出（放粉噪声把 `Analog PCM Volume` 在 0
  和 16 之间切，电池电流毫无变化）。

  正确做法是补上缺的东西：补丁 0027 给 machine driver 加 TDM 分支，补丁
  0026 把 `qcom,tdm-invert-sync` / `tdm-data-delay` / `tdm-data-out` 真的送
  到 ADSP（`q6afe_tdm_port_prepare()` 原本把这三项解析完就丢了）。后端留在
  `TERTIARY_TDM_RX_0`，由 `scripts/assert-alioth-dtb.py` 第 4c 条守住端口与
  帧参数、第 4e 条守住 gpio137。

## 首次开机

刷进 `userdata` 的镜像只有几 GB（按内容大小做的），而分区是 106 GiB。
`alioth-firstboot` 在开机早期把根文件系统扩展到整个分区 —— 不扩展的话
Steam 第一次装游戏就没空间，而报错离原因很远。

顺序是这个脚本的全部要点：

```
哨兵存在？ -- 不在就什么都不做（已经跑过了）
扩展
标记 successful
删哨兵                      <-- 只有全都成功才走到这里
```

哨兵 `/var/lib/alioth-firstboot-pending` 由构建时放进镜像，脚本只删不建。
任何中断（掉电、SIGKILL、`resize2fs` 失败）都必然落在「哨兵还在」的状态，
下次开机自然重来。反过来写就会留下一个永远只有几 GB 的根文件系统，而且
没有任何东西会再去修它。`scripts/assert-alioth-firstboot.sh` 真的在
`resize2fs` 跑到一半时 SIGKILL 掉它来验证这件事。

标记 successful 放在扩展成功**之后**：在那之前，bootloader 的自动回退
（连续失败 7 次换槽，spec §6.3）是唯一的兜底，不能提前关掉。

enable 链接放在 `usr/lib/systemd/system/sysinit.target.wants/` 而不是
`/etc` 下，因为 SteamOS 的 `/etc` 是 overlayfs 且挂载很晚，而这个 unit
要在 `sysinit.target` 之前跑。

> **待真机核实（Task 8）：** `qbootctl -u` 的 `-u` 是「mark boot successful」
> （linux-msm/qbootctl），没在真机上验过。脚本在它失败时会把 `qbootctl -h`
> 打进日志并保留哨兵，所以一次开机就能看出正确的用法。
