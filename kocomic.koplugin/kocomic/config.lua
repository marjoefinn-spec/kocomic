--[[--
KoComic 配置读写。

所有配置保存在 KOReader settings 目录下的 kocomic.lua 中,
下载的漫画放在用户可见的下载目录,临时图片放在 cache 目录。
]]

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local util = require("util")

local Config = {
    -- 默认值(用户没设置过的项走这里)
    DEFAULTS = {
        api_host = "api.copy202601.com",
        image_size = "c1500x",     -- c800x 省流 / c1500x 清晰
        username = "",
        token = "",
        chapters_per_book = 1,     -- 每个 CBZ 包含多少话
        auto_open = true,          -- 下载完成后询问是否立即阅读
        keep_cache = false,        -- 打包后是否保留原始图片
        page_size = 21,            -- 列表每次拉取条数
        layout_mode = "auto",      -- auto 自动判断 / strip 条漫重裁 / page 原图分页
        split_spread = "rtl",      -- 跨页大图拆两页:none 不拆 / rtl 右→左 / ltr 左→右
        jpeg_quality = 85,         -- 重排后的图片质量
        auto_levels = true,        -- 自动色阶:把发灰的扫描件黑白点拉到位
        enhance_originals = false, -- 单页漫画的原图也做色阶(会重新编码)
        reader_contrast = 1.5,     -- 写进书里的对比度,KOReader 默认是 1.0
        append_comments = true,    -- 每话末尾附上本话吐槽
        comments_limit = 40,       -- 最多附多少条
        page_width = nil,          -- 裁页尺寸,nil = 跟着屏幕走
        page_height = nil,
        download_dir = nil,        -- nil 表示用默认目录
        mark_downloaded = true,    -- 章节列表标记已下载
    },
}

function Config:open()
    if not self.settings then
        self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/kocomic.lua")
    end
    return self.settings
end

function Config:get(key)
    local value = self:open():readSetting(key)
    if value == nil then
        return self.DEFAULTS[key]
    end
    return value
end

function Config:set(key, value)
    self:open():saveSetting(key, value)
    self:open():flush()
end

function Config:isLoggedIn()
    local token = self:get("token")
    return type(token) == "string" and token ~= ""
end

function Config:logout()
    self:set("token", "")
end

-- 下载目录(用户可见,存放最终的 CBZ)
function Config:getDownloadDir()
    local dir = self:get("download_dir")
    if type(dir) ~= "string" or dir == "" then
        local home = G_reader_settings:readSetting("home_dir")
            or require("apps/filemanager/filemanagerutil").getDefaultDir()
        dir = home .. "/漫画"
    end
    if not util.pathExists(dir) then
        util.makePath(dir)
    end
    return dir
end

-- 裁页用的目标尺寸,默认就是这块屏幕的大小
function Config:getPageWidth()
    local value = tonumber(self:get("page_width"))
    if value and value >= 200 then
        return math.floor(value)
    end
    return require("device").screen:getWidth()
end

function Config:getPageHeight()
    local value = tonumber(self:get("page_height"))
    if value and value >= 200 then
        return math.floor(value)
    end
    return require("device").screen:getHeight()
end

-- 缓存目录(下载中的原始图片,打包后默认删除)
function Config:getCacheDir()
    local dir = DataStorage:getDataDir() .. "/cache/kocomic"
    if not util.pathExists(dir) then
        util.makePath(dir)
    end
    return dir
end

return Config
