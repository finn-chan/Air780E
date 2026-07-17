local lib_smtp = require "lib_smtp"

local function cloneTable(source, visited)
    if type(source) ~= "table" then
        return source
    end
    visited = visited or {}
    if visited[source] then
        return visited[source]
    end

    local result = {}
    visited[source] = result
    for k, v in pairs(source) do
        result[cloneTable(k, visited)] = cloneTable(v, visited)
    end
    return result
end

local function urlencodeTab(params)
    local msg = {}
    for k, v in pairs(params) do
        if type(v) == "table" then
            return nil, "application/x-www-form-urlencoded 不支持嵌套 table"
        end
        if type(k) ~= "string" and type(k) ~= "number" then
            return nil, "application/x-www-form-urlencoded 的字段名必须是字符串或数字"
        end
        if type(v) ~= "string" and type(v) ~= "number" and type(v) ~= "boolean" then
            return nil, "application/x-www-form-urlencoded 的字段值必须是字符串、数字或布尔值"
        end
        table.insert(msg, string.urlEncode(tostring(k)) .. "=" .. string.urlEncode(tostring(v)))
        table.insert(msg, "&")
    end
    table.remove(msg)
    return table.concat(msg)
end

local function findHeader(headers, name)
    local normalized_name = string.lower(name)
    for k, v in pairs(headers) do
        if type(k) == "string" and string.lower(k) == normalized_name then
            return k, v
        end
    end
end

