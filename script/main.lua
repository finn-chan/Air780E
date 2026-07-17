PROJECT = "air780e_forwarder"
VERSION = "1.0.0"

log.setLevel("DEBUG")
log.info("main", PROJECT, VERSION)
log.info("main", "开机原因", pm.lastReson())

sys = require "sys"
sysplus = require "sysplus"

-- 添加硬狗防止程序卡死
wdt.init(9000)
sys.timerLoopStart(wdt.feed, 3000)

-- 设置电平输出 3.3V
-- pm.ioVol(pm.IOVOL_ALL_GPIO, 3300)

-- 设置 DNS
socket.setDNS(nil, 1, "119.29.29.29")
socket.setDNS(nil, 2, "223.5.5.5")

-- SIM 自动恢复, 周期性获取小区信息, 网络遇到严重故障时尝试自动恢复等功能
mobile.setAuto(10000, 30000, 8, true, 60000)

-- 开启 IPv6
-- mobile.ipv6(true)

-- 初始化 fskv
log.info("main", "fskv.init", fskv.init())

-- POWERKEY
local rtos_bsp = rtos.bsp()
local pin_table = { ["EC618"] = 35, ["EC718P"] = 46, ["EC718PV"] = 46 }
local powerkey_pin = pin_table[rtos_bsp]

if powerkey_pin then
    local button_last_press_time, button_last_release_time = 0, 0
    gpio.setup(powerkey_pin, function()
        local current_time = mcu.ticks()
        -- 按下
        if gpio.get(powerkey_pin) == 0 then
            button_last_press_time = current_time -- 记录最后一次按下时间
            return
        end
        -- 释放
        if button_last_press_time == 0 then -- 开机前已经按下, 开机后释放
            return
        end
        if current_time - button_last_release_time < 250 then -- 防止连按
            return
        end
        local duration = current_time - button_last_press_time -- 按键持续时间
        button_last_release_time = current_time -- 记录最后一次释放时间
        if duration > 2000 then
            log.debug("EVENT.POWERKEY_LONG_PRESS", duration)
            sys.publish("POWERKEY_LONG_PRESS", duration)
        elseif duration > 50 then
            log.debug("EVENT.POWERKEY_SHORT_PRESS", duration)
            sys.publish("POWERKEY_SHORT_PRESS", duration)
        end
    end, gpio.PULLUP, gpio.FALLING)
end

-- 加载模块
config = require "config"
util_http = require "util_http"
util_netled = require "util_netled"
util_mobile = require "util_mobile"
util_location = require "util_location"
util_notify = require "util_notify"
util_sms_control = require "util_sms_control"

-- 由于 NOTIFY_TYPE 支持多个配置, 需按照包含来判断
local containsValue = function(t, value)
    if t == value then return true end
    if type(t) ~= "table" then return false end
    for k, v in pairs(t) do if v == value then return true end end
    return false
end

if containsValue(config.NOTIFY_TYPE, "serial") then
    -- 串口配置
    uart.setup(1, 115200, 8, 1, uart.NONE)
    -- 串口接收回调
    uart.on(1, "receive", function(id, len)
        local data = uart.read(id, len)
        log.info("uart read:", id, len, data)
        if config.ROLE == "MASTER" then
            -- 主机, 通过队列发送数据
            util_notify.add(data)
        else
            -- 从机, 通过串口发送数据
            uart.write(1, data)
        end
    end)
end

-- 判断白名单号码是否符合触发短信控制的条件
local function isWhiteListNumber(sender_number)
    return util_sms_control.isWhiteListNumber(config.SMS_CONTROL_WHITELIST_NUMBERS, sender_number)
end

local pending_sms_control = nil

-- 新版固件会通过 SMS_SENT 返回真实发送结果；旧版固件不会触发此事件。
sys.subscribe("SMS_SENT", function(result)
    if not pending_sms_control then
        return
    end

    local control = pending_sms_control
    pending_sms_control = nil
    local result_text = result and "成功" or "失败"
    if result then
        log.info("smsControl", "短信发送成功", control.receiver_number)
    else
        log.warn("smsControl", "短信发送失败", control.receiver_number)
    end
    util_notify.add({
        "短信控制发送" .. result_text,
        "目标号码: " .. control.receiver_number,
        "控制号码: " .. control.sender_number,
        "#SMS #CTRL_RESULT" .. (result and "" or " #CTRL_FAILED")
    })
end)

