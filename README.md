# -
# Tang Nano 20K 四键复音乐器

预编译文件是 **`release/instrument.fs`**。适配 27 MHz 的 Tang Nano 20K（GW2AR-LV18QN88C8/I7）和本工作区的 Music Carrier Rev A。接线与下表一致时，烧录无需重新综合。所有演奏、合成、I²S、手势识别、串口协议和灯带控制均在 FPGA 内执行。

## 下载与第一次试听

1. 断电接线。先接四个触摸输出和 DAC，把有源音箱音量调低。也可以单独用 BLE 遥控来检查音频。外接灯带单独供电，所有参与通信的模块共地。
2. USB-C 接开发板，打开 Gowin Programmer，扫描到对应 GW2A(R)-18 器件。选 **SRAM Mode**，选择 `release/instrument.fs`，执行下载。首次试听时手指离开触摸片，让模块完成上电校准。
3. 同时碰第 1、第 3 键，应听到 C4 和 E4，灯带第 1、第 3 颗分别亮红、蓝。单独松开第 1 键，E4 应继续响。全松开后声音淡出。
4. 验证后需要掉电保存时，再选 **External Flash Mode → Generic Flash**，选择同一 `.fs` 并执行写入。该操作会替换已有的外部 Flash 启动程序。也可用命令行从本工程目录下载：

```powershell
# 临时装入 SRAM
openFPGALoader -b tangnano20k release/instrument.fs

# 保存到外部 Flash，供下次上电启动
openFPGALoader -b tangnano20k -f release/instrument.fs
```