return {
    -- 发送到 custom_post
    ["custom_post"] = function(msg)
        if config.CUSTOM_POST_URL == nil or config.CUSTOM_POST_URL == "" then
            log.error("util_notify", "未配置 `config.CUSTOM_POST_URL`")
            return
        end
        if type(config.CUSTOM_POST_BODY_TABLE) ~= "table" then
            log.error("util_notify", "未配置 `config.CUSTOM_POST_BODY_TABLE`")
            return
        end

        if config.CUSTOM_POST_HEADERS ~= nil and type(config.CUSTOM_POST_HEADERS) ~= "table" then
            log.error("util_notify", "`config.CUSTOM_POST_HEADERS` 必须是 table")
            return
        end

        local header = cloneTable(config.CUSTOM_POST_HEADERS or {})
        for k, v in pairs(header) do
            if type(k) ~= "string" then
                log.error("util_notify", "`config.CUSTOM_POST_HEADERS` 的字段名必须是字符串")
                return
            end
            if type(v) ~= "string" and type(v) ~= "number" and type(v) ~= "boolean" then
                log.error("util_notify", "`config.CUSTOM_POST_HEADERS` 的字段值必须是字符串、数字或布尔值", k)
                return
            end
            header[k] = tostring(v)
        end
        local content_type_key, content_type = findHeader(header, "content-type")
        if content_type == nil or content_type == "" then
            content_type = config.CUSTOM_POST_CONTENT_TYPE
        end
        if content_type == nil or content_type == "" then
            content_type = "application/x-www-form-urlencoded"
        end
        content_type = tostring(content_type)
        if content_type_key then
            header[content_type_key] = content_type
        else
            header["Content-Type"] = content_type
        end

        local body = cloneTable(config.CUSTOM_POST_BODY_TABLE)
        -- 遍历并替换其中的变量
        local function traverse_and_replace(t, visited)
            visited = visited or {}
            if visited[t] then
                return
            end
            visited[t] = true
            for k, v in pairs(t) do
                if type(v) == "table" then
                    traverse_and_replace(v, visited)
                elseif type(v) == "string" then
                    -- 使用函数作为替换值，避免通知内容中的 `%` 被 gsub 当作捕获引用。
                    t[k] = string.gsub(v, "{msg}", function()
                        return msg
                    end)
                end
            end
        end
        traverse_and_replace(body)

        -- 根据 content-type 进行编码, 默认为 application/x-www-form-urlencoded
        if string.find(string.lower(content_type), "json", 1, true) then
            local encode_ok, encoded_body = pcall(json.encode, body)
            if not encode_ok or type(encoded_body) ~= "string" then
                log.error("util_notify", "`config.CUSTOM_POST_BODY_TABLE` JSON 编码失败")
                return
            end
            body = encoded_body
        else
            local encode_error
            body, encode_error = urlencodeTab(body)
            if body == nil then
                log.error("util_notify", encode_error)
                return
            end
        end

        -- URL 可能包含 webhook token，body 可能包含短信正文，避免写入日志。
        log.info("util_notify", "POST", "custom_post", content_type)
        local res_code, res_headers, res_body = util_http.fetch(nil, "POST", config.CUSTOM_POST_URL, header, body)

        -- 有些接口在 HTTP 2xx 中通过响应正文表达业务失败，可按需配置成功关键字。
        local success_keyword = config.CUSTOM_POST_SUCCESS_BODY_KEYWORD
        if type(res_code) == "number"
            and res_code >= 200
            and res_code < 300
            and type(success_keyword) == "string"
            and success_keyword ~= ""
            and (type(res_body) ~= "string" or not string.find(res_body, success_keyword, 1, true)) then
            log.error("util_notify", "custom_post 响应正文未包含成功关键字", "code:", res_code)
            return res_code, res_headers, res_body, true
        end
        return res_code, res_headers, res_body
    end,
    -- 发送到 telegram
    ["telegram"] = function(msg)
        if config.TELEGRAM_API == nil or config.TELEGRAM_API == "" then
            log.error("util_notify", "未配置 `config.TELEGRAM_API`")
            return
        end
        if config.TELEGRAM_CHAT_ID == nil or config.TELEGRAM_CHAT_ID == "" then
            log.error("util_notify", "未配置 `config.TELEGRAM_CHAT_ID`")
            return
        end

        local header = { ["content-type"] = "application/json" }
        local body = { ["chat_id"] = config.TELEGRAM_CHAT_ID, ["disable_web_page_preview"] = true, ["text"] = msg }

        log.info("util_notify", "POST", config.TELEGRAM_API)
        return util_http.fetch(nil, "POST", config.TELEGRAM_API, header, json.encode(body))
    end,
    -- 发送到 gotify
    ["gotify"] = function(msg)
        if config.GOTIFY_API == nil or config.GOTIFY_API == "" then
            log.error("util_notify", "未配置 `config.GOTIFY_API`")
            return
        end
        if config.GOTIFY_TOKEN == nil or config.GOTIFY_TOKEN == "" then
            log.error("util_notify", "未配置 `config.GOTIFY_TOKEN`")
            return
        end

        local url = config.GOTIFY_API .. "/message?token=" .. config.GOTIFY_TOKEN
        local header = { ["Content-Type"] = "application/json; charset=utf-8" }
        local body = { title = config.GOTIFY_TITLE, message = msg, priority = config.GOTIFY_PRIORITY }

        log.info("util_notify", "POST", config.GOTIFY_API)
        return util_http.fetch(nil, "POST", url, header, json.encode(body))
    end,
    -- 发送到 pushdeer
    ["pushdeer"] = function(msg)
        if config.PUSHDEER_API == nil or config.PUSHDEER_API == "" then
            log.error("util_notify", "未配置 `config.PUSHDEER_API`")
            return
        end
        if config.PUSHDEER_KEY == nil or config.PUSHDEER_KEY == "" then
            log.error("util_notify", "未配置 `config.PUSHDEER_KEY`")
            return
        end

        local header = { ["Content-Type"] = "application/x-www-form-urlencoded" }
        local body = { pushkey = config.PUSHDEER_KEY or "", type = "text", text = msg }

        log.info("util_notify", "POST", config.PUSHDEER_API)
        return util_http.fetch(nil, "POST", config.PUSHDEER_API, header, urlencodeTab(body))
    end,
    -- 发送到 bark
    ["bark"] = function(msg)
        if config.BARK_API == nil or config.BARK_API == "" then
            log.error("util_notify", "未配置 `config.BARK_API`")
            return
        end
        if config.BARK_KEY == nil or config.BARK_KEY == "" then
            log.error("util_notify", "未配置 `config.BARK_KEY`")
            return
        end

        local header = { ["Content-Type"] = "application/x-www-form-urlencoded" }
        local body = { body = msg }
        local url = config.BARK_API .. "/" .. config.BARK_KEY

        log.info("util_notify", "POST", url)
        return util_http.fetch(nil, "POST", url, header, urlencodeTab(body))
    end,
    -- 发送到 dingtalk
    ["dingtalk"] = function(msg)
        if config.DINGTALK_WEBHOOK == nil or config.DINGTALK_WEBHOOK == "" then
            log.error("util_notify", "未配置 `config.DINGTALK_WEBHOOK`")
            return
        end

        local url = config.DINGTALK_WEBHOOK
        -- 如果配置了 config.DINGTALK_SECRET 则需要签名(加签), 没配置则为自定义关键词
        if (config.DINGTALK_SECRET and config.DINGTALK_SECRET ~= "") then
            -- 时间异常则等待同步
            if os.time() < 1714500000 then
                socket.sntp()
                sys.waitUntil("NTP_UPDATE", 1000 * 10)
            end
            local timestamp = tostring(os.time()) .. "000"
            local sign = crypto.hmac_sha256(timestamp .. "\n" .. config.DINGTALK_SECRET, config.DINGTALK_SECRET):fromHex():toBase64():urlEncode()
            url = url .. "&timestamp=" .. timestamp .. "&sign=" .. sign
        end

        local header = { ["Content-Type"] = "application/json; charset=utf-8" }
        local body = { msgtype = "text", text = { content = msg } }
        body = json.encode(body)

        log.info("util_notify", "POST", url)
        local res_code, res_headers, res_body = util_http.fetch(nil, "POST", url, header, body)

        -- 处理响应
        -- https://open.dingtalk.com/document/orgapp/custom-robots-send-group-messages
        if res_code == 200 and res_body and res_body ~= "" then
            local res_data = json.decode(res_body)
            local res_errcode = res_data.errcode or 0
            local res_errmsg = res_data.errmsg or ""
            -- 系统繁忙 / 发送速度太快而限流
            if res_errcode == -1 or res_errcode == 410100 then
                return 500, res_headers, res_body
            end
            -- timestamp 无效
            if res_errcode == 310000 and (string.find(res_errmsg, "timestamp") or string.find(res_errmsg, "过期")) then
                socket.sntp()
                return 500, res_headers, res_body
            end
        end
        return res_code, res_headers, res_body
    end,
    -- 发送到 feishu
    ["feishu"] = function(msg)
        if config.FEISHU_WEBHOOK == nil or config.FEISHU_WEBHOOK == "" then
            log.error("util_notify", "未配置 `config.FEISHU_WEBHOOK`")
            return
        end

        local header = { ["Content-Type"] = "application/json; charset=utf-8" }
        local body = { msg_type = "text", content = { text = msg } }

        log.info("util_notify", "POST", config.FEISHU_WEBHOOK)
        return util_http.fetch(nil, "POST", config.FEISHU_WEBHOOK, header, json.encode(body))
    end,
    -- 发送到 wecom
    ["wecom"] = function(msg)
        if config.WECOM_WEBHOOK == nil or config.WECOM_WEBHOOK == "" then
            log.error("util_notify", "未配置 `config.WECOM_WEBHOOK`")
            return
        end

        local header = { ["Content-Type"] = "application/json; charset=utf-8" }
        local body = { msgtype = "text", text = { content = msg } }

        log.info("util_notify", "POST", config.WECOM_WEBHOOK)
        local res_code, res_headers, res_body = util_http.fetch(nil, "POST", config.WECOM_WEBHOOK, header, json.encode(body))

        -- 处理响应
        -- https://developer.work.weixin.qq.com/document/path/90313
        if res_code == 200 and res_body and res_body ~= "" then
            local res_data = json.decode(res_body)
            local res_errcode = res_data.errcode or 0
            -- 系统繁忙 / 接口调用超过限制
            if res_errcode == -1 or res_errcode == 45009 then
                return 500, res_headers, res_body
            end
        end
        return res_code, res_headers, res_body
    end,
    -- 发送到 pushover
    ["pushover"] = function(msg)
        if config.PUSHOVER_API_TOKEN == nil or config.PUSHOVER_API_TOKEN == "" then
            log.error("util_notify", "未配置 `config.PUSHOVER_API_TOKEN`")
            return
        end
        if config.PUSHOVER_USER_KEY == nil or config.PUSHOVER_USER_KEY == "" then
            log.error("util_notify", "未配置 `config.PUSHOVER_USER_KEY`")
            return
        end

        local header = { ["Content-Type"] = "application/json; charset=utf-8" }
        local body = { token = config.PUSHOVER_API_TOKEN, user = config.PUSHOVER_USER_KEY, message = msg }
        local url = "https://api.pushover.net/1/messages.json"

        log.info("util_notify", "POST", url)
        return util_http.fetch(nil, "POST", url, header, json.encode(body))
    end,
    -- 发送到 inotify
    ["inotify"] = function(msg)
        if config.INOTIFY_API == nil or config.INOTIFY_API == "" then
            log.error("util_notify", "未配置 `config.INOTIFY_API`")
            return
        end
        if not config.INOTIFY_API:endsWith(".send") then
            log.error("util_notify", "`config.INOTIFY_API` 必须以 `.send` 结尾")
            return
        end

        local url = config.INOTIFY_API .. "/" .. string.urlEncode(msg)

        log.info("util_notify", "GET", url)
        return util_http.fetch(nil, "GET", url)
    end,
    -- 发送到 next-smtp-proxy
    ["next-smtp-proxy"] = function(msg)
        if config.NEXT_SMTP_PROXY_API == nil or config.NEXT_SMTP_PROXY_API == "" then
            log.error("util_notify", "未配置 `config.NEXT_SMTP_PROXY_API`")
            return
        end
        if config.NEXT_SMTP_PROXY_USER == nil or config.NEXT_SMTP_PROXY_USER == "" then
            log.error("util_notify", "未配置 `config.NEXT_SMTP_PROXY_USER`")
            return
        end
        if config.NEXT_SMTP_PROXY_PASSWORD == nil or config.NEXT_SMTP_PROXY_PASSWORD == "" then
            log.error("util_notify", "未配置 `config.NEXT_SMTP_PROXY_PASSWORD`")
            return
        end
        if config.NEXT_SMTP_PROXY_HOST == nil or config.NEXT_SMTP_PROXY_HOST == "" then
            log.error("util_notify", "未配置 `config.NEXT_SMTP_PROXY_HOST`")
            return
        end
        if config.NEXT_SMTP_PROXY_PORT == nil or config.NEXT_SMTP_PROXY_PORT == "" then
            log.error("util_notify", "未配置 `config.NEXT_SMTP_PROXY_PORT`")
            return
        end
        if config.NEXT_SMTP_PROXY_TO_EMAIL == nil or config.NEXT_SMTP_PROXY_TO_EMAIL == "" then
            log.error("util_notify", "未配置 `config.NEXT_SMTP_PROXY_TO_EMAIL`")
            return
        end

        local header = { ["Content-Type"] = "application/x-www-form-urlencoded" }
        local body = {
            user = config.NEXT_SMTP_PROXY_USER,
            password = config.NEXT_SMTP_PROXY_PASSWORD,
            host = config.NEXT_SMTP_PROXY_HOST,
            port = config.NEXT_SMTP_PROXY_PORT,
            form_name = config.NEXT_SMTP_PROXY_FORM_NAME,
            to_email = config.NEXT_SMTP_PROXY_TO_EMAIL,
            subject = config.NEXT_SMTP_PROXY_SUBJECT,
            text = msg,
        }

        log.info("util_notify", "POST", config.NEXT_SMTP_PROXY_API)
        return util_http.fetch(nil, "POST", config.NEXT_SMTP_PROXY_API, header, urlencodeTab(body))
    end,
    ["smtp"] = function(msg)
        local smtp_config = {
            host = config.SMTP_HOST,
            port = config.SMTP_PORT,
            username = config.SMTP_USERNAME,
            password = config.SMTP_PASSWORD,
            mail_from = config.SMTP_MAIL_FROM,
            mail_to = config.SMTP_MAIL_TO,
            tls_enable = config.SMTP_TLS_ENABLE,
        }
        local result = lib_smtp.send(msg, config.SMTP_MAIL_SUBJECT, smtp_config)
        log.info("util_notify", "SMTP", result.success, result.message, result.is_retry)
        if result.success then
            return 200, nil, result.message
        end
        if result.is_retry then
            return 500, nil, result.message
        end
        return 400, nil, result.message
    end,
    -- 发送到 serial
    ["serial"] = function(msg)
        uart.write(1, msg)
        log.info("util_notify", "serial", "消息已转发到串口")
        sys.wait(1000)
        return 200
    end,
}
