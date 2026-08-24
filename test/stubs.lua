--[[--
把 KOReader 的运行环境「假装」出来,好让插件能在电脑上跑起来做冒烟测试。

只补插件真正用到的那部分 API,行为跟真机上一致就行,不求完整。
真正联网的活儿(HTTP、zip、文件系统)交给 Python 那边的 PY.* 帮手。
]]

local PY = _G.PY
assert(PY, "需要先由 Python 注入 PY 帮手表")

local function preload(name, module)
    package.preload[name] = function() return module end
end

-- Windows 的 C 运行时不认 UTF-8 路径,而插件的成品文件名里全是中文。
-- 真机(Linux)上没这问题,这里把这几个调用转给 Python 处理。
os.rename = function(from, to) return PY.rename(from, to) end
os.remove = function(path) return PY.remove(path) end
local real_io_open = io.open
io.open = function(path, mode)
    if PY.needs_wide_path(path) then
        return PY.open_file(path, mode)
    end
    return real_io_open(path, mode)
end

-- —————————————— 基础工具 ——————————————

local unpack_ = table.unpack or unpack

local socket = {}
function socket.skip(n, ...)
    local values = { ... }
    local rest = {}
    for i = n + 1, select("#", ...) do
        rest[#rest + 1] = values[i]
    end
    return unpack_(rest)
end
function socket.sleep() end
preload("socket", socket)

local ltn12 = { sink = {}, source = {} }
function ltn12.sink.table(t)
    return function(chunk)
        if chunk then t[#t + 1] = chunk end
        return 1
    end
end
function ltn12.sink.file(handle)
    return function(chunk)
        if chunk then
            handle:write(chunk)
        else
            handle:close()
        end
        return 1
    end
end
function ltn12.source.string(text)
    local sent = false
    return function()
        if sent then return nil end
        sent = true
        return text
    end
end
preload("ltn12", ltn12)

local http = {}
function http.request(request)
    local body
    if request.source then
        local chunks = {}
        while true do
            local chunk = request.source()
            if not chunk or chunk == "" then break end
            chunks[#chunks + 1] = chunk
        end
        body = table.concat(chunks)
    end
    local code, data, headers = PY.http_request(request.method or "GET", request.url,
                                                request.headers, body)
    if request.sink then
        if data then request.sink(data) end
        request.sink(nil)
    end
    if code == 0 then
        return nil, "network error"
    end
    return 1, code, headers, "HTTP/1.1 " .. tostring(code)
end
preload("socket.http", http)

preload("socket.url", { escape = function(s) return PY.url_escape(s) end })
preload("mime", { b64 = function(s) return PY.b64(s) end })

local socketutil = {
    LARGE_BLOCK_TIMEOUT = 10, LARGE_TOTAL_TIMEOUT = 30,
    FILE_BLOCK_TIMEOUT = 15, FILE_TOTAL_TIMEOUT = 60,
}
function socketutil:set_timeout() end
function socketutil:reset_timeout() end
preload("socketutil", socketutil)

preload("json", {
    decode = function(text) return PY.json_decode(text) end,
    encode = function(value) return PY.json_encode(value) end,
})

local ffiUtil = {}
function ffiUtil.sleep() end
function ffiUtil.usleep() end
function ffiUtil.purgeDir(dir) return PY.purge_dir(dir) end
function ffiUtil.template(text) return text end
preload("ffi/util", ffiUtil)

local lfs = {}
function lfs.attributes(path, what) return PY.attributes(path, what) end
function lfs.dir(path)
    local names = PY.list_dir(path)
    assert(names, "打不开目录:" .. tostring(path))
    local i = 0
    return function()
        i = i + 1
        return names[i]
    end
end
function lfs.mkdir(path) return PY.makedirs(path) end
preload("libs/libkoreader-lfs", lfs)

local logger = {}
local function log(level)
    return function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
        print("[" .. level .. "] " .. table.concat(parts, " "))
    end
end
logger.dbg = function() end
logger.info = log("info")
logger.warn = log("warn")
logger.err = log("err")
preload("logger", logger)

-- —————————————— 存储 ——————————————

local DataStorage = {}
function DataStorage:getSettingsDir() return PY.test_dir() .. "/settings" end
function DataStorage:getDataDir() return PY.test_dir() end
preload("datastorage", DataStorage)

local LuaSettings = {}
function LuaSettings:open(path)
    local o = { path = path, data = {} }
    function o:readSetting(key) return self.data[key] end
    function o:saveSetting(key, value) self.data[key] = value end
    function o:flush() end
    return o
end
preload("luasettings", LuaSettings)

local util = {}
function util.getSafeFilename(str, path, limit)
    local name = tostring(str or "未知"):gsub("[\\/:%*%?\"<>|\r\n\t]", "_")
    if limit then name = name:sub(1, limit) end
    return name
end
function util.makePath(path) return PY.makedirs(path) end
function util.pathExists(path) return PY.exists(path) end
function util.removeFile(path) os.remove(path) end
function util.splitFilePathName(file) return file:match("(.*/)(.*)") end
preload("util", util)

-- 记下每本书写了哪些阅读设置,测试里要检查
_G.TEST_DOCSETTINGS = {}
local DocSettings = {}
function DocSettings:open(path)
    local store = { path = path, data = {} }
    function store:saveSetting(key, value) self.data[key] = value end
    function store:readSetting(key) return self.data[key] end
    function store:flush() TEST_DOCSETTINGS[self.path] = self.data end
    return store
end
preload("docsettings", DocSettings)

preload("apps/filemanager/filemanagerutil", { getDefaultDir = function() return PY.test_dir() end })
preload("apps/reader/readerui", { showReader = function(_, path) print("[open]", path) end })

-- —————————————— 打包 ——————————————

local Archiver = { Writer = {} }
function Archiver.Writer:new()
    local o = { entries = {} }
    setmetatable(o, self)
    self.__index = self
    return o
end
function Archiver.Writer:open(path, format)
    self.path, self.format, self.entries = path, format, {}
    return true
end
function Archiver.Writer:setZipCompression(method)
    self.method = method
    return true
end
function Archiver.Writer:addFileFromMemory(name, data)
    self.entries[#self.entries + 1] = { name, data }
    return true
end
function Archiver.Writer:close()
    if self.path then
        PY.zip_write(self.path, self.entries)
        self.path = nil
    end
end
preload("ffi/archiver", Archiver)

-- —————————————— 图像 ——————————————

-- 真机那份 imageutil 全是 FFI,电脑上跑不了,换成 Pillow 版
package.preload["kocomic/imageutil"] = function()
    return dofile(PY.test_dir_src() .. "/stub_imageutil.lua")
end

-- 只有 reader.lua 拿它取几个颜色常量,真正的画布操作都在 stub_imageutil 里
preload("ffi/blitbuffer", {
    COLOR_WHITE = 255, COLOR_BLACK = 0, COLOR_GRAY_3 = 0x33,
    TYPE_BB8 = 1, TYPE_BB8A = 2, TYPE_BBRGB24 = 4, TYPE_BBRGB32 = 5,
    new = function() error("测试环境里不该直接建 BlitBuffer") end,
})

local Device = {
    screen = {
        getWidth = function() return 1264 end,     -- Kindle Oasis 3
        getHeight = function() return 1680 end,
        scaleBySize = function(_, size) return math.floor(size) end,
    },
    input = { group = { Back = "Back", PgFwd = "RPgFwd", PgBack = "RPgBack" } },
    hasKeys = function() return true end,
    isTouchDevice = function() return true end,
    hasColorScreen = function() return false end,
}
preload("device", Device)

-- —————————————— UI ——————————————

-- 跟 KOReader 的 Widget 一样的继承方式,这样 Browser:extend/new 的行为才对得上
local Widget = {}
function Widget:extend(subclass)
    local o = subclass or {}
    setmetatable(o, self)
    self.__index = self
    return o
end
function Widget:new(o)
    o = self:extend(o)
    if o.init then o:init() end
    return o
end

_G.TEST = { shown = {}, log = {} }
local function record(kind, widget)
    TEST.shown[#TEST.shown + 1] = { kind = kind, widget = widget }
    TEST.log[#TEST.log + 1] = kind .. ": " .. tostring(widget and (widget.text or widget.title or widget.title_text) or "")
    return widget
end

local UIManager = {}
function UIManager:show(widget) record(widget and widget.widget_kind or "widget", widget) end
function UIManager:close() end
function UIManager:forceRePaint() end
function UIManager:setDirty() end
function UIManager:unschedule() end
function UIManager:nextTick(callback) callback() end
function UIManager:scheduleIn(_, callback) callback() end
function UIManager:unschedule() end
preload("ui/uimanager", UIManager)

local function simpleWidget(kind)
    local W = Widget:extend{ widget_kind = kind }
    return W
end

preload("ui/widget/infomessage", simpleWidget("InfoMessage"))
preload("ui/widget/confirmbox", simpleWidget("ConfirmBox"))
preload("ui/widget/buttondialog", simpleWidget("ButtonDialog"))
preload("ui/widget/inputdialog", (function()
    local D = simpleWidget("InputDialog")
    function D:getInputText() return TEST.next_input or "" end
    function D:onShowKeyboard() end
    return D
end)())
preload("ui/widget/multiinputdialog", (function()
    local D = simpleWidget("MultiInputDialog")
    function D:getFields() return TEST.next_fields or { "", "" } end
    function D:onShowKeyboard() end
    return D
end)())
preload("ui/widget/imageviewer", simpleWidget("ImageViewer"))
preload("ui/widget/textviewer", simpleWidget("TextViewer"))
preload("ui/widget/pathchooser", simpleWidget("PathChooser"))
preload("ui/widget/spinwidget", simpleWidget("SpinWidget"))

preload("ui/geometry", { new = function(_, o) return o or {} end })
preload("ui/gesturerange", { new = function(_, o) return o or {} end })
preload("ui/font", { getFace = function(_, _, size) return { size = size or 20 } end })
preload("ui/widget/imagewidget", (function()
    local W = simpleWidget("ImageWidget")
    function W:free() end
    return W
end)())
preload("ui/widget/textwidget", (function()
    local W = simpleWidget("TextWidget")
    function W:getSize() return { w = 160, h = 18 } end
    function W:paintTo() end
    function W:free() end
    return W
end)())
-- 真机上由 TextBoxWidget 断行排版,这里只估个高度,好让分页逻辑跑起来
preload("ui/widget/textboxwidget", (function()
    local W = simpleWidget("TextBoxWidget")
    -- 量高和画字都交给 Python 的 Pillow,这样吐槽页能导出来用眼睛看
    function W:getSize()
        local size = self.face and self.face.size or 20
        return {
            w = self.width or 600,
            h = PY.img_text_size(self.text or "", size, self.width or 600),
        }
    end
    function W:paintTo(bb, x, y)
        PY.img_text(bb.id, x, y, self.text or "",
            self.face and self.face.size or 20, self.width or 600)
    end
    function W:free() end
    return W
end)())

preload("ui/widget/container/inputcontainer", Widget:extend{})

local NetworkMgr = {}
function NetworkMgr:runWhenOnline(callback) callback() end
function NetworkMgr:isOnline() return true end
preload("ui/network/manager", NetworkMgr)

local Trapper = {}
function Trapper:wrap(func) func() end
function Trapper:info(text)
    if text then TEST.log[#TEST.log + 1] = "progress: " .. text:gsub("\n", " | ") end
    return true
end
function Trapper:reset() end
function Trapper:clear() end
function Trapper:setPausedText() end
preload("ui/trapper", Trapper)

-- Menu:照抄 KOReader 的关键行为(item_table / paths / switchItemTable)
local Menu = Widget:extend{ widget_kind = "Menu" }
function Menu:init()
    self.paths = {}
    self.page = 1
    self.item_table = self.item_table or {}
    self.title_bar = { left_button = { image = { dimen = {} } },
        setTitle = function() end, setSubTitle = function() end }
end
function Menu:switchItemTable(title, item_table, item_number, item_match, subtitle)
    if title then self.title = title end
    if subtitle then self.subtitle = subtitle end
    if item_table then self.item_table = item_table end
    self.selected_number = item_number
end
function Menu:setTitleBarLeftIcon() end
function Menu:onCloseAllMenus()
    TEST.log[#TEST.log + 1] = "menu closed"
    if self.close_callback then self.close_callback() end
    return true
end
function Menu:onClose() return self:onCloseAllMenus() end
preload("ui/widget/menu", Menu)

preload("ui/widget/container/widgetcontainer", Widget:extend{})
preload("dispatcher", { registerAction = function() end })
preload("gettext", setmetatable({ ngettext = function(_, b) return b end },
    { __call = function(_, text) return text end }))

_G.G_reader_settings = { readSetting = function() return nil end }

return true