-- 短信接收回调
sms.setNewSmsCb(function(sender_number, sms_content, m)
    local time = os.date("%Y-%m-%d %H:%M:%S")
    if type(m) == "table"
        and type(m.year) == "number"
        and type(m.mon) == "number"
        and type(m.day) == "number"
        and type(m.hour) == "number"
        and type(m.min) == "number"
        and type(m.sec) == "number" then
        time = string.format("%d/%02d/%02d %02d:%02d:%02d", m.year + 2000, m.mon, m.day, m.hour, m.min, m.sec)
    end

    sender_number = tostring(sender_number or "")
    sms_content = tostring(sms_content or "")
    local safe_sms_content = util_sms_control.redactToken(sms_content, config.SMS_CONTROL_TOKEN)
    log.info("smsCallback", time, sender_number, safe_sms_content)

    -- 短信控制
    local is_sms_ctrl = false
    local control_failed = false
    local looks_like_control = util_sms_control.looksLikeCommand(sms_content)
    -- 判断发送者是否为白名单号码
    if isWhiteListNumber(sender_number) then
        local receiver_number, sms_content_to_be_sent, parse_error =
            util_sms_control.parseCommand(sms_content, config.SMS_CONTROL_TOKEN)

        if receiver_number then
            local accepted = sms.send(receiver_number, sms_content_to_be_sent)
            if accepted then
                is_sms_ctrl = true
                pending_sms_control = {
                    receiver_number = receiver_number,
                    sender_number = sender_number
                }
                log.info("smsControl", "短信已进入发送队列", receiver_number)
            else
                control_failed = true
                log.warn("smsControl", "短信发送请求被拒绝，短信模块可能繁忙或当前网络不支持", receiver_number)
            end
        elseif parse_error and looks_like_control then
            control_failed = true
            log.warn("smsControl", parse_error, sender_number)
        end
    elseif looks_like_control then
        log.warn("smsControl", "发送号码不在白名单中", sender_number,
            util_sms_control.normalizePhoneNumber(sender_number) or "")
    end

    -- 发送通知
    util_notify.add({
        safe_sms_content,
        "",
        "发件号码: " .. sender_number,
        "发件时间: " .. time,
        "#SMS" .. (is_sms_ctrl and " #CTRL" or "") .. (control_failed and " #CTRL_FAILED" or "")
    })
end)

sys.taskInit(function()
    -- 等待网络环境准备就绪
    sys.waitUntil("IP_READY", 1000 * 60 * 5)

    util_netled.init()

    -- 开机通知
    if config.BOOT_NOTIFY then
        sys.timerStart(util_notify.add, 1000 * 5, "#BOOT_" .. pm.lastReson())
    end

    -- 定时同步时间
    if os.time() < 1714500000 then
        socket.sntp()
    end
    if type(config.SNTP_INTERVAL) == "number" and config.SNTP_INTERVAL >= 1000 * 60 then
        sys.timerLoopStart(socket.sntp, config.SNTP_INTERVAL)
    end

    -- 定时查询流量
    if type(config.QUERY_TRAFFIC_INTERVAL) == "number" and config.QUERY_TRAFFIC_INTERVAL >= 1000 * 60 then
        sys.timerLoopStart(util_mobile.queryTraffic, config.QUERY_TRAFFIC_INTERVAL)
    end

    -- 定时基站定位
    if type(config.LOCATION_INTERVAL) == "number" and config.LOCATION_INTERVAL >= 1000 * 60 then
        util_location.refresh(nil, true)
        sys.timerLoopStart(util_location.refresh, config.LOCATION_INTERVAL)
    end

    -- 定时上报
    if type(config.REPORT_INTERVAL) == "number" and config.REPORT_INTERVAL >= 1000 * 60 then
        sys.timerLoopStart(function() util_notify.add("#ALIVE_REPORT") end, config.REPORT_INTERVAL)
    end

    -- 电源键短按发送测试通知
    sys.subscribe("POWERKEY_SHORT_PRESS", function() util_notify.add("#ALIVE") end)
    -- 电源键长按查询流量
    sys.subscribe("POWERKEY_LONG_PRESS", util_mobile.queryTraffic)

    sys.wait(60000);
    -- EC618配置小区重选信号差值门限，不能大于15dbm，必须在飞行模式下才能用
    mobile.flymode(0, true)
    mobile.config(mobile.CONF_RESELTOWEAKNCELL, 10)
    mobile.config(mobile.CONF_STATICCONFIG, 1) -- 开启网络静态优化
    mobile.flymode(0, false)
end)

sys.taskInit(function()
    if type(config.PIN_CODE) ~= "string" or config.PIN_CODE == "" then
        return
    end
    -- 开机等待 5 秒仍未联网, 再进行 pin 验证
    if not sys.waitUntil("IP_READY", 1000 * 5) then
        util_mobile.pinVerify(config.PIN_CODE)
    end
end)

-- 定时开关飞行模式
if type(config.FLYMODE_INTERVAL) == "number" and config.FLYMODE_INTERVAL >= 1000 * 60 then
    sys.timerLoopStart(function()
        sys.taskInit(function()
            log.info("main", "定时开关飞行模式")
            mobile.reset()
            sys.wait(1000)
            mobile.flymode(0, true)
            mobile.flymode(0, false)
        end)
    end, config.FLYMODE_INTERVAL)
end

-- 通话相关
local is_calling = false

sys.subscribe("CC_IND", function(status)
    if cc == nil then return end

    if status == "INCOMINGCALL" then
        -- 来电事件, 期间会重复触发
        if is_calling then return end
        is_calling = true

        log.info("cc_status", "INCOMINGCALL", "来电事件", cc.lastNum())

        -- 发送通知
        util_notify.add({ "来电号码: " .. cc.lastNum(), "来电时间: " .. os.date("%Y-%m-%d %H:%M:%S"), "#CALL #CALL_IN" })
        return
    end

    if status == "DISCONNECTED" then
        -- 挂断事件
        is_calling = false
        log.info("cc_status", "DISCONNECTED", "挂断事件", cc.lastNum())

        -- 发送通知
        util_notify.add({ "来电号码: " .. cc.lastNum(), "挂断时间: " .. os.date("%Y-%m-%d %H:%M:%S"), "#CALL #CALL_DISCONNECTED" })
        return
    end

    log.info("cc_status", status)
end)

sys.run()
