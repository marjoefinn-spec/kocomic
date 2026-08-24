--[[--
KoComic —— 在 KOReader 里看拷贝漫画。

移植自 kComics(https://github.com/lxdklp/kComics,GPL-3.0):
接口调用照搬,界面全部改用 KOReader 的部件,
下载产物从 MOBI 换成 CBZ —— KOReader 自己就能直接翻。
]]

local Browser = require("kocomic/browser")
local Config = require("kocomic/config")
local Dispatcher = require("dispatcher")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local KoComic = WidgetContainer:extend{
    name = "kocomic",
}

function KoComic:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function KoComic:onDispatcherRegisterActions()
    Dispatcher:registerAction("kocomic_open", {
        category = "none",
        event = "ShowKoComic",
        title = "看漫画 KoComic",
        general = true,
    })
end

function KoComic:addToMainMenu(menu_items)
    menu_items.kocomic = {
        text = "看漫画 KoComic",
        sorting_hint = "search",
        callback = function()
            self:onShowKoComic()
        end,
    }
end

function KoComic:onShowKoComic()
    if self.browser then
        return true
    end
    -- 保证目录存在,免得第一次用就在各种地方报错
    Config:getDownloadDir()
    Config:getCacheDir()
    self.browser = Browser:new{
        ui = self.ui,
        close_callback = function()
            self.browser = nil
        end,
    }
    UIManager:show(self.browser)
    return true
end

return KoComic
