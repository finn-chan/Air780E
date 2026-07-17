package.path = "script/?.lua;" .. package.path

local util_sms_control = require "util_sms_control"

local function assertEqual(actual, expected, message)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)))
    end
end

local normalized_number = "+8613800138000"
for _, number in ipairs({
    "13800138000",
    "86 138 0013 8000",
    "+86-138-0013-8000",
    "008613800138000"
}) do
    assertEqual(util_sms_control.normalizePhoneNumber(number), normalized_number, "normalize " .. number)
end

assertEqual(util_sms_control.normalizePhoneNumber("10010"), "10010", "keep service number")
assertEqual(util_sms_control.isWhiteListNumber({ "13800138000" }, "+8613800138000"), true, "match +86 sender")
assertEqual(util_sms_control.isWhiteListNumber({ [2] = "13800138000" }, "8613800138000"), true, "match sparse whitelist")
assertEqual(util_sms_control.isWhiteListNumber({ 13800138000 }, "+8613800138000"), true, "match numeric config")
assertEqual(util_sms_control.isWhiteListNumber({}, "13800138000"), false, "empty whitelist")

local receiver, content, parse_error = util_sms_control.parseCommand("SMS,10010,余额查询")
assertEqual(receiver, "10010", "parse receiver")
assertEqual(content, "余额查询", "parse content")
assertEqual(parse_error, nil, "parse without error")

receiver, content, parse_error = util_sms_control.parseCommand(" sms , +8610010 , 查询流量 ")
assertEqual(receiver, "+8610010", "parse case-insensitive command")
assertEqual(content, "查询流量", "trim content")
assertEqual(parse_error, nil, "parse flexible whitespace")

receiver, content, parse_error = util_sms_control.parseCommand("secret,SMS,10086,CXLL", "secret")
assertEqual(receiver, "10086", "parse token receiver")
assertEqual(content, "CXLL", "parse token content")
assertEqual(parse_error, nil, "parse token without error")

receiver, content, parse_error = util_sms_control.parseCommand("wrong,SMS,10086,CXLL", "secret")
assertEqual(receiver, nil, "reject wrong token")
assertEqual(parse_error, "控制口令不正确", "wrong token reason")

receiver, content, parse_error = util_sms_control.parseCommand("SMS,10,x")
assertEqual(receiver, nil, "reject short receiver")
assertEqual(parse_error, "目标号码长度不正确", "short receiver reason")

assertEqual(util_sms_control.looksLikeCommand("SMS,10010,101"), true, "detect command")
assertEqual(util_sms_control.looksLikeCommand("secret, sms,10010,101"), true, "detect token command")
assertEqual(util_sms_control.looksLikeCommand("普通 SMS 通知"), false, "ignore normal sms text")

assertEqual(
    util_sms_control.redactToken("secret,SMS,10086,CXLL", "secret"),
    "***,SMS,10086,CXLL",
    "redact token"
)
assertEqual(
    util_sms_control.redactToken("SMS,10086,CXLL", "secret"),
    "SMS,10086,CXLL",
    "do not redact normal message"
)

print("util_sms_control tests passed")
