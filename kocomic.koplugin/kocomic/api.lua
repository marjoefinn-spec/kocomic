--[[--
拷贝漫画 App API 封装。

接口用法参考 kComics 的 bin/src/api/copymanga.py,
网络请求改用 KOReader 自带的 LuaSocket(socket.http 已内置 https 支持)。

所有函数的返回约定:成功返回数据,失败返回 nil 加一条中文错误信息。
]]

local Config = require("kocomic/config")
local JSON = require("json")
local ffiUtil = require("ffi/util")
local http = require("socket.http")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local ltn12 = require("ltn12")
local mime = require("mime")
local socket = require("socket")
local socketurl = require("socket.url")
local socketutil = require("socketutil")

local Api = {
    APP_VERSION = "2025.08.15",
    USER_AGENT = "COPY/3.0.0",
    PLATFORM = "1",
    REGION = "1",
}

-- —————————————— 小工具 ——————————————

-- JSON 里的 null 在 lua 侧不一定是 nil,统一收敛成字符串或默认值
local function asString(value, default)
    if type(value) == "string" and value ~= "" then
        return value
    end
    return default
end

local function asList(value)
    return type(value) == "table" and value or {}
end

local function encodeParams(params)
    local parts = {}
    for k, v in pairs(params) do
        parts[#parts + 1] = k .. "=" .. socketurl.escape(tostring(v))
    end
    return table.concat(parts, "&")
end

function Api:baseUrl()
    return "https://" .. Config:get("api_host")
end

function Api:url(path, params)
    local url = self:baseUrl() .. path
    if params and next(params) then
        url = url .. "?" .. encodeParams(params)
    end
    return url
end

function Api:headers(no_token)
    local headers = {
        ["User-Agent"] = self.USER_AGENT,
        ["Accept"] = "application/json",
        ["Accept-Encoding"] = "identity",
        ["version"] = self.APP_VERSION,
        ["platform"] = self.PLATFORM,
        ["region"] = self.REGION,
        -- 要 jpg 不要 webp:mupdf 打开 CBZ 时不认 webp
        ["webp"] = "0",
    }
    if not no_token then
        local token = Config:get("token")
        if type(token) == "string" and token ~= "" then
            headers["authorization"] = "Token " .. token
        end
    end
    return headers
end

-- —————————————— 请求 ——————————————

--- 发一次 HTTP 请求并解析 JSON,失败自动重试。
function Api:request(url, body, headers, retries)
    headers = headers or self:headers()
    retries = retries or 2
    if body then
        headers["Content-Type"] = "application/x-www-form-urlencoded;charset=UTF-8"
        headers["Content-Length"] = tostring(#body)
    end
    local last_err
    for attempt = 1, retries + 1 do
        local sink = {}
        socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
        local request = {
            url = url,
            method = body and "POST" or "GET",
            headers = headers,
            source = body and ltn12.source.string(body) or nil,
            sink = ltn12.sink.table(sink),
        }
        local code, resp_headers, status = socket.skip(1, http.request(request))
        socketutil:reset_timeout()
        local raw = table.concat(sink)
        logger.dbg("KoComic:", request.method, url, "->", code, #raw, "bytes")
        if raw ~= "" then
            local ok, parsed = pcall(JSON.decode, raw)
            if ok and type(parsed) == "table" then
                return parsed
            end
            last_err = "服务器返回的内容无法解析"
        elseif resp_headers == nil then
            last_err = "网络不可用(" .. tostring(status or code) .. ")"
        else
            last_err = "请求失败:" .. tostring(status or code)
        end
        if attempt <= retries then
            ffiUtil.sleep(1)
        end
    end
    return nil, last_err
end

--- 接口报错时文案里常常带着官网地址(比如 210 那条会说「请到官网更新最新 APP」,
--- 实测里面的 www.copy3000.com 对应的 api.copy3000.com 是活的)。
--- 顺手把这些域名记下来,以后域名换了自动查找时当线索用。
function Api.harvestHosts(message)
    if type(message) ~= "string" then
        return
    end
    local found = {}
    for domain in message:gmatch("https?://([%w%.%-]+)") do
        found[#found + 1] = "api." .. domain:gsub("^www%.", "")
    end
    if #found == 0 then
        return
    end
    local kept, seen = {}, {}
    for _, host in ipairs(found) do
        if not seen[host] then
            seen[host] = true
            kept[#kept + 1] = host
        end
    end
    for _, host in ipairs(Config:get("share_hosts") or {}) do
        if not seen[host] and #kept < 8 then
            seen[host] = true
            kept[#kept + 1] = host
        end
    end
    Config:set("share_hosts", kept)
end

--- 请求 + 校验业务返回码,直接给出 results。
function Api:call(url, body, headers)
    local res, err = self:request(url, body, headers)
    if not res then
        return nil, err
    end
    local code = tonumber(res.code)
    if code ~= 200 then
        local message = asString(res.message, asString(res.detail, "错误码 " .. tostring(res.code)))
        Api.harvestHosts(message)
        if code == 401 then
            message = "登录已过期,请重新登录"
        elseif code == 210 then
            message = "接口被风控(210):" .. message .. "\n可稍后再试,或登录一个账号"
        end
        return nil, message
    end
    return res.results or {}
end

-- —————————————— 数据整形 ——————————————

local function pickComic(item)
    if type(item) ~= "table" then
        return {}
    end
    if type(item.comic) == "table" then
        return item.comic
    end
    return item
end

local function authorNames(comic)
    local names = {}
    for _, author in ipairs(asList(comic.author)) do
        if type(author) == "table" and type(author.name) == "string" then
            names[#names + 1] = author.name
        end
    end
    return names
end

--- 从各种形状的「浏览记录」里抠出读到第几话。
-- 收藏列表里叫 last_browse{last_browse_id,last_browse_name},
-- /query 接口里叫 browse{chapter_id,chapter_name},还见过 chapter_uuid/name 的写法,
-- 一并认了,认不出来就当没有。
function Api.parseBrowse(source)
    if type(source) ~= "table" then
        return nil
    end
    local browse = source
    if type(source.last_browse) == "table" then
        browse = source.last_browse
    elseif type(source.browse) == "table" then
        browse = source.browse
    end
    if type(browse) ~= "table" then
        return nil
    end
    local id = asString(browse.chapter_id) or asString(browse.chapter_uuid)
        or asString(browse.last_browse_id)
    local name = asString(browse.chapter_name) or asString(browse.last_browse_name)
        or asString(browse.name)
    if not id and not name then
        return nil
    end
    return { chapter_id = id, chapter_name = name }
end

--- 这部漫画最新更新到第几话
local function latestChapter(comic)
    local name = asString(comic.last_chapter_name)
    if name then
        return name
    end
    if type(comic.last_chapter) == "table" then
        return asString(comic.last_chapter.name)
    end
    return nil
end

--- 把搜索/榜单/收藏里的一条记录整理成统一结构
function Api.toComic(item)
    local comic = pickComic(item)
    local browse = Api.parseBrowse(item)
    return {
        name = asString(comic.name, "未知作品"),
        path_word = asString(comic.path_word, ""),
        author = table.concat(authorNames(comic), "、"),
        cover = asString(comic.cover, ""),
        popular = tonumber(comic.popular) or 0,
        browse_name = browse and browse.chapter_name or nil,
        browse_id = browse and browse.chapter_id or nil,
        latest_name = latestChapter(comic),
    }
end

local function toComicList(results)
    local items = {}
    for _, item in ipairs(asList(results.list)) do
        local comic = Api.toComic(item)
        if comic.path_word ~= "" then
            items[#items + 1] = comic
        end
    end
    return items, tonumber(results.total) or #items
end

-- —————————————— 浏览 ——————————————

--- 关键词搜索
function Api:search(keyword, offset, limit)
    local results, err = self:call(self:url("/api/v3/search/comic", {
        limit = limit or Config:get("page_size"),
        offset = offset or 0,
        q = keyword,
        q_type = "",
        platform = self.PLATFORM,
    }))
    if not results then
        return nil, err
    end
    return toComicList(results)
end

--- 漫画列表,ordering 可用 -datetime_updated(最近更新)、-popular(人气)
function Api:comics(ordering, offset, limit)
    local results, err = self:call(self:url("/api/v3/comics", {
        limit = limit or Config:get("page_size"),
        offset = offset or 0,
        ordering = ordering or "-datetime_updated",
        platform = self.PLATFORM,
    }))
    if not results then
        return nil, err
    end
    return toComicList(results)
end

--- 排行榜,date_type: day / week / month / total
function Api:ranks(date_type, offset, limit)
    local results, err = self:call(self:url("/api/v3/ranks", {
        limit = limit or Config:get("page_size"),
        offset = offset or 0,
        date_type = date_type or "day",
        type = "",
    }))
    if not results then
        return nil, err
    end
    return toComicList(results)
end

-- 详情和章节列表一进一出翻好几次,缓存一下少挨点风控(force 参数可以强刷)
local info_cache = {}
local chapter_cache = {}

--- 漫画详情(不含章节,章节按分组另外拉)
function Api:comicInfo(path_word, force)
    if not force and info_cache[path_word] then
        return info_cache[path_word]
    end
    local results, err = self:call(self:url("/api/v3/comic2/" .. path_word, {
        platform = self.PLATFORM,
    }))
    if not results then
        return nil, err
    end
    local comic = type(results.comic) == "table" and results.comic or nil
    if not comic then
        return nil, "接口没有返回这部漫画的信息"
    end
    local tags = {}
    for _, theme in ipairs(asList(comic.theme)) do
        if type(theme) == "table" and type(theme.name) == "string" then
            tags[#tags + 1] = theme.name
        end
    end
    local status
    if type(comic.status) == "table" then
        status = asString(comic.status.display, "")
    else
        status = asString(comic.status, "")
    end
    local groups = {}
    for _, group in pairs(type(results.groups) == "table" and results.groups or {}) do
        if type(group) == "table" and asString(group.path_word) then
            groups[#groups + 1] = {
                name = asString(group.name, "默认"),
                path_word = group.path_word,
                count = tonumber(group.count) or 0,
            }
        end
    end
    -- default 分组永远排在最前
    table.sort(groups, function(a, b)
        if (a.path_word == "default") ~= (b.path_word == "default") then
            return a.path_word == "default"
        end
        return a.name < b.name
    end)
    if #groups == 0 then
        groups = { { name = "默认", path_word = "default", count = 0 } }
    end
    local info = {
        name = asString(comic.name, "未知作品"),
        path_word = asString(comic.path_word, path_word),
        cover = asString(comic.cover, ""),
        authors = table.concat(authorNames(comic), "、"),
        tags = table.concat(tags, " / "),
        brief = asString(comic.brief, ""),
        status = status,
        updated = asString(comic.datetime_updated, ""),
        popular = tonumber(comic.popular) or 0,
        groups = groups,
    }
    info_cache[path_word] = info
    return info
end

--- 取某个分组下的全部章节(接口一次最多 100 条)
function Api:chapters(path_word, group_path, force)
    local cache_key = path_word .. "/" .. group_path
    if not force and chapter_cache[cache_key] then
        return chapter_cache[cache_key]
    end
    local chapters = {}
    local offset = 0
    while true do
        local results, err = self:call(self:url(
            "/api/v3/comic/" .. path_word .. "/group/" .. group_path .. "/chapters",
            { limit = 100, offset = offset }))
        if not results then
            return nil, err
        end
        local list = asList(results.list)
        for _, chapter in ipairs(list) do
            if type(chapter) == "table" and asString(chapter.uuid) then
                chapters[#chapters + 1] = {
                    uuid = chapter.uuid,
                    name = asString(chapter.name, "未命名"),
                    index = tonumber(chapter.index) or #chapters,
                    size = tonumber(chapter.size) or 0,
                }
            end
        end
        local total = tonumber(results.total) or #chapters
        offset = offset + 100
        if #list == 0 or offset >= total then
            break
        end
    end
    table.sort(chapters, function(a, b) return a.index < b.index end)
    if #chapters == 0 then
        return nil, "这个分组下没有章节"
    end
    chapter_cache[cache_key] = chapters
    return chapters
end

--- 章节图片列表,返回 { {url=, index=}, ... }
function Api:chapterPages(path_word, chapter_uuid)
    local results, err = self:call(self:url(
        "/api/v3/comic/" .. path_word .. "/chapter2/" .. chapter_uuid,
        { platform = self.PLATFORM }))
    if not results then
        return nil, err
    end
    local chapter = type(results.chapter) == "table" and results.chapter or {}
    local contents = asList(chapter.contents)
    local words = asList(chapter.words)
    local size = Config:get("image_size")
    local pages = {}
    for i, content in ipairs(contents) do
        local url = type(content) == "table" and asString(content.url) or nil
        if url then
            -- 图片地址里带着尺寸(.../c800x.jpg),换成设置里的清晰度
            url = url:gsub("c%d+x%.", size .. ".")
            pages[#pages + 1] = {
                url = url,
                index = (tonumber(words[i]) or (i - 1)) + 1,
            }
        end
    end
    table.sort(pages, function(a, b) return a.index < b.index end)
    if #pages == 0 then
        return nil, "这一话没有可下载的图片"
    end
    return pages
end

-- —————————————— 吐槽(章节评论)——————————————

--- 一话的吐槽。拷贝漫画管章节评论叫「吐槽」,接口一次最多给 100 条,免登录可读。
function Api:chapterComments(chapter_uuid, want)
    want = math.max(1, tonumber(want) or 40)
    local comments = {}
    local offset = 0
    while #comments < want do
        local batch = math.min(100, want - #comments)
        local results, err = self:call(self:url("/api/v3/roasts", {
            chapter_id = chapter_uuid,
            limit = batch,
            offset = offset,
        }))
        if not results then
            return nil, err
        end
        local list = asList(results.list)
        for _, item in ipairs(list) do
            local text = type(item) == "table" and asString(item.comment)
            if text then
                comments[#comments + 1] = {
                    user = asString(item.user_name, "匿名"),
                    time = (asString(item.create_at, "")):sub(1, 10),
                    text = text,
                }
            end
        end
        local total = tonumber(results.total) or #comments
        offset = offset + batch
        if #list == 0 or offset >= total then
            break
        end
    end
    return comments
end

-- —————————————— 账号 ——————————————

function Api:login(username, password)
    local salt = 1729
    local encoded = mime.b64(password .. "-" .. salt)
    local body = encodeParams({
        username = username,
        password = encoded,
        salt = salt,
    })
    local results, err = self:call(self:url("/api/v3/login"), body, self:headers(true))
    if not results then
        return nil, err
    end
    local token = asString(results.token)
    if not token then
        return nil, "登录失败:服务器没有返回 token"
    end
    return token
end

function Api:favorites(offset, limit)
    local results, err = self:call(self:url("/api/v3/member/collect/comics", {
        limit = limit or 36,
        offset = offset or 0,
        free_type = 1,
        ordering = "-datetime_updated",
    }))
    if not results then
        return nil, err
    end
    return toComicList(results)
end

--- 账号那边对这部漫画的记录:收藏了没、读到第几话。
-- 没登录的话服务器会把 collect/browse 都返回 null(不报错)。
function Api:comicStatus(path_word)
    local results, err = self:call(self:url("/api/v3/comic2/" .. path_word .. "/query"))
    if not results then
        return nil, err
    end
    local collect = results.collect
    local browse = Api.parseBrowse(results)
    return {
        logged_in = results.is_login == true,
        collected = type(collect) == "table" or type(collect) == "number",
        browse_id = browse and browse.chapter_id or nil,
        browse_name = browse and browse.chapter_name or nil,
    }
end

function Api:isFavorite(path_word)
    local status, err = self:comicStatus(path_word)
    if not status then
        return nil, err
    end
    return status.collected
end

function Api:setFavorite(path_word, is_collect)
    local results, err = self:call(self:url("/api/v3/comic2/" .. path_word,
        { platform = self.PLATFORM }))
    if not results then
        return nil, err
    end
    local comic = type(results.comic) == "table" and results.comic or {}
    local comic_id = asString(comic.uuid)
    if not comic_id then
        return nil, "没能取到这部漫画的 uuid"
    end
    local body = encodeParams({
        comic_id = comic_id,
        is_collect = is_collect and 1 or 0,
        authorization = "Token " .. Config:get("token"),
    })
    local ok, post_err = self:call(self:url("/api/v3/member/collect/comic"), body)
    if not ok then
        return nil, post_err
    end
    return true
end

-- —————————————— 下载 ——————————————

--- 下载一张图片到本地。先写 .part 再改名,中断不会留下半张图。
function Api:downloadImage(url, target_path, retries)
    retries = retries or 2
    local temp_path = target_path .. ".part"
    local last_err
    for attempt = 1, retries + 1 do
        local file = io.open(temp_path, "wb")
        if not file then
            return nil, "无法写入:" .. target_path
        end
        socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
        local code, resp_headers, status = socket.skip(1, http.request{
            url = url,
            headers = {
                ["User-Agent"] = self.USER_AGENT,
                ["Accept-Encoding"] = "identity",
            },
            sink = ltn12.sink.file(file),
        })
        socketutil:reset_timeout()
        if code == 200 and (lfs.attributes(temp_path, "size") or 0) > 0 then
            os.remove(target_path)
            if os.rename(temp_path, target_path) then
                return true
            end
            last_err = "改名失败"
        elseif code == 200 then
            last_err = "下载到的图片是空的"
        else
            last_err = "HTTP " .. tostring(status or code)
        end
        os.remove(temp_path)
        if attempt <= retries then
            ffiUtil.sleep(1)
        end
    end
    return nil, last_err
end

return Api
