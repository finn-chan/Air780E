# Air700E / Air780E / Air780EP / Air780EPV 短信转发 来电通知

## 保姆级教程：https://kdocs.cn/l/coe1ozIlSX70

## :sparkles: Feature

- [x] 多种通知方式
    - [x] [Telegram](https://github.com/0wQ/telegram-notify)
    - [x] [PushDeer](https://www.pushdeer.com/)
    - [x] [Bark](https://github.com/Finb/Bark)
    - [x] [钉钉群机器人 DingTalk](https://open.dingtalk.com/document/robots/custom-robot-access)
    - [x] [飞书群机器人 Feishu](https://open.feishu.cn/document/ukTMukTMukTM/ucTM5YjL3ETO24yNxkjN)
    - [x] [企业微信群机器人 WeCom](https://developer.work.weixin.qq.com/document/path/91770)
    - [x] [Pushover](https://pushover.net/api)
    - [x] [邮件 next-smtp-proxy](https://github.com/0wQ/next-smtp-proxy)
    - [x] [Gotify](https://gotify.net)
    - [x] [Inotify](https://github.com/xpnas/Inotify) / [合宙官方的推送服务](https://push.luatos.org)
    - [x] 邮件 (SMTP协议)
- [x] 通过短信控制设备
    - [x] 发短信, 格式: `SMS,10010,余额查询`
- [x] 定时基站定位
- [x] 定时查询流量
- [x] 定时上报存活
- [x] 开机通知
- [x] POW 按键长按短按操作
- [x] 使用消息队列, 测试添加几百条通知, 不会卡死
- [x] 通知发送失败, 自动重发, 断电后再次开机可以恢复重发
- [x] 支持主从模式，一主对多从，从机通过串口转发消息，主机接受消息后转发到通知服务

## :hammer: Usage

https://mizore.notion.site/Air780E-e750efe0d6cc40c3baa276eeb811d534

### 短信控制

先在 `script/config.lua` 中配置允许控制设备的号码：

```lua
SMS_CONTROL_WHITELIST_NUMBERS = { "+8613800138000" },
```

`+86`、`86`、`0086` 和国内 11 位手机号会统一后再进行白名单判断。默认控制格式：

```text
SMS,10010,余额查询
```

建议同时设置 `SMS_CONTROL_TOKEN`。设置后需要把口令放在指令最前面：

```lua
SMS_CONTROL_TOKEN = "请替换为不含英文逗号的随机口令",
```

```text
请替换为不含英文逗号的随机口令,SMS,10010,余额查询
```

设备通知中的 `#CTRL` 表示发送请求已被短信模块接受，`#CTRL_FAILED` 表示解析或发送失败。支持
`SMS_SENT` 事件的新版固件还会发送带 `#CTRL_RESULT` 的最终结果通知。

### 运营商和固件兼容性

- 移动、联通卡通常可以直接使用短信功能。
- 电信短信依赖支持 CC/VoLTE 的模组和固件，并且 SIM 卡需要开通 VoLTE；经典 Air780E、Air780EP
  等型号的普通固件通常不支持电信短信。
- Air700E 的短信支持范围取决于具体子型号，部分型号仅支持移动卡。
- 物联网卡、纯流量卡可能没有开通短信能力，应先用普通手机卡验证收发短信。

短信能否收发是远程控制的前置条件。遇到运营商差异时，应先确认模组型号、烧录的 core 固件以及
SIM 卡本身是否支持短信。
