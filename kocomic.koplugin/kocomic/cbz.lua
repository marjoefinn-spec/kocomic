--[[--
把下载好的图片打包成 CBZ(其实就是一个 zip)。

用 KOReader 自带的 libarchive 绑定写包,压缩方式选 store ——
漫画图片本身已经压过了,再 deflate 一遍只会白费 CPU 和电量。
]]

local Archiver = require("ffi/archiver")
local logger = require("logger")

local Cbz = {}

--- 按文件头认出图片格式,决定放进包里的扩展名。
--- mupdf 是靠扩展名决定要不要解这一项的,名字给错了就会漏页。
function Cbz.detectExtension(data)
    if not data or #data < 12 then
        return nil
    end
    if data:sub(1, 3) == "\255\216\255" then
        return "jpg"
    end
    if data:sub(1, 8) == "\137PNG\r\n\26\n" then
        return "png"
    end
    if data:sub(1, 4) == "GIF8" then
        return "gif"
    end
    if data:sub(1, 4) == "RIFF" and data:sub(9, 12) == "WEBP" then
        return "webp"
    end
    return nil
end

local function readFile(path)
    local file = io.open(path, "rb")
    if not file then
        return nil
    end
    local data = file:read("*a")
    file:close()
    return data
end

--- 打包。
-- @param out_path 目标 .cbz 路径
-- @param entries  { { path = 图片路径, name = 包内名字(不带扩展名) }, ... }
-- @return 成功返回 out_path 和一张格式统计表,失败返回 nil 加错误信息
function Cbz.create(out_path, entries)
    if not entries or #entries == 0 then
        return nil, "没有可打包的图片"
    end
    local temp_path = out_path .. ".tmp"
    os.remove(temp_path)
    local writer = Archiver.Writer:new()
    if not writer:open(temp_path, "zip") then
        return nil, writer.err or "无法创建 CBZ"
    end
    writer:setZipCompression("store")
    local stats = { count = 0, webp = 0, skipped = 0 }
    for _, entry in ipairs(entries) do
        local data = readFile(entry.path)
        local extension = data and Cbz.detectExtension(data)
        if not extension then
            stats.skipped = stats.skipped + 1
            logger.warn("KoComic: 跳过无法识别的图片", entry.path)
        else
            if extension == "webp" then
                stats.webp = stats.webp + 1
            end
            if not writer:addFileFromMemory(entry.name .. "." .. extension, data) then
                local err = writer.err or "写入失败"
                writer:close()
                os.remove(temp_path)
                return nil, err
            end
            stats.count = stats.count + 1
        end
    end
    writer:close()
    if stats.count == 0 then
        os.remove(temp_path)
        return nil, "没有一张图片能被识别"
    end
    os.remove(out_path)
    if not os.rename(temp_path, out_path) then
        os.remove(temp_path)
        return nil, "无法写入:" .. out_path
    end
    return out_path, stats
end

return Cbz