[官方板卡下载图解](https://wiki.sipeed.com/hardware/en/tang/tang-nano-20k/example/led.html) · [openFPGALoader 板卡表](https://github.com/trabucayre/openFPGALoader/blob/master/doc/boards.yml)

没有耳放时，可以直接在电脑播放 [6.7 秒音色试听](preview/instrument-demo.wav)。样本来自本工程 I²S 仿真，依次为三角波、方波和锯齿波。若要边弹边听，给开发板与 HC-08 供电，然后在这台 Windows 电脑双击 [Play-live.cmd](preview/Play-live.cmd)。电脑读取蓝牙触摸键、音量和音色，用电脑扬声器合成播放，Ctrl+C 结束。此方式不经过 PCM5102A。其他电脑可安装 Python 包 `bleak numpy sounddevice`，运行 `python preview/live.py`，或加 `--address` 指定自己的蓝牙模块。

## 接线

表中数字是 **FPGA 封装脚号**，可与 `instrument.cst` 核对。本表的 J6/J7 等指 **Music Carrier Rev A 扩展板**上的模块接口；裸板接线图中的 J5/J6 则是 Tang 本板两排引脚。例如裸板 J6.11 是 GPIO26，扩展板 J6 是 DAC 接口。FPGA 信号侧统一用 3.3 V。[裸板正面图](wiring/01-front.png) · [背面图](wiring/02-back.png) · [整机接线图](wiring/03-system.png) · [Sipeed 板卡资料](https://wiki.sipeed.com/hardware/en/tang/tang-nano-20k/nano-20k.html)

| 模块 | 扩展板引脚 → 模块 | FPGA 封装脚 |
|---|---|---|
| 四路 TTP223 | J11、J12、J13、J14 各自 1=3.3 V，2=GND，3=OUT，依次对应键 1～4 | 27、28、25、85 |
| PCM5102A | J6 的 1→BCK，3→LRCK/LCK，5→DIN，7→XSMT（适用时），2/4/6/8/10 为地。9 是 5 V，只接明确支持 5 V 的模块 VIN | BCK 56、LRCK 55、DIN 54、XSMT 79 |
| HC-08D | J7 的 1=3.3 V，2=GND，3→模块 RXD，4←模块 TXD。确认所用底板供电脚额定值 | FPGA TX 53、RX 74 |
| APDS9930 / APDS9960 兼容模块 | J8 的 1=3.3 V，2=GND，3=SCL，4=SDA。轮询读取，INT 可悬空 | SCL 72、SDA 71 |
| 8 颗 WS2812(B) | J9 的 1=GND，2→灯带 **DIN**。J9 仅送数据和地，灯带 +5 V 单独供电并共地 | 26，扩展板上经 AHCT 缓冲转为 5 V |

- **触摸**使用点动、按下高电平模式。每个通道必须先检测到一次稳定松开才能演奏，防止上电时未插的通道被扩展板上拉而持续发声。若四个模块都是低有效，把顶层 `TOUCH_ACTIVE_HIGH` 改为 0 并重新编译。
- **DAC** 使用标准 I²S（FMT=低）、三线 PLL（SCK 接地）、DEMP=低。若模块已把 XSMT 硬接高电平，J6 的 7 脚保持断开。PCM5102A 的左右声道是线路输出，可接有源音箱 AUX 或耳放输入。普通低阻耳机接耳放输出。[TI PCM5102A 数据手册](https://www.ti.com/lit/ds/symlink/pcm5102a.pdf)
- **直连开发板**时，为 SDA 和 SCL 各加一个约 4.7 kΩ 的 3.3 V 上拉（已有合适上拉的模块可直接使用）。5 V 灯带的数据线用 74AHCT125 等缓冲器升到 5 V。扩展板已提供这两项。使用这套引脚时，板载 HDMI、LCD 和 microSD 接口留空。

## 演奏与灯光

| 键 | 音符 | 手机按下 / 松开 | 对应灯色 |
|---|---|---|---|
| 1 | C4，261.63 Hz | `1` / `a` | 红 |
| 2 | D4，293.66 Hz | `2` / `b` | 绿 |
| 3 | E4，329.63 Hz | `3` / `c` | 蓝 |
| 4 | G4，392.00 Hz | `4` / `d` | 琥珀 |

每个音有独立振荡器和起落音包络。同一音可同时由手机和触摸键保持，两边都松开后才止音。前四颗灯对应实际按住的音，第 5～8 颗显示音频峰值，音量越大、和弦越响，通常亮得越多。灯带约每 10 ms 刷新一次。

FPGA 从触摸模块 OUT 稳定翻转开始，连续确认约 0.61 ms，再按约 21.33 µs 一帧合成。起音包络约 1.37 ms 到峰值，松开最长约 5.44 ms 回零。手指到声音的实测延迟还包含触摸芯片的扫描和 DAC 滤波。例如 TTP223-BA6 在 3 V 下，手册给出的快模式和低功耗模式最大响应分别约 60 ms 和 220 ms。[Tontek TTP223-BA6 数据手册](https://datasheet.lcsc.com/lcsc/2103021907_Tontek-Design-Tech-TTP223-BA6_C2757936.pdf)

I²S 用 3.000 MHz BCK、46,875 Hz LRCK、每声道 32 位、标准 I²S 一位延迟，左右输出相同。DDS 按该采样率定音；上电先连续输出 1024 帧零样本，再释放 XSMT。这些参数已由仿真验证；实板 DAC 的三线 PLL 锁定及模拟输出待测。[TI 数据手册](https://www.ti.com/lit/ds/symlink/pcm5102a.pdf)

## 手机 BLE 操作

手机用支持 **BLE 特征写入和通知** 的调试 APP，连 HC-08D 的从机透传服务。常见 HC-08 固件用服务 `FFE0`、特征 `FFE1`，具体以模块广播的服务为准。FPGA UART 默认为 **9600、8N1**；若模块改过波特率，修改顶层 `BAUD` 与其一致。[汇承 HC-08 使用手册](https://www.hc01.com/downloads/HC-08V3.1.pdf)

1. 订阅透传特征的通知。选择 ASCII / UTF-8 文本模式，发送 `0?`，会清除远程按键并读取当前本地状态。若 APP 只支持十六进制写入，`0?` 是 `30 3F`。
2. 发 `13`（十六进制 `31 33`），同时保持 C4、E4。发 `a` 松开 C4，再发 `c` 松开 E4。随时发 `0` 释放所有远程音，本地正在按住的音继续响。
3. 本地触摸变化或收到 `?` 时，FPGA 回传 ASCII `K` + 一位大写十六进制掩码 + 换行。例如 `K5\n` 表示第 1、3 键按下，`KF\n` 表示四键全按，`K0\n` 表示全松开。自制 APP 可按换行拼包，解析十六进制值，将 bit 0～3 映射到四个状态灯。手机琴键在按下事件写入数字，松开或触摸取消事件写入对应小写字母。
4. J7 仅连接串口，FPGA 无法从这两根数据线确定手机何时断开。若按住远程音时掉线，重连后发 `0?` 可恢复；正常退出前发 `0`。

## APDS9930 与 APDS9960 兼容模块的手势

上电时先把手移开。APDS9930 测量接近强度，固件用一次接近持续的时间区分快速挥手与停留，左右掠过的效果相同。[Broadcom APDS9930 手册](https://docs.broadcom.com/wcs-public/products/data-sheets--technical-specifications/data-sheet/736/749/av02-3190en_ds_apds-9930_2015-11-13.pdf)

两类模块都使用 I²C 地址 0x39，固件先读芯片 ID 来选择寄存器。APDS9930（ID 0x39）读取 10 位接近值。APDS9960 兼容模块（包括本机读到的 ID 0x9E）从 0x9C 读取 8 位接近值，乘 4 后再用同一套手势阈值。蓝牙查询显示换算后的值。两类模块都使用上表的四根线。[APDS9960 数据手册](https://content.arduino.cc/assets/Nano_BLE_Sense_av02-4191en_ds_apds-9960.pdf) · [ESPHome APDS9960 驱动](https://github.com/esphome/esphome/blob/dev/esphome/components/apds9960/apds9960.cpp)

| 动作 | 结果 |
|---|---|
| 手掠过并移开，持续至少约两次采样、短于约半秒 | 松开时切下一种音色，循环为三角波 → 方波 → 锯齿波 |
| 靠近并保持约半秒，反射读数强 | 逐档加音量 |
| 在检测范围内稍微退远并保持，反射读数较弱 | 逐档减音量 |
| 移出检测范围 | 停止调节；长停结束不再额外切音色 |

默认音量 8/15，0 为静音。约每 20～21 ms 采样一次，长停后约每 0.17 s 调一档。阈值是传感器原始计数，不能换算成固定厘米。若需要适配不同窗口或安装高度，在 `rtl/sensor.v` 调 `ENTER_LEVEL=180`、`LEAVE_LEVEL=120`、`LOUDER_LEVEL=450`，保持三者顺序为松开 < 进入 < 增大音量。传感器断开不影响演奏，重新接入会自动初始化。

用裸 Tang 接线时，开发板元件面朝上、USB-C 在上。右排从 HDMI 端往上数，第 3 脚接 SDA (71)，第 4 脚接 SCL (72)，第 5 脚为 3V3，第 6 脚为 GND。

通过蓝牙发 ASCII `!`（十六进制 `21`），可在没有音响的情况下查询手势。举例：`G1391C2801` 表示在线、芯片 ID 为 0x39、接近值 0x1C2（450）、音量 8、音色 0、最近一次采样成功。每帧以换行结束，各字段固定为 1、2、3、1、1、1 位十六进制数。离线时 ID 和接近值保留最近成功读数。最后一位诊断码：0 尚未完成，1 采样成功，2 总线等待超时，3 数据线占用并尝试恢复，4 设备地址无应答，5 后续传输无应答，6 芯片 ID 不符，7 接近寄存器尚无有效数据。电脑端安装 bleak 后可运行 `python read_gesture.py --seconds 20` 连续采样；多个同名模块时加 `--address` 指定设备。先移开手，再靠近、停留、移开，对比接近值与音量或音色。

## 重新编译和验证

- **Gowin IDE** 打开 `instrument.gprj`，顶层为 `instrument`，工程包含 RTL、引脚约束和 27 MHz 时钟约束。工程配置已使能 **Use SSPI as regular IO**，供 52～56 脚上的灯带备用输出、UART 和 I²S 使用。在其他工程中导入源码时也要开启此项。
- **生成随包位流的方式**是 `python build.py`。需要 Yosys、nextpnr-himbaechel 和 Apycula 的 `gowin_pack` 在 PATH 上，也支持同名工具的 YoWASP 版本。此次使用 yowasp-yosys 0.70.0.0.post1259、yowasp-nextpnr-himbaechel-gowin 0.11.1.0.post826、apycula 0.32。布局布线用 27 MHz 约束，打包时显式加 `--sspi_as_gpio`。成功后位流在 `release/instrument.fs`，同目录附 SHA-256。
- **功能仿真**安装 Icarus Verilog 后运行 `python simulate.py`。四组自检均已通过，覆盖物理 I²S 数据解码和四音叠加、BLE UART 收发、APDS9930 总线与手势、顶层按键与 8 灯 GRB 数据及复位间隔。
- 带手势查询的位流按 **27 MHz** 通过布局布线时序检查。数字逻辑、引脚约束和位流生成已验证；传感距离与模块安装方式有关。
