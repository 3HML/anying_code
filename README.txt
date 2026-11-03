安映——基于国产FPGA的交互式多媒体展示终端
队伍编号：49962

本工程在单块安路FPGA开发板上实现TF卡图片显示、音乐播放、参数设置、串口交互、红外遥控及低功耗睡眠。

快速开始
1. 将整个AnYing_49962目录解压到本地较短英文路径，例如D:/AnYing_49962。
2. 使用安路TD 6.2.190657打开AnYing_Code/src/td_project/lab_ex5_i2s_v1.0.al。
   目标器件EG4S20BG256，顶层模块top。工程已配置引脚、时钟和实现策略，可直接执行综合、布局布线及位流生成。
3. 使用AnYing_Code/bit/AnYing.bit配置开发板；将FAT32格式TF卡插入卡槽，HDMI B连接显示器。
4. 串口交互：双击AnYing_Code/tools/uart/Open_Serial_Control.cmd，选择CH340端口并连接。

目录说明
AnYing_Code/src/             完整HDL源码、厂商IP、工程配置、引脚和时序约束
AnYing_Code/bit/             可直接下载的位流
AnYing_Code/tools/uart/      串口上位机、启动脚本和使用说明
AnYing_Code/tools/media/     WAV音频格式转换脚本和素材要求
AnYing_Code/docs/           编译、操作、接线与遥控资料
AnYing_Code/reports/        资源、布局布线时序及综合告警
TF_Card/                    可直接复制到TF卡的图片与音乐
TF卡素材使用说明.txt          素材配置与复制方法
SHA256SUMS.txt               文件完整性校验清单

图片与音乐
图片：24位未压缩BMP，正高度，4:3，640×480～1280×960。
音频：48 kHz、16 bit、单声道PCM WAV，最多32首。
图片与音乐放在TF卡根目录，使用不同的英文短文件名。随附素材见TF_Card目录，复制方法见TF卡素材使用说明.txt；格式转换要求见AnYing_Code/tools/media/使用说明.txt。

使用资料
首次运行请阅读AnYing_Code/docs/编译与运行.txt和操作说明.txt。
红外模块接线与20键遥控映射见AnYing_Code/docs/红外模块资料。
