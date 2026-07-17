local util_sms_control = {}

local function trim(value)
    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- 统一短信号码格式。
--- 中国大陆手机号统一为 +86 格式，其他纯数字国际号码统一 00 前缀为 +。
--- 短号码和字母发送方保持原样，避免误改运营商服务号码。
-- @param number string|number
-- @return string|nil
function util_sms_control.normalizePhoneNumber(number)
    if type(number) == "number" then
        number = tostring(number)
    elseif type(number) ~= "string" then
        return nil
    end

    number = trim(number)
    if number == "" then
        return nil
    end

    local compact_number = number:gsub("[%s%-%(%)]+", "")
    if compact_number:match("^00%d+$") then
        compact_number = "+" .. compact_number:sub(3)
    end

    if compact_number:match("^%+%d+$") then
        return compact_number
    end

    if not compact_number:match("^%d+$") then
        return number
    end

    -- 中国大陆 11 位手机号。
    if #compact_number == 11 and compact_number:sub(1, 1) == "1" then
        return "+86" .. compact_number
    end

    -- 部分短信 PDU 会保留 86，但不会保留国际号码的 +。
    if #compact_number == 13
        and compact_number:sub(1, 2) == "86"
        and compact_number:sub(3, 3) == "1" then
        return "+" .. compact_number
    end

    return compact_number
end

--- 判断发送号码是否在白名单中。
-- @param whitelist table
-- @param sender_number string
-- @return boolean
function util_sms_control.isWhiteListNumber(whitelist, sender_number)
    if type(whitelist) ~= "table" then
        return false
    end

    local normalized_sender = util_sms_control.normalizePhoneNumber(sender_number)
    if not normalized_sender then
        return false
    end

    -- 使用 pairs 兼容稀疏数组；号码值同时兼容字符串和整数配置。
    for _, value in pairs(whitelist) do
        if util_sms_control.normalizePhoneNumber(value) == normalized_sender then
            return true
        end
    end
    return false
end

--- 解析短信控制指令。
--- 未配置 token: SMS,10010,余额查询
--- 已配置 token: token,SMS,10010,余额查询
-- @param sms_content string
-- @param configured_token string|nil
-- @return string|nil receiver_number
-- @return string|nil content_to_send
-- @return string|nil error_reason
function util_sms_control.parseCommand(sms_content, configured_token)
    if type(sms_content) ~= "string" then
        return nil, nil, "短信内容无效"
    end

    local command = trim(sms_content)
    local token = type(configured_token) == "string" and trim(configured_token) or ""

    if token ~= "" then
        if token:find(",", 1, true) then
            return nil, nil, "SMS_CONTROL_TOKEN 不能包含英文逗号"
        end

        local provided_token, command_without_token = command:match("^([^,]+),%s*(.+)$")
        if not provided_token or trim(provided_token) ~= token then
            return nil, nil, "控制口令不正确"
        end
        command = command_without_token
    end

    local command_name, receiver_number, content_to_send =
        command:match("^([%a]+)%s*,%s*(%+?%d+)%s*,(.*)$")

    if not command_name or command_name:upper() ~= "SMS" then
        return nil, nil, "控制指令格式不正确"
    end

    content_to_send = trim(content_to_send)
    if content_to_send == "" then
        return nil, nil, "待发送短信内容为空"
    end

    local number_without_plus = receiver_number:gsub("^%+", "")
    if #number_without_plus < 3 or #number_without_plus > 20 then
        return nil, nil, "目标号码长度不正确"
    end

    return receiver_number, content_to_send, nil
end

--- 判断短信是否看起来像控制指令，用于区分普通短信和格式错误的控制短信。
-- @param sms_content string
-- @return boolean
function util_sms_control.looksLikeCommand(sms_content)
    if type(sms_content) ~= "string" then
        return false
    end

    local command = trim(sms_content):upper()
    return command:match("^SMS%s*,") ~= nil
        or command:match("^[^,]+,%s*SMS%s*,") ~= nil
end

--- 避免控制口令出现在日志和通知正文中。
-- @param sms_content string
-- @param configured_token string|nil
-- @return string
function util_sms_control.redactToken(sms_content, configured_token)
    if type(sms_content) ~= "string" then
        return ""
    end

    local token = type(configured_token) == "string" and trim(configured_token) or ""
    if token == "" then
        return sms_content
    end

    local leading_space, provided_token, remaining_content =
        sms_content:match("^(%s*)([^,]+),(.*)$")
    if provided_token and trim(provided_token) == token then
        return leading_space .. "***," .. remaining_content
    end
    return sms_content
end

return util_sms_control
